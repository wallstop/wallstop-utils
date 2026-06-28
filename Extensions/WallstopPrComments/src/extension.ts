import * as vscode from 'vscode';

import { AuthService, redactSecrets } from './auth';
import { GitHubClient } from './githubClient';
import { formatReviewThreadRecords } from './renderer';
import { attachWebSuggestedDiffs, unmatchedSuggestionKeys } from './webSuggestions';
import {
  buildAddRepoQuickPickItems,
  enumerationHosts,
  parseRepositoryInput,
  RepositoryStore,
  selectableRepositories,
} from './repositoryStore';
import { collectUnavailableSuggestionWarnings, reviewThreadToRecord } from './records';
import { PrCommentsTreeProvider, type PullRequestNode, type TreeNode } from './treeProvider';
import { AutoRefreshScheduler, type AutoRefreshConfig } from './autoRefresh';
import type { AccessibleRepository, RepositoryRef, ReviewScope, ReviewThreadRecord, WebSuggestedDiffResult } from './types';

const SCOPE_KEY = 'wallstopPrComments.scope';

export function activate(context: vscode.ExtensionContext): void {
  const store = new RepositoryStore(context.globalState);
  const auth = new AuthService({
    getGitHubSession: async (scopes, createIfNone) => {
      try {
        const session = await vscode.authentication.getSession('github', scopes, { createIfNone });
        return session?.accessToken;
      } catch {
        return undefined;
      }
    },
    getSecret: async (key) => context.secrets.get(key),
    storeSecret: async (key, value) => context.secrets.store(key, value),
    deleteSecret: async (key) => context.secrets.delete(key),
  });
  const output = vscode.window.createOutputChannel('Wallstop PR Comments');
  const client = new GitHubClient({
    getToken: (host, createIfNone) => auth.getToken(host, createIfNone),
    getWebCookie: (host) => auth.getWebCookie(host),
    browserWebHtmlProvider: (url) => getBrowserWebSuggestionsHtml(url),
    log: (message) => output.appendLine(`[${new Date().toISOString()}] ${message}`),
  });
  const provider = new PrCommentsTreeProvider(store, client);
  const autoRefresh = new AutoRefreshScheduler({
    refresh: () => provider.refresh(),
    getConfig: () => readAutoRefreshConfig(),
    setInterval: (handler, ms) => setInterval(handler, ms),
    clearInterval: (handle) => clearInterval(handle),
  });
  autoRefresh.reconfigure();

  context.subscriptions.push(
    output,
    vscode.window.registerTreeDataProvider('wallstopPrComments.repos', provider),
    { dispose: () => autoRefresh.dispose() },
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('wallstopPrComments.autoRefresh')) {
        autoRefresh.reconfigure();
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.refresh', () => provider.refresh()),
    vscode.commands.registerCommand('wallstopPrComments.refreshRepo', async (node?: TreeNode) => {
      const repository = findRepository(node) ?? (await pickRepository(store.list()));
      if (repository !== undefined) {
        provider.refresh(repository);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.addRepo', () =>
      addRepositoriesInteractively(store, client, provider),
    ),
    vscode.commands.registerCommand('wallstopPrComments.removeRepo', async (node?: RepositoryNode) => {
      const repository = node?.repository ?? (await pickRepository(store.list()));
      if (repository === undefined) {
        return;
      }

      await store.remove(repository);
      provider.refresh();
    }),
    vscode.commands.registerCommand('wallstopPrComments.setScope', async () => {
      const selected = await vscode.window.showQuickPick(
        [
          { label: 'Unresolved', scope: 'unresolved' as const, description: 'Current actionable review threads' },
          { label: 'All review comments', scope: 'all' as const, description: 'Every file review comment' },
          { label: 'Resolved only', scope: 'resolved' as const, description: 'Only resolved review threads' },
        ],
        { title: 'Review Comment Scope' },
      );
      if (selected !== undefined) {
        await context.globalState.update(SCOPE_KEY, selected.scope);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.copyComments', async (node?: PullRequestNode) => {
      const target = node ?? (await pickPullRequest(store.list(), client));
      if (target === undefined) {
        return;
      }

      await copyReviewComments(context, client, target.repository, target.pullRequest.number);
    }),
    vscode.commands.registerCommand('wallstopPrComments.openInBrowser', async (node?: PullRequestNode) => {
      try {
        const target = node ?? (await pickPullRequest(store.list(), client));
        if (target?.pullRequest.url !== undefined && target.pullRequest.url !== '') {
          await vscode.env.openExternal(vscode.Uri.parse(target.pullRequest.url));
        }
      } catch (error) {
        await showError(error);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.setToken', async (node?: TreeNode) => {
      const repository = findRepository(node) ?? (await pickRepository(store.list()));
      if (repository === undefined) {
        return;
      }

      const token = await vscode.window.showInputBox({
        title: `Set Manual Token for ${repository.host}`,
        prompt: 'Stored in VS Code SecretStorage. Used as fallback, and by default for GHES.',
        password: true,
        ignoreFocusOut: true,
      });
      if (token !== undefined) {
        await auth.storeToken(repository.host, token);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.clearToken', async (node?: TreeNode) => {
      const repository = findRepository(node) ?? (await pickRepository(store.list()));
      if (repository !== undefined) {
        await auth.clearToken(repository.host);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.setWebCookie', async (node?: TreeNode) => {
      const repository = findRepository(node) ?? (await pickRepository(store.list()));
      if (repository === undefined) {
        return;
      }

      const cookie = await vscode.window.showInputBox({
        title: `Set GitHub Web Cookie for ${repository.host}`,
        prompt: 'Optional best-effort enrichment for web-only Copilot suggested changesets.',
        password: true,
        ignoreFocusOut: true,
      });
      if (cookie !== undefined) {
        await auth.storeWebCookie(repository.host, cookie);
      }
    }),
    vscode.commands.registerCommand('wallstopPrComments.clearWebCookie', async (node?: TreeNode) => {
      const repository = findRepository(node) ?? (await pickRepository(store.list()));
      if (repository !== undefined) {
        await auth.clearWebCookie(repository.host);
      }
    }),
  );
}

export function deactivate(): void {
  // No resources to dispose beyond VS Code subscriptions.
}

async function copyReviewComments(
  context: vscode.ExtensionContext,
  client: GitHubClient,
  repository: RepositoryRef,
  prNumber: number,
): Promise<void> {
  const scope = getCurrentScope(context);
  try {
    const result = await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `Copying PR #${prNumber} review comments`,
      },
      async () => client.getReviewThreads(repository, prNumber, scope, { promptForAuth: true }),
    );

    const includeDiffHunks = getIncludeDiffHunks();
    const records = result.threads
      .map((thread) => reviewThreadToRecord(thread, { includeDiffHunks }))
      .filter(isReviewThreadRecord);
    try {
      const webDiffs = await client.getWebSuggestedDiffs(repository, prNumber, {
        allowBrowserFallback: getBrowserWebSuggestionsCommand() !== undefined,
      });
      result.warnings.push(...attachWebSuggestedDiffsAndCollectWarnings(records, webDiffs));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      result.warnings.push(`Optional GitHub web suggested-change enrichment failed: ${message}`);
    }
    result.warnings.push(...collectUnavailableSuggestionWarnings(records));

    const text = formatReviewThreadRecords(records);
    await vscode.env.clipboard.writeText(text);
    if (result.warnings.length > 0) {
      await vscode.window.showWarningMessage(`Copied PR comments with warnings: ${result.warnings.join(' ')}`);
    } else {
      await vscode.window.showInformationMessage(`Copied PR #${prNumber} review comments.`);
    }
  } catch (error) {
    await showError(error);
  }
}

export function attachWebSuggestedDiffsAndCollectWarnings(
  records: ReviewThreadRecord[],
  webDiffs: WebSuggestedDiffResult,
): string[] {
  if (webDiffs.suggestions.size === 0) {
    return webDiffs.provenance === 'webSuggestionMarkersUnparseable'
      ? [
          'Detected a GitHub suggested change on the PR files page but could not parse its diff (the rendered format may have changed); open the PR on GitHub to view it.',
        ]
      : [];
  }

  const warnings: string[] = [];
  const attached = attachWebSuggestedDiffs(records, webDiffs.suggestions);
  const unmatched = unmatchedSuggestionKeys(records, webDiffs.suggestions);
  if (attached > 0) {
    warnings.push(`Attached ${attached} suggested change diff(s) from ${webDiffs.provenance}.`);
  }

  if (unmatched.length > 0) {
    warnings.push(
      `Extracted web suggested changes for ${webDiffs.suggestions.size} comment id(s) from ${webDiffs.provenance}, but ${unmatched.length} did not match copied review comments (unmatched comment ids: ${unmatched.join(', ')}).`,
    );
  } else if (attached === 0) {
    warnings.push(
      `Extracted web suggested changes for ${webDiffs.suggestions.size} comment id(s) from ${webDiffs.provenance}, but no new diffs were attached to copied review comments.`,
    );
  }

  return warnings;
}

async function addRepositoriesInteractively(
  store: RepositoryStore,
  client: GitHubClient,
  provider: PrCommentsTreeProvider,
): Promise<void> {
  const hosts = enumerationHosts(store.list());
  let accessible: AccessibleRepository[];
  try {
    accessible = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Loading accessible repositories…' },
      async () => {
        const settled = await Promise.allSettled(
          hosts.map((host) => client.listAccessibleRepositories(host, { promptForAuth: true })),
        );
        const repositories = settled.flatMap((result) => (result.status === 'fulfilled' ? result.value : []));
        const firstFailure = settled.find((result): result is PromiseRejectedResult => result.status === 'rejected');
        // Only treat listing as failed when nothing came back at all; a single bad host (e.g. a GHES
        // host without a token) should not block repos that loaded from another host.
        if (repositories.length === 0 && firstFailure !== undefined) {
          throw firstFailure.reason;
        }

        return repositories;
      },
    );
  } catch (error) {
    await showError(error);
    await addRepositoryManually(store, provider);
    return;
  }

  const items = buildAddRepoQuickPickItems(selectableRepositories(accessible, store.list()));
  const picks = await vscode.window.showQuickPick(items, {
    title: 'Add Repositories',
    placeHolder: 'Select repositories to add (type to filter), or choose manual entry',
    canPickMany: true,
    matchOnDescription: true,
    matchOnDetail: true,
    ignoreFocusOut: true,
  });
  if (picks === undefined || picks.length === 0) {
    return;
  }

  let added = false;
  let manualRequested = false;
  for (const pick of picks) {
    if (pick.manualEntry === true) {
      manualRequested = true;
    } else if (pick.repository !== undefined) {
      await store.add(pick.repository);
      added = true;
    }
  }

  if (added) {
    provider.refresh();
  }

  if (manualRequested) {
    await addRepositoryManually(store, provider);
  }
}

async function addRepositoryManually(store: RepositoryStore, provider: PrCommentsTreeProvider): Promise<void> {
  const input = await vscode.window.showInputBox({
    title: 'Add GitHub Repository',
    prompt: 'Enter owner/repo or a GitHub HTTPS repository URL.',
    ignoreFocusOut: true,
  });
  if (input === undefined) {
    return;
  }

  try {
    await store.add(parseRepositoryInput(input));
    provider.refresh();
  } catch (error) {
    await showError(error);
  }
}

export async function getBrowserWebSuggestionsHtml(url: string): Promise<string | undefined> {
  const command = getBrowserWebSuggestionsCommand();
  if (command === undefined) {
    return undefined;
  }

  const result = await vscode.commands.executeCommand<unknown>(command, url);
  if (typeof result === 'string') {
    return result;
  }

  if (isRecord(result) && typeof result.html === 'string') {
    return result.html;
  }

  throw new Error(`Browser web suggestions command '${command}' must return an HTML string or { html: string }.`);
}

function getIncludeDiffHunks(): boolean {
  const configured = vscode.workspace.getConfiguration('wallstopPrComments').get<boolean>('includeDiffHunks');
  return configured !== false;
}

function readAutoRefreshConfig(): AutoRefreshConfig {
  const config = vscode.workspace.getConfiguration('wallstopPrComments');
  return {
    enabled: config.get<boolean>('autoRefresh.enabled') !== false,
    intervalMinutes: config.get<number>('autoRefresh.intervalMinutes') ?? 10,
  };
}

function getBrowserWebSuggestionsCommand(): string | undefined {
  const command = vscode.workspace
    .getConfiguration('wallstopPrComments')
    .inspect<string>('browserWebSuggestionsCommand')
    ?.globalValue
    ?.trim();
  return command === '' ? undefined : command;
}

function getCurrentScope(context: vscode.ExtensionContext): ReviewScope {
  const stateScope = context.globalState.get<ReviewScope>(SCOPE_KEY);
  if (stateScope === 'all' || stateScope === 'resolved' || stateScope === 'unresolved') {
    return stateScope;
  }

  const configured = vscode.workspace.getConfiguration('wallstopPrComments').get<ReviewScope>('defaultScope');
  return configured === 'all' || configured === 'resolved' || configured === 'unresolved' ? configured : 'unresolved';
}

async function pickRepository(repositories: RepositoryRef[]): Promise<RepositoryRef | undefined> {
  const selected = await vscode.window.showQuickPick(
    repositories.map((repository) => ({
      label: `${repository.owner}/${repository.repo}`,
      description: repository.host,
      repository,
    })),
    { title: 'Repository' },
  );
  return selected?.repository;
}

async function pickPullRequest(
  repositories: RepositoryRef[],
  client: GitHubClient,
): Promise<PullRequestNode | undefined> {
  const repository = await pickRepository(repositories);
  if (repository === undefined) {
    return undefined;
  }

  const pullRequests = await client.listPullRequests(repository, { promptForAuth: true });
  const selected = await vscode.window.showQuickPick(
    pullRequests.map((pullRequest) => ({
      label: `#${pullRequest.number} ${pullRequest.title}`,
      description: `${pullRequest.merged ? 'merged' : pullRequest.isDraft ? 'draft' : pullRequest.state.toLowerCase()} by ${pullRequest.author}`,
      pullRequest,
    })),
    { title: `${repository.owner}/${repository.repo} Pull Request` },
  );

  return selected === undefined
    ? undefined
    : {
        kind: 'pullRequest',
        repository,
        pullRequest: selected.pullRequest,
      };
}

function findRepository(node: TreeNode | undefined): RepositoryRef | undefined {
  if (node === undefined || node.kind === 'empty') {
    return undefined;
  }

  return node.repository;
}

async function showError(error: unknown): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  await vscode.window.showErrorMessage(redactSecrets(message));
}

function isReviewThreadRecord(record: ReviewThreadRecord | undefined): record is ReviewThreadRecord {
  return record !== undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
