import assert from 'node:assert/strict';
import test from 'node:test';

import { GitHubClient } from '../src/githubClient';
import type { FetchLike } from '../src/http';
import { reviewThreadToRecord } from '../src/records';

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

test('fails unresolved scope when authenticated GraphQL is unavailable', async () => {
  const client = new GitHubClient({
    getToken: async () => undefined,
    fetch: async () => {
      throw new Error('fetch should not be called');
    },
  });

  await assert.rejects(
    () => client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'unresolved'),
    /Authentication is required.*unresolved/i,
  );
});

test('falls back to REST for all review comments when GraphQL auth is unavailable', async () => {
  const fetch: FetchLike = async (url) => {
    assert.match(String(url), /\/repos\/org\/repo\/pulls\/10\/comments/);
    return jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/rest.ts',
        body: 'REST comment',
        line: 7,
        start_line: null,
        original_line: 7,
        original_start_line: null,
        diff_hunk: '@@ -1 +1 @@\n-old\n+new',
        user: { login: 'reviewer' },
        html_url: 'https://github.com/org/repo/pull/10#discussion_r1',
      },
    ]);
  };
  const client = new GitHubClient({ getToken: async () => undefined, fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].path, 'src/rest.ts');
  assert.equal(result.threads[0].isResolved, undefined);
  assert.equal(result.warnings[0], 'GraphQL authentication unavailable; copied all review comments from REST with unknown resolved state.');
});

test('REST fallback buckets nested review-comment replies by top-level root', async () => {
  const fetch: FetchLike = async () =>
    jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/rest.ts',
        body: 'Root comment',
        line: 7,
        original_line: 7,
        user: { login: 'reviewer' },
      },
      {
        id: 2,
        node_id: 'node-2',
        in_reply_to_id: 1,
        path: 'src/rest.ts',
        body: 'First reply',
        line: 7,
        original_line: 7,
        user: { login: 'reviewer' },
      },
      {
        id: 3,
        node_id: 'node-3',
        in_reply_to_id: 2,
        path: 'src/rest.ts',
        body: 'Nested reply',
        line: 7,
        original_line: 7,
        user: { login: 'reviewer' },
      },
    ]);
  const client = new GitHubClient({ getToken: async () => undefined, fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].id, 'rest-1');
  assert.deepEqual(result.threads[0].comments.map((comment) => comment.body), [
    'Root comment',
    'First reply',
    'Nested reply',
  ]);
});

test('maps outdated REST fallback comments to original line ranges', async () => {
  const fetch: FetchLike = async () =>
    jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/outdated.ts',
        body: 'Outdated comment',
        line: 99,
        start_line: 98,
        original_line: 7,
        original_start_line: 5,
        outdated: true,
        user: { login: 'reviewer' },
      },
    ]);
  const client = new GitHubClient({ getToken: async () => undefined, fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');
  const record = reviewThreadToRecord(result.threads[0]);

  assert.ok(record);
  assert.equal(record.lineStart, 5);
  assert.equal(record.lineEnd, 7);
});

test('falls back to REST for all review comments when GraphQL returns errors payload', async () => {
  const calls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    if (init?.body !== undefined) {
      calls.push('graphql');
      return jsonResponse({
        data: null,
        errors: [{ type: 'FORBIDDEN', message: 'Resource not accessible by integration' }],
      });
    }

    calls.push('rest');
    assert.match(String(url), /\/repos\/org\/repo\/pulls\/10\/comments/);
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, undefined);
    return jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/rest.ts',
        body: 'REST fallback comment',
        line: 7,
        start_line: null,
        original_line: 7,
        original_start_line: null,
        user: { login: 'reviewer' },
      },
    ]);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.deepEqual(calls, ['graphql', 'rest']);
  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].comments[0].body, 'REST fallback comment');
  assert.equal(result.warnings[0], 'GraphQL returned errors; copied all review comments from REST with unknown resolved state.');
});

test('passes interactive auth request through list and copy operations when requested', async () => {
  const tokenRequests: boolean[] = [];
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body !== undefined) {
      return jsonResponse({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          },
        },
      });
    }

    return jsonResponse([]);
  };
  const client = new GitHubClient({
    getToken: async (_host, createIfNone) => {
      tokenRequests.push(createIfNone === true);
      return 'token';
    },
    fetch,
  });

  await client.listPullRequests({ host: 'github.com', owner: 'org', repo: 'repo' }, { promptForAuth: true });
  await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all', { promptForAuth: true });

  assert.deepEqual(tokenRequests, [true, true]);
});

test('maps merged pull requests from REST merged_at data', async () => {
  const fetch: FetchLike = async () =>
    jsonResponse([
      {
        number: 12,
        title: 'Merged work',
        state: 'closed',
        draft: false,
        merged_at: '2026-01-01T00:00:00Z',
        user: { login: 'octo' },
        head: { ref: 'feature/merged' },
        updated_at: '2026-01-02T00:00:00Z',
        html_url: 'https://github.com/org/repo/pull/12',
      },
    ]);
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const pullRequests = await client.listPullRequests({ host: 'github.com', owner: 'org', repo: 'repo' });

  assert.equal(pullRequests[0].merged, true);
});

