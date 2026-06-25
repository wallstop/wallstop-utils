import assert from 'node:assert/strict';
import Module from 'node:module';
import test from 'node:test';

function loadExtensionWithVscodeStub(options: {
  command: string | undefined;
  workspaceCommand?: string;
  executeCommand: (command: string, url: string) => Promise<unknown>;
}): { getBrowserWebSuggestionsHtml: (url: string) => Promise<string | undefined> } {
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
    return require('../src/extension') as { getBrowserWebSuggestionsHtml: (url: string) => Promise<string | undefined> };
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
