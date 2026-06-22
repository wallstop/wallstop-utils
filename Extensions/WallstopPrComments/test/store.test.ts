import assert from 'node:assert/strict';
import test from 'node:test';

import { groupPullRequests, parseRepositoryInput, RepositoryStore } from '../src/repositoryStore';
import type { PullRequestSummary, RepositoryRef } from '../src/types';

class MemoryMemento {
  private readonly values = new Map<string, unknown>();

  get<T>(key: string, fallback: T): T {
    return (this.values.has(key) ? this.values.get(key) : fallback) as T;
  }

  async update(key: string, value: unknown): Promise<void> {
    this.values.set(key, value);
  }
}

test('persists sticky repositories in global state shape only', async () => {
  const state = new MemoryMemento();
  const store = new RepositoryStore(state);
  const repo: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };

  await store.add(repo);

  assert.deepEqual(store.list(), [repo]);
  assert.deepEqual(state.get('wallstopPrComments.repositories', []), [repo]);
});

test('de-duplicates repositories by normalized host owner and name', async () => {
  const store = new RepositoryStore(new MemoryMemento());

  await store.add({ host: 'GitHub.COM', owner: 'Wallstop', repo: 'Utils' });
  await store.add({ host: 'github.com', owner: 'Wallstop', repo: 'Utils' });

  assert.deepEqual(store.list(), [{ host: 'github.com', owner: 'Wallstop', repo: 'Utils' }]);
});

test('accepts GitHub Enterprise HTTPS repository URLs with safe hostnames', () => {
  assert.deepEqual(parseRepositoryInput('https://github.enterprise.local/platform/api-repo/pull/42'), {
    host: 'github.enterprise.local',
    owner: 'platform',
    repo: 'api-repo',
  });
});

test('rejects local, private, ported, and user-info repository URL hosts', () => {
  assert.throws(() => parseRepositoryInput('https://localhost/org/repo'), /Localhost/);
  assert.throws(() => parseRepositoryInput('https://192.168.1.10/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://[::1]/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://[::ffff:127.0.0.1]/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://[fe90::1]/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://[fea0::1]/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://[febf::1]/org/repo'), /not allowed/);
  assert.throws(() => parseRepositoryInput('https://github.com:8443/org/repo'), /port/);
  assert.throws(() => parseRepositoryInput('https://token@github.com/org/repo'), /user info/);
  assert.throws(() => parseRepositoryInput('https://-github.com/org/repo'), /Invalid GitHub host/);
});

test('groups open pull requests first and closed or merged pull requests separately', () => {
  const prs: PullRequestSummary[] = [
    {
      number: 2,
      title: 'merged',
      state: 'CLOSED',
      isDraft: false,
      merged: true,
      author: 'octo',
      headRefName: 'feature/merged',
      updatedAt: '2026-01-02T00:00:00Z',
      url: 'https://example.test/2',
    },
    {
      number: 1,
      title: 'open',
      state: 'OPEN',
      isDraft: false,
      merged: false,
      author: 'octo',
      headRefName: 'feature/open',
      updatedAt: '2026-01-03T00:00:00Z',
      url: 'https://example.test/1',
    },
  ];

  assert.deepEqual(groupPullRequests(prs), {
    open: [prs[1]],
    closed: [prs[0]],
  });
});
