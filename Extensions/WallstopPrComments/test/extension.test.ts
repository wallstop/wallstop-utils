import assert from 'node:assert/strict';
import Module from 'node:module';
import test from 'node:test';

import type { ReviewThreadRecord, WebSuggestedDiffResult } from '../src/types';

interface ExtensionTestExports {
  attachWebSuggestedDiffsAndCollectWarnings(
    records: ReviewThreadRecord[],
    webDiffs: WebSuggestedDiffResult,
  ): string[];
  getBrowserWebSuggestionsHtml(url: string): Promise<string | undefined>;
}

function loadExtensionWithVscodeStub(options: {
  command: string | undefined;
  workspaceCommand?: string;
  executeCommand: (command: string, url: string) => Promise<unknown>;
}): ExtensionTestExports {
  const moduleLoader = Module as unknown as {
    _load: (request: string, parent: NodeModule | null, isMain: boolean) => unknown;
  };
  const originalLoad = moduleLoader._load;
  moduleLoader._load = (request, parent, isMain) => {
    if (request === 'vscode') {
      return {
        authentication: { getSession: async () => undefined },
        commands: {
          executeCommand: options.executeCommand,
          registerCommand: () => ({ dispose: () => undefined }),
        },
        env: {
          clipboard: { writeText: async () => undefined },
          openExternal: async () => undefined,
        },
        ProgressLocation: { Notification: 1 },
        Uri: { parse: (value: string) => ({ value }) },
        window: {
          registerTreeDataProvider: () => ({ dispose: () => undefined }),
          showErrorMessage: async () => undefined,
          showInformationMessage: async () => undefined,
          showInputBox: async () => undefined,
          showQuickPick: async () => undefined,
          showWarningMessage: async () => undefined,
          withProgress: async (_options: unknown, task: () => Promise<unknown>) => task(),
        },
        workspace: {
          getConfiguration: () => ({
            inspect: (key: string) => key === 'browserWebSuggestionsCommand'
              ? { globalValue: options.command, workspaceValue: options.workspaceCommand }
              : undefined,
          }),
        },
      };
    }

    return originalLoad(request, parent, isMain);
  };

  try {
    delete require.cache[require.resolve('../src/extension')];
    return require('../src/extension') as ExtensionTestExports;
  } finally {
    moduleLoader._load = originalLoad;
  }
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
