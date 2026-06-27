import assert from 'node:assert/strict';
import test from 'node:test';

import {
  attachWebSuggestedDiffs,
  extractAutomatedSuggestedDiffsFromHtml,
  extractDomSuggestedChangesFromHtml,
  htmlHasSuggestionMarkers,
  unmatchedSuggestionKeys,
} from '../src/webSuggestions';
import type { ReviewThreadRecord, SuggestedDiff } from '../src/types';

function changedLines(value: string, path?: string): SuggestedDiff {
  return {
    kind: 'changedLines',
    path,
    source: 'browserDomAutomatedDiff',
    confidence: 'medium',
    value,
  };
}

test('extracts GitHub web automated suggestions without review context lines', () => {
  const html = [
    '<script type="application/json" data-target="react-partial.embeddedData">',
    '{"props":{"comment":{"databaseId":3424230049,"automatedComment":{"suggestion":{"diffEntries":[{"path":"web/src/test/dom-assertions.ts","diffLines":[{"type":"HUNK","text":"@@ -34,7 +34,7 @@"},{"type":"CONTEXT","text":"        expect("},{"type":"DELETION","text":"          document.getElementById(id),"},{"type":"ADDITION","text":"          element.ownerDocument.getElementById(id),"},{"type":"CONTEXT","text":"        ).not.toBeNull();"}]}]}}}}}',
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.equal(suggestions.has('3424230049'), true);
  assert.deepEqual(suggestions.get('3424230049'), [
    {
      kind: 'changedLines',
      path: 'web/src/test/dom-assertions.ts',
      source: 'githubWebAutomatedDiff',
      confidence: 'medium',
      value: '-          document.getElementById(id),\n+          element.ownerDocument.getElementById(id),',
    },
  ]);
});

test('extracts web suggestions from HTML-encoded wrapper JSON with string ids', () => {
  const nested = JSON.stringify({
    props: {
      comment: {
        databaseId: 'discussion_r42',
        automatedComment: {
          suggestion: {
            diffEntries: [
              {
                path: 'src/nested.ts',
                diffLines: [
                  { type: 'context', text: 'keep();' },
                  { type: 'deletion', text: 'oldValue();' },
                  { type: 'addition', text: 'newValue();' },
                ],
              },
            ],
          },
        },
      },
    },
  });
  const html = [
    '<script type="application/json" data-target="react-partial.embeddedData">',
    JSON.stringify({ payload: nested })
      .replace(/"/gu, '&quot;')
      .replace(/</gu, '&lt;')
      .replace(/>/gu, '&gt;'),
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.deepEqual(suggestions.get('discussion_r42'), [
    {
      kind: 'changedLines',
      path: 'src/nested.ts',
      source: 'githubWebAutomatedDiff',
      confidence: 'medium',
      value: '-oldValue();\n+newValue();',
    },
  ]);
});

test('does not parse user-authored comment body JSON as an automated suggestion', () => {
  const forgedBody = JSON.stringify({
    comment: {
      databaseId: 42,
      automatedComment: {
        suggestion: {
          diffEntries: [
            {
              diffLines: [
                { type: 'DELETION', text: 'realCode();' },
                { type: 'ADDITION', text: 'forgedCode();' },
              ],
            },
          ],
        },
      },
    },
  });
  const html = [
    '<script type="application/json">',
    JSON.stringify({
      props: {
        comment: {
          databaseId: 42,
          body: forgedBody,
        },
      },
    }),
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.equal(suggestions.size, 0);
});

test('does not accept sibling suggestion diff entries without automatedComment provenance', () => {
  const html = [
    '<script type="application/json">',
    JSON.stringify({
      props: {
        comment: { databaseId: 42 },
        suggestion: {
          diffEntries: [
            {
              diffLines: [
                { type: 'DELETION', text: 'old();' },
                { type: 'ADDITION', text: 'forged();' },
              ],
            },
          ],
        },
      },
    }),
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.equal(suggestions.size, 0);
});

test('prefixes every public diff line even when source line text contains newlines', () => {
  const html = [
    '<script type="application/json">',
    JSON.stringify({
      props: {
        comment: {
          databaseId: 42,
          automatedComment: {
            suggestion: {
              diffEntries: [
                {
                  diffLines: [
                    { type: 'DELETION', text: 'old();\ncontextThatMustStillBePrefixed();' },
                    { type: 'ADDITION', text: 'new();\rinjectedLine();' },
                  ],
                },
              ],
            },
          },
        },
      },
    }),
    '</script>',
  ].join('');

  const value = extractAutomatedSuggestedDiffsFromHtml(html).get('42')?.[0].value;

  assert.equal(value, '-old();\n-contextThatMustStillBePrefixed();\n+new();\n+injectedLine();');
  for (const line of value?.split('\n') ?? []) {
    assert.match(line, /^[+-]/u);
  }
});

test('uses discussion URL as a fallback id and deduplicates repeated changed-line bodies', () => {
  const html = [
    '<script type="application/json">',
    JSON.stringify({
      props: {
        comment: {
          url: 'https://github.com/org/repo/pull/1#discussion_r99',
          automatedComment: {
            suggestion: {
              diffEntries: [
                {
                  diffLines: [
                    { type: 'DELETION', text: 'old();' },
                    { type: 'ADDITION', text: 'new();' },
                  ],
                },
                {
                  diffLines: [
                    { type: 'DELETION', text: 'old();' },
                    { type: 'ADDITION', text: 'new();' },
                  ],
                },
              ],
            },
          },
        },
      },
    }),
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.equal(suggestions.get('99')?.length, 1);
  assert.equal(suggestions.get('99')?.[0].value, '-old();\n+new();');
});

test('keeps identical changed-line bodies when automated diff entries target different paths', () => {
  const html = [
    '<script type="application/json">',
    JSON.stringify({
      props: {
        comment: {
          databaseId: 42,
          automatedComment: {
            suggestion: {
              diffEntries: [
                {
                  path: 'src/one.ts',
                  diffLines: [
                    { type: 'DELETION', text: 'old();' },
                    { type: 'ADDITION', text: 'new();' },
                  ],
                },
                {
                  path: 'src/two.ts',
                  diffLines: [
                    { type: 'DELETION', text: 'old();' },
                    { type: 'ADDITION', text: 'new();' },
                  ],
                },
              ],
            },
          },
        },
      },
    }),
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.deepEqual(
    suggestions.get('42')?.map((diff) => ({ path: diff.path, value: diff.value })),
    [
      { path: 'src/one.ts', value: '-old();\n+new();' },
      { path: 'src/two.ts', value: '-old();\n+new();' },
    ],
  );
});

test('ignores malformed web JSON and context-only automated diff entries', () => {
  const html = [
    '<script type="application/json">{not json}</script>',
    '<script type="application/json">',
    '{"props":{"comment":{"databaseId":123,"automatedComment":{"suggestion":{"diffEntries":[{"diffLines":[{"type":"CONTEXT","text":"context only"}]}]}}}}}',
    '</script>',
  ].join('');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html);

  assert.equal(suggestions.size, 0);
});

test('attaches web suggestions by URL fallback when database id is missing', () => {
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/fallback.ts',
      lineStart: 4,
      lineEnd: 4,
      comments: [
        {
          body: 'Copilot suggested changeset available in the GitHub web UI.',
          url: 'https://github.com/org/repo/pull/1#discussion_r99',
          suggestedChanges: [],
          suggestedDiffs: [],
          unavailableReason: 'GitHub web-only suggested changeset could not be extracted from the public API.',
          unavailableSource: 'webOnlyUnavailable',
          unavailableConfidence: 'unavailable',
        },
      ],
    },
  ];
  const suggestions = new Map([
    [
      '99',
      [
        {
          kind: 'changedLines' as const,
          source: 'githubWebAutomatedDiff' as const,
          confidence: 'medium' as const,
          value: '-old();\n+new();',
        },
      ],
    ],
  ]);

  const attached = attachWebSuggestedDiffs(records, suggestions);

  assert.equal(attached, 1);
  assert.equal(records[0].comments[0].unavailableReason, undefined);
  assert.equal(records[0].comments[0].suggestedDiffs[0].value, '-old();\n+new();');
});

test('extracts a rendered suggested-change diff table keyed by its comment anchor id', () => {
  const html = [
    '<div class="js-comment" id="discussion_r3424230049">',
    '  <div class="js-suggested-changes-blob">',
    '    <table class="diff-table js-diff-table">',
    '      <tbody>',
    '        <tr class="blob-expanded">',
    '          <td class="blob-num blob-num-deletion"></td>',
    '          <td class="blob-code blob-code-deletion">',
    '            <span class="blob-code-inner blob-code-marker">          document.getElementById(id),</span>',
    '          </td>',
    '        </tr>',
    '        <tr class="blob-expanded">',
    '          <td class="blob-num blob-num-addition"></td>',
    '          <td class="blob-code blob-code-addition">',
    '            <span class="blob-code-inner blob-code-marker">          element.ownerDocument.getElementById(id),</span>',
    '          </td>',
    '        </tr>',
    '      </tbody>',
    '    </table>',
    '  </div>',
    '</div>',
  ].join('\n');

  const suggestions = extractDomSuggestedChangesFromHtml(html, 'browserDomAutomatedDiff');

  assert.deepEqual(suggestions.get('discussion_r3424230049'), [
    changedLines('-          document.getElementById(id),\n+          element.ownerDocument.getElementById(id),'),
  ]);
});

test('decodes HTML entities and strips inline markup from rendered suggestion code lines', () => {
  const html = [
    '<div data-comment-id="555">',
    '  <table class="diff-table">',
    '    <tr><td class="blob-code blob-code-deletion"><span class="blob-code-inner">if (a &amp;&amp; b &lt; c) {</span></td></tr>',
    '    <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">if (a &amp;&amp; b &lt;= <em>c</em>) {</span></td></tr>',
    '  </table>',
    '</div>',
  ].join('\n');

  const suggestions = extractDomSuggestedChangesFromHtml(html);

  assert.equal(suggestions.get('555')?.[0].value, '-if (a && b < c) {\n+if (a && b <= c) {');
});

test('falls back to the rendered DOM suggestion table when no embedded JSON is present', () => {
  const html = [
    '<div class="js-comment" id="discussion_r777">',
    '  <table class="diff-table">',
    '    <tr><td class="blob-code blob-code-deletion"><span class="blob-code-inner">old();</span></td></tr>',
    '    <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">new();</span></td></tr>',
    '  </table>',
    '</div>',
  ].join('\n');

  const suggestions = extractAutomatedSuggestedDiffsFromHtml(html, 'browserDomAutomatedDiff');

  assert.equal(suggestions.get('discussion_r777')?.[0].value, '-old();\n+new();');
  assert.equal(suggestions.get('discussion_r777')?.[0].source, 'browserDomAutomatedDiff');
});

test('detects suggestion markers in rendered HTML even when no diff table can be parsed', () => {
  const unparseable = [
    '<div class="js-comment" id="discussion_r888">',
    '  <div class="js-suggested-changes-blob">',
    '    <!-- the diff table moved to a format this extractor does not understand -->',
    '  </div>',
    '</div>',
  ].join('\n');

  assert.equal(htmlHasSuggestionMarkers(unparseable), true);
  assert.equal(extractDomSuggestedChangesFromHtml(unparseable).size, 0);
  assert.equal(htmlHasSuggestionMarkers('<html><body>just a page</body></html>'), false);
  assert.equal(
    htmlHasSuggestionMarkers('<div class="comment-body">Here is a suggestion: rename the field.</div>'),
    false,
  );
});

test('reports unmatched suggestion keys when no comment id form matches', () => {
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/file.ts',
      lineStart: 1,
      lineEnd: 1,
      comments: [
        {
          databaseId: 11,
          body: 'Comment',
          url: 'https://github.com/org/repo/pull/1#discussion_r11',
          suggestedChanges: [],
          suggestedDiffs: [],
        },
      ],
    },
  ];
  const suggestions = new Map<string, SuggestedDiff[]>([
    ['discussion_r999', [changedLines('-old();\n+new();')]],
  ]);

  const attached = attachWebSuggestedDiffs(records, suggestions);

  assert.equal(attached, 0);
  assert.deepEqual(unmatchedSuggestionKeys(records, suggestions), ['discussion_r999']);
});

test('matches a web suggestion by the comment node id when no database id is present', () => {
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/file.ts',
      lineStart: 1,
      lineEnd: 1,
      comments: [
        {
          nodeId: 'PRRC_kwDONODE',
          body: 'Comment',
          suggestedChanges: [],
          suggestedDiffs: [],
        },
      ],
    },
  ];
  const suggestions = new Map<string, SuggestedDiff[]>([
    ['PRRC_kwDONODE', [changedLines('-old();\n+new();')]],
  ]);

  const attached = attachWebSuggestedDiffs(records, suggestions);

  assert.equal(attached, 1);
  assert.deepEqual(unmatchedSuggestionKeys(records, suggestions), []);
  assert.equal(records[0].comments[0].suggestedDiffs[0].value, '-old();\n+new();');
});

