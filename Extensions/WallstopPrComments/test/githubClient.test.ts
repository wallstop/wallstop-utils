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
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, 'Bearer token');
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

test('retries all-scope REST fallback without auth only after authenticated REST auth failure', async () => {
  const calls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    if (init?.body !== undefined) {
      calls.push('graphql');
      return new Response(JSON.stringify({ message: 'bad credentials' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      });
    }

    const authorization = (init?.headers as Record<string, string> | undefined)?.Authorization;
    calls.push(authorization === undefined ? 'rest-unauthenticated' : 'rest-authenticated');
    assert.match(String(url), /\/repos\/org\/repo\/pulls\/10\/comments/);
    if (authorization !== undefined) {
      assert.equal(authorization, 'Bearer token');
      return new Response(JSON.stringify({ message: 'bad credentials' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      });
    }

    return jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/rest.ts',
        body: 'Public REST fallback comment',
        line: 7,
        original_line: 7,
        user: { login: 'reviewer' },
      },
    ]);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.deepEqual(calls, ['graphql', 'rest-authenticated', 'rest-unauthenticated']);
  assert.equal(result.threads[0].comments[0].body, 'Public REST fallback comment');
  assert.deepEqual(result.warnings, [
    'GraphQL authentication failed; copied all review comments from REST with unknown resolved state.',
    'Authenticated REST fallback failed; retried unauthenticated REST for public review comments.',
  ]);
});

test('falls back to REST when the GraphQL endpoint returns a real HTTP 403 (body consumed during retry classification)', async () => {
  const calls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    if (init?.body !== undefined) {
      calls.push('graphql');
      // A real HTTP 403 with NO rate-limit signal: resilientFetch reads this body to rule out a
      // secondary rate limit, then must hand it back readable so readJsonResponse can raise HttpError(403).
      return new Response(JSON.stringify({ message: 'Resource not accessible by integration' }), {
        status: 403,
        headers: { 'content-type': 'application/json' },
      });
    }

    calls.push('rest');
    assert.match(String(url), /\/repos\/org\/repo\/pulls\/10\/comments/);
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, 'Bearer token');
    return jsonResponse([
      {
        id: 1,
        node_id: 'node-1',
        path: 'src/rest.ts',
        body: 'REST fallback comment after 403',
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

  assert.deepEqual(calls, ['graphql', 'rest'], 'a GraphQL HTTP 403 must trigger the REST fallback, not throw a TypeError');
  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].comments[0].body, 'REST fallback comment after 403');
  assert.equal(result.warnings[0], 'GraphQL authentication failed; copied all review comments from REST with unknown resolved state.');
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

test('listPullRequests normalizes repository hosts before auth and REST calls', async () => {
  const tokenHosts: string[] = [];
  const urls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    urls.push(String(url));
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, 'Bearer token');
    return jsonResponse([]);
  };
  const client = new GitHubClient({
    getToken: async (host) => {
      tokenHosts.push(host);
      return 'token';
    },
    fetch,
  });

  const pullRequests = await client.listPullRequests({ host: ' GitHub.COM ', owner: 'org', repo: 'repo' });

  assert.deepEqual(tokenHosts, ['github.com']);
  assert.equal(pullRequests.length, 0);
  assert.match(urls[0], /^https:\/\/api\.github\.com\/repos\/org\/repo\/pulls\?/u);
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
  // Inject an instant sleep so the resilient-fetch backoff on the 503 cross-check does not
  // spend real time; the assertion (cross-check fails, GraphQL body preserved) is unchanged.
  const client = new GitHubClient({ getToken: async () => 'token', fetch, sleep: async () => undefined });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'unresolved');

  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].comments[0].body, 'GraphQL body');
  assert.match(result.warnings[0], /REST review-comment cross-check failed/i);
});

