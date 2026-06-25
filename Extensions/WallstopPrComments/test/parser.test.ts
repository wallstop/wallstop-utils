import assert from 'node:assert/strict';
import test from 'node:test';

import {
  cleanCommentText,
  extractEmbeddedCommentLocations,
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
  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.source), ['apiMarkdownSuggestion']);
  assert.deepEqual(extractSuggestionBlocks(body).map((item) => item.confidence), ['high']);
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
  assert.equal(isLikelyWebOnlySuggestedChangeset({ authorLogin: 'human-reviewer', body, suggestionCount: 0 }), false);
});

test('does not classify human usernames containing bot names as unavailable suggested diffs', () => {
  for (const [authorLogin, body] of [
    ['cursor-fan', 'This normal review comment has no markdown suggestion.'],
    ['bugbot-fan', 'Suggested changeset is available through https://cursor.com/open?link=abc.'],
    ['not-copilot-reviewer', 'Copilot suggested changeset available in the GitHub web UI.'],
    ['human-reviewer', '<!-- BUGBOT_BUG_ID: copied-marker --> Finding text.'],
  ]) {
    const record = reviewThreadToRecord({
      id: `thread-${authorLogin}`,
      path: 'src/human.ts',
      isResolved: false,
      line: 12,
      comments: [
        {
          id: 'comment-1',
          authorLogin,
          body,
        },
      ],
    });

    assert.ok(record);
    assert.equal(record.comments[0].unavailableReason, undefined);
    assert.equal(record.comments[0].unavailableSource, undefined);
  }
});

test('does not mark trusted bot prose as unavailable without a generated suggestion marker', () => {
  for (const authorLogin of ['cursor[bot]', 'cursor-bugbot[bot]', 'bugbot[bot]', 'copilot-pull-request-reviewer[bot]']) {
    const record = reviewThreadToRecord({
      id: `thread-${authorLogin}`,
      path: 'src/bot-prose.ts',
      isResolved: false,
      line: 12,
      comments: [
        {
          id: 'comment-1',
          authorLogin,
          body: 'This finding has prose but no generated suggested-fix marker.',
        },
      ],
    });

    assert.ok(record);
    assert.equal(record.comments[0].unavailableReason, undefined);
    assert.equal(record.comments[0].unavailableSource, undefined);
  }
});

test('strips Cursor and Bugbot chrome while preserving prose', () => {
  const body = [
    '<!-- BUGBOT_BUG_ID: 9ba7cf02-5286-48f8-9b14-368e1013dd72 -->',
    '<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 LOCATIONS END -->',
    '### BOM test never actually writes a BOM **Low Severity**',
    '<details><summary>Additional Locations (1)</summary>',
    '- [`scripts/test-llm-harness.ps1#L110-L118`](https://github.com/org/repo/blob/sha/scripts/test-llm-harness.ps1#L110-L118)',
    '</details>',
    '<div><a href="https://cursor.com/open?link=abc"><picture><img alt="Fix in Cursor" src="https://cursor.com/assets/fix-in-cursor-dark.png"></picture></a></div>',
    '<sup>Reviewed by [Cursor Bugbot](https://cursor.com/bugbot) for commit abc.</sup>',
  ].join('\n');

  const cleaned = cleanCommentText(body);

  assert.match(cleaned, /BOM test never actually writes a BOM/);
  assert.doesNotMatch(cleaned, /BUGBOT_BUG_ID|LOCATIONS|Additional Locations|Fix in Cursor|Reviewed by|cursor\.com|https?:\/\/|<details|<div|<sup|!\[/);
});

test('extracts Cursor and Bugbot embedded locations in order', () => {
  const body = '<!-- LOCATIONS START https://github.com/org/repo/blob/abc123/Scripts/Some%20File.ps1#L10 scripts/other.ps1#L20-L22 scripts/other.ps1#L30-L25 LOCATIONS END -->';

  assert.deepEqual(extractEmbeddedCommentLocations(body), [
    { path: 'Scripts/Some File.ps1', lineStart: 10, lineEnd: 10 },
    { path: 'scripts/other.ps1', lineStart: 20, lineEnd: 22 },
    { path: 'scripts/other.ps1', lineStart: 30, lineEnd: 30 },
  ]);
});

test('uses embedded Cursor Bugbot locations for rendered record location', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'scripts/test-llm-harness.ps1',
    isResolved: false,
    startLine: 96,
    line: 96,
    originalStartLine: 96,
    originalLine: 96,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'cursor[bot]',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 scripts/test-llm-harness.ps1#L110-L118 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, 'scripts/test-llm-harness.ps1');
  assert.equal(record.lineStart, 93);
  assert.equal(record.lineEnd, 96);
  assert.equal(record.locationSource, 'embedded');
  assert.equal(record.githubPath, 'scripts/test-llm-harness.ps1');
  assert.equal(record.githubLineStart, 96);
  assert.equal(record.githubLineEnd, 96);
  assert.deepEqual(record.embeddedLocations, [
    { path: 'scripts/test-llm-harness.ps1', lineStart: 93, lineEnd: 96 },
    { path: 'scripts/test-llm-harness.ps1', lineStart: 110, lineEnd: 118 },
  ]);
});

