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

function loadTreeProvider(): { PrCommentsTreeProvider: typeof PrCommentsTreeProviderClass } {
  const moduleLoader = Module as unknown as {
    _load: (request: string, parent: NodeModule | null, isMain: boolean) => unknown;
  };
  const originalLoad = moduleLoader._load;
  moduleLoader._load = (request, parent, isMain) => {
    if (request === 'vscode') {
      return {
        EventEmitter: class {
          readonly event = () => ({ dispose: () => undefined });
          fire(): void {}
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
