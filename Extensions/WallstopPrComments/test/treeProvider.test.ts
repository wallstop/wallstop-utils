import assert from 'node:assert/strict';
import Module from 'node:module';
import test from 'node:test';

import type { GitHubClient } from '../src/githubClient';
import type { PullRequestSummary, RepositoryRef } from '../src/types';
import type { PrCommentsTreeProvider as PrCommentsTreeProviderClass, TreeNode } from '../src/treeProvider';

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
};

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((promiseResolve, promiseReject) => {
    resolve = promiseResolve;
    reject = promiseReject;
  });

  return { promise, resolve, reject };
}

const firedEvents: Array<TreeNode | undefined> = [];

function loadTreeProvider(): { PrCommentsTreeProvider: typeof PrCommentsTreeProviderClass } {
  firedEvents.length = 0;
  const moduleLoader = Module as unknown as {
    _load: (request: string, parent: NodeModule | null, isMain: boolean) => unknown;
  };
  const originalLoad = moduleLoader._load;
  moduleLoader._load = (request, parent, isMain) => {
    if (request === 'vscode') {
      return {
        EventEmitter: class {
          readonly event = () => ({ dispose: () => undefined });
          fire(value: TreeNode | undefined): void {
            firedEvents.push(value);
          }
        },
        ThemeIcon: class {
          constructor(readonly id: string) {}
        },
        TreeItem: class {
          constructor(readonly label: string, readonly collapsibleState: number) {}
        },
        TreeItemCollapsibleState: {
          None: 0,
          Collapsed: 1,
          Expanded: 2,
        },
      };
    }

    return originalLoad(request, parent, isMain);
  };

  try {
    delete require.cache[require.resolve('../src/treeProvider')];
    return require('../src/treeProvider') as { PrCommentsTreeProvider: typeof PrCommentsTreeProviderClass };
  } finally {
    moduleLoader._load = originalLoad;
  }
}

const repository: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
const repositoryNode: TreeNode = { kind: 'repository', repository };

const pullRequest: PullRequestSummary = {
  number: 42,
  title: 'Fix review loading',
  state: 'OPEN',
  isDraft: false,
  merged: false,
  author: 'octo',
  headRefName: 'fix/review-loading',
  updatedAt: '2026-06-23T00:00:00Z',
  url: 'https://github.com/wallstop/utils/pull/42',
};

function fakeGitHubToken(): string {
  return `${'ghp_'}${'12345678901234567890'}`;
}

test('deduplicates concurrent repository pull request loads', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const load = createDeferred<PullRequestSummary[]>();
  let loadCount = 0;
  const client = {
    listPullRequests: async () => {
      loadCount += 1;
      return load.promise;
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);

  const first = provider.getChildren(repositoryNode);
  const second = provider.getChildren(repositoryNode);
  assert.equal(loadCount, 1);

  load.resolve([pullRequest]);
  const [firstChildren, secondChildren] = await Promise.all([first, second]);

  assert.deepEqual(firstChildren.map((child) => child.kind), ['group', 'group']);
  assert.deepEqual(secondChildren, firstChildren);
  assert.equal(firstChildren[0].kind, 'group');
  if (firstChildren[0].kind === 'group') {
    assert.deepEqual(firstChildren[0].pullRequests, [pullRequest]);
  }
});

test('ignores stale repository loads that resolve after refresh', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loads: Deferred<PullRequestSummary[]>[] = [];
  const client = {
    listPullRequests: async () => {
      const load = createDeferred<PullRequestSummary[]>();
      loads.push(load);
      return load.promise;
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);

  const stale = provider.getChildren(repositoryNode);
  assert.equal(loads.length, 1);
  provider.refresh();
  loads[0].resolve([pullRequest]);
  await stale;

  const fresh = provider.getChildren(repositoryNode);
  assert.equal(loads.length, 2);
  loads[1].resolve([pullRequest]);
  const freshChildren = await fresh;

  assert.equal(freshChildren[0].kind, 'group');
  if (freshChildren[0].kind === 'group') {
    assert.deepEqual(freshChildren[0].pullRequests, [pullRequest]);
  }
});

