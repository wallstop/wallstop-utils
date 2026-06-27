const HUNK_HEADER = /^@@\s+-\d+(?:,\d+)?\s+\+(?<newStart>\d+)(?:,\d+)?\s+@@/u;

/**
 * Narrows a unified `diff_hunk` to only the lines whose new-side line number
 * falls within `[start, end]`, dropping the `@@` header and any out-of-range
 * context. Deletion (`-`) lines are anchored to the new-side position they sit
 * at, so a focused replacement keeps its paired `-`/`+` rows together.
 *
 * Because every deletion in a replacement group shares the new-side line number
 * of the first addition that follows it, a narrow (e.g. single-line) range that
 * clips the addition run would otherwise keep *all* the group's deletions beside
 * only the surviving additions — a visibly lopsided block. To avoid that, the
 * leading deletions of a group are clamped to the number of additions kept from
 * that same group (a paired window). Pure-deletion groups (no following
 * additions) are never clamped, since every removed line is honest context.
 *
 * When no range is supplied the whole hunk body (sans header) is returned.
 */
export function trimDiffHunkToRange(
  diffHunk: string | undefined,
  start: number | undefined,
  end: number | undefined,
): string {
  if (diffHunk === undefined || diffHunk.trim() === '') {
    return '';
  }

  const lines = normalizeLineEndings(diffHunk).split('\n');
  const headerIndex = lines.findIndex((line) => HUNK_HEADER.test(line));
  const body = dropTrailingEmptyLine(headerIndex >= 0 ? lines.slice(headerIndex + 1) : lines);

  if (start === undefined && end === undefined) {
    return body.filter((line) => line !== '').join('\n');
  }

  const rangeStart = start ?? end ?? Number.NEGATIVE_INFINITY;
  const rangeEnd = end ?? start ?? Number.POSITIVE_INFINITY;
  const headerMatch = headerIndex >= 0 ? HUNK_HEADER.exec(lines[headerIndex]) : null;
  let newLine = headerMatch?.groups?.newStart !== undefined ? Number.parseInt(headerMatch.groups.newStart, 10) : 1;

  const kept: string[] = [];
  // The in-range deletions and additions of the current replacement group are
  // buffered so the group can be emitted as a unit: clamped deletions first,
  // then the surviving additions, preserving unified-diff order.
  let pendingDeletions: string[] = [];
  let pendingAdditions: string[] = [];

  const flushGroup = (): void => {
    if (pendingDeletions.length > 0) {
      // No paired additions kept → pure deletion: surface every removed line.
      // Otherwise clamp the leading deletions to the additions that survived so
      // the displayed block stays paired rather than visibly lopsided.
      const limit = pendingAdditions.length === 0 ? pendingDeletions.length : pendingAdditions.length;
      kept.push(...pendingDeletions.slice(0, limit));
    }

    kept.push(...pendingAdditions);
    pendingDeletions = [];
    pendingAdditions = [];
  };

  for (const line of body) {
    const marker = line[0];
    if (marker === '-') {
      // A deletion sits at the new-side boundary it precedes; buffer it so the
      // group can be clamped once its addition run is known.
      if (newLine >= rangeStart && newLine <= rangeEnd) {
        pendingDeletions.push(line);
      }
      continue;
    }

    if (marker === '+') {
      if (newLine >= rangeStart && newLine <= rangeEnd) {
        pendingAdditions.push(line);
      }
      newLine += 1;
      continue;
    }

    if (marker === ' ' || marker === undefined) {
      // A context line ends the current replacement group.
      flushGroup();
      if (newLine >= rangeStart && newLine <= rangeEnd) {
        kept.push(line);
      }
      newLine += 1;
    }
  }

  flushGroup();
  return kept.join('\n');
}

