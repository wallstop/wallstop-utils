import * as vscode from 'vscode';

import { groupPullRequests, repositoryKey } from './repositoryStore';
import type { GitHubClient } from './githubClient';
import type { PullRequestSummary, RepositoryRef } from './types';

export type TreeNode = RepositoryNode | GroupNode | PullRequestNode | EmptyNode;

export interface RepositoryNode {
  kind: 'repository';
  repository: RepositoryRef;
}

export interface GroupNode {
  kind: 'group';
  repository: RepositoryRef;
  label: string;
  pullRequests: PullRequestSummary[];
  expanded: boolean;
}

export interface PullRequestNode {
  kind: 'pullRequest';
  repository: RepositoryRef;
  pullRequest: PullRequestSummary;
}

interface EmptyNode {
  kind: 'empty';
  label: string;
}

export interface RepositorySource {
  list(): RepositoryRef[];
}

export class PrCommentsTreeProvider implements vscode.TreeDataProvider<TreeNode> {
  private readonly onDidChangeTreeDataEmitter = new vscode.EventEmitter<TreeNode | undefined>();
  readonly onDidChangeTreeData = this.onDidChangeTreeDataEmitter.event;
  private readonly pullRequestCache = new Map<string, PullRequestSummary[]>();
  private readonly errorCache = new Map<string, string>();

  constructor(
    private readonly repositories: RepositorySource,
    private readonly client: GitHubClient,
  ) {}

  refresh(): void {
    this.pullRequestCache.clear();
    this.errorCache.clear();
    this.onDidChangeTreeDataEmitter.fire(undefined);
  }

  async getChildren(element?: TreeNode): Promise<TreeNode[]> {
    if (element === undefined) {
      const repositories = this.repositories.list();
      return repositories.length === 0
        ? [{ kind: 'empty', label: 'No repositories pinned' }]
        : repositories.map((repository) => ({ kind: 'repository', repository }));
    }

    if (element.kind === 'repository') {
      return this.getRepositoryChildren(element.repository);
    }

    if (element.kind === 'group') {
      return element.pullRequests.length === 0
        ? [{ kind: 'empty', label: 'No pull requests' }]
        : element.pullRequests.map((pullRequest) => ({
            kind: 'pullRequest',
            repository: element.repository,
            pullRequest,
          }));
    }

    return [];
  }

  getTreeItem(element: TreeNode): vscode.TreeItem {
    switch (element.kind) {
      case 'repository':
        return this.repositoryTreeItem(element.repository);
      case 'group':
        return this.groupTreeItem(element);
      case 'pullRequest':
        return this.pullRequestTreeItem(element);
      case 'empty':
        return new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.None);
    }
  }

  private async getRepositoryChildren(repository: RepositoryRef): Promise<TreeNode[]> {
    const key = repositoryKey(repository);
    if (!this.pullRequestCache.has(key) && !this.errorCache.has(key)) {
      try {
        this.pullRequestCache.set(key, await this.client.listPullRequests(repository, { promptForAuth: true }));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.errorCache.set(key, message);
      }
    }

    const error = this.errorCache.get(key);
    if (error !== undefined) {
      return [{ kind: 'empty', label: `Failed to load PRs: ${error}` }];
    }

    const grouped = groupPullRequests(this.pullRequestCache.get(key) ?? []);
    return [
      {
        kind: 'group',
        repository,
        label: `Open Pull Requests (${grouped.open.length})`,
        pullRequests: grouped.open,
        expanded: true,
      },
      {
        kind: 'group',
        repository,
        label: `Closed / Merged Pull Requests (${grouped.closed.length})`,
        pullRequests: grouped.closed,
        expanded: false,
      },
    ];
  }

  private repositoryTreeItem(repository: RepositoryRef): vscode.TreeItem {
    const item = new vscode.TreeItem(
      `${repository.owner}/${repository.repo}`,
      vscode.TreeItemCollapsibleState.Expanded,
    );
    item.description = repository.host;
    item.contextValue = 'repository';
    item.iconPath = new vscode.ThemeIcon('repo');
    item.tooltip = `${repository.host}/${repository.owner}/${repository.repo}`;
    return item;
  }

  private groupTreeItem(group: GroupNode): vscode.TreeItem {
    const item = new vscode.TreeItem(
      group.label,
      group.expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed,
    );
    item.iconPath = new vscode.ThemeIcon(group.expanded ? 'git-pull-request' : 'archive');
    return item;
  }

  private pullRequestTreeItem(node: PullRequestNode): vscode.TreeItem {
    const pr = node.pullRequest;
    const state = pr.merged ? 'merged' : pr.isDraft ? 'draft' : pr.state.toLowerCase();
    const item = new vscode.TreeItem(`#${pr.number} ${pr.title}`, vscode.TreeItemCollapsibleState.None);
    item.description = `${state} by ${pr.author} | ${pr.headRefName} | updated ${formatRelativeTime(pr.updatedAt)}`;
    item.tooltip = `#${pr.number} ${pr.title}\n${state} by ${pr.author}\n${pr.headRefName}\nUpdated ${pr.updatedAt}`;
    item.contextValue = 'pullRequest';
    item.iconPath = new vscode.ThemeIcon(pr.state === 'OPEN' ? 'git-pull-request' : 'git-merge');
    item.command = {
      command: 'wallstopPrComments.copyComments',
      title: 'Copy Review Comments',
      arguments: [node],
    };
    return item;
  }
}

function formatRelativeTime(isoDate: string): string {
  const timestamp = Date.parse(isoDate);
  if (!Number.isFinite(timestamp)) {
    return 'unknown';
  }

  const diffMs = Date.now() - timestamp;
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (diffMs < hour) {
    return `${Math.max(1, Math.round(diffMs / minute))}m ago`;
  }
  if (diffMs < day) {
    return `${Math.round(diffMs / hour)}h ago`;
  }

  return `${Math.round(diffMs / day)}d ago`;
}
