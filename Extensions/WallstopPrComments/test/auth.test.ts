import assert from 'node:assert/strict';
import test from 'node:test';

import { AuthService, redactSecrets, sanitizeHeaderValue } from '../src/auth';

function syntheticGitHubToken(kind: 'ghp' | 'ghs' | 'gho' | 'ghu' | 'ghr' | 'github_pat'): string {
  return `${kind}_${'a'.repeat(36)}`;
}

const sanitizationCases: Array<{
  readonly name: string;
  readonly value: string | undefined;
  readonly expected: string | undefined;
}> = [
  {
    name: 'removes control characters and trims',
    value: '  ghp_secret\r\nInjected: yes\u007F  ',
    expected: 'ghp_secretInjected: yes',
  },
  {
    name: 'returns undefined for empty sanitized values',
    value: '\r\n\t',
    expected: undefined,
  },
  {
    name: 'preserves undefined',
    value: undefined,
    expected: undefined,
  },
];

for (const { name, value, expected } of sanitizationCases) {
  test(`sanitizes user supplied header values at the boundary: ${name}`, () => {
    assert.equal(sanitizeHeaderValue(value), expected);
  });
}

const redactionCases: Array<{
  readonly name: string;
  readonly text: string;
  readonly sensitiveValues?: readonly string[];
  readonly expected: string;
}> = [
  {
    name: 'GitHub classic token and explicit sensitive value',
    text: `Authorization failed for ${syntheticGitHubToken('ghp')} and custom-secret`,
    sensitiveValues: ['custom-secret'],
    expected: 'Authorization failed for ***REDACTED*** and ***REDACTED***',
  },
  {
    name: 'GitHub fine-grained token',
    text: `Token value: ${syntheticGitHubToken('github_pat')}`,
    expected: 'Token value: ***REDACTED***',
  },
  {
    name: 'Authorization bearer header',
    text: `Authorization: Bearer ${'a'.repeat(24)}`,
    expected: 'Authorization: Bearer ***REDACTED***',
  },
  {
    name: 'Authorization token header',
    text: `Authorization: token ${'b'.repeat(24)}`,
    expected: 'Authorization: token ***REDACTED***',
  },
  {
    name: 'ignores blank explicit sensitive values',
    text: 'Nothing to redact',
    sensitiveValues: ['   '],
    expected: 'Nothing to redact',
  },
];

for (const { name, text, sensitiveValues, expected } of redactionCases) {
  test(`redacts secrets: ${name}`, () => {
    assert.equal(redactSecrets(text, sensitiveValues), expected);
  });
}

test('uses VS Code GitHub auth for github.com before manual secrets', async () => {
  const calls: string[] = [];
  const service = new AuthService({
    getGitHubSession: async () => {
      calls.push('vscode');
      return 'vscode-token';
    },
    getSecret: async () => {
      calls.push('secret');
      return 'manual-token';
    },
  });

  assert.equal(await service.getToken('github.com'), 'vscode-token');
  assert.deepEqual(calls, ['vscode']);
});

test('passes interactive sign-in request to VS Code auth and keeps manual PAT fallback', async () => {
  const createIfNoneValues: boolean[] = [];
  const service = new AuthService({
    getGitHubSession: async (_scopes, createIfNone) => {
      createIfNoneValues.push(createIfNone);
      return undefined;
    },
    getSecret: async () => 'manual-token',
  });

  assert.equal(await service.getToken('github.com', true), 'manual-token');
  assert.deepEqual(createIfNoneValues, [true]);
});

test('uses manual PAT fallback for GHES hosts', async () => {
  const calls: string[] = [];
  const service = new AuthService({
    getGitHubSession: async () => {
      calls.push('vscode');
      return 'vscode-token';
    },
    getSecret: async () => {
      calls.push('secret');
      return 'manual-token';
    },
  });

  assert.equal(await service.getToken('ghes.example.com'), 'manual-token');
  assert.deepEqual(calls, ['secret']);
});

test('normalizes and validates auth secret hosts before lookup', async () => {
  const secretKeys: string[] = [];
  const service = new AuthService({
    getGitHubSession: async () => undefined,
    getSecret: async (key) => {
      secretKeys.push(key);
      return 'manual-token';
    },
  });

  assert.equal(await service.getToken(' GitHub.COM '), 'manual-token');
  assert.deepEqual(secretKeys, ['wallstopPrComments.token.github.com']);
});

test('rejects unsafe auth hosts before secret access', async () => {
  let secretCalled = false;
  const service = new AuthService({
    getGitHubSession: async () => undefined,
    getSecret: async () => {
      secretCalled = true;
      return 'manual-token';
    },
  });

  await assert.rejects(() => service.getToken('localhost'), /Localhost GitHub hosts are not allowed/u);
  assert.equal(secretCalled, false);
});