/**
 * Returns the current new-side file lines (context + additions, markers
 * stripped) that a suggestion anchored to `[start, end]` would replace — the
 * "before" side when reconstructing a suggestion into a unified diff.
 *
 * GitHub guarantees the commented line is the *last* new-side line of the
 * `diff_hunk` (the hunk is the diff up to and including the comment), so this
 * anchors from the END: it returns the last `N` new-side lines, where `N` is the
 * anchored span (`end - start + 1`, or `1` when only one bound is known), clamped
 * to the available new-side lines. Anchoring on that structural guarantee and a
 * *relative* span — never the absolute header line number — is what makes it
 * robust to two real-world hazards that the forward-counting approach silently
 * failed on: GitHub truncating a long hunk to its tail while keeping the original
 * `@@` header, and the thread `line` drifting past the hunk window after later
 * commits. Both leave the header numbering unable to reach the anchor, which
 * previously yielded an empty before-context and a deletion-less suggestion.
 *
 * Returns `''` (so the caller renders the suggestion as raw text rather than
 * fabricating deletions) when the hunk is missing, exposes no new-side line
 * (pure deletion), or no anchor is supplied.
 */
export function extractNewSideLinesInRange(
  diffHunk: string | undefined,
  start: number | undefined,
  end: number | undefined,
): string {
  if (diffHunk === undefined || diffHunk.trim() === '') {
    return '';
  }

  // No anchor at all: the replaced range is unknowable, so never fabricate a
  // before-context. (Guards the function in isolation; records.ts also gates the
  // call on a resolvable anchor.)
  if (start === undefined && end === undefined) {
    return '';
  }

  const lines = normalizeLineEndings(diffHunk).split('\n');
  const headerIndex = lines.findIndex((line) => HUNK_HEADER.test(line));
  const body = dropTrailingEmptyLine(headerIndex >= 0 ? lines.slice(headerIndex + 1) : lines);

  // The new-side file lines (context + additions, markers stripped), in order.
  // Deletions are not on the new side and are skipped — including a trailing
  // deletion run, so the last entry stays the commented line.
  const newSide: string[] = [];
  for (const line of body) {
    const marker = line[0];
    if (marker === '-') {
      continue;
    }

    // marker === undefined is an interior blank body line that survived
    // dropTrailingEmptyLine: a genuine, empty new-side line. Keep it as ''.
    newSide.push(marker === '+' || marker === ' ' ? line.slice(1) : line);
  }

  if (newSide.length === 0) {
    return '';
  }

  const span = start !== undefined && end !== undefined ? end - start + 1 : 1;
  const take = Math.min(Math.max(span, 1), newSide.length);
  return newSide.slice(newSide.length - take).join('\n');
}

/**
 * Builds a GitHub-style unified diff from the lines a `\`\`\`suggestion` block
 * replaces (`before`) and the suggested replacement (`after`): every original
 * line is emitted as a `-` deletion and every suggested line as a `+` addition,
 * the same transformation GitHub renders for a suggested change.
 *
 * Returns `undefined` when there is no `before` context to diff against, since a
 * pure addition is just the suggestion text and adds no diff value.
 */
export function reconstructSuggestionDiff(before: string, after: string): string | undefined {
  const beforeLines = splitPreservingDeletion(before);
  if (beforeLines.length === 0) {
    return undefined;
  }

  const afterLines = after === '' ? [] : normalizeLineEndings(after).split('\n');
  const lines = [
    ...beforeLines.map((line) => `-${line}`),
    ...afterLines.map((line) => `+${line}`),
  ];
  return lines.join('\n');
}

/**
 * Drops every trailing empty body line. A `diff_hunk` terminated by a trailing
 * newline splits into a phantom empty element that the ranged scans would
 * otherwise count as a real new-side line and emit as a spurious blank entry
 * once a range's end runs past the hunk's last genuine line. A doubly-trailing
 * newline yields two such phantoms, so a single strip would still leak one.
 * Every empty trailing element carries no new-side content, so removing them all
 * is lossless and hardens both scans against malformed hunks.
 */
function dropTrailingEmptyLine(body: readonly string[]): string[] {
  let end = body.length;
  while (end > 0 && body[end - 1] === '') {
    end -= 1;
  }

  return body.slice(0, end);
}

function splitPreservingDeletion(text: string): string[] {
  if (text === '') {
    return [];
  }

  return normalizeLineEndings(text).split('\n');
}

function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n');
}