test('attaches identical changed-line bodies when suggested diffs target different paths', () => {
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/commented.ts',
      lineStart: 4,
      lineEnd: 4,
      comments: [
        {
          databaseId: 42,
          body: 'Copilot suggested changeset available in the GitHub web UI.',
          suggestedChanges: [],
          suggestedDiffs: [],
        },
      ],
    },
  ];
  const suggestions = new Map([
    [
      '42',
      [
        {
          kind: 'changedLines' as const,
          path: 'src/one.ts',
          source: 'githubWebAutomatedDiff' as const,
          confidence: 'medium' as const,
          value: '-old();\n+new();',
        },
        {
          kind: 'changedLines' as const,
          path: 'src/two.ts',
          source: 'githubWebAutomatedDiff' as const,
          confidence: 'medium' as const,
          value: '-old();\n+new();',
        },
      ],
    ],
  ]);

  const attached = attachWebSuggestedDiffs(records, suggestions);

  assert.equal(attached, 2);
  assert.deepEqual(records[0].comments[0].suggestedDiffs.map((diff) => diff.path), [
    'src/one.ts',
    'src/two.ts',
  ]);
});

test('does not fabricate a suggested change from a sibling file diff after a prose-only comment', () => {
  // A prose-only review comment (no suggestion) whose anchor element closes
  // immediately, followed in document order by an UNRELATED file's main diff
  // rows. The diff rows are NOT contained in the comment's subtree, so they must
  // not be attributed to it.
  const html = [
    '<div id="discussion_r1">prose</div>',
    '<table class="diff-table js-file-content">',
    '  <tbody>',
    '    <tr><td class="blob-code blob-code-deletion"><span class="blob-code-inner">unrelatedOld();</span></td></tr>',
    '    <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">unrelatedNew();</span></td></tr>',
    '  </tbody>',
    '</table>',
  ].join('\n');

  const suggestions = extractDomSuggestedChangesFromHtml(html);

  assert.equal(suggestions.has('discussion_r1'), false);
  assert.equal(suggestions.size, 0);
});