test('fetches public GitHub web suggested diffs without a cookie first', async () => {
  const calls: Array<{ url: string; headers: Record<string, string> | undefined }> = [];
  const fetch: FetchLike = async (url, init) => {
    calls.push({
      url: String(url),
      headers: init?.headers as Record<string, string> | undefined,
    });
    return new Response([
      '<script type="application/json" data-target="react-partial.embeddedData">',
      '{"props":{"comment":{"databaseId":42,"automatedComment":{"suggestion":{"diffEntries":[{"path":"src/public.ts","diffLines":[{"type":"DELETION","text":"old();"},{"type":"ADDITION","text":"new();"}]}]}}}}}',
      '</script>',
    ].join(''));
  };
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch,
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://github.com/org/repo/pull/10/files');
  assert.deepEqual(calls[0].headers, undefined);
  assert.equal(result.suggestions.get('42')?.[0].source, 'githubWebAutomatedDiff');
  assert.equal(result.provenance, 'githubWebAutomatedDiff');
});

test('retries private GitHub web suggested diffs with an explicit sanitized cookie after public fetch has no diffs', async () => {
  const calls: Array<Record<string, string> | undefined> = [];
  const fetch: FetchLike = async (_url, init) => {
    calls.push(init?.headers as Record<string, string> | undefined);
    if (calls.length === 1) {
      return new Response('<html>Sign in</html>', { status: 200 });
    }

    return new Response([
      '<script type="application/json" data-target="react-partial.embeddedData">',
      '{"props":{"comment":{"databaseId":42,"automatedComment":{"suggestion":{"diffEntries":[{"path":"src/private.ts","diffLines":[{"type":"DELETION","text":"old();"},{"type":"ADDITION","text":"new();"}]}]}}}}}',
      '</script>',
    ].join(''));
  };
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => '  user_session=abc\r\nInjected: nope  ',
    fetch,
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(calls.length, 2);
  assert.equal(calls[0], undefined);
  assert.deepEqual(calls[1], { Cookie: 'user_session=abcInjected: nope' });
  assert.equal(result.suggestions.get('42')?.[0].path, 'src/private.ts');
});

test('uses opt-in browser-backed extractor after raw GitHub web HTML exposes no diffs', async () => {
  const fetch: FetchLike = async () => new Response('<html>No embedded suggestions</html>');
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch,
    browserWebHtmlProvider: async (url) => {
      assert.equal(url, 'https://github.com/org/repo/pull/10/files');
      return [
        '<script type="application/json" data-target="react-partial.embeddedData">',
        '{"props":{"comment":{"databaseId":42,"automatedComment":{"suggestion":{"diffEntries":[{"path":"src/browser.ts","diffLines":[{"type":"DELETION","text":"old();"},{"type":"ADDITION","text":"new();"}]}]}}}}}',
        '</script>',
      ].join('');
    },
  });

  const result = await client.getWebSuggestedDiffs(
    { host: 'github.com', owner: 'org', repo: 'repo' },
    10,
    { allowBrowserFallback: true },
  );

  assert.equal(result.provenance, 'browserDomAutomatedDiff');
  assert.equal(result.suggestions.get('42')?.[0].source, 'browserDomAutomatedDiff');
  assert.equal(result.suggestions.get('42')?.[0].path, 'src/browser.ts');
});

test('uses opt-in browser-backed extractor when an explicit web cookie fetch fails', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.headers !== undefined) {
      return new Response('bad cookie', { status: 401 });
    }

    return new Response('<html>No embedded suggestions</html>');
  };
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => 'user_session=stale',
    fetch,
    browserWebHtmlProvider: async () => [
      '<script type="application/json" data-target="react-partial.embeddedData">',
      '{"props":{"comment":{"databaseId":42,"automatedComment":{"suggestion":{"diffEntries":[{"path":"src/browser.ts","diffLines":[{"type":"DELETION","text":"old();"},{"type":"ADDITION","text":"new();"}]}]}}}}}',
      '</script>',
    ].join(''),
  });

  const result = await client.getWebSuggestedDiffs(
    { host: 'github.com', owner: 'org', repo: 'repo' },
    10,
    { allowBrowserFallback: true },
  );

  assert.equal(result.provenance, 'browserDomAutomatedDiff');
  assert.equal(result.suggestions.get('42')?.[0].path, 'src/browser.ts');
});

test('reports explicit web cookie failures when browser fallback cannot provide suggestions', async () => {
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => 'user_session=stale',
    fetch: async (_url, init) => init?.headers === undefined
      ? new Response('<html>No embedded suggestions</html>')
      : new Response('bad cookie', { status: 401 }),
    browserWebHtmlProvider: async () => '<html>No embedded suggestions</html>',
  });

  await assert.rejects(
    () => client.getWebSuggestedDiffs(
      { host: 'github.com', owner: 'org', repo: 'repo' },
      10,
      { allowBrowserFallback: true },
    ),
    /Fetch GitHub web PR page failed/,
  );
});

