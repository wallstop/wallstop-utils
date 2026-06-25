import { sanitizeHeaderValue } from './auth';
import { extractAutomatedSuggestedDiffsFromHtml } from './webSuggestions';
import { HttpError, isAuthFailure, readJsonResponse, type FetchLike } from './http';
import { assertSafeGitHubHost } from './repositoryStore';
import type {
  PullRequestSummary,
  RepositoryRef,
  ReviewComment,
  ReviewScope,
  ReviewThread,
  ReviewThreadResult,
  WebSuggestedDiffResult,
} from './types';

interface GitHubClientOptions {
  getToken(host: string, createIfNone?: boolean): Promise<string | undefined>;
  getWebCookie?(host: string): Promise<string | undefined>;
  browserWebHtmlProvider?(url: string): Promise<string | undefined>;
  fetch?: FetchLike;
}

interface AuthRequestOptions {
  promptForAuth?: boolean;
}

interface WebSuggestionRequestOptions {
  allowBrowserFallback?: boolean;
}

interface GraphQLPageInfo {
  hasNextPage: boolean;
  endCursor: string | null;
}

interface GraphQLCommentNode {
  id: string;
  databaseId?: number | string;
  body?: string;
  diffHunk?: string | null;
  path?: string | null;
  line?: number | null;
  startLine?: number | null;
  originalLine?: number | null;
  originalStartLine?: number | null;
  author?: { login?: string | null } | null;
  url?: string | null;
}

interface GraphQLThreadNode {
  id: string;
  path?: string | null;
  isResolved?: boolean | null;
  isOutdated?: boolean | null;
  line?: number | null;
  startLine?: number | null;
  originalLine?: number | null;
  originalStartLine?: number | null;
  comments: {
    nodes: GraphQLCommentNode[];
    pageInfo: GraphQLPageInfo;
  };
}

interface ReviewThreadsPageData {
  repository?: {
    pullRequest?: {
      reviewThreads: {
        nodes: GraphQLThreadNode[];
        pageInfo: GraphQLPageInfo;
      };
    } | null;
  } | null;
}

interface ReviewThreadCommentsPageData {
  node?: {
    comments: {
      nodes: GraphQLCommentNode[];
      pageInfo: GraphQLPageInfo;
    };
  } | null;
}

interface RestReviewComment {
  id?: number;
  node_id?: string;
  in_reply_to_id?: number | null;
  path?: string;
  body?: string;
  line?: number | null;
  start_line?: number | null;
  original_line?: number | null;
  original_start_line?: number | null;
  diff_hunk?: string | null;
  outdated?: boolean | null;
  user?: { login?: string | null } | null;
  html_url?: string | null;
}

const REVIEW_THREADS_QUERY = `
query ReviewThreadsPage($owner: String!, $repo: String!, $prNumber: Int!, $threadsCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 50, after: $threadsCursor) {
        nodes {
          id
          path
          isResolved
          isOutdated
          line
          startLine
          originalLine
          originalStartLine
          comments(first: 50) {
            nodes {
              id
              databaseId
              body
              diffHunk
              path
              line
              startLine
              originalLine
              originalStartLine
              author { login }
              url
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}`;

const THREAD_COMMENTS_QUERY = `
query ReviewThreadCommentsPage($threadId: ID!, $commentsCursor: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 50, after: $commentsCursor) {
        nodes {
          id
          databaseId
          body
          diffHunk
          path
          line
          startLine
          originalLine
          originalStartLine
          author { login }
          url
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}`;

export class GitHubClient {
  private readonly fetch: FetchLike;

  constructor(private readonly options: GitHubClientOptions) {
    this.fetch = options.fetch ?? fetch;
  }

