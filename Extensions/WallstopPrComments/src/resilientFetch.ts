import type { FetchLike } from './http';

/** Metadata handed to {@link ResilientFetchOptions.onRetry} before each backoff wait. */
export interface RetryInfo {
  /** Zero-based index of the attempt that just failed. */
  attempt: number;
  /** HTTP status that triggered the retry, when the failure was a response (absent for thrown errors). */
  status?: number;
  /** Milliseconds the resilient fetch will sleep before the next attempt. */
  waitMs: number;
  /** True when the wait was derived from a rate-limit signal rather than plain backoff. */
  rateLimited: boolean;
}

export interface ResilientFetchOptions {
  /** Retry attempts after the initial try (so total attempts = maxRetries + 1). Default 3. */
  maxRetries?: number;
  /** Base unit for exponential backoff in milliseconds. Default 500. */
  baseDelayMs?: number;
  /** Upper bound for a single backoff wait in milliseconds. Default 30_000. */
  maxDelayMs?: number;
  /** Upper bound for a single rate-limit (`Retry-After`/`x-ratelimit-reset`) wait. Default 60_000. */
  maxRateLimitWaitMs?: number;
  /** Per-attempt timeout in milliseconds; `0`/undefined disables the abort timer. Default 30_000. */
  perAttemptTimeoutMs?: number;
  /** Injected sleep so tests resolve instantly; defaults to a real `setTimeout` delay. */
  sleep?: (ms: number) => Promise<void>;
  /** Injected clock for `Retry-After`/rate-limit math; defaults to {@link Date.now}. */
  now?: () => number;
  /** Injected RNG in `[0, 1)` for jitter; defaults to {@link Math.random}. */
  random?: () => number;
  /** Observer invoked right before each backoff wait (for logging/telemetry). */
  onRetry?: (info: RetryInfo) => void;
}

const DEFAULT_MAX_RETRIES = 3;
const DEFAULT_BASE_DELAY_MS = 500;
const DEFAULT_MAX_DELAY_MS = 30_000;
const DEFAULT_MAX_RATE_LIMIT_WAIT_MS = 60_000;
const DEFAULT_PER_ATTEMPT_TIMEOUT_MS = 30_000;

/** HTTP statuses that are safe to retry as transient even without a rate-limit signal. */
const RETRYABLE_STATUSES = new Set([408, 429, 500, 502, 503, 504]);

interface RetryPlan {
  waitMs: number;
  rateLimited: boolean;
}

/**
 * Wraps a {@link FetchLike} with retry, exponential backoff + jitter, `Retry-After`
 * and GitHub primary/secondary rate-limit handling, and a per-attempt abort timeout.
 *
 * Body-read-once safety: a response is classified from its status + headers only.
 * A non-retryable response is returned untouched (the caller still owns its body).
 * When the final retry is exhausted on a retryable status whose body had to be read
 * for classification (secondary rate-limit detection), the body is reconstructed via
 * `new Response(text, { status, headers })` so the caller can still read it.
 *
 * Plain `401`/`403` auth failures are intentionally NOT retried (a bare 403 without a
 * rate-limit signal is treated as authorization, preserving the GraphQL-auth -> REST
 * fallback paths in {@link GitHubClient}).
 */