test('preserves unparseable marker provenance instead of masking it with a later cookie failure', async () => {
  const calls: Array<Record<string, string> | undefined> = [];
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => 'user_session=stale',
    fetch: async (_url, init) => {
      calls.push(init?.headers as Record<string, string> | undefined);
      if (init?.headers !== undefined) {
        return new Response('bad cookie', { status: 401 });
      }

      return new Response([
        '<div class="js-comment" id="discussion_r42">',
        '  <div class="js-suggested-changes-blob"><!-- marker present, parser cannot read this shape --></div>',
        '</div>',
      ].join(''));
    },
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(calls.length, 2);
  assert.equal(result.suggestions.size, 0);
  assert.equal(result.provenance, 'webSuggestionMarkersUnparseable');
});

test('preserves unparseable marker provenance instead of masking it with a later browser fallback failure', async () => {
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch: async () => new Response([
      '<div class="js-comment" id="discussion_r42">',
      '  <div class="js-suggested-changes-blob"><!-- marker present, parser cannot read this shape --></div>',
      '</div>',
    ].join('')),
    browserWebHtmlProvider: async () => {
      throw new Error('Browser command unavailable');
    },
  });

  const result = await client.getWebSuggestedDiffs(
    { host: 'github.com', owner: 'org', repo: 'repo' },
    10,
    { allowBrowserFallback: true },
  );

  assert.equal(result.suggestions.size, 0);
  assert.equal(result.provenance, 'webSuggestionMarkersUnparseable');
});

test('does not use browser-backed extractor unless explicitly enabled', async () => {
  let browserCalled = false;
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch: async () => new Response('<html>No embedded suggestions</html>'),
    browserWebHtmlProvider: async () => {
      browserCalled = true;
      return '';
    },
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(browserCalled, false);
  assert.equal(result.suggestions.size, 0);
  assert.equal(result.provenance, 'webOnlyUnavailable');
});

test('getWebSuggestedDiffs normalizes repository hosts before github.com eligibility and cookie lookup', async () => {
  const cookieHosts: string[] = [];
  const urls: string[] = [];
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async (host) => {
      cookieHosts.push(host);
      return undefined;
    },
    fetch: async (url) => {
      urls.push(String(url));
      return new Response('<html>No embedded suggestions</html>');
    },
  });

  const result = await client.getWebSuggestedDiffs({ host: ' GitHub.COM ', owner: 'org', repo: 'repo' }, 10);

  assert.deepEqual(cookieHosts, ['github.com']);
  assert.deepEqual(urls, ['https://github.com/org/repo/pull/10/files']);
  assert.equal(result.provenance, 'webOnlyUnavailable');
});

test('reports unparseable provenance when the page shows suggestion markers it cannot parse', async () => {
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch: async () => new Response([
      '<div class="js-comment" id="discussion_r42">',
      '  <div class="js-suggested-changes-blob"><!-- format this extractor cannot read --></div>',
      '</div>',
    ].join('')),
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(result.suggestions.size, 0);
  assert.equal(result.provenance, 'webSuggestionMarkersUnparseable');
});

test('extracts rendered DOM suggestion tables from the public web page', async () => {
  const client = new GitHubClient({
    getToken: async () => 'api-token',
    getWebCookie: async () => undefined,
    fetch: async () => new Response([
      '<div class="js-comment" id="discussion_r42">',
      '  <div class="js-suggested-changes-blob">',
      '  <table class="diff-table">',
      '    <tr><td class="blob-code blob-code-deletion"><span class="blob-code-inner">old();</span></td></tr>',
      '    <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">new();</span></td></tr>',
      '  </table>',
      '  </div>',
      '</div>',
    ].join('')),
  });

  const result = await client.getWebSuggestedDiffs({ host: 'github.com', owner: 'org', repo: 'repo' }, 10);

  assert.equal(result.provenance, 'githubWebAutomatedDiff');
  assert.equal(result.suggestions.get('discussion_r42')?.[0].value, '-old();\n+new();');
  assert.equal(result.suggestions.get('discussion_r42')?.[0].source, 'githubWebAutomatedDiff');
});

