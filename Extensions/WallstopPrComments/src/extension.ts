import * as vscode from 'vscode';

import { AuthService, redactSecrets } from './auth';
import { GitHubClient } from './githubClient';
import { formatReviewThreadRecords } from './renderer';
import { attachWebSuggestedDiffs } from './webSuggestions';
import { parseRepositoryInput, RepositoryStore } from './repositoryStore';
import { collectUnavailableSuggestionWarnings, reviewThreadToRecord } from './records';
import { PrCommentsTreeProvider, type PullRequestNode, type RepositoryNode, type TreeNode } from './treeProvider';
import type { RepositoryRef, ReviewScope, ReviewThreadRecord } from './types';

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
  const client = new GitHubClient({
    getToken: (host, createIfNone) => auth.getToken(host, createIfNone),
    getWebCookie: (host) => auth.getWebCookie(host),
  });
  const provider = new PrCommentsTreeProvider(store, client);

  context.subscriptions.push(
    vscode.window.registerTreeDataProvider('wallstopPrComments.repos', provider),
    vscode.commands.registerCommand('wallstopPrComments.refresh', () => provider.refresh()),
    vscode.commands.registerCommand('wallstopPrComments.addRepo', async () => {
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
    }),
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
      if (node?.pullRequest.url !== undefined && node.pullRequest.url !== '') {
        await vscode.env.openExternal(vscode.Uri.parse(node.pullRequest.url));
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

    const records = result.threads.map(reviewThreadToRecord).filter(isReviewThreadRecord);
    try {
      const webDiffs = await client.getWebSuggestedDiffs(repository, prNumber);
      if (webDiffs.size > 0) {
        const attached = attachWebSuggestedDiffs(records, webDiffs);
        if (attached > 0) {
          result.warnings.push(`Attached ${attached} GitHub web suggested change diff(s).`);
        }
      }
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