test('ignores stale repository loads that resolve after targeted repository refresh', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loads: Deferred<PullRequestSummary[]>[] = [];
  const client = {
    listPullRequests: async () => {
      const load = createDeferred<PullRequestSummary[]>();
      loads.push(load);
      return load.promise;
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);
  const [node] = await provider.getChildren(undefined);
  assert.equal(node.kind, 'repository');

  const staleLoad = provider.getChildren(node);
  assert.equal(loads.length, 1);

  provider.refresh(repository);
  const freshPullRequest = { ...pullRequest, number: 43, title: 'Fresh PR' };
  const freshLoad = provider.getChildren(node);
  assert.equal(loads.length, 2);
  loads[1].resolve([freshPullRequest]);

  const freshChildren = await freshLoad;
  assert.equal(freshChildren[0].kind, 'group');
  if (freshChildren[0].kind === 'group') {
    assert.deepEqual(freshChildren[0].pullRequests, [freshPullRequest]);
  }

  const stalePullRequest = { ...pullRequest, number: 41, title: 'Stale PR' };
  loads[0].resolve([stalePullRequest]);
  const staleChildren = await staleLoad;
  assert.equal(staleChildren[0].kind, 'group');
  if (staleChildren[0].kind === 'group') {
    assert.deepEqual(staleChildren[0].pullRequests, [freshPullRequest]);
  }

  const cachedChildren = await provider.getChildren(node);
  assert.equal(loads.length, 2, 'the stale completion must not evict or poison the fresh cache');
  assert.equal(cachedChildren[0].kind, 'group');
  if (cachedChildren[0].kind === 'group') {
    assert.deepEqual(cachedChildren[0].pullRequests, [freshPullRequest]);
  }
});

test('ignores stale repository load errors after targeted repository refresh', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loads: Deferred<PullRequestSummary[]>[] = [];
  const client = {
    listPullRequests: async () => {
      const load = createDeferred<PullRequestSummary[]>();
      loads.push(load);
      return load.promise;
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);
  const [node] = await provider.getChildren(undefined);
  assert.equal(node.kind, 'repository');

  const staleLoad = provider.getChildren(node);
  assert.equal(loads.length, 1);

  provider.refresh(repository);
  const freshPullRequest = { ...pullRequest, number: 44, title: 'Fresh after stale error' };
  const freshLoad = provider.getChildren(node);
  assert.equal(loads.length, 2);
  loads[1].resolve([freshPullRequest]);

  await freshLoad;
  loads[0].reject(new Error('stale failure'));
  const staleChildren = await staleLoad;

  assert.equal(staleChildren[0].kind, 'group');
  if (staleChildren[0].kind === 'group') {
    assert.deepEqual(staleChildren[0].pullRequests, [freshPullRequest]);
  }

  const cachedChildren = await provider.getChildren(node);
  assert.equal(loads.length, 2, 'the stale error must not trigger another load or cache an error');
  assert.equal(cachedChildren[0].kind, 'group');
  if (cachedChildren[0].kind === 'group') {
    assert.deepEqual(cachedChildren[0].pullRequests, [freshPullRequest]);
  }
});

test('redacts repository load failures before rendering tree error labels', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const client = {
    listPullRequests: async () => {
      throw new Error(`token ${fakeGitHubToken()} failed`);
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);
  const [node] = await provider.getChildren(undefined);

  const children = await provider.getChildren(node);

  assert.equal(children.length, 1);
  assert.equal(children[0].kind, 'empty');
  if (children[0].kind === 'empty') {
    assert.match(children[0].label, /token \*\*\*REDACTED\*\*\* failed/u);
    assert.equal(children[0].label.includes(fakeGitHubToken()), false);
  }
});

const repositoryB: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'other' };

test('getChildren(undefined) returns a stable memoized repository node per repo', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const client = { listPullRequests: async () => [] } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository, repositoryB] }, client);

  const first = await provider.getChildren(undefined);
  const second = await provider.getChildren(undefined);

  assert.equal(first.length, 2);
  assert.equal(first[0].kind, 'repository');
  assert.equal(first[1].kind, 'repository');
  assert.equal(first[0], second[0], 'first repository node reference must be stable across getChildren calls');
  assert.equal(first[1], second[1], 'second repository node reference must be stable across getChildren calls');
});

test('refresh(repository) fires only the memoized node for that repo and reloads only its cache', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loadsByRepo = new Map<string, number>();
  const client = {
    listPullRequests: async (target: RepositoryRef) => {
      loadsByRepo.set(target.repo, (loadsByRepo.get(target.repo) ?? 0) + 1);
      return [pullRequest];
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository, repositoryB] }, client);

  const roots = await provider.getChildren(undefined);
  const nodeA = roots[0];
  const nodeB = roots[1];
  assert.equal(nodeA.kind, 'repository');
  assert.equal(nodeB.kind, 'repository');

  // Prime both repository caches.
  await provider.getChildren(nodeA);
  await provider.getChildren(nodeB);
  assert.equal(loadsByRepo.get('utils'), 1);
  assert.equal(loadsByRepo.get('other'), 1);

  firedEvents.length = 0;
  provider.refresh(repository);

  assert.deepEqual(firedEvents, [nodeA], 'refresh(repository) must fire exactly the memoized node for that repo');

  // Re-reading children reloads only the evicted repo.
  await provider.getChildren(nodeA);
  await provider.getChildren(nodeB);
  assert.equal(loadsByRepo.get('utils'), 2, 'refreshed repo A reloads');
  assert.equal(loadsByRepo.get('other'), 1, 'untouched repo B does not reload');
});