function singleThreadGraphQLPage(body: string): unknown {
  return {
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
                      body,
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
                  pageInfo: { hasNextPage: false, endCursor: null },
                },
              },
            ],
            pageInfo: { hasNextPage: false, endCursor: null },
          },
        },
      },
    },
  };
}

test('retries a GraphQL RATE_LIMITED error (HTTP 200 + data:null) and then succeeds without falling back to REST', async () => {
  const sleeps: number[] = [];
  const operations: string[] = [];
  let graphqlAttempts = 0;
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body === undefined) {
      operations.push('rest');
      return jsonResponse([]);
    }

    graphqlAttempts += 1;
    operations.push('graphql');
    if (graphqlAttempts === 1) {
      return jsonResponse({
        data: null,
        errors: [{ type: 'RATE_LIMITED', message: 'API rate limit exceeded' }],
      });
    }

    return jsonResponse(singleThreadGraphQLPage('Top'));
  };
  const client = new GitHubClient({
    getToken: async () => 'token',
    fetch,
    sleep: async (ms: number) => {
      sleeps.push(ms);
    },
    now: () => 0,
  });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(graphqlAttempts, 2, 'a RATE_LIMITED GraphQL response must be retried, not surfaced as a hard error');
  assert.equal(operations.includes('rest'), true, 'the REST cross-check still runs after the retried GraphQL success');
  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].comments[0].body, 'Top');
  assert.equal(sleeps.length >= 1, true, 'the RATE_LIMITED retry must back off via the injected sleep');
});

test('uses partial GraphQL data when errors accompany a non-null data payload and warns', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body === undefined) {
      return jsonResponse([]);
    }

    return jsonResponse({
      ...(singleThreadGraphQLPage('Partial body') as { data: unknown }),
      errors: [{ type: 'SERVICE_UNAVAILABLE', message: 'Something failed for an adjacent field' }],
    });
  };
  const client = new GitHubClient({
    getToken: async () => 'token',
    fetch,
    sleep: async () => undefined,
    now: () => 0,
  });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(result.threads.length, 1, 'partial data must be used rather than thrown away');
  assert.equal(result.threads[0].comments[0].body, 'Partial body');
  assert.equal(
    result.warnings.some((warning) => /partial GraphQL data/i.test(warning)),
    true,
    'partial GraphQL data must surface a warning so the user knows the result may be incomplete',
  );
});

test('getReviewThreads normalizes repository hosts before auth, GraphQL, and REST cross-check calls', async () => {
  const tokenHosts: string[] = [];
  const urls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    urls.push(String(url));
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
    getToken: async (host) => {
      tokenHosts.push(host);
      return 'token';
    },
    fetch,
  });

  const result = await client.getReviewThreads(
    { host: ' GitHub.COM ', owner: 'org', repo: 'repo' },
    10,
    'all',
  );

  assert.deepEqual(tokenHosts, ['github.com']);
  assert.equal(result.threads.length, 0);
  assert.equal(urls[0], 'https://api.github.com/graphql');
  assert.match(urls[1], /^https:\/\/api\.github\.com\/repos\/org\/repo\/pulls\/10\/comments\?/u);
});

test('preserves earlier GraphQL review-thread pages when a later page keeps failing', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body === undefined) {
      return jsonResponse([]);
    }

    const request = JSON.parse(String(init.body));
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
                          body: 'First page comment',
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
                      pageInfo: { hasNextPage: false, endCursor: null },
                    },
                  },
                ],
                pageInfo: { hasNextPage: true, endCursor: 'threads-c1' },
              },
            },
          },
        },
      });
    }

    return new Response('upstream exploded', { status: 500 });
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch, sleep: async () => undefined, maxRetries: 1 });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(result.threads.length, 1);
  assert.equal(result.threads[0].id, 'thread-1', 'the gathered GraphQL thread must be kept, not replaced by a REST fallback');
  assert.equal(result.threads[0].comments[0].body, 'First page comment');
  assert.equal(
    result.warnings.some((warning) => /results may be incomplete/i.test(warning)),
    true,
    'a later-page failure must surface an incompleteness warning',
  );
});

