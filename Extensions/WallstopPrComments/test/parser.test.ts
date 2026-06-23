import assert from 'node:assert/strict';
import test from 'node:test';

import {
  cleanCommentText,
  extractSuggestionBlocks,
  isLikelyWebOnlySuggestedChangeset,
} from '../src/markdownSuggestions';
import { reviewThreadToRecord } from '../src/records';

test('extracts a single suggestion fence verbatim', () => {
  const body = [
    'Please apply this.',
    '',
    '```suggestion',
    'if (enabled) {',
    '  run();',
    '}',
    '```',
  ].join('\n');

  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.value), [
    'if (enabled) {\n  run();\n}',
  ]);
});

test('extracts multiple suggestion fences in document order', () => {
  const body = [
    '```suggestion',
    'alpha',
    '```',
    'middle',
    '```suggestion',
    'beta',
    '```',
  ].join('\n');

  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.value), ['alpha', 'beta']);
});

test('represents an empty suggestion fence as a deletion suggestion', () => {
  const body = ['Remove it.', '', '```suggestion', '```'].join('\n');

  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.value), ['']);
});

test('extracts indented and list-contained suggestion fences with parser support', () => {
  const body = ['1. Please change:', '', '   ```suggestion', '   const value = 1;', '   ```'].join('\n');

  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.value), ['const value = 1;']);
  assert.equal(cleanCommentText(body), '1. Please change:');
});

test('normalizes CRLF input without leaking carriage returns', () => {
  const body = 'Fix this.\r\n\r\n```suggestion\r\nGet-Fixed\r\n```';

  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.value), ['Get-Fixed']);
  assert.equal(cleanCommentText(body), 'Fix this.');
});

test('ignores non-suggestion code fences', () => {
  const body = ['```ts', 'const context = true;', '```'].join('\n');

  assert.deepEqual(extractSuggestionBlocks(body), []);
  assert.equal(cleanCommentText(body), 'const context = true;');
});

test('scans replies as well as the top-level comment', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/reply.ts',
    isResolved: false,
    isOutdated: false,
    line: 8,
    comments: [
      {
        id: 'c1',
        body: 'The generated code needs a concrete value.',
      },
      {
        id: 'c2',
        body: ['Use this:', '', '```suggestion', 'const concrete = true;', '```'].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.deepEqual(
    record.comments.flatMap((comment) => comment.suggestedChanges.map((change) => change.value)),
    ['const concrete = true;'],
  );
});

test('marks likely Copilot web-only suggested changesets as unavailable instead of fabricating diffHunk output', () => {
  const body = 'Copilot suggested changeset available in the GitHub web UI.';

  assert.equal(isLikelyWebOnlySuggestedChangeset({ authorLogin: 'copilot-pull-request-reviewer[bot]', body, suggestionCount: 0 }), true);
});