test('ignores mismatched embedded locations for file-anchored GitHub review threads', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/real.ts',
    isResolved: false,
    startLine: 10,
    line: 12,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'cursor[bot]',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START src/other.ts#L1-L2 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, 'src/real.ts');
  assert.equal(record.lineStart, 10);
  assert.equal(record.lineEnd, 12);
  assert.equal(record.locationSource, 'github');
  assert.deepEqual(record.embeddedLocations, [
    { path: 'src/other.ts', lineStart: 1, lineEnd: 2 },
  ]);
});

test('ignores same-path embedded line overrides from non-bot comments', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/real.ts',
    isResolved: false,
    startLine: 10,
    line: 12,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'human-reviewer',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START src/real.ts#L1-L2 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, 'src/real.ts');
  assert.equal(record.lineStart, 10);
  assert.equal(record.lineEnd, 12);
  assert.equal(record.locationSource, 'github');
  assert.deepEqual(record.embeddedLocations, []);
});

test('ignores embedded locations from human usernames that merely contain bot names', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/real.ts',
    isResolved: false,
    startLine: 10,
    line: 12,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'cursor-fan',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START src/real.ts#L1-L2 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, 'src/real.ts');
  assert.equal(record.lineStart, 10);
  assert.equal(record.lineEnd, 12);
  assert.equal(record.locationSource, 'github');
  assert.deepEqual(record.embeddedLocations, []);
});

test('accepts embedded locations from known Cursor and Bugbot bot identities', () => {
  for (const authorLogin of ['cursor[bot]', 'cursor-bugbot[bot]', 'bugbot[bot]']) {
    const record = reviewThreadToRecord({
      id: `thread-${authorLogin}`,
      path: 'src/real.ts',
      isResolved: false,
      startLine: 10,
      line: 12,
      comments: [
        {
          id: 'comment-1',
          authorLogin,
          body: [
            'Finding text.',
            '<!-- LOCATIONS START src/real.ts#L1-L2 LOCATIONS END -->',
          ].join('\n'),
        },
      ],
    });

    assert.ok(record);
    assert.equal(record.lineStart, 1);
    assert.equal(record.lineEnd, 2);
    assert.equal(record.locationSource, 'embedded');
  }
});

test('uses first embedded location for conversation-level comments without GitHub file anchors', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: '<conversation>',
    isResolved: false,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'cursor[bot]',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START src/from-conversation.ts#L7-L9 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, 'src/from-conversation.ts');
  assert.equal(record.lineStart, 7);
  assert.equal(record.lineEnd, 9);
  assert.equal(record.locationSource, 'embedded');
});

test('ignores embedded paths in conversation-level comments from non-bot authors', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: '<conversation>',
    isResolved: false,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'human-reviewer',
        body: [
          'Finding text.',
          '<!-- LOCATIONS START src/spoofed.ts#L7-L9 LOCATIONS END -->',
        ].join('\n'),
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.path, '<conversation>');
  assert.equal(record.lineStart, undefined);
  assert.equal(record.lineEnd, undefined);
  assert.equal(record.locationSource, 'github');
  assert.deepEqual(record.embeddedLocations, []);
});

test('marks Cursor and Bugbot external fixes unavailable without fabricating a diff', () => {
  const record = reviewThreadToRecord({
    id: 'thread-1',
    path: 'src/cursor.ts',
    isResolved: false,
    line: 12,
    comments: [
      {
        id: 'comment-1',
        authorLogin: 'cursor[bot]',
        body: 'Suggested changeset is available through <a href="https://cursor.com/open?link=abc">Fix in Cursor</a>.',
        diffHunk: '@@ -1 +1 @@\n-old\n+new',
      },
    ],
  });

  assert.ok(record);
  assert.equal(record.comments[0].unavailableReason, 'External bot suggested fix was not exposed by the GitHub API.');
  assert.equal(record.comments[0].unavailableSource, 'externalBotUnavailable');
  assert.equal(record.comments[0].unavailableConfidence, 'unavailable');
  assert.deepEqual(record.comments[0].suggestedDiffs, []);
});