export function createResilientFetch(fetch: FetchLike, options: ResilientFetchOptions = {}): FetchLike {
  const maxRetries = Math.max(0, options.maxRetries ?? DEFAULT_MAX_RETRIES);
  const baseDelayMs = options.baseDelayMs ?? DEFAULT_BASE_DELAY_MS;
  const maxDelayMs = options.maxDelayMs ?? DEFAULT_MAX_DELAY_MS;
  const maxRateLimitWaitMs = options.maxRateLimitWaitMs ?? DEFAULT_MAX_RATE_LIMIT_WAIT_MS;
  const perAttemptTimeoutMs = options.perAttemptTimeoutMs ?? DEFAULT_PER_ATTEMPT_TIMEOUT_MS;
  const sleep = options.sleep ?? realSleep;
  const now = options.now ?? Date.now;
  const random = options.random ?? Math.random;
  const onRetry = options.onRetry;

  return async (input, init) => {
    let attempt = 0;
    for (;;) {
      const isLastAttempt = attempt >= maxRetries;

      let response: Response;
      try {
        response = await fetch(input, withTimeoutSignal(init, perAttemptTimeoutMs));
      } catch (error) {
        if (isLastAttempt || !isRetryableNetworkError(error)) {
          throw error;
        }

        const waitMs = backoffDelay(attempt, baseDelayMs, maxDelayMs, random);
        onRetry?.({ attempt, status: undefined, waitMs, rateLimited: false });
        await sleep(waitMs);
        attempt += 1;
        continue;
      }

      const plan = await planRetry(response, attempt, {
        baseDelayMs,
        maxDelayMs,
        maxRateLimitWaitMs,
        now,
        random,
      });
      if (plan === undefined) {
        // Non-retryable: hand back a response the caller can read. Classification may have consumed
        // the body (e.g. a plain 403 read to rule out a secondary rate limit), so reconstruct it when
        // needed — otherwise the original is returned untouched. Mirrors the exhausted-retry branch.
        return restoreReadableResponse(response);
      }

      if (isLastAttempt) {
        // Out of retries on a retryable status: hand back a body the caller can read.
        return restoreReadableResponse(response);
      }

      onRetry?.({ attempt, status: response.status, waitMs: plan.waitMs, rateLimited: plan.rateLimited });
      await sleep(plan.waitMs);
      attempt += 1;
    }
  };
}

interface RetryPlanContext {
  baseDelayMs: number;
  maxDelayMs: number;
  maxRateLimitWaitMs: number;
  now: () => number;
  random: () => number;
}

/**
 * Decides whether a response should be retried and how long to wait. Returns
 * `undefined` for non-retryable responses (which must be returned untouched).
 *
 * NOTE: this may consume the response body (for secondary rate-limit detection on a
 * 403), so a retryable response classified here can no longer be read directly; callers
 * giving up must use {@link restoreReadableResponse} to reconstruct it.
 */
async function planRetry(response: Response, attempt: number, context: RetryPlanContext): Promise<RetryPlan | undefined> {
  const { status } = response;

  // 429 is always a rate limit; wait per Retry-After / x-ratelimit-reset (header or backoff).
  if (status === 429) {
    return {
      waitMs: rateLimitWaitMs(response, context),
      rateLimited: true,
    };
  }

  // Primary rate limit on a 403: the remaining-quota header is exhausted.
  if (status === 403 && response.headers.get('x-ratelimit-remaining') === '0') {
    return {
      waitMs: rateLimitWaitMs(response, context),
      rateLimited: true,
    };
  }

  if (status === 403) {
    // A 403 is only retryable when it is a secondary rate limit; otherwise it is auth.
    const retryAfter = response.headers.get('retry-after');
    const text = await response.text();
    storeConsumedBody(response, text);
    if (isSecondaryRateLimit(text) || retryAfter !== null) {
      return {
        waitMs: rateLimitWaitMs(response, context),
        rateLimited: true,
      };
    }
    return undefined;
  }

  if (RETRYABLE_STATUSES.has(status)) {
    const retryAfter = parseRetryAfter(response.headers.get('retry-after'), context.now);
    if (retryAfter !== undefined) {
      return {
        waitMs: Math.min(retryAfter, context.maxRateLimitWaitMs),
        rateLimited: true,
      };
    }
    return {
      waitMs: backoffDelay(attempt, context.baseDelayMs, context.maxDelayMs, context.random),
      rateLimited: false,
    };
  }

  return undefined;
}