  async listPullRequests(repository: RepositoryRef, options: AuthRequestOptions = {}): Promise<PullRequestSummary[]> {
    const token = await this.options.getToken(repository.host, options.promptForAuth === true);
    const response = await this.fetch(
      `${restBaseUrl(repository.host)}/repos/${encodeURIComponent(repository.owner)}/${encodeURIComponent(repository.repo)}/pulls?state=all&per_page=50&sort=updated&direction=desc`,
      { headers: this.restHeaders(token) },
    );
    const pullRequests = await readJsonResponse<unknown[]> (response, 'List pull requests');
    return pullRequests.filter(isRecord).map((pullRequest) => ({
      number: readNumber(pullRequest.number) ?? 0,
      title: readString(pullRequest.title) ?? '(untitled)',
      state: readString(pullRequest.state)?.toUpperCase() === 'OPEN' ? 'OPEN' : 'CLOSED',
      isDraft: readBoolean(pullRequest.draft) ?? false,
      merged: readString(pullRequest.merged_at) !== undefined,
      author: isRecord(pullRequest.user) ? readString(pullRequest.user.login) ?? 'unknown' : 'unknown',
      headRefName: isRecord(pullRequest.head) ? readString(pullRequest.head.ref) ?? '' : '',
      updatedAt: readString(pullRequest.updated_at) ?? '',
      url: readString(pullRequest.html_url) ?? '',
    }));
  }

  async getReviewThreads(
    repository: RepositoryRef,
    prNumber: number,
    scope: ReviewScope,
    options: AuthRequestOptions = {},
  ): Promise<ReviewThreadResult> {
    const token = await this.options.getToken(repository.host, options.promptForAuth === true);
    if (token === undefined && scope !== 'all') {
      throw new Error(`Authentication is required to copy ${scope} review threads because REST cannot expose resolved state.`);
    }

    if (token === undefined) {
      return {
        threads: await this.fetchRestReviewThreads(repository, prNumber, undefined),
        warnings: ['GraphQL authentication unavailable; copied all review comments from REST with unknown resolved state.'],
      };
    }

    try {
      const warnings: string[] = [];
      const threads = await this.fetchGraphQLReviewThreads(repository, prNumber, token);
      try {
        const restComments = await this.fetchRestReviewComments(repository, prNumber, token);
        mergeRestComments(threads, restComments);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        warnings.push(`REST review-comment cross-check failed; using GraphQL comment bodies only. ${message}`);
      }

      return {
        threads: threads.filter((thread) => scope === 'all' || (scope === 'unresolved' ? thread.isResolved === false : thread.isResolved === true)),
        warnings,
      };
    } catch (error) {
      if (scope === 'all' && shouldFallbackToRestForAllScope(error)) {
        return this.fetchRestReviewThreadsAfterGraphQLFallback(repository, prNumber, token, allScopeFallbackReason(error));
      }

      throw error;
    }
  }

  async getWebSuggestedDiffs(
    repository: RepositoryRef,
    prNumber: number,
    options: WebSuggestionRequestOptions = {},
  ): Promise<WebSuggestedDiffResult> {
    if (repository.host.toLowerCase() !== 'github.com') {
      return { suggestions: new Map(), provenance: 'webOnlyUnavailable' };
    }

    const url = `https://github.com/${encodeURIComponent(repository.owner)}/${encodeURIComponent(repository.repo)}/pull/${prNumber}/files`;
    const publicHtml = await this.fetchGitHubWebHtml(url, undefined, false);
    if (publicHtml !== undefined) {
      const publicSuggestions = extractAutomatedSuggestedDiffsFromHtml(publicHtml, 'githubWebAutomatedDiff');
      if (publicSuggestions.size > 0) {
        return { suggestions: publicSuggestions, provenance: 'githubWebAutomatedDiff' };
      }
    }

    const safeCookie = sanitizeHeaderValue(await this.options.getWebCookie?.(repository.host));
    let privateFetchError: unknown;
    if (safeCookie !== undefined) {
      try {
        const privateHtml = await this.fetchGitHubWebHtml(url, { Cookie: safeCookie }, true);
        if (privateHtml !== undefined) {
          const privateSuggestions = extractAutomatedSuggestedDiffsFromHtml(privateHtml, 'githubWebAutomatedDiff');
          if (privateSuggestions.size > 0) {
            return { suggestions: privateSuggestions, provenance: 'githubWebAutomatedDiff' };
          }
        }
      } catch (error) {
        privateFetchError = error;
      }
    }

    if (options.allowBrowserFallback === true && this.options.browserWebHtmlProvider !== undefined) {
      const browserHtml = await this.options.browserWebHtmlProvider(url);
      if (browserHtml !== undefined) {
        const browserSuggestions = extractAutomatedSuggestedDiffsFromHtml(browserHtml, 'browserDomAutomatedDiff');
        if (browserSuggestions.size > 0) {
          return { suggestions: browserSuggestions, provenance: 'browserDomAutomatedDiff' };
        }
      }
    }

    if (privateFetchError !== undefined) {
      throw privateFetchError;
    }

    return { suggestions: new Map(), provenance: 'webOnlyUnavailable' };
  }

