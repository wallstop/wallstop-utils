import assert from 'node:assert/strict';
import Module from 'node:module';
import test from 'node:test';

import type {
  AccessibleRepository,
  PullRequestSummary,
  RepositoryRef,
  ReviewThreadRecord,
  WebSuggestedDiffResult,
} from '../src/types';

interface ExtensionTestExports {
  activate(context: unknown): void;
  attachWebSuggestedDiffsAndCollectWarnings(
    records: ReviewThreadRecord[],
    webDiffs: WebSuggestedDiffResult,
  ): string[];
  getBrowserWebSuggestionsHtml(url: string): Promise<string | undefined>;
}

type CommandHandler = (...args: unknown[]) => unknown;

interface ExtensionHarness extends ExtensionTestExports {
  commands: Map<string, CommandHandler>;
  errorMessages: string[];
  firedTreeEvents: unknown[];
  openedUrls: string[];
  warningMessages: string[];
  treeProvider?: {
    getChildren(element?: unknown): Promise<unknown[]>;
  };
}

function loadExtensionWithVscodeStub(options: {
  command: string | undefined;
  workspaceCommand?: string;
  executeCommand?: (command: string, url: string) => Promise<unknown>;
  listPullRequests?: (repository: RepositoryRef) => Promise<PullRequestSummary[]>;
  listAccessibleRepositories?: (host: string) => Promise<AccessibleRepository[]>;
  showQuickPick?: (items: unknown[], options: { title?: string }) => Promise<unknown>;
}): ExtensionHarness {
  const commands = new Map<string, CommandHandler>();
  const errorMessages: string[] = [];
  const firedTreeEvents: unknown[] = [];
  const openedUrls: string[] = [];
  const warningMessages: string[] = [];
  let treeProvider: ExtensionHarness['treeProvider'];
  const moduleLoader = Module as unknown as {
    _load: (request: string, parent: NodeModule | null, isMain: boolean) => unknown;
  };
  const originalLoad = moduleLoader._load;
  moduleLoader._load = (request, parent, isMain) => {
    if (request === 'vscode') {
      return {
        authentication: { getSession: async () => undefined },
        commands: {
          executeCommand: options.executeCommand ?? (async () => undefined),
          registerCommand: (command: string, handler: CommandHandler) => {
            commands.set(command, handler);
            return { dispose: () => undefined };
          },
        },
        EventEmitter: class {
          readonly event = () => ({ dispose: () => undefined });
          fire(value: unknown): void {
            firedTreeEvents.push(value);
          }
        },
        env: {
          clipboard: { writeText: async () => undefined },
          openExternal: async (uri: { value?: string; toString?: () => string }) => {
            openedUrls.push(uri.value ?? uri.toString?.() ?? String(uri));
          },
        },
        ProgressLocation: { Notification: 1 },
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
        Uri: { parse: (value: string) => ({ value, toString: () => value }) },
        window: {
          createOutputChannel: () => ({
            appendLine: () => undefined,
            dispose: () => undefined,
          }),
          registerTreeDataProvider: (_viewId: string, provider: ExtensionHarness['treeProvider']) => {
            treeProvider = provider;
            return { dispose: () => undefined };
          },
          showErrorMessage: async (message: string) => {
            errorMessages.push(message);
          },
          showInformationMessage: async () => undefined,
          showInputBox: async () => undefined,
          showQuickPick: async (items: unknown[], quickPickOptions: { title?: string }) =>
            options.showQuickPick?.(items, quickPickOptions),
          showWarningMessage: async (message: string) => {
            warningMessages.push(message);
          },
          withProgress: async (_options: unknown, task: () => Promise<unknown>) => task(),
        },
        workspace: {
          getConfiguration: () => ({
            get: (key: string) => (key === 'autoRefresh.enabled' ? false : undefined),
            inspect: (key: string) => key === 'browserWebSuggestionsCommand'
              ? { globalValue: options.command, workspaceValue: options.workspaceCommand }
              : undefined,
          }),
          onDidChangeConfiguration: () => ({ dispose: () => undefined }),
        },
      };
    }

    if (request === './githubClient') {
      return {
        GitHubClient: class {
          async listPullRequests(repository: RepositoryRef): Promise<PullRequestSummary[]> {
            return options.listPullRequests?.(repository) ?? [];
          }

          async listAccessibleRepositories(host: string): Promise<AccessibleRepository[]> {
            return options.listAccessibleRepositories?.(host) ?? [];
          }

          async getReviewThreads(): Promise<{ threads: []; warnings: [] }> {
            return { threads: [], warnings: [] };
          }

          async getWebSuggestedDiffs(): Promise<WebSuggestedDiffResult> {
            return { provenance: 'githubWebAutomatedDiff', suggestions: new Map() };
          }
        },
      };
    }

    return originalLoad(request, parent, isMain);
  };

  try {
    delete require.cache[require.resolve('../src/extension')];
    delete require.cache[require.resolve('../src/treeProvider')];
    const extension = require('../src/extension') as ExtensionTestExports;
    const harness = Object.assign(extension, {
      commands,
      errorMessages,
      firedTreeEvents,
      openedUrls,
      warningMessages,
    });
    Object.defineProperty(harness, 'treeProvider', {
      get: () => treeProvider,
    });
    return harness as ExtensionHarness;
  } finally {
    moduleLoader._load = originalLoad;
  }
}

