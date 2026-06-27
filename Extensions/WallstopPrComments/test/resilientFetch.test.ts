import assert from 'node:assert/strict';
import test from 'node:test';

import { createResilientFetch } from '../src/resilientFetch';
import type { FetchLike } from '../src/http';

/**
 * Build a fetch double that returns the queued responses in order.
 * Each entry is either a `Response`, or a function producing one (so we can
 * observe the per-call init, e.g. the injected AbortSignal).
 */
function queue(...entries: Array<Response | ((input: string, init?: RequestInit) => Response | Promise<Response>)>): {
  fetch: FetchLike;
  calls: Array<{ input: string; init?: RequestInit }>;
} {
  const calls: Array<{ input: string; init?: RequestInit }> = [];
  let index = 0;
  const fetch: FetchLike = async (input, init) => {
    calls.push({ input, init });
    const entry = entries[index];
    index += 1;
    if (entry === undefined) {
      throw new Error(`resilient fetch called more times (${index}) than queued (${entries.length}).`);
    }
    return typeof entry === 'function' ? entry(input, init) : entry;
  };
  return { fetch, calls };
}

/** Records every sleep duration and resolves instantly so tests never wait on a wall clock. */
function fakeSleep(): { sleep: (ms: number) => Promise<void>; durations: number[] } {
  const durations: number[] = [];
  return {
    durations,
    sleep: async (ms: number) => {
      durations.push(ms);
    },
  };
}

