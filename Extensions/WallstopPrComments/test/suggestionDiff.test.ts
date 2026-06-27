import assert from 'node:assert/strict';
import test from 'node:test';

import { extractNewSideLinesInRange, reconstructSuggestionDiff, trimDiffHunkToRange } from '../src/suggestionDiff';

test('trims a diff hunk to the new-side lines overlapping the comment range', () => {
  const hunk = [
    '@@ -10,4 +10,4 @@ function run() {',
    ' const before = 1;',
    '-const middle = 2;',
    '+const middle = two;',
    ' const after = 3;',
  ].join('\n');

  assert.equal(trimDiffHunkToRange(hunk, 11, 11), ['-const middle = 2;', '+const middle = two;'].join('\n'));
});

test('returns an empty string when the comment range is outside the hunk new-side window', () => {
  const hunk = ['@@ -1,2 +1,3 @@', '-old', '+new'].join('\n');

  assert.equal(trimDiffHunkToRange(hunk, 4, 4), '');
});

test('keeps the whole hunk body when no range is supplied', () => {
  const hunk = ['@@ -1,1 +1,1 @@', '-old', '+new'].join('\n');

  assert.equal(trimDiffHunkToRange(hunk, undefined, undefined), ['-old', '+new'].join('\n'));
});

test('reconstructs a unified -/+ diff from before lines and a suggestion block', () => {
  const before = 'document.getElementById(id),';
  const suggestion = 'element.ownerDocument.getElementById(id),';

  assert.equal(
    reconstructSuggestionDiff(before, suggestion),
    ['-document.getElementById(id),', '+element.ownerDocument.getElementById(id),'].join('\n'),
  );
});

test('reconstructs a multi-line suggestion diff and renders an empty suggestion as a pure deletion', () => {
  assert.equal(
    reconstructSuggestionDiff('a();\nb();', 'a();\nb2();'),
    ['-a();', '-b();', '+a();', '+b2();'].join('\n'),
  );
  assert.equal(reconstructSuggestionDiff('drop();', ''), '-drop();');
});

test('returns undefined when there is no before context to diff against', () => {
  assert.equal(reconstructSuggestionDiff('', 'added();'), undefined);
});

test('clamps deletions to the paired addition window so a single-line range is not lopsided', () => {
  const hunk = [
    '@@ -10,4 +10,4 @@ function run() {',
    '-const c = 3;',
    '-const d = 4;',
    '+const c = 30;',
    '+const d = 40;',
  ].join('\n');

  // Range 10-10 anchors on the first new-side line. Both deletions share that
  // anchor, but only the addition at line 10 survives the range — keep just the
  // paired deletion so the block reads 1 deletion vs 1 addition, not 2 vs 1.
  assert.equal(trimDiffHunkToRange(hunk, 10, 10), ['-const c = 3;', '+const c = 30;'].join('\n'));
});

test('keeps the full deletion+addition group symmetric when the whole range is selected', () => {
  const hunk = [
    '@@ -10,4 +10,4 @@ function run() {',
    '-const c = 3;',
    '-const d = 4;',
    '+const c = 30;',
    '+const d = 40;',
  ].join('\n');

  assert.equal(
    trimDiffHunkToRange(hunk, 10, 11),
    ['-const c = 3;', '-const d = 4;', '+const c = 30;', '+const d = 40;'].join('\n'),
  );
});

test('keeps all deletions for a pure-deletion hunk with no paired additions', () => {
  const hunk = ['@@ -10,3 +10,1 @@', ' keep();', '-gone-one;', '-gone-two;'].join('\n');

  // No additions follow the deletions, so there is no paired window to clamp to;
  // surfacing every removed line is the honest context.
  assert.equal(trimDiffHunkToRange(hunk, 11, 11), ['-gone-one;', '-gone-two;'].join('\n'));
});

test('does not emit a phantom blank line when a trailing-newline hunk range exceeds the last real line', () => {
  // A diff_hunk terminated by a trailing newline splits into a phantom empty
  // body line. A range whose end exceeds the last genuine new-side line must
  // not surface that empty line as a spurious blank entry.
  const hunk = ['@@ -10,3 +10,3 @@', ' const before = 1;', '-const middle = 2;', '+const middle = two;', ' const after = 3;', ''].join('\n');

  assert.equal(
    trimDiffHunkToRange(hunk, 10, 13),
    [' const before = 1;', '-const middle = 2;', '+const middle = two;', ' const after = 3;'].join('\n'),
  );
});

test('extractNewSideLinesInRange does not surface a phantom blank line from a trailing-newline hunk', () => {
  const hunk = ['@@ -1,3 +1,3 @@', ' keep();', '-document.getElementById(id),', '+X', ''].join('\n');

  // new-side lines are: keep() at 1, X at 2. Deletions are skipped. A range
  // ending past those lines must not append the phantom empty line.
  assert.equal(extractNewSideLinesInRange(hunk, 1, 6), ['keep();', 'X'].join('\n'));
});

test('trimDiffHunkToRange strips multiple trailing empty body lines, not just one', () => {
  // A doubly-trailing-newline hunk splits into two phantom empty body lines.
  // Both are content-free and must be dropped so a range running past the last
  // genuine new-side line never leaks a phantom blank.
  const hunk = '@@ -1,1 +1,1 @@\n+a\n\n';

  assert.equal(trimDiffHunkToRange(hunk, 1, 9), '+a');
});

test('extractNewSideLinesInRange strips multiple trailing empty body lines, not just one', () => {
  const hunk = '@@ -1,1 +1,1 @@\n+a\n\n';

  assert.equal(extractNewSideLinesInRange(hunk, 1, 9), 'a');
});

test('trimDiffHunkToRange strips a CRLF doubly-trailing newline down to the real line', () => {
  // CRLF line endings normalize to LF before the trailing-empty scan, so a hunk
  // ending in two CRLF newlines must collapse to the single genuine line just
  // like the LF form — not leak a phantom blank from the second terminator.
  const hunk = '@@ -1,1 +1,1 @@\r\n+a\r\n\r\n';

  assert.equal(trimDiffHunkToRange(hunk, 1, 9), '+a');
});

test('trimDiffHunkToRange strips trailing phantom blanks while preserving a genuine blank context line', () => {
  // A blank line in the file shows up as a context row whose marker is a space
  // (`" "`, i.e. line[0] === " "), not an empty string, whereas a trailing
  // newline phantom is the empty string. This hunk pairs both: a genuine
  // blank-context row sitting as the LAST body line before two trailing phantom
  // blanks. Placing the real blank immediately ahead of the phantoms makes this
  // fixture discriminate three strip behaviors at once: a single-strip leaves a
  // leaked phantom (`['" a"','"-b"','"+B"','" "','""']`); a marker-blind
  // end-anchored strip (one that drops trailing rows where `line.trim() === ""`)
  // runs straight through the empty phantoms AND the `" "` blank-context row and
  // eats the genuine blank (`['" a"','"-b"','"+B"']`); only the
  // strip-all-trailing-*empty-string*-rows behavior drops both phantoms yet stops
  // at the `" "` row, preserving it. New-side numbering: `" a"` is line 1, `"-b"`
  // is a deletion anchored to the `"+B"` it precedes (line 2), `"+B"` is line 2,
  // and the blank-context `" "` is line 3 — all inside the 1..4 range.
  const hunk = ['@@ -1,4 +1,4 @@', ' a', '-b', '+B', ' ', '', ''].join('\n');

  assert.equal(trimDiffHunkToRange(hunk, 1, 4), [' a', '-b', '+B', ' '].join('\n'));
});