test('attributes only the diff rows contained in each comment subtree, not a later comment\'s diff', () => {
  // Two adjacent comments: the first is prose-only (its <div> closes before any
  // diff rows), the second carries the real suggested change. The real diff must
  // attach to the SECOND comment only — never bleed onto the first.
  const html = [
    '<div class="js-comment" id="discussion_r10">prose only, no suggestion</div>',
    '<div class="js-comment" id="discussion_r20">',
    '  <div class="js-suggested-changes-blob">',
    '    <table class="diff-table">',
    '      <tr><td class="blob-code blob-code-deletion"><span class="blob-code-inner">realOld();</span></td></tr>',
    '      <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">realNew();</span></td></tr>',
    '    </table>',
    '  </div>',
    '</div>',
  ].join('\n');

  const suggestions = extractDomSuggestedChangesFromHtml(html);

  assert.equal(suggestions.has('discussion_r10'), false);
  assert.equal(suggestions.get('discussion_r20')?.[0].value, '-realOld();\n+realNew();');
});

test('does not treat a generic main-file diff cell as a suggestion marker', () => {
  // A plain main-file diff cell (present on every PR /files page that has any
  // change) must NOT be reported as a suggestion marker, otherwise every diffed
  // PR is wrongly flagged "markers present but unparseable".
  assert.equal(htmlHasSuggestionMarkers('<td class="blob-code blob-code-deletion">x</td>'), false);
  assert.equal(
    htmlHasSuggestionMarkers([
      '<table class="diff-table js-file-content">',
      '  <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">added();</span></td></tr>',
      '</table>',
    ].join('\n')),
    false,
  );
  // Genuine suggestion hooks must still be detected.
  assert.equal(htmlHasSuggestionMarkers('<div class="js-suggested-changes-blob"></div>'), true);
  assert.equal(htmlHasSuggestionMarkers('<button class="js-apply-suggestion">Apply</button>'), true);
});