function createExtensionContext(repositories: readonly RepositoryRef[]): unknown {
  const state = new Map<string, unknown>([['wallstopPrComments.repositories', [...repositories]]]);
  return {
    globalState: {
      get: (key: string, fallback?: unknown) => state.get(key) ?? fallback,
      update: async (key: string, value: unknown) => {
        state.set(key, value);
      },
    },
    secrets: {
      get: async () => undefined,
      store: async () => undefined,
      delete: async () => undefined,
    },
    subscriptions: [],
  };
}

function fakeTokenFailure(): Error {
  return new Error(`token ${'ghp_'}${'12345678901234567890'} failed`);
}

test('browser web suggestions provider invokes configured VS Code command with PR files URL', async () => {
  const calls: Array<{ command: string; url: string }> = [];
  const { getBrowserWebSuggestionsHtml } = loadExtensionWithVscodeStub({
    command: 'example.browserHtml',
    executeCommand: async (command, url) => {
      calls.push({ command, url });
      return '<script type="application/json">{}</script>';
    },
  });

  const html = await getBrowserWebSuggestionsHtml('https://github.com/org/repo/pull/1/files');

  assert.equal(html, '<script type="application/json">{}</script>');
  assert.deepEqual(calls, [
    { command: 'example.browserHtml', url: 'https://github.com/org/repo/pull/1/files' },
  ]);
});

test('browser web suggestions provider accepts object html results', async () => {
  const { getBrowserWebSuggestionsHtml } = loadExtensionWithVscodeStub({
    command: 'example.browserHtml',
    executeCommand: async () => ({ html: '<script type="application/json">{}</script>' }),
  });

  assert.equal(
    await getBrowserWebSuggestionsHtml('https://github.com/org/repo/pull/1/files'),
    '<script type="application/json">{}</script>',
  );
});

test('browser web suggestions provider error documents every supported return shape', async () => {
  const { getBrowserWebSuggestionsHtml } = loadExtensionWithVscodeStub({
    command: 'example.browserHtml',
    executeCommand: async () => ({ text: '<html></html>' }),
  });

  await assert.rejects(
    () => getBrowserWebSuggestionsHtml('https://github.com/org/repo/pull/1/files'),
    /must return an HTML string or \{ html: string \}/u,
  );
});

test('browser web suggestions provider is disabled when no command is configured', async () => {
  let called = false;
  const { getBrowserWebSuggestionsHtml } = loadExtensionWithVscodeStub({
    command: '   ',
    executeCommand: async () => {
      called = true;
      return '';
    },
  });

  assert.equal(await getBrowserWebSuggestionsHtml('https://github.com/org/repo/pull/1/files'), undefined);
  assert.equal(called, false);
});