test('preserves a review thread first comment page when its comment pagination keeps failing', async () => {
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body === undefined) {
      return jsonResponse([]);
    }

    const request = JSON.parse(String(init.body));
    if (request.operationName === 'ReviewThreadCommentsPage') {
      return new Response('comment page exploded', { status: 500 });
    }

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
                        body: 'Thread 1 first page',
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
                    pageInfo: { hasNextPage: true, endCursor: 'comments-c1' },
                  },
                },
                {
                  id: 'thread-2',
                  path: 'src/b.ts',
                  isResolved: false,
                  isOutdated: false,
                  line: 2,
                  startLine: null,
                  originalLine: 2,
                  originalStartLine: null,
                  comments: {
                    nodes: [
                      {
                        id: 'comment-2',
                        databaseId: 2,
                        body: 'Thread 2 complete',
                        diffHunk: null,
                        path: 'src/b.ts',
                        line: 2,
                        startLine: null,
                        originalLine: 2,
                        originalStartLine: null,
                        author: { login: 'reviewer' },
                        url: 'https://github.com/org/repo/pull/10#discussion_r2',
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
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch, sleep: async () => undefined, maxRetries: 1 });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  assert.equal(result.threads.length, 2, 'one thread failing its comment pagination must not drop other threads');
  assert.equal(result.threads[0].comments[0].body, 'Thread 1 first page');
  assert.equal(result.threads[1].comments[0].body, 'Thread 2 complete');
  assert.equal(
    result.warnings.some((warning) => /results may be incomplete/i.test(warning)),
    true,
    'a failed comment page must surface an incompleteness warning',
  );
});

test('preserves earlier REST review-comment pages when a later page keeps failing', async () => {
  const firstPage = Array.from({ length: 100 }, (_unused, index) => ({
    id: index + 1,
    node_id: `node-${index + 1}`,
    path: 'src/rest.ts',
    body: `comment ${index + 1}`,
    line: 1,
    original_line: 1,
    user: { login: 'reviewer' },
  }));
  const fetch: FetchLike = async (url) => {
    if (/[?&]page=1\b/u.test(String(url))) {
      return jsonResponse(firstPage);
    }

    return new Response('rest page exploded', { status: 500 });
  };
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  const totalComments = result.threads.reduce((sum, thread) => sum + thread.comments.length, 0);
  assert.equal(totalComments, 100, 'the gathered first REST page must be preserved when a later page fails');
  assert.equal(
    result.warnings.some((warning) => /results may be incomplete/i.test(warning)),
    true,
    'a failed REST page must surface an incompleteness warning',
  );
});

test('preserves earlier REST review-comment pages when a later page is malformed', async () => {
  const firstPage = Array.from({ length: 100 }, (_unused, index) => ({
    id: index + 1,
    node_id: `node-${index + 1}`,
    path: 'src/rest.ts',
    body: `comment ${index + 1}`,
    line: 1,
    original_line: 1,
    user: { login: 'reviewer' },
  }));
  const fetch: FetchLike = async (url) => {
    if (/[?&]page=1\b/u.test(String(url))) {
      return jsonResponse(firstPage);
    }

    return jsonResponse({ message: 'not an array' });
  };
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  const totalComments = result.threads.reduce((sum, thread) => sum + thread.comments.length, 0);
  assert.equal(totalComments, 100, 'the gathered first REST page must be preserved when a later malformed page fails');
  assert.equal(
    result.warnings.some((warning) => /results may be incomplete/i.test(warning) && /non-array response/i.test(warning)),
    true,
    'a malformed later REST page must surface an incompleteness warning',
  );
});