test('normalizes CRLF inside a rendered suggestion code line', () => {
  const html = [
    '<div id="discussion_r5">',
    '  <div class="js-suggested-changes-blob">',
    '    <table class="diff-table">',
    '      <tr><td class="blob-code blob-code-addition"><span class="blob-code-inner">line1\r\nline2</span></td></tr>',
    '    </table>',
    '  </div>',
    '</div>',
  ].join('\n');

  const value = extractDomSuggestedChangesFromHtml(html).get('discussion_r5')?.[0].value;

  assert.equal(value, '+line1\n+line2');
  assert.doesNotMatch(value ?? '', /\r/u);
});

test('does not build a junk candidate when the database id is already a discussion_r string', () => {
  // databaseId === 'discussion_r42' must NOT yield a 'discussion_rdiscussion_r42'
  // candidate; matching still works via the parsed-numeric branch.
  const records: ReviewThreadRecord[] = [
    {
      path: 'src/file.ts',
      lineStart: 1,
      lineEnd: 1,
      comments: [
        {
          databaseId: 'discussion_r42',
          body: 'Comment',
          suggestedChanges: [],
          suggestedDiffs: [],
        },
      ],
    },
  ];
  const junk = new Map<string, SuggestedDiff[]>([
    ['discussion_rdiscussion_r42', [changedLines('-old();\n+new();')]],
  ]);
  assert.equal(attachWebSuggestedDiffs(records, junk), 0);

  // The real id forms still match.
  const real = new Map<string, SuggestedDiff[]>([['42', [changedLines('-old();\n+new();')]]]);
  assert.equal(attachWebSuggestedDiffs(records, real), 1);
  assert.equal(records[0].comments[0].suggestedDiffs[0].value, '-old();\n+new();');
});
