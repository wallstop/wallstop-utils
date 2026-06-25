import assert from 'node:assert/strict';
import test from 'node:test';

import { attachWebSuggestedDiffs, extractAutomatedSuggestedDiffsFromHtml } from '../src/webSuggestions';
import type { ReviewThreadRecord } from '../src/types';

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
          unavailableSource: 'externalBotUnavailable',
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