test('preserves earlier REST review-comment pages when a later page contains malformed items', async () => {
  const firstPage = Array.from({ length: 100 }, (_unused, index) => ({
    id: index + 1,
    node_id: `node-${index + 1}`,
    path: 'src/rest.ts',
    body: `comment ${index + 1}`,
    line: 1,
    original_line: 1,
    user: { login: 'reviewer' },
  }));
  const fetch: FetchLike = async (url) => {
    if (/[?&]page=1\b/u.test(String(url))) {
      return jsonResponse(firstPage);
    }

    return jsonResponse([{ message: 'not a review comment' }]);
  };
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  const result = await client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all');

  const totalComments = result.threads.reduce((sum, thread) => sum + thread.comments.length, 0);
  assert.equal(totalComments, 100, 'the gathered first REST page must be preserved when a later page has malformed entries');
  assert.equal(
    result.warnings.some((warning) => /results may be incomplete/i.test(warning) && /malformed review comment/i.test(warning)),
    true,
    'a malformed later REST page item must surface an incompleteness warning',
  );
});

test('propagates a first-page REST failure instead of silently returning empty results', async () => {
  const fetch: FetchLike = async () => new Response('rest page exploded', { status: 500 });
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  await assert.rejects(() => client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all'));
});

test('propagates a first-page malformed REST response instead of silently returning empty results', async () => {
  const fetch: FetchLike = async () => jsonResponse({ message: 'not an array' });
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  await assert.rejects(
    () => client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all'),
    /non-array response/u,
  );
});

test('propagates first-page malformed REST items instead of silently returning empty results', async () => {
  const fetch: FetchLike = async () => jsonResponse([{ message: 'not a review comment' }]);
  const client = new GitHubClient({ getToken: async () => undefined, fetch, sleep: async () => undefined, maxRetries: 1 });

  await assert.rejects(
    () => client.getReviewThreads({ host: 'github.com', owner: 'org', repo: 'repo' }, 10, 'all'),
    /malformed review comment/u,
  );
});

test('lists accessible repositories across paginated REST results and maps fields', async () => {
  const firstPage = Array.from({ length: 100 }, (_unused, index) => ({
    full_name: `wallstop/repo-${index + 1}`,
    name: `repo-${index + 1}`,
    owner: { login: 'wallstop' },
    private: index % 2 === 0,
    archived: false,
    fork: false,
    pushed_at: '2026-06-20T00:00:00Z',
    description: null,
  }));
  const secondPage = [
    {
      full_name: 'octo/tools',
      name: 'tools',
      owner: { login: 'octo' },
      private: false,
      archived: true,
      fork: true,
      pushed_at: '2026-06-25T00:00:00Z',
      description: 'cli',
    },
  ];
  const urls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    urls.push(String(url));
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, 'Bearer token');
    return jsonResponse(/[?&]page=1\b/u.test(String(url)) ? firstPage : secondPage);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  const repositories = await client.listAccessibleRepositories('github.com');

  assert.equal(repositories.length, 101);
  assert.match(urls[0], /https:\/\/api\.github\.com\/user\/repos\?/u);
  assert.match(urls[0], /affiliation=owner,collaborator,organization_member/u);
  assert.match(urls[0], /sort=pushed/u);
  assert.equal(repositories[0].private, true);
  assert.deepEqual(
    { host: repositories[100].host, owner: repositories[100].owner, repo: repositories[100].repo },
    { host: 'github.com', owner: 'octo', repo: 'tools' },
  );
  assert.equal(repositories[100].archived, true);
  assert.equal(repositories[100].fork, true);
  assert.equal(repositories[100].description, 'cli');
});

test('preserves earlier accessible repository pages when a later page keeps failing', async () => {
  const firstPage = Array.from({ length: 100 }, (_unused, index) => ({
    full_name: `wallstop/repo-${index + 1}`,
    name: `repo-${index + 1}`,
    owner: { login: 'wallstop' },
    private: false,
    archived: false,
    fork: false,
  }));
  const logs: string[] = [];
  const fetch: FetchLike = async (url) => {
    if (/[?&]page=1\b/u.test(String(url))) {
      return jsonResponse(firstPage);
    }

    return new Response('repository page exploded', { status: 500 });
  };
  const client = new GitHubClient({
    getToken: async () => 'token',
    fetch,
    sleep: async () => undefined,
    maxRetries: 0,
    log: (message) => logs.push(message),
  });

  const repositories = await client.listAccessibleRepositories('github.com');

  assert.equal(repositories.length, 100, 'the gathered first repository page must be preserved when a later page fails');
  assert.equal(
    logs.some((message) => /Stopped paginating accessible repositories.+results may be incomplete/u.test(message)),
    true,
    'a failed repository page must surface an incompleteness diagnostic',
  );
});

