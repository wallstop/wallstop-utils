import assert from 'node:assert/strict';
import test from 'node:test';

import { extractAutomatedSuggestedDiffsFromHtml } from '../src/webSuggestions';

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
      value: '-          document.getElementById(id),\n+          element.ownerDocument.getElementById(id),',
    },
  ]);
});