test('retries a 503 then returns the eventual success without re-reading the success body', async () => {
  const { fetch, calls } = queue(
    new Response('temporary', { status: 503 }),
    new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.equal(await response.json().then((value: { ok: boolean }) => value.ok), true);
  assert.equal(calls.length, 2);
  assert.equal(durations.length, 1);
});

test('does not retry a 401 auth failure and returns the original response untouched for the caller to read', async () => {
  const { fetch, calls } = queue(
    new Response('{"message":"bad credentials"}', { status: 401, headers: { 'content-type': 'application/json' } }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 401);
  assert.equal(calls.length, 1, 'a plain 401 must not be retried');
  assert.equal(durations.length, 0);
  assert.equal(await response.json().then((value: { message: string }) => value.message), 'bad credentials');
});

test('does not retry a plain 403 forbidden response (preserves GraphQL FORBIDDEN -> REST fallback)', async () => {
  const { fetch, calls } = queue(new Response('forbidden', { status: 403 }));
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 403);
  assert.equal(calls.length, 1, 'a plain 403 (no rate-limit signal) must not be retried');
  // Classification reads the body to rule out a secondary rate limit; the caller (readJsonResponse)
  // must still be able to read it, otherwise the GraphQL-403 -> REST fallback throws `Body is unusable`.
  assert.equal(await response.text(), 'forbidden', 'a non-retried 403 body consumed during classification must be readable');
});

test('honors a numeric Retry-After header (seconds) on a 429 instead of exponential backoff', async () => {
  const { fetch } = queue(
    new Response('slow down', { status: 429, headers: { 'retry-after': '7' } }),
    new Response('ok', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3, baseDelayMs: 500 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.deepEqual(durations, [7000], 'Retry-After: 7 must wait exactly 7000ms, not the 500ms base backoff');
});

test('honors an HTTP-date Retry-After header relative to the injected clock', async () => {
  const epoch = Date.UTC(2026, 0, 1, 0, 0, 0);
  const retryAt = new Date(epoch + 12_000).toUTCString();
  const { fetch } = queue(
    new Response('slow down', { status: 503, headers: { 'retry-after': retryAt } }),
    new Response('ok', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => epoch, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.deepEqual(durations, [12_000], 'HTTP-date Retry-After must wait until the target time per the injected now()');
});

test('treats a 403 primary rate limit (remaining 0) by waiting until x-ratelimit-reset', async () => {
  const nowSeconds = 1_000_000;
  const resetSeconds = nowSeconds + 30;
  const { fetch } = queue(
    new Response('rate limited', {
      status: 403,
      headers: {
        'x-ratelimit-remaining': '0',
        'x-ratelimit-reset': String(resetSeconds),
      },
    }),
    new Response('ok', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, {
    sleep,
    now: () => nowSeconds * 1000,
    random: () => 0,
    maxRetries: 3,
    maxRateLimitWaitMs: 60_000,
  });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.deepEqual(durations, [30_000], 'primary rate limit must wait until x-ratelimit-reset (30s)');
});

test('detects a secondary rate limit on a 403 body (no retry-after header) and retries', async () => {
  // No retry-after header here on purpose, so the retry is carried SOLELY by the body-based
  // secondary-rate-limit detection (isSecondaryRateLimit) — GitHub routinely sends these 403s
  // with the message body but no retry-after. This discriminates that branch.
  const { fetch, calls } = queue(
    new Response('You have exceeded a secondary rate limit. Please wait a few minutes.', {
      status: 403,
    }),
    new Response('ok', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3, baseDelayMs: 500 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2, 'a secondary-rate-limit 403 body must retry even without a retry-after header');
  assert.deepEqual(durations, [500], 'with no retry-after/reset the secondary-rate-limit wait falls back to baseDelayMs');
});

test('caps a rate-limit wait at maxRateLimitWaitMs', async () => {
  const nowSeconds = 1_000_000;
  const resetSeconds = nowSeconds + 3600; // one hour away
  const { fetch } = queue(
    new Response('rate limited', {
      status: 429,
      headers: {
        'x-ratelimit-remaining': '0',
        'x-ratelimit-reset': String(resetSeconds),
      },
    }),
    new Response('ok', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, {
    sleep,
    now: () => nowSeconds * 1000,
    random: () => 0,
    maxRetries: 3,
    maxRateLimitWaitMs: 45_000,
  });

  await resilient('https://api.github.com/x');

  assert.deepEqual(durations, [45_000], 'an hour-away reset must be capped to maxRateLimitWaitMs');
});

test('retries on a thrown network error and then succeeds', async () => {
  let attempt = 0;
  const fetch: FetchLike = async () => {
    attempt += 1;
    if (attempt === 1) {
      throw new TypeError('fetch failed');
    }
    return new Response('ok', { status: 200 });
  };
  const { sleep, durations } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(response.status, 200);
  assert.equal(attempt, 2);
  assert.equal(durations.length, 1);
});

test('re-throws a network error after exhausting all retries', async () => {
  let attempts = 0;
  const fetch: FetchLike = async () => {
    attempts += 1;
    throw new TypeError('fetch failed');
  };
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 2 });

  await assert.rejects(() => resilient('https://api.github.com/x'), /fetch failed/);
  assert.equal(attempts, 3, 'maxRetries=2 means 1 initial + 2 retries = 3 attempts');
});

test('returns a reconstructable response after exhausting retries on a retryable status', async () => {
  const body = '{"message":"server exploded"}';
  const { fetch, calls } = queue(
    new Response(body, { status: 500, headers: { 'content-type': 'application/json', 'x-trace': 'abc' } }),
    new Response(body, { status: 500, headers: { 'content-type': 'application/json', 'x-trace': 'abc' } }),
    new Response(body, { status: 500, headers: { 'content-type': 'application/json', 'x-trace': 'abc' } }),
  );
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 2 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(calls.length, 3);
  assert.equal(response.status, 500);
  // The body must still be readable even though classification consumed the original stream.
  assert.equal(await response.text(), body);
  assert.equal(response.headers.get('x-trace'), 'abc');
});

test('uses exponential backoff with jitter bounded by the random factor', async () => {
  const { fetch } = queue(
    new Response('a', { status: 502 }),
    new Response('b', { status: 502 }),
    new Response('c', { status: 200 }),
  );
  const { sleep, durations } = fakeSleep();
  // random()=1 selects the top of the jitter band so we get the deterministic upper bound.
  const resilient = createResilientFetch(fetch, {
    sleep,
    now: () => 0,
    random: () => 1,
    maxRetries: 5,
    baseDelayMs: 100,
    maxDelayMs: 10_000,
  });

  await resilient('https://api.github.com/x');

  assert.equal(durations.length, 2);
  // attempt 0 -> base*2^0=100 .. attempt 1 -> base*2^1=200, at the top of the jitter band.
  assert.ok(durations[0] >= 100 && durations[0] <= 200, `first backoff ${durations[0]} out of band`);
  assert.ok(durations[1] >= 200 && durations[1] <= 400, `second backoff ${durations[1]} out of band`);
  assert.ok(durations[1] > durations[0], 'backoff must grow between attempts');
});

test('passes a per-attempt AbortSignal to the underlying fetch', async () => {
  let sawSignal = false;
  const fetch: FetchLike = async (_input, init) => {
    sawSignal = init?.signal instanceof AbortSignal;
    return new Response('ok', { status: 200 });
  };
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, perAttemptTimeoutMs: 5000 });

  await resilient('https://api.github.com/x');

  assert.equal(sawSignal, true, 'each attempt must carry an AbortSignal so a hung request times out');
});

test('does not retry a non-retryable 404 and returns the original response object', async () => {
  const original = new Response('missing', { status: 404 });
  const { fetch, calls } = queue(original);
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, { sleep, now: () => 0, random: () => 0, maxRetries: 3 });

  const response = await resilient('https://api.github.com/x');

  assert.equal(calls.length, 1);
  assert.equal(response, original, 'a non-retryable response must be returned untouched (same instance, body unread)');
});

test('invokes the onRetry observer with attempt metadata for each retry', async () => {
  const events: Array<{ attempt: number; status?: number; waitMs: number }> = [];
  const { fetch } = queue(
    new Response('x', { status: 503 }),
    new Response('ok', { status: 200 }),
  );
  const { sleep } = fakeSleep();
  const resilient = createResilientFetch(fetch, {
    sleep,
    now: () => 0,
    random: () => 0,
    maxRetries: 3,
    onRetry: (info) => events.push({ attempt: info.attempt, status: info.status, waitMs: info.waitMs }),
  });

  await resilient('https://api.github.com/x');

  assert.equal(events.length, 1);
  assert.equal(events[0].status, 503);
  assert.ok(events[0].waitMs > 0);
});