test('browser web suggestions provider ignores workspace-supplied command setting', async () => {
  let called = false;
  const { getBrowserWebSuggestionsHtml } = loadExtensionWithVscodeStub({
    command: undefined,
    workspaceCommand: 'workspace.suppliedCommand',
    executeCommand: async () => {
      called = true;
      return '';
    },
  });

  assert.equal(await getBrowserWebSuggestionsHtml('https://github.com/org/repo/pull/1/files'), undefined);
  assert.equal(called, false);
});

test('web suggestion warning helper reports unmatched ids even after partial attachment', () => {
  const { attachWebSuggestedDiffsAndCollectWarnings } = loadExtensionWithVscodeStub({
    command: undefined,
    executeCommand: async () => undefined,
  });
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/file.ts',
      lineStart: 1,
      lineEnd: 1,
      comments: [
        {
          databaseId: 42,
          body: 'Comment',
          suggestedChanges: [],
          suggestedDiffs: [],
        },
      ],
    },
  ];

  const warnings = attachWebSuggestedDiffsAndCollectWarnings(records, {
    provenance: 'githubWebAutomatedDiff',
    suggestions: new Map([
      [
        '42',
        [
          {
            kind: 'changedLines',
            source: 'githubWebAutomatedDiff',
            confidence: 'medium',
            value: '-old();\n+new();',
          },
        ],
      ],
      [
        'discussion_r999',
        [
          {
            kind: 'changedLines',
            source: 'githubWebAutomatedDiff',
            confidence: 'medium',
            value: '-otherOld();\n+otherNew();',
          },
        ],
      ],
    ]),
  });

  assert.equal(records[0].comments[0].suggestedDiffs[0].value, '-old();\n+new();');
  assert.equal(warnings.some((warning) => /Attached 1 suggested change diff/u.test(warning)), true);
  assert.equal(warnings.some((warning) => /unmatched comment ids: discussion_r999/u.test(warning)), true);
});

test('web suggestion warning helper surfaces unparseable marker provenance', () => {
  const { attachWebSuggestedDiffsAndCollectWarnings } = loadExtensionWithVscodeStub({
    command: undefined,
    executeCommand: async () => undefined,
  });

  const warnings = attachWebSuggestedDiffsAndCollectWarnings([], {
    provenance: 'webSuggestionMarkersUnparseable',
    suggestions: new Map(),
  });

  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /rendered format may have changed/u);
});

test('refreshRepo command without a tree node prompts and refreshes only the selected repository', async () => {
  const repositoryA: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
  const repositoryB: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'other' };
  let repositoryPickerCalls = 0;
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    showQuickPick: async (items, options) => {
      assert.equal(options.title, 'Repository');
      repositoryPickerCalls += 1;
      return items.find((item) =>
        typeof item === 'object' &&
        item !== null &&
        'repository' in item &&
        (item.repository as RepositoryRef).repo === 'other',
      );
    },
  });
  extension.activate(createExtensionContext([repositoryA, repositoryB]));
  const roots = await extension.treeProvider?.getChildren(undefined);
  assert.equal(roots?.length, 2);

  extension.firedTreeEvents.length = 0;
  await extension.commands.get('wallstopPrComments.refreshRepo')?.();

  assert.equal(repositoryPickerCalls, 1);
  assert.equal(extension.firedTreeEvents.length, 1);
  assert.equal(extension.firedTreeEvents[0], roots?.[1], 'command-palette refresh must fire the selected repo node');
});

test('refreshRepo command without a tree node is a no-op when repository picking is canceled', async () => {
  const repository: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
  let repositoryPickerCalls = 0;
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    showQuickPick: async (_items, options) => {
      assert.equal(options.title, 'Repository');
      repositoryPickerCalls += 1;
      return undefined;
    },
  });
  extension.activate(createExtensionContext([repository]));
  await extension.treeProvider?.getChildren(undefined);

  extension.firedTreeEvents.length = 0;
  await extension.commands.get('wallstopPrComments.refreshRepo')?.();

  assert.equal(repositoryPickerCalls, 1);
  assert.deepEqual(extension.firedTreeEvents, []);
});