/** Computes a rate-limit wait from `Retry-After` (preferred) or `x-ratelimit-reset`, capped. */
function rateLimitWaitMs(response: Response, context: RetryPlanContext): number {
  const retryAfter = parseRetryAfter(response.headers.get('retry-after'), context.now);
  if (retryAfter !== undefined) {
    return clampWait(retryAfter, context.maxRateLimitWaitMs);
  }

  const reset = Number.parseInt(response.headers.get('x-ratelimit-reset') ?? '', 10);
  if (Number.isFinite(reset)) {
    const waitMs = reset * 1000 - context.now();
    return clampWait(waitMs, context.maxRateLimitWaitMs);
  }

  return clampWait(context.baseDelayMs, context.maxRateLimitWaitMs);
}

function clampWait(waitMs: number, maxWaitMs: number): number {
  if (!Number.isFinite(waitMs) || waitMs < 0) {
    return 0;
  }
  return Math.min(waitMs, maxWaitMs);
}

/** Parses a `Retry-After` header (delta-seconds or HTTP-date) into milliseconds. */
function parseRetryAfter(headerValue: string | null, now: () => number): number | undefined {
  if (headerValue === null) {
    return undefined;
  }

  const trimmed = headerValue.trim();
  if (trimmed === '') {
    return undefined;
  }

  const seconds = Number(trimmed);
  if (Number.isFinite(seconds)) {
    return Math.max(0, seconds * 1000);
  }

  const dateMs = Date.parse(trimmed);
  if (Number.isFinite(dateMs)) {
    return Math.max(0, dateMs - now());
  }

  return undefined;
}

/** Full-jitter exponential backoff: a uniform sample of `[base, base*2^attempt]`, capped. */
function backoffDelay(attempt: number, baseDelayMs: number, maxDelayMs: number, random: () => number): number {
  const ceiling = Math.min(baseDelayMs * 2 ** attempt, maxDelayMs);
  const floor = Math.min(baseDelayMs, ceiling);
  const span = ceiling - floor;
  return Math.round(floor + span * clampUnit(random()));
}

function clampUnit(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(1, Math.max(0, value));
}

function isSecondaryRateLimit(body: string): boolean {
  return /secondary rate limit/i.test(body);
}

function isRetryableNetworkError(error: unknown): boolean {
  // A timeout abort or a transport-level rejection (e.g. TypeError: fetch failed) is transient.
  return error instanceof Error;
}

/**
 * Builds a fresh `RequestInit` that attaches a per-attempt timeout `AbortSignal`,
 * combined with any caller-supplied signal so either source can abort the attempt.
 */
function withTimeoutSignal(init: RequestInit | undefined, perAttemptTimeoutMs: number): RequestInit | undefined {
  if (perAttemptTimeoutMs <= 0) {
    return init;
  }

  const timeoutSignal = AbortSignal.timeout(perAttemptTimeoutMs);
  const callerSignal = init?.signal ?? undefined;
  const signal = callerSignal === undefined ? timeoutSignal : anySignal([callerSignal, timeoutSignal]);
  return { ...(init ?? {}), signal };
}

/** Combines abort signals; falls back to the timeout signal if `AbortSignal.any` is unavailable. */
function anySignal(signals: AbortSignal[]): AbortSignal {
  const combiner = (AbortSignal as { any?: (signals: AbortSignal[]) => AbortSignal }).any;
  if (typeof combiner === 'function') {
    return combiner(signals);
  }
  return signals[signals.length - 1];
}

// Cache of bodies consumed during classification, keyed by the original Response.
const consumedBodies = new WeakMap<Response, string>();

function storeConsumedBody(response: Response, text: string): void {
  consumedBodies.set(response, text);
}

/**
 * Returns a response whose body the caller can still read. If classification consumed
 * the original body, reconstruct it; otherwise return the original untouched.
 */
function restoreReadableResponse(response: Response): Response {
  const consumed = consumedBodies.get(response);
  if (consumed !== undefined) {
    return new Response(consumed, { status: response.status, headers: response.headers });
  }
  return response;
}

function realSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
