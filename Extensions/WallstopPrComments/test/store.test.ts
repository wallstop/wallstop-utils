import assert from 'node:assert/strict';
import test from 'node:test';

import {
  assertSafeGitHubHost,
  buildAddRepoQuickPickItems,
  enumerationHosts,
  groupPullRequests,
  parseRepositoryInput,
  RepositoryStore,
  selectableRepositories,
} from '../src/repositoryStore';
import type { AccessibleRepository, PullRequestSummary, RepositoryRef } from '../src/types';

function accessibleRepository(
  partial: Partial<AccessibleRepository> & { owner: string; repo: string },
): AccessibleRepository {
  return {
    host: 'github.com',
    fullName: `${partial.owner}/${partial.repo}`,
    private: false,
    archived: false,
    fork: false,
    pushedAt: undefined,
    description: undefined,
    ...partial,
  };
}

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

test('skips invalid persisted repositories instead of throwing during list', async () => {
  const state = new MemoryMemento();
  const store = new RepositoryStore(state);
  await state.update('wallstopPrComments.repositories', [
    null,
    'github.com/wallstop/utils',
    { host: '', owner: 'wallstop', repo: 'utils' },
    { host: 'localhost', owner: 'wallstop', repo: 'utils' },
    { host: 'github.com', owner: '', repo: 'utils' },
    { host: 'github.com', owner: 'wallstop', repo: 'bad/name' },
    { host: 'GitHub.COM', owner: 'wallstop', repo: 'utils' },
    { host: 'github.com', owner: 'wallstop', repo: 'utils' },
  ]);

  assert.deepEqual(store.list(), [{ host: 'github.com', owner: 'wallstop', repo: 'utils' }]);
});

test('treats non-array persisted repository state as empty', async () => {
  const state = new MemoryMemento();
  const store = new RepositoryStore(state);
  await state.update('wallstopPrComments.repositories', { host: 'github.com', owner: 'wallstop', repo: 'utils' });

  assert.deepEqual(store.list(), []);
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
  assert.throws(() => parseRepositoryInput('https://010.010.010.010/org/repo'), /Invalid GitHub host/);
  assert.throws(() => parseRepositoryInput('https://0x8.0x8.0x8.0x8/org/repo'), /Invalid GitHub host/);
});

test('rejects URL-reinterpretable IPv4 host aliases before request URL construction', () => {
  for (const host of ['2130706433', '0177.0.0.1', '0x7f.0.0.1', '127.1', '1.2.3.04', '008.008.008.008']) {
    assert.throws(() => assertSafeGitHubHost(host), /Invalid GitHub host/u);
  }
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

test('treats merged pull requests as closed even if stale summary state is open', () => {
  const mergedOpen: PullRequestSummary = {
    number: 3,
    title: 'merged with stale open state',
    state: 'OPEN',
    isDraft: false,
    merged: true,
    author: 'octo',
    headRefName: 'feature/stale-open',
    updatedAt: '2026-01-04T00:00:00Z',
    url: 'https://example.test/3',
  };

  assert.deepEqual(groupPullRequests([mergedOpen]), {
    open: [],
    closed: [mergedOpen],
  });
});

test('selectableRepositories drops archived and already-added repos, de-dupes, and sorts by pushed desc', () => {
  const repos: AccessibleRepository[] = [
    accessibleRepository({ owner: 'wallstop', repo: 'old', pushedAt: '2026-01-01T00:00:00Z' }),
    accessibleRepository({ owner: 'wallstop', repo: 'archived', archived: true, pushedAt: '2026-06-30T00:00:00Z' }),
    accessibleRepository({ owner: 'wallstop', repo: 'new', pushedAt: '2026-06-20T00:00:00Z' }),
    accessibleRepository({ owner: 'wallstop', repo: 'undated' }),
    accessibleRepository({ owner: 'WALLSTOP', repo: 'NEW', pushedAt: '2026-06-25T00:00:00Z' }),
    accessibleRepository({ owner: 'wallstop', repo: 'utils' }),
  ];
  const alreadyAdded: RepositoryRef[] = [{ host: 'GitHub.com', owner: 'Wallstop', repo: 'Utils' }];

  const result = selectableRepositories(repos, alreadyAdded);

  assert.deepEqual(
    result.map((repository) => repository.repo),
    ['new', 'old', 'undated'],
  );
});

test('buildAddRepoQuickPickItems puts a manual-entry item first and shapes repository items', () => {
  const items = buildAddRepoQuickPickItems([
    accessibleRepository({
      owner: 'wallstop',
      repo: 'utils',
      private: true,
      pushedAt: '2026-06-20T10:30:00Z',
      description: 'helpers',
    }),
  ]);

  assert.equal(items.length, 2);
  assert.equal(items[0].manualEntry, true);
  assert.equal(items[0].alwaysShow, true);
  assert.match(items[0].label, /Enter owner\/repo/u);
  assert.equal(items[0].repository, undefined);
  assert.equal(items[1].label, 'wallstop/utils');
  assert.deepEqual(items[1].repository, { host: 'github.com', owner: 'wallstop', repo: 'utils' });
  assert.match(items[1].description ?? '', /private/u);
  assert.match(items[1].description ?? '', /2026-06-20/u);
  assert.equal(items[1].detail, 'helpers');
});

test('enumerationHosts always includes github.com plus distinct stored hosts (lowercased)', () => {
  assert.deepEqual(
    enumerationHosts([
      { host: 'github.com', owner: 'a', repo: 'b' },
      { host: 'GHE.example.com', owner: 'c', repo: 'd' },
      { host: 'ghe.example.com', owner: 'e', repo: 'f' },
    ]),
    ['github.com', 'ghe.example.com'],
  );
});
