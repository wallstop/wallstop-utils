import { sanitizeHeaderValue } from './auth';
import { extractAutomatedSuggestedDiffsFromHtml, htmlHasSuggestionMarkers } from './webSuggestions';
import { HttpError, isAuthFailure, readJsonResponse, type FetchLike } from './http';
import { assertSafeGitHubHost } from './repositoryStore';
import { createResilientFetch, type RetryInfo } from './resilientFetch';
import type {
  AccessibleRepository,
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
  /** Injected for instant, deterministic retry/backoff tests; defaults to real timers. */
  sleep?: (ms: number) => Promise<void>;
  /** Injected clock for Retry-After/rate-limit math; defaults to {@link Date.now}. */
  now?: () => number;
  /** Maximum retry attempts for transient HTTP and GraphQL rate-limit failures. */
  maxRetries?: number;
  /** Optional sink for diagnostic messages (e.g. transient retries), surfaced via an output channel. */
  log?: (message: string) => void;
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

const GRAPHQL_MAX_RETRIES = 3;

/** Page cap for `GET /user/repos` (100 per page) so very large accounts stay bounded. */
const MAX_REPOSITORY_PAGES = 20;

export class GitHubClient {
  private readonly fetch: FetchLike;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private readonly maxRetries: number;

  constructor(private readonly options: GitHubClientOptions) {
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.now = options.now ?? Date.now;
    this.maxRetries = options.maxRetries ?? GRAPHQL_MAX_RETRIES;
    this.fetch = createResilientFetch(options.fetch ?? fetch, {
      sleep: this.sleep,
      now: this.now,
      maxRetries: this.maxRetries,
      onRetry: options.log === undefined ? undefined : (info) => options.log?.(formatRetryLog(info)),
    });
  }

  async listPullRequests(repository: RepositoryRef, options: AuthRequestOptions = {}): Promise<PullRequestSummary[]> {
    const normalizedRepository = normalizeRepositoryRef(repository);
    const token = await this.options.getToken(normalizedRepository.host, options.promptForAuth === true);
    const response = await this.fetch(
      `${restBaseUrl(normalizedRepository.host)}/repos/${encodeURIComponent(normalizedRepository.owner)}/${encodeURIComponent(normalizedRepository.repo)}/pulls?state=all&per_page=50&sort=updated&direction=desc`,
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

  async listAccessibleRepositories(host: string, options: AuthRequestOptions = {}): Promise<AccessibleRepository[]> {
    const safeHost = assertSafeGitHubHost(host);
    const token = await this.options.getToken(safeHost, options.promptForAuth === true);
    if (token === undefined) {
      throw new Error(`Authentication is required to list repositories for ${safeHost}.`);
    }

    const repositories: AccessibleRepository[] = [];
    for (let page = 1; page <= MAX_REPOSITORY_PAGES; page++) {
      let pageRepositories: unknown[];
      try {
        const response = await this.fetch(
          `${restBaseUrl(safeHost)}/user/repos?per_page=100&page=${page}&sort=pushed&affiliation=owner,collaborator,organization_member`,
          { headers: this.restHeaders(token) },
        );
        pageRepositories = await readJsonResponse<unknown[]>(response, 'List accessible repositories');
        if (!Array.isArray(pageRepositories)) {
          throw new Error('List accessible repositories returned a non-array response.');
        }

        for (const value of pageRepositories) {
          const mapped = mapAccessibleRepository(safeHost, value);
          if (mapped !== undefined) {
            repositories.push(mapped);
          }
        }
      } catch (error) {
        // Keep repositories already gathered when a later page fails; a first-page failure still
        // throws so auth and host issues surface clearly instead of producing an empty picker.
        if (repositories.length === 0) {
          throw error;
        }

        this.options.log?.(`Stopped paginating accessible repositories for ${safeHost} after a failed page; results may be incomplete. ${error instanceof Error ? error.message : String(error)}`);
        break;
      }

      if (pageRepositories.length < 100) {
        break;
      }
    }

    return repositories;
  }

  async getReviewThreads(
    repository: RepositoryRef,
    prNumber: number,
    scope: ReviewScope,
    options: AuthRequestOptions = {},
  ): Promise<ReviewThreadResult> {
    const normalizedRepository = normalizeRepositoryRef(repository);
    const token = await this.options.getToken(normalizedRepository.host, options.promptForAuth === true);
    if (token === undefined && scope !== 'all') {
      throw new Error(`Authentication is required to copy ${scope} review threads because REST cannot expose resolved state.`);
    }

    if (token === undefined) {
      const warnings = ['GraphQL authentication unavailable; copied all review comments from REST with unknown resolved state.'];
      const threads = await this.fetchRestReviewThreads(normalizedRepository, prNumber, undefined, warnings);
      return { threads, warnings };
    }

    try {
      const warnings: string[] = [];
      const threads = await this.fetchGraphQLReviewThreads(normalizedRepository, prNumber, token, warnings);
      try {
        // Best-effort enrichment of GraphQL bodies; intentionally not given the `warnings` sink, so a
        // partial REST page here does not raise a misleading "incomplete" alarm over data GraphQL
        // already supplies in full. A first-page failure still throws and is reported just below.
        const restComments = await this.fetchRestReviewComments(normalizedRepository, prNumber, token);
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
        return this.fetchRestReviewThreadsAfterGraphQLFallback(normalizedRepository, prNumber, token, allScopeFallbackReason(error));
      }

      throw error;
    }
  }

  async getWebSuggestedDiffs(
    repository: RepositoryRef,
    prNumber: number,
    options: WebSuggestionRequestOptions = {},
  ): Promise<WebSuggestedDiffResult> {
    const normalizedRepository = normalizeRepositoryRef(repository);
    if (normalizedRepository.host !== 'github.com') {
      return { suggestions: new Map(), provenance: 'webOnlyUnavailable' };
    }

    const url = `https://github.com/${encodeURIComponent(normalizedRepository.owner)}/${encodeURIComponent(normalizedRepository.repo)}/pull/${prNumber}/files`;
    let sawSuggestionMarkers = false;
    const publicHtml = await this.fetchGitHubWebHtml(url, undefined, false);
    if (publicHtml !== undefined) {
      const publicSuggestions = extractAutomatedSuggestedDiffsFromHtml(publicHtml, 'githubWebAutomatedDiff');
      if (publicSuggestions.size > 0) {
        return { suggestions: publicSuggestions, provenance: 'githubWebAutomatedDiff' };
      }
      sawSuggestionMarkers ||= htmlHasSuggestionMarkers(publicHtml);
    }

    const safeCookie = sanitizeHeaderValue(await this.options.getWebCookie?.(normalizedRepository.host));
    let privateFetchError: unknown;
    if (safeCookie !== undefined) {
      try {
        const privateHtml = await this.fetchGitHubWebHtml(url, { Cookie: safeCookie }, true);
        if (privateHtml !== undefined) {
          const privateSuggestions = extractAutomatedSuggestedDiffsFromHtml(privateHtml, 'githubWebAutomatedDiff');
          if (privateSuggestions.size > 0) {
            return { suggestions: privateSuggestions, provenance: 'githubWebAutomatedDiff' };
          }
          sawSuggestionMarkers ||= htmlHasSuggestionMarkers(privateHtml);
        }
      } catch (error) {
        privateFetchError = error;
      }
    }

    if (options.allowBrowserFallback === true && this.options.browserWebHtmlProvider !== undefined) {
      try {
        const browserHtml = await this.options.browserWebHtmlProvider(url);
        if (browserHtml !== undefined) {
          const browserSuggestions = extractAutomatedSuggestedDiffsFromHtml(browserHtml, 'browserDomAutomatedDiff');
          if (browserSuggestions.size > 0) {
            return { suggestions: browserSuggestions, provenance: 'browserDomAutomatedDiff' };
          }
          sawSuggestionMarkers ||= htmlHasSuggestionMarkers(browserHtml);
        }
      } catch (error) {
        if (!sawSuggestionMarkers) {
          throw error;
        }
      }
    }

    if (sawSuggestionMarkers) {
      return {
        suggestions: new Map(),
        provenance: 'webSuggestionMarkersUnparseable',
      };
    }

    if (privateFetchError !== undefined) {
      throw privateFetchError;
    }

    return {
      suggestions: new Map(),
      provenance: 'webOnlyUnavailable',
    };
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

  private async fetchGraphQLReviewThreads(
    repository: RepositoryRef,
    prNumber: number,
    token: string,
    warnings: string[],
  ): Promise<ReviewThread[]> {
    const threads: ReviewThread[] = [];
    let threadsCursor: string | null = null;
    do {
      try {
        const data: ReviewThreadsPageData = await this.graphql<ReviewThreadsPageData>(repository.host, token, REVIEW_THREADS_QUERY, {
          owner: repository.owner,
          repo: repository.repo,
          prNumber,
          threadsCursor,
        }, 'ReviewThreadsPage', warnings);
        const page = data.repository?.pullRequest?.reviewThreads;
        if (page === undefined) {
          throw new Error('Pull request reviewThreads were not present in the GraphQL response.');
        }

        for (const node of page.nodes) {
          const thread = mapGraphQLThread(node);
          await this.fetchRemainingGraphQLComments(repository.host, token, thread, node.comments.pageInfo, warnings);
          threads.push(thread);
        }

        threadsCursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
      } catch (error) {
        // Preserve threads already gathered: a transient failure on a later page must not discard
        // the whole pull request. A first-page failure still throws so getReviewThreads can fall
        // back to REST for all-scope copies.
        if (threads.length === 0) {
          throw error;
        }

        warnings.push(`Stopped paginating review threads after a failed page; results may be incomplete. ${error instanceof Error ? error.message : String(error)}`);
        break;
      }
    } while (threadsCursor !== null);

    return threads;
  }

  private async fetchRemainingGraphQLComments(
    host: string,
    token: string,
    thread: ReviewThread,
    pageInfo: GraphQLPageInfo,
    warnings: string[],
  ): Promise<void> {
    let commentsCursor = pageInfo.hasNextPage ? pageInfo.endCursor : null;
    while (commentsCursor !== null) {
      try {
        const data: ReviewThreadCommentsPageData = await this.graphql<ReviewThreadCommentsPageData>(host, token, THREAD_COMMENTS_QUERY, {
          threadId: thread.id,
          commentsCursor,
        }, 'ReviewThreadCommentsPage', warnings);
        const comments = data.node?.comments;
        if (comments === undefined) {
          throw new Error(`Review thread comments were not present for ${thread.id}.`);
        }

        thread.comments.push(...comments.nodes.map(mapGraphQLComment));
        commentsCursor = comments.pageInfo.hasNextPage ? comments.pageInfo.endCursor : null;
      } catch (error) {
        // The thread already holds its first comment page from the parent query, so keep what we
        // have and let the caller continue with other threads rather than failing the whole copy.
        warnings.push(`Stopped paginating comments for review thread ${thread.id}; results may be incomplete. ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
    }
  }

  private async graphql<T>(
    host: string,
    token: string,
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
    warnings?: string[],
  ): Promise<T> {
    assertGraphQLVariableMap(query, variables);

    for (let attempt = 0; ; attempt++) {
      const response = await this.fetch(graphqlEndpoint(host), {
        method: 'POST',
        headers: {
          ...this.restHeaders(token),
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ query, variables, operationName }),
      });
      const payload = await readJsonResponse<{ data?: T | null; errors?: unknown[] }>(response, operationName);
      const errors = payload.errors !== undefined && payload.errors.length > 0 ? payload.errors : undefined;

      // GraphQL rate limits surface as HTTP 200 with `data:null` + a RATE_LIMITED error,
      // invisible to the HTTP layer. Back off and retry while we still have data null/absent.
      if (payload.data == null && errors !== undefined && isGraphQLRateLimited(errors) && attempt < this.maxRetries) {
        await this.sleep(graphqlBackoffDelay(attempt));
        continue;
      }

      // Gate on `!= null` (not `!== undefined`) so an explicit `data:null` still throws and
      // preserves the GraphQL-errors -> REST all-scope fallback.
      if (payload.data != null) {
        if (errors !== undefined) {
          warnings?.push(`${operationName} returned partial GraphQL data with errors: ${summarizeGraphQLErrors(errors)}`);
        }
        return payload.data;
      }

      if (errors !== undefined) {
        throw new GraphQLErrorsError(operationName, errors);
      }

      throw new Error(`${operationName} returned no data.`);
    }
  }

  private async fetchRestReviewThreads(repository: RepositoryRef, prNumber: number, token: string | undefined, warnings?: string[]): Promise<ReviewThread[]> {
    return restCommentsToThreads(await this.fetchRestReviewComments(repository, prNumber, token, warnings));
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
        threads: await this.fetchRestReviewThreads(repository, prNumber, token, warnings),
        warnings,
      };
    } catch (error) {
      if (token === undefined || !isAuthFailure(error)) {
        throw error;
      }

      const fallbackWarnings = [
        ...warnings,
        'Authenticated REST fallback failed; retried unauthenticated REST for public review comments.',
      ];
      return {
        threads: await this.fetchRestReviewThreads(repository, prNumber, undefined, fallbackWarnings),
        warnings: fallbackWarnings,
      };
    }
  }

  private async fetchRestReviewComments(
    repository: RepositoryRef,
    prNumber: number,
    token: string | undefined,
    warnings?: string[],
  ): Promise<RestReviewComment[]> {
    const comments: RestReviewComment[] = [];
    for (let page = 1; page <= 100; page++) {
      let pageComments: RestReviewComment[];
      try {
        const response = await this.fetch(
          `${restBaseUrl(repository.host)}/repos/${encodeURIComponent(repository.owner)}/${encodeURIComponent(repository.repo)}/pulls/${prNumber}/comments?per_page=100&page=${page}`,
          { headers: this.restHeaders(token) },
        );
        const parsed = await readJsonResponse<unknown>(response, 'List review comments');
        if (!Array.isArray(parsed)) {
          throw new Error('List review comments returned a non-array response.');
        }

        assertRestReviewCommentPage(parsed);
        pageComments = parsed as RestReviewComment[];
        comments.push(...pageComments);
      } catch (error) {
        // Keep comments already gathered when a later page fails; a first-page failure still throws
        // so the unauthenticated / all-scope REST paths surface (and can fall back on) the error.
        if (comments.length === 0) {
          throw error;
        }

        warnings?.push(`Stopped paginating REST review comments after a failed page; results may be incomplete. ${error instanceof Error ? error.message : String(error)}`);
        break;
      }

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

function isGraphQLRateLimited(errors: readonly unknown[]): boolean {
  return errors.some((error) => isRecord(error) && readString(error.type)?.toUpperCase() === 'RATE_LIMITED');
}

function graphqlBackoffDelay(attempt: number): number {
  // Bounded exponential backoff (1s, 2s, 4s, ... capped) for GraphQL rate-limit retries.
  return Math.min(1000 * 2 ** attempt, 30_000);
}

function summarizeGraphQLErrors(errors: readonly unknown[]): string {
  return errors
    .map((error) => {
      if (!isRecord(error)) {
        return String(error);
      }
      const type = readString(error.type);
      const message = readString(error.message);
      return [type, message].filter((part) => part !== undefined && part !== '').join(': ') || JSON.stringify(error);
    })
    .join('; ');
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

function normalizeRepositoryRef(repository: RepositoryRef): RepositoryRef {
  return {
    ...repository,
    host: assertSafeGitHubHost(repository.host),
  };
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

function assertRestReviewCommentPage(values: readonly unknown[]): void {
  for (const [index, value] of values.entries()) {
    if (!isRecord(value) || readNumber(value.id) === undefined) {
      throw new Error(`List review comments returned a malformed review comment at index ${index}.`);
    }
  }
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

function formatRetryLog(info: RetryInfo): string {
  const target = info.status !== undefined ? `HTTP ${info.status}` : 'a network error';
  const reason = info.rateLimited ? 'a rate limit' : 'a transient failure';
  return `Retrying after ${reason} (${target}); waiting ${info.waitMs}ms before attempt ${info.attempt + 2}.`;
}

function mapAccessibleRepository(host: string, value: unknown): AccessibleRepository | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const fullName = readString(value.full_name);
  const fromFullName = fullName !== undefined ? splitFullName(fullName) : undefined;
  const owner = (isRecord(value.owner) ? readString(value.owner.login) : undefined) ?? fromFullName?.owner;
  const repo = readString(value.name) ?? fromFullName?.repo;
  if (owner === undefined || owner === '' || repo === undefined || repo === '') {
    return undefined;
  }

  return {
    host,
    owner,
    repo,
    fullName: fullName ?? `${owner}/${repo}`,
    private: readBoolean(value.private) ?? false,
    archived: readBoolean(value.archived) ?? false,
    fork: readBoolean(value.fork) ?? false,
    pushedAt: readString(value.pushed_at),
    description: readString(value.description) ?? undefined,
  };
}

function splitFullName(fullName: string): { owner: string; repo: string } | undefined {
  const slash = fullName.indexOf('/');
  if (slash <= 0 || slash >= fullName.length - 1) {
    return undefined;
  }

  return { owner: fullName.slice(0, slash), repo: fullName.slice(slash + 1) };
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