test('refresh(repository) fires the same memoized instance getChildren(undefined) returns', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const client = { listPullRequests: async () => [pullRequest] } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);

  const roots = await provider.getChildren(undefined);
  const nodeA = roots[0];

  firedEvents.length = 0;
  provider.refresh(repository);

  assert.equal(firedEvents.length, 1);
  assert.equal(firedEvents[0], nodeA, 'fired node must be the identical instance returned by getChildren(undefined)');
});

const missingMemoizedNodeRefreshScenarios: Array<{
  readonly name: string;
  readonly arrange: (provider: PrCommentsTreeProviderClass) => Promise<void>;
}> = [
  {
    name: 'the repository root has not rendered yet',
    arrange: async () => undefined,
  },
  {
    name: 'a no-arg refresh cleared the memoized roots',
    arrange: async (provider) => {
      await provider.getChildren(undefined);
      firedEvents.length = 0;
      provider.refresh();
      firedEvents.length = 0;
    },
  },
];

for (const scenario of missingMemoizedNodeRefreshScenarios) {
  test(`refresh(repository) fires a full refresh when ${scenario.name}`, async () => {
    const { PrCommentsTreeProvider } = loadTreeProvider();
    const client = { listPullRequests: async () => [pullRequest] } as unknown as GitHubClient;
    const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);

    await scenario.arrange(provider);
    provider.refresh(repository);

    assert.deepEqual(firedEvents, [undefined]);
  });
}

test('no-arg refresh() fires undefined and reloads every repository', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loadsByRepo = new Map<string, number>();
  const client = {
    listPullRequests: async (target: RepositoryRef) => {
      loadsByRepo.set(target.repo, (loadsByRepo.get(target.repo) ?? 0) + 1);
      return [pullRequest];
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository, repositoryB] }, client);

  const roots = await provider.getChildren(undefined);
  await provider.getChildren(roots[0]);
  await provider.getChildren(roots[1]);
  assert.equal(loadsByRepo.get('utils'), 1);
  assert.equal(loadsByRepo.get('other'), 1);

  firedEvents.length = 0;
  provider.refresh();

  assert.deepEqual(firedEvents, [undefined], 'no-arg refresh() must fire undefined');

  const refreshedRoots = await provider.getChildren(undefined);
  await provider.getChildren(refreshedRoots[0]);
  await provider.getChildren(refreshedRoots[1]);
  assert.equal(loadsByRepo.get('utils'), 2, 'repo A reloads after global refresh');
  assert.equal(loadsByRepo.get('other'), 2, 'repo B reloads after global refresh');
});

test('refresh(repository) for an unknown repo fires nothing and leaves caches intact', async () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const loadsByRepo = new Map<string, number>();
  const client = {
    listPullRequests: async (target: RepositoryRef) => {
      loadsByRepo.set(target.repo, (loadsByRepo.get(target.repo) ?? 0) + 1);
      return [pullRequest];
    },
  } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);

  const roots = await provider.getChildren(undefined);
  await provider.getChildren(roots[0]);
  assert.equal(loadsByRepo.get('utils'), 1);

  firedEvents.length = 0;
  provider.refresh(repositoryB);

  assert.deepEqual(firedEvents, [], 'refreshing a repo with no memoized node fires nothing');
  await provider.getChildren(roots[0]);
  assert.equal(loadsByRepo.get('utils'), 1, 'unrelated repo cache is untouched');
});

test('uses merged icon for merged pull request summaries even with stale open state', () => {
  const { PrCommentsTreeProvider } = loadTreeProvider();
  const client = { listPullRequests: async () => [] } as unknown as GitHubClient;
  const provider = new PrCommentsTreeProvider({ list: () => [repository] }, client);
  const mergedOpenNode: TreeNode = {
    kind: 'pullRequest',
    repository,
    pullRequest: {
      ...pullRequest,
      state: 'OPEN',
      merged: true,
    },
  };

  const item = provider.getTreeItem(mergedOpenNode) as { iconPath?: { id: string } };

  assert.equal(item.iconPath?.id, 'git-merge');
});
