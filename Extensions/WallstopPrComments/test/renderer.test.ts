import assert from 'node:assert/strict';
import test from 'node:test';

import { formatReviewThreadRecords } from '../src/renderer';
import { collectUnavailableSuggestionWarnings, reviewThreadToRecord } from '../src/records';

test('renders the exact clipboard block format with comment and suggested change', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/main.ts',
    isResolved: false,
    isOutdated: false,
    startLine: 10,
    line: 12,
    comments: [
      {
        id: 'comment-1',
        body: ['Please use the owner document.', '', '```suggestion', 'element.ownerDocument.getElementById(id)', '```'].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(
    formatReviewThreadRecords([record]),
    [
      '---',
      '(src/main.ts) 10-12',
      'Comment:',
      'Please use the owner document.',
      'Suggested change:',
      'element.ownerDocument.getElementById(id)',
      '---',
    ].join('\n'),
  );
});

test('never renders diffHunk as a suggested change', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/context.ts',
    isResolved: false,
    isOutdated: false,
    line: 4,
    comments: [
      {
        id: 'comment-1',
        body: 'Looks wrong.',
        diffHunk: '@@ -1,2 +1,3 @@\n-old\n+new',
      },
    ],
  });

  assert.ok(record);
  const output = formatReviewThreadRecords([record]);

  assert.match(output, /Comment:\nLooks wrong\./);
  assert.doesNotMatch(output, /Suggested change:/);
  assert.doesNotMatch(output, /@@ -1,2/);
  assert.doesNotMatch(output, /\+new/);
});

test('renders multiple suggestions from multiple comments without dropping empty deletion suggestions', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/multi.ts',
    isResolved: false,
    isOutdated: false,
    line: 20,
    comments: [
      {
        id: 'comment-1',
        body: ['First.', '', '```suggestion', 'first();', '```'].join('\n'),
      },
      {
        id: 'comment-2',
        body: ['Delete this.', '', '```suggestion', '```'].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(
    formatReviewThreadRecords([record]),
    [
      '---',
      '(src/multi.ts) 20-20',
      'Comment:',
      'First.',
      'Suggested change:',
      'first();',
      'Comment:',
      'Delete this.',
      'Suggested change:',
      '',
      '---',
    ].join('\n'),
  );
});

test('renders public web suggested diffs as changed lines only', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'web/src/test/dom-assertions.ts',
    isResolved: false,
    isOutdated: false,
    line: 34,
    comments: [
      {
        id: 'comment-1',
        databaseId: 3424230049,
        body: 'Copilot suggested changeset available in the GitHub web UI.',
        authorLogin: 'copilot-pull-request-reviewer[bot]',
        suggestedDiffs: [
          {
            kind: 'changedLines',
            source: 'githubWebAutomatedDiff',
            confidence: 'medium',
            value: '-          document.getElementById(id),\n+          element.ownerDocument.getElementById(id),',
          },
        ],
      },
    ],
  });

  assert.ok(record);
  const output = formatReviewThreadRecords([record]);

  assert.match(output, /Suggested change:\n-          document\.getElementById\(id\),\n\+          element\.ownerDocument\.getElementById\(id\),/);
  assert.doesNotMatch(output, /@@|not\.toBeNull|CONTEXT/);
});

test('renders mismatched web suggested diff paths in the suggestion label', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/commented.ts',
    isResolved: false,
    line: 10,
    comments: [
      {
        id: 'comment-1',
        body: 'Copilot suggested changeset available in the GitHub web UI.',
        authorLogin: 'copilot-pull-request-reviewer[bot]',
        suggestedDiffs: [
          {
            kind: 'changedLines',
            source: 'githubWebAutomatedDiff',
            confidence: 'medium',
            path: 'src/changed.ts',
            value: '-old();\n+new();',
          },
        ],
      },
    ],
  });

  assert.ok(record);
  assert.equal(
    formatReviewThreadRecords([record]),
    [
      '---',
      '(src/commented.ts) 10-10',
      'Comment:',
      'Copilot suggested changeset available in the GitHub web UI.',
      'Suggested change (src/changed.ts):',
      '-old();',
      '+new();',
      '---',
    ].join('\n'),
  );
});

test('keeps unavailable web-only suggestions as metadata without fake suggested-change text', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/copilot.ts',
    isResolved: false,
    isOutdated: false,
    line: 5,
    comments: [
      {
        id: 'comment-1',
        databaseId: 12,
        body: 'Copilot suggested changeset available in the GitHub web UI.',
        authorLogin: 'copilot-pull-request-reviewer[bot]',
      },
    ],
  });

  assert.ok(record);
  assert.equal(
    record.comments[0].unavailableReason,
    'GitHub web-only suggested changeset could not be extracted from the public API.',
  );
  assert.equal(record.comments[0].unavailableSource, 'webOnlyUnavailable');
  assert.deepEqual(collectUnavailableSuggestionWarnings([record]), [
    'src/copilot.ts:5: GitHub web-only suggested changeset could not be extracted from the public API.',
  ]);

  const output = formatReviewThreadRecords([record]);
  assert.match(output, /Comment:\nCopilot suggested changeset available in the GitHub web UI\./);
  assert.doesNotMatch(output, /Suggested change:/);
  assert.doesNotMatch(output, /\(unavailable:/);
});

test('renders placeholder-only unavailable web suggestions instead of reporting no comments', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/placeholder.ts',
    isResolved: false,
    isOutdated: false,
    line: 9,
    comments: [
      {
        id: 'comment-1',
        databaseId: 12,
        body: '![Copilot suggested changeset](https://example.test/suggestion.png)',
        authorLogin: 'copilot-pull-request-reviewer[bot]',
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.comments[0].body, '');
  assert.equal(
    formatReviewThreadRecords([record]),
    [
      '---',
      '(src/placeholder.ts) 9-9',
      'Suggestion unavailable:',
      'GitHub web-only suggested changeset could not be extracted from the public API.',
      '---',
    ].join('\n'),
  );
});
