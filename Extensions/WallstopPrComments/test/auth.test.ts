import assert from 'node:assert/strict';
import test from 'node:test';

import { AuthService, redactSecrets, sanitizeHeaderValue } from '../src/auth';

test('sanitizes user supplied header values at the boundary', () => {
  assert.equal(sanitizeHeaderValue('  ghp_secret\r\nInjected: yes\u007F  '), 'ghp_secretInjected: yes');
  assert.equal(sanitizeHeaderValue('\r\n\t'), undefined);
});

test('redacts GitHub token shapes and explicit sensitive values', () => {
  const text = 'Authorization failed for ghp_abcdefghijklmnopqrstuvwxyz and custom-secret';

  assert.equal(redactSecrets(text, ['custom-secret']), 'Authorization failed for ***REDACTED*** and ***REDACTED***');
});

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