  private async fetchGitHubWebHtml(
    url: string,
    headers: Record<string, string> | undefined,
    throwOnFailure: boolean,
  ): Promise<string | undefined> {
    const response = await this.fetch(url, headers === undefined ? undefined : { headers });
    const html = await response.text();
    if (!response.ok) {
      if (throwOnFailure) {
        throw new HttpError('Fetch GitHub web PR page failed.', response.status, html);
      }

      return undefined;
    }

    return html;
  }

  private async fetchGraphQLReviewThreads(repository: RepositoryRef, prNumber: number, token: string): Promise<ReviewThread[]> {
    const threads: ReviewThread[] = [];
    let threadsCursor: string | null = null;
    do {
      const data: ReviewThreadsPageData = await this.graphql<ReviewThreadsPageData>(repository.host, token, REVIEW_THREADS_QUERY, {
        owner: repository.owner,
        repo: repository.repo,
        prNumber,
        threadsCursor,
      }, 'ReviewThreadsPage');
      const page = data.repository?.pullRequest?.reviewThreads;
      if (page === undefined) {
        throw new Error('Pull request reviewThreads were not present in the GraphQL response.');
      }

      for (const node of page.nodes) {
        const thread = mapGraphQLThread(node);
        await this.fetchRemainingGraphQLComments(repository.host, token, thread, node.comments.pageInfo);
        threads.push(thread);
      }

      threadsCursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
    } while (threadsCursor !== null);

    return threads;
  }

  private async fetchRemainingGraphQLComments(
    host: string,
    token: string,
    thread: ReviewThread,
    pageInfo: GraphQLPageInfo,
  ): Promise<void> {
    let commentsCursor = pageInfo.hasNextPage ? pageInfo.endCursor : null;
    while (commentsCursor !== null) {
      const data: ReviewThreadCommentsPageData = await this.graphql<ReviewThreadCommentsPageData>(host, token, THREAD_COMMENTS_QUERY, {
        threadId: thread.id,
        commentsCursor,
      }, 'ReviewThreadCommentsPage');
      const comments = data.node?.comments;
      if (comments === undefined) {
        throw new Error(`Review thread comments were not present for ${thread.id}.`);
      }

      thread.comments.push(...comments.nodes.map(mapGraphQLComment));
      commentsCursor = comments.pageInfo.hasNextPage ? comments.pageInfo.endCursor : null;
    }
  }

  private async graphql<T>(
    host: string,
    token: string,
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
  ): Promise<T> {
    assertGraphQLVariableMap(query, variables);
    const response = await this.fetch(graphqlEndpoint(host), {
      method: 'POST',
      headers: {
        ...this.restHeaders(token),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, variables, operationName }),
    });
    const payload = await readJsonResponse<{ data?: T; errors?: unknown[] }>(response, operationName);
    if (payload.errors !== undefined && payload.errors.length > 0) {
      throw new GraphQLErrorsError(operationName, payload.errors);
    }

    if (payload.data === undefined) {
      throw new Error(`${operationName} returned no data.`);
    }