test('paginates review threads and nested thread comments through GraphQL', async () => {
  const seenOperations: string[] = [];
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body === undefined) {
      return jsonResponse([]);
    }

    const request = JSON.parse(String(init?.body));
    seenOperations.push(request.operationName);

    if (request.operationName === 'ReviewThreadsPage' && request.variables.threadsCursor === null) {
      return jsonResponse({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [
                  {
                    id: 'thread-1',
                    path: 'src/a.ts',
                    isResolved: false,
                    isOutdated: false,
                    line: 1,
                    startLine: null,
                    originalLine: 1,
                    originalStartLine: null,
                    comments: {
                      nodes: [
                        {
                          id: 'comment-1',
                          databaseId: 1,
                          body: 'Top',
                          diffHunk: null,
                          path: 'src/a.ts',
                          line: 1,
                          startLine: null,
                          originalLine: 1,
                          originalStartLine: null,
                          author: { login: 'reviewer' },
                          url: 'https://github.com/org/repo/pull/10#discussion_r1',
                        },
                      ],
                      pageInfo: { hasNextPage: true, endCursor: 'comment-cursor-1' },
                    },
                  },
                ],
                pageInfo: { hasNextPage: true, endCursor: 'thread-cursor-1' },
              },
            },
          },
        },
      });
    }

    if (request.operationName === 'ReviewThreadCommentsPage') {
      assert.equal(request.variables.threadId, 'thread-1');
      assert.equal(request.variables.commentsCursor, 'comment-cursor-1');
      return jsonResponse({
        data: {
          node: {
            comments: {
              nodes: [
                {
                  id: 'comment-2',
                  databaseId: 2,
                  body: ['Reply suggestion', '', '```suggestion', 'reply();', '```'].join('\n'),
                  diffHunk: null,
                  path: 'src/a.ts',
                  line: 1,
                  startLine: null,
                  originalLine: 1,
                  originalStartLine: null,
                  author: { login: 'reviewer' },
                  url: 'https://github.com/org/repo/pull/10#discussion_r2',
                },
              ],
              pageInfo: { hasNextPage: false, endCursor: null },
            },
          },
        },
      });
    }

    if (request.operationName === 'ReviewThreadsPage' && request.variables.threadsCursor === 'thread-cursor-1') {
      return jsonResponse({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [
                  {
                    id: 'thread-2',
                    path: 'src/b.ts',
                    isResolved: true,
                    isOutdated: false,
                    line: 4,
                    startLine: null,
                    originalLine: 4,
                    originalStartLine: null,
                    comments: {
                      nodes: [
                        {
                          id: 'comment-3',
                          databaseId: 3,
                          body: 'Resolved',
                          diffHunk: null,
                          path: 'src/b.ts',
                          line: 4,
                          startLine: null,
                          originalLine: 4,
                          originalStartLine: null,
                          author: { login: 'reviewer' },
                          url: 'https://github.com/org/repo/pull/10#discussion_r3',
                        },
                      ],
                      pageInfo: { hasNextPage: false, endCursor: null },
                    },
                  },
                ],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          },
        },
      });
    }

    throw new Error(`unexpected operation ${request.operationName}`);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.deepEqual(seenOperations.slice(0, 3), ['ReviewThreadsPage', 'ReviewThreadCommentsPage', 'ReviewThreadsPage']);
  assert.equal(result.threads.length, 2);
  assert.equal(result.threads[0].comments.length, 2);
  assert.equal(result.threads[0].comments[1].body.includes('```suggestion'), true);
});

test('uses REST review comments to cross-check and fill raw bodies by database id', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body) {
      return jsonResponse({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [
                  {
                    id: 'thread-1',
                    path: 'src/fill.ts',
                    isResolved: false,
                    isOutdated: false,
                    line: 3,
                    startLine: null,
                    originalLine: 3,
                    originalStartLine: null,
                    comments: {
                      nodes: [
                        {
                          id: 'comment-1',
                          databaseId: 123,
                          body: '',
                          diffHunk: null,
                          path: 'src/fill.ts',
                          line: 3,
                          startLine: null,
                          originalLine: 3,
                          originalStartLine: null,
                          author: { login: 'reviewer' },
                          url: 'https://github.com/org/repo/pull/10#discussion_r123',
                        },
                      ],
                      pageInfo: { hasNextPage: false, endCursor: null },
                    },
                  },
                ],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          },
        },
      });
    }

    return jsonResponse([
      {
        id: 123,
        node_id: 'comment-1',
        path: 'src/fill.ts',
        body: ['REST body', '', '```suggestion', 'fromRest();', '```'].join('\n'),
        line: 3,
        start_line: null,
        original_line: 3,
        original_start_line: null,
        diff_hunk: '@@ -1 +1 @@\n-context',
        user: { login: 'reviewer' },
        html_url: 'https://github.com/org/repo/pull/10#discussion_r123',
      },
    ]);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'unresolved');

  assert.equal(result.threads[0].comments[0].body, ['REST body', '', '```suggestion', 'fromRest();', '```'].join('\n'));
  assert.equal(result.threads[0].comments[0].diffHunk, '@@ -1 +1 @@\n-context');
});

test('keeps GraphQL results when REST cross-check fails', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body) {
      return jsonResponse({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [
                  {
                    id: 'thread-1',
                    path: 'src/graphql.ts',
                    isResolved: false,
                    isOutdated: false,
                    line: 11,
                    startLine: null,
                    originalLine: 11,
                    originalStartLine: null,
                    comments: {
                      nodes: [
                        {
                          id: 'comment-1',
                          databaseId: 123,
                          body: 'GraphQL body',
                          diffHunk: null,
                          path: 'src/graphql.ts',
                          line: 11,
                          startLine: null,
                          originalLine: 11,
                          originalStartLine: null,
                          author: { login: 'reviewer' },
                          url: 'https://github.com/org/repo/pull/10#discussion_r123',
                        },
                      ],
                      pageInfo: { hasNextPage: false, endCursor: null },
                    },
                  },
                ],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          },
        },
      });
    }

    return new Response('REST unavailable', { status: 503 });
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'unresolved');

  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].comments[0].body, 'GraphQL body');
  assert.match(result.warnings[0], /REST review-comment cross-check failed/i);
});
