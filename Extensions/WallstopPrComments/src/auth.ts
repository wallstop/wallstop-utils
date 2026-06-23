export interface AuthDependencies {
  getGitHubSession(scopes: string[], createIfNone: boolean): PromiseLike<string | undefined>;
  getSecret(key: string): PromiseLike<string | undefined>;
  storeSecret?(key: string, value: string): PromiseLike<void>;
  deleteSecret?(key: string): PromiseLike<void>;
}

const TOKEN_PREFIX = 'wallstopPrComments.token.';
const WEB_COOKIE_PREFIX = 'wallstopPrComments.webCookie.';

export function sanitizeHeaderValue(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }

  const sanitized = value.replace(/[\x00-\x1F\x7F]/gu, '').trim();
  return sanitized === '' ? undefined : sanitized;
}

export function redactSecrets(text: string, sensitiveValues: readonly string[] = []): string {
  let redacted = text;
  for (const value of sensitiveValues) {
    if (value.trim() === '') {
      continue;
    }

    redacted = redacted.split(value).join('***REDACTED***');
  }

  redacted = redacted.replace(/gh[pousr]_[A-Za-z0-9_]{20,}/gu, '***REDACTED***');
  redacted = redacted.replace(/github_pat_[A-Za-z0-9_]{20,}/gu, '***REDACTED***');
  redacted = redacted.replace(/\b(Bearer|token)\s+[A-Za-z0-9_.-]{20,}/giu, '$1 ***REDACTED***');
  return redacted;
}

export class AuthService {
  constructor(private readonly dependencies: AuthDependencies) {}

  async getToken(host: string, createIfNone = false): Promise<string | undefined> {
    const normalizedHost = normalizeHost(host);
    if (normalizedHost === 'github.com') {
      const sessionToken = sanitizeHeaderValue(
        await this.dependencies.getGitHubSession(['repo', 'read:user'], createIfNone),
      );
      if (sessionToken !== undefined) {
        return sessionToken;
      }
    }

    return sanitizeHeaderValue(await this.dependencies.getSecret(tokenSecretKey(normalizedHost)));
  }

  async storeToken(host: string, token: string): Promise<void> {
    if (this.dependencies.storeSecret === undefined) {
      throw new Error('Secret storage is not available.');
    }

    const safeToken = sanitizeHeaderValue(token);
    if (safeToken === undefined) {
      throw new Error('Token is empty after header sanitization.');
    }

    await this.dependencies.storeSecret(tokenSecretKey(normalizeHost(host)), safeToken);
  }

  async clearToken(host: string): Promise<void> {
    await this.dependencies.deleteSecret?.(tokenSecretKey(normalizeHost(host)));
  }

  async getWebCookie(host: string): Promise<string | undefined> {
    return sanitizeHeaderValue(await this.dependencies.getSecret(webCookieSecretKey(normalizeHost(host))));
  }

  async storeWebCookie(host: string, cookie: string): Promise<void> {
    if (this.dependencies.storeSecret === undefined) {
      throw new Error('Secret storage is not available.');
    }

    const safeCookie = sanitizeHeaderValue(cookie);
    if (safeCookie === undefined) {
      throw new Error('Cookie is empty after header sanitization.');
    }

    await this.dependencies.storeSecret(webCookieSecretKey(normalizeHost(host)), safeCookie);
  }

  async clearWebCookie(host: string): Promise<void> {
    await this.dependencies.deleteSecret?.(webCookieSecretKey(normalizeHost(host)));
  }
}

function normalizeHost(host: string): string {
  return host.trim().toLowerCase();
}

function tokenSecretKey(host: string): string {
  return `${TOKEN_PREFIX}${host}`;
}

function webCookieSecretKey(host: string): string {
  return `${WEB_COOKIE_PREFIX}${host}`;
}