    return payload.data;
  }

  private async fetchRestReviewThreads(repository: RepositoryRef, prNumber: number, token: string | undefined): Promise<ReviewThread[]> {
    return restCommentsToThreads(await this.fetchRestReviewComments(repository, prNumber, token));
  }

  private async fetchRestReviewThreadsAfterGraphQLFallback(
    repository: RepositoryRef,
    prNumber: number,
    token: string | undefined,
    reason: string,
  ): Promise<ReviewThreadResult> {
    const warnings = [`${reason}; copied all review comments from REST with unknown resolved state.`];
    try {
      return {
        threads: await this.fetchRestReviewThreads(repository, prNumber, token),
        warnings,
      };
    } catch (error) {
      if (token === undefined || !isAuthFailure(error)) {
        throw error;
      }

      return {
        threads: await this.fetchRestReviewThreads(repository, prNumber, undefined),
        warnings: [
          ...warnings,
          'Authenticated REST fallback failed; retried unauthenticated REST for public review comments.',
        ],
      };
    }
  }

  private async fetchRestReviewComments(repository: RepositoryRef, prNumber: number, token: string | undefined): Promise<RestReviewComment[]> {
    const comments: RestReviewComment[] = [];
    for (let page = 1; page <= 100; page++) {
      const response = await this.fetch(
        `${restBaseUrl(repository.host)}/repos/${encodeURIComponent(repository.owner)}/${encodeURIComponent(repository.repo)}/pulls/${prNumber}/comments?per_page=100&page=${page}`,
        { headers: this.restHeaders(token) },
      );
      const pageComments = await readJsonResponse<RestReviewComment[]>(response, 'List review comments');
      comments.push(...pageComments);
      if (pageComments.length < 100) {
        break;
      }
    }

    return comments;
  }

  private restHeaders(token: string | undefined): Record<string, string> {
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    const safeToken = sanitizeHeaderValue(token);
    if (safeToken !== undefined) {
      headers.Authorization = `Bearer ${safeToken}`;
    }

    return headers;
  }
}

class GraphQLErrorsError extends Error {
  constructor(
    operationName: string,
    readonly errors: unknown[],
  ) {
    super(`${operationName} returned GraphQL errors: ${JSON.stringify(errors)}`);
  }
}

function shouldFallbackToRestForAllScope(error: unknown): boolean {
  return isAuthFailure(error) || error instanceof GraphQLErrorsError;
}

function allScopeFallbackReason(error: unknown): string {
  return error instanceof GraphQLErrorsError ? 'GraphQL returned errors' : 'GraphQL authentication failed';
}

export function assertGraphQLVariableMap(query: string, variables: Record<string, unknown>): void {
  const declaredVariables = [...query.matchAll(/\$([A-Za-z_][A-Za-z0-9_]*)/gu)].map((match) => match[1]);
  const expected = [...new Set(declaredVariables)];
  const actual = Object.keys(variables);
  const missing = expected.filter((key) => !actual.includes(key));
  const unexpected = actual.filter((key) => !expected.includes(key));
  if (missing.length > 0 || unexpected.length > 0) {
    throw new Error(`GraphQL variable map does not match query variables. Missing: ${missing.join(', ') || '(none)'}; unexpected: ${unexpected.join(', ') || '(none)'}.`);
  }
}

function graphqlEndpoint(host: string): string {
  const safeHost = assertSafeGitHubHost(host);
  return safeHost === 'github.com' ? 'https://api.github.com/graphql' : `https://${safeHost}/api/graphql`;
}

function restBaseUrl(host: string): string {
  const safeHost = assertSafeGitHubHost(host);
  return safeHost === 'github.com' ? 'https://api.github.com' : `https://${safeHost}/api/v3`;
}

function mapGraphQLThread(node: GraphQLThreadNode): ReviewThread {
  return {
    id: node.id,
    path: node.path ?? '<conversation>',
    isResolved: node.isResolved ?? undefined,
    isOutdated: node.isOutdated ?? undefined,
    line: node.line ?? undefined,
    startLine: node.startLine ?? undefined,
    originalLine: node.originalLine ?? undefined,
    originalStartLine: node.originalStartLine ?? undefined,
    comments: node.comments.nodes.map(mapGraphQLComment),
  };
}

function mapGraphQLComment(node: GraphQLCommentNode): ReviewComment {
  return {
    id: node.id,
    databaseId: node.databaseId,
    body: node.body ?? '',
    authorLogin: node.author?.login ?? undefined,
    url: node.url ?? undefined,
    diffHunk: node.diffHunk ?? undefined,
    path: node.path ?? undefined,
    line: node.line ?? undefined,
    startLine: node.startLine ?? undefined,
    originalLine: node.originalLine ?? undefined,
    originalStartLine: node.originalStartLine ?? undefined,
  };
}