test('propagates a first-page accessible repository failure instead of silently returning empty results', async () => {
  const logs: string[] = [];
  const fetch: FetchLike = async () => new Response('repository page exploded', { status: 500 });
  const client = new GitHubClient({
    getToken: async () => 'token',
    fetch,
    sleep: async () => undefined,
    maxRetries: 0,
    log: (message) => logs.push(message),
  });

  await assert.rejects(() => client.listAccessibleRepositories('github.com'), /List accessible repositories failed/u);
  assert.deepEqual(logs, []);
});

test('listAccessibleRepositories normalizes hosts before auth, REST calls, and mapped identities', async () => {
  const tokenHosts: string[] = [];
  const urls: string[] = [];
  const fetch: FetchLike = async (url, init) => {
    urls.push(String(url));
    assert.equal((init?.headers as Record<string, string> | undefined)?.Authorization, 'Bearer token');
    return jsonResponse([
      {
        full_name: 'wallstop/repo',
        name: 'repo',
        owner: { login: 'wallstop' },
        private: false,
        archived: false,
        fork: false,
      },
    ]);
  };
  const client = new GitHubClient({
    getToken: async (host) => {
      tokenHosts.push(host);
      return 'token';
    },
    fetch,
  });

  const repositories = await client.listAccessibleRepositories(' GitHub.COM ');

  assert.deepEqual(tokenHosts, ['github.com']);
  assert.match(urls[0], /^https:\/\/api\.github\.com\/user\/repos\?/u);
  assert.equal(repositories[0].host, 'github.com');
});

test('listAccessibleRepositories rejects unsafe hosts before token lookup', async () => {
  let tokenCalled = false;
  const client = new GitHubClient({
    getToken: async () => {
      tokenCalled = true;
      return 'token';
    },
    fetch: async () => {
      throw new Error('fetch should not be called');
    },
  });

  await assert.rejects(() => client.listAccessibleRepositories('localhost'), /Localhost GitHub hosts are not allowed/u);
  assert.equal(tokenCalled, false);
});

test('listAccessibleRepositories rejects URL-reinterpretable IPv4 host aliases before token lookup', async () => {
  let tokenCalled = false;
  const client = new GitHubClient({
    getToken: async () => {
      tokenCalled = true;
      return 'token';
    },
    fetch: async () => {
      throw new Error('fetch should not be called');
    },
  });

  await assert.rejects(() => client.listAccessibleRepositories('2130706433'), /Invalid GitHub host/u);
  assert.equal(tokenCalled, false);
});

test('listAccessibleRepositories requires a token', async () => {
  const client = new GitHubClient({
    getToken: async () => undefined,
    fetch: async () => {
      throw new Error('fetch should not be called');
    },
  });

  await assert.rejects(() => client.listAccessibleRepositories('github.com'), /[Aa]uthentication is required/u);
});

test('listAccessibleRepositories targets the GHES /api/v3 base for enterprise hosts', async () => {
  const urls: string[] = [];
  const fetch: FetchLike = async (url) => {
    urls.push(String(url));
    return jsonResponse([]);
  };
  const client = new GitHubClient({ getToken: async () => 'token', fetch });

  await client.listAccessibleRepositories('ghe.example.com');

  assert.match(urls[0], /^https:\/\/ghe\.example\.com\/api\/v3\/user\/repos\?/u);
});

test('reports transient retries through the injected log hook', async () => {
  const logs: string[] = [];
  let attempts = 0;
  const fetch: FetchLike = async (_url, init) => {
    if (init?.body !== undefined) {
      return jsonResponse([]);
    }

    attempts += 1;
    return attempts === 1 ? new Response('upstream hiccup', { status: 503 }) : jsonResponse([]);
  };
  const client = new GitHubClient({
    getToken: async () => 'token',
    fetch,
    sleep: async () => undefined,
    maxRetries: 2,
    log: (message) => logs.push(message),
  });

  await client.listPullRequests({ host: 'github.com', owner: 'org', repo: 'repo' });

  assert.equal(attempts, 2, 'the 503 must be retried once');
  assert.equal(
    logs.some((line) => /retry/iu.test(line)),
    true,
    'a transient retry must be reported through the log hook',
  );
});