test('openInBrowser command without a tree node prompts for a pull request', async () => {
  const repository: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
  const pullRequest: PullRequestSummary = {
    number: 42,
    title: 'Fix sidebar refresh',
    state: 'OPEN',
    isDraft: false,
    merged: false,
    author: 'octo',
    headRefName: 'fix/sidebar-refresh',
    updatedAt: '2026-06-24T00:00:00Z',
    url: 'https://github.com/wallstop/utils/pull/42',
  };
  const pickerTitles: string[] = [];
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    listPullRequests: async (target) => {
      assert.deepEqual(target, repository);
      return [pullRequest];
    },
    showQuickPick: async (items, options) => {
      pickerTitles.push(options.title ?? '');
      if (options.title === 'Repository') {
        return items[0];
      }

      assert.equal(options.title, 'wallstop/utils Pull Request');
      return items[0];
    },
  });
  extension.activate(createExtensionContext([repository]));

  await extension.commands.get('wallstopPrComments.openInBrowser')?.();

  assert.deepEqual(pickerTitles, ['Repository', 'wallstop/utils Pull Request']);
  assert.deepEqual(extension.openedUrls, [pullRequest.url]);
});

test('openInBrowser command surfaces picker load failures instead of throwing raw command errors', async () => {
  const repository: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    listPullRequests: async () => {
      throw fakeTokenFailure();
    },
    showQuickPick: async (items, options) => {
      assert.equal(options.title, 'Repository');
      return items[0];
    },
  });
  extension.activate(createExtensionContext([repository]));

  await assert.doesNotReject(() => extension.commands.get('wallstopPrComments.openInBrowser')?.() as Promise<unknown>);

  assert.deepEqual(extension.openedUrls, []);
  assert.equal(extension.errorMessages.length, 1);
  assert.match(extension.errorMessages[0], /token \*\*\*REDACTED\*\*\* failed/u);
});

test('copyComments command surfaces picker load failures instead of throwing raw command errors', async () => {
  const repository: RepositoryRef = { host: 'github.com', owner: 'wallstop', repo: 'utils' };
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    listPullRequests: async () => {
      throw fakeTokenFailure();
    },
    showQuickPick: async (items, options) => {
      assert.equal(options.title, 'Repository');
      return items[0];
    },
  });
  extension.activate(createExtensionContext([repository]));

  await assert.doesNotReject(() => extension.commands.get('wallstopPrComments.copyComments')?.() as Promise<unknown>);

  assert.equal(extension.errorMessages.length, 1);
  assert.match(extension.errorMessages[0], /token \*\*\*REDACTED\*\*\* failed/u);
});

test('addRepo warns when repository enumeration only partially succeeds', async () => {
  const hosts: string[] = [];
  const selectedPickerTitles: string[] = [];
  const extension = loadExtensionWithVscodeStub({
    command: undefined,
    listAccessibleRepositories: async (host) => {
      hosts.push(host);
      if (host === 'github.example.com') {
        throw fakeTokenFailure();
      }

      return [
        {
          host,
          owner: 'wallstop',
          repo: 'utils',
          fullName: 'wallstop/utils',
          private: false,
          archived: false,
          fork: false,
          pushedAt: '2026-06-24T00:00:00Z',
        },
      ];
    },
    showQuickPick: async (_items, options) => {
      selectedPickerTitles.push(options.title ?? '');
      return [];
    },
  });
  extension.activate(
    createExtensionContext([{ host: 'github.example.com', owner: 'existing', repo: 'repo' }]),
  );

  await extension.commands.get('wallstopPrComments.addRepo')?.();

  assert.deepEqual(hosts, ['github.com', 'github.example.com']);
  assert.deepEqual(selectedPickerTitles, ['Add Repositories']);
  assert.equal(extension.warningMessages.length, 1);
  assert.match(extension.warningMessages[0], /Loaded repositories from 1 of 2 host\(s\)/u);
  assert.match(extension.warningMessages[0], /token \*\*\*REDACTED\*\*\* failed/u);
  assert.equal(extension.errorMessages.length, 0);
});