function restCommentsToThreads(comments: readonly RestReviewComment[]): ReviewThread[] {
  const byId = new Map<number, RestReviewComment>();
  for (const comment of comments) {
    if (comment.id !== undefined) {
      byId.set(comment.id, comment);
    }
  }

  const groups = new Map<number, RestReviewComment[]>();
  for (const comment of comments) {
    if (comment.id === undefined) {
      continue;
    }

    const rootId = findRestThreadRootId(comment, byId);
    const group = groups.get(rootId) ?? [];
    group.push(comment);
    groups.set(rootId, group);
  }

  return [...groups.entries()].map(([rootId, group]) => {
    const rootComment = byId.get(rootId);
    const orderedGroup = rootComment === undefined
      ? group
      : [rootComment, ...group.filter((comment) => comment.id !== rootId)];
    const first = rootComment ?? orderedGroup[0];
    return {
      id: `rest-${rootId}`,
      path: first.path ?? '<conversation>',
      isResolved: undefined,
      isOutdated: first.outdated ?? false,
      line: first.line ?? first.original_line ?? undefined,
      startLine: first.start_line ?? first.original_start_line ?? undefined,
      originalLine: first.original_line ?? undefined,
      originalStartLine: first.original_start_line ?? undefined,
      comments: orderedGroup.map(mapRestComment),
    };
  });
}

function findRestThreadRootId(comment: RestReviewComment, byId: ReadonlyMap<number, RestReviewComment>): number {
  if (comment.id === undefined) {
    throw new Error('REST review comment root lookup requires a comment id.');
  }

  const originalId = comment.id;
  let current = comment;
  let rootId = originalId;
  const seen = new Set<number>();

  while (current.id !== undefined) {
    if (seen.has(current.id)) {
      return originalId;
    }
    seen.add(current.id);

    const parentId = current.in_reply_to_id ?? undefined;
    if (parentId === undefined) {
      return rootId;
    }

    rootId = parentId;
    const parent = byId.get(parentId);
    if (parent === undefined) {
      return rootId;
    }

    current = parent;
  }

  return rootId;
}

function mapRestComment(comment: RestReviewComment): ReviewComment {
  return {
    id: comment.node_id,
    nodeId: comment.node_id,
    databaseId: comment.id,
    body: comment.body ?? '',
    authorLogin: comment.user?.login ?? undefined,
    url: comment.html_url ?? undefined,
    diffHunk: comment.diff_hunk ?? undefined,
    path: comment.path,
    line: comment.line ?? undefined,
    startLine: comment.start_line ?? undefined,
    originalLine: comment.original_line ?? undefined,
    originalStartLine: comment.original_start_line ?? undefined,
  };
}

function mergeRestComments(threads: ReviewThread[], restComments: readonly RestReviewComment[]): void {
  const byDatabaseId = new Map<number, RestReviewComment>();
  const byNodeId = new Map<string, RestReviewComment>();
  for (const comment of restComments) {
    if (comment.id !== undefined) {
      byDatabaseId.set(comment.id, comment);
    }
    if (comment.node_id !== undefined) {
      byNodeId.set(comment.node_id, comment);
    }
  }

  for (const thread of threads) {
    for (const comment of thread.comments) {
      const restByDatabaseId = typeof comment.databaseId === 'number' ? byDatabaseId.get(comment.databaseId) : undefined;
      const rest = restByDatabaseId ?? byNodeId.get(comment.id ?? '');
      if (rest === undefined) {
        continue;
      }

      comment.body = rest.body ?? comment.body;
      comment.diffHunk = rest.diff_hunk ?? comment.diffHunk;
      comment.path = rest.path ?? comment.path;
      comment.line = rest.line ?? comment.line;
      comment.startLine = rest.start_line ?? comment.startLine;
      comment.originalLine = rest.original_line ?? comment.originalLine;
      comment.originalStartLine = rest.original_start_line ?? comment.originalStartLine;
    }
  }
}

function readString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function readNumber(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined;
}

function readBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
