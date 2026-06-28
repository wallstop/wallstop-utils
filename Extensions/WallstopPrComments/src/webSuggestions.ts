import { isUnifiedDiffNoNewlineSentinel } from './diffMetadata';
import type { AutomatedSuggestionSource, RenderableComment, ReviewThreadRecord, SuggestedDiff } from './types';

export function extractAutomatedSuggestedDiffsFromHtml(
  html: string,
  source: AutomatedSuggestionSource = 'githubWebAutomatedDiff',
): Map<string, SuggestedDiff[]> {
  const suggestionsByCommentId = new Map<string, SuggestedDiff[]>();
  for (const payload of extractJsonScriptPayloads(html)) {
    for (const parsed of parseJsonCandidates(payload)) {
      collectAutomatedDiffs(parsed, suggestionsByCommentId, source);
    }
  }

  if (suggestionsByCommentId.size === 0) {
    if (!htmlHasSuggestionMarkers(html)) {
      return suggestionsByCommentId;
    }

    return extractDomSuggestedChangesFromHtmlCore(html, source, true);
  }

  return suggestionsByCommentId;
}

/** Comment anchors GitHub renders on a review comment / suggested-change blob. */
const COMMENT_ANCHOR_REGEX = /(?:id="(?<discussion>discussion_r\d+)"|data-comment-id="(?<commentId>[^"]+)")/giu;
/** A rendered diff code cell: `blob-code-deletion` (old) or `blob-code-addition` (new). */
const DIFF_LINE_REGEX = /<td\b[^>]*class="[^"]*\bblob-code-(?<kind>deletion|addition)\b[^"]*"[^>]*>(?<cell>[\s\S]*?)<\/td>/giu;
/**
 * Structural markers proving a *suggested change* is on the page even if its diff
 * table cannot be parsed. Deliberately limited to suggestion-specific GitHub DOM
 * hooks — NOT generic `blob-code-deletion`/`blob-code-addition` cells, which appear
 * in every ordinary main-file diff on a PR /files page. Flagging those would make
 * every diffed PR (with no suggested change at all) report "markers present but
 * unparseable", defeating the honest "no suggestion" vs "unparseable" distinction.
 */
const SUGGESTION_MARKER_REGEX = /js-suggested-changes-blob|js-suggested-change-(?:blob|line)|js-apply-suggestion|data-(?:test-selector|target)="[^"]*suggested-change/iu;

/**
 * Parses GitHub's *rendered* suggested-change markup (the suggestion diff `<table>`
 * rows: `blob-code-deletion` / `blob-code-addition` blob lines) into a `-`/`+`
 * unified diff per comment, keyed by the comment anchor whose element subtree
 * *contains* the diff rows (`id="discussion_r<id>"` or `data-comment-id="<id>"`).
 *
 * Attribution is by DOM containment, not document order: a diff row is only
 * attributed to a comment when it lies inside that comment element's open/close
 * span. This prevents fabricating a suggested change from an *unrelated* main-file
 * diff table that merely follows a prose-only review comment in document order —
 * such rows are siblings, not children, so they are dropped instead of attached.
 *
 * This is the route the browser/webview provider exercises: it returns live DOM
 * where the SPA's suggestion data is present, whereas the static `embeddedData`
 * JSON the legacy path reads is typically absent from the server-rendered page.
 */
export function extractDomSuggestedChangesFromHtml(
  html: string,
  source: AutomatedSuggestionSource = 'githubWebAutomatedDiff',
): Map<string, SuggestedDiff[]> {
  return extractDomSuggestedChangesFromHtmlCore(html, source, false);
}

function extractDomSuggestedChangesFromHtmlCore(
  html: string,
  source: AutomatedSuggestionSource,
  markerScoped: boolean,
): Map<string, SuggestedDiff[]> {
  const suggestionsByCommentId = new Map<string, SuggestedDiff[]>();
  const anchors = collectCommentAnchorSpans(html);
  if (anchors.length === 0) {
    return suggestionsByCommentId;
  }

  const linesByCommentId = new Map<string, string[]>();
  const anchorsToScan = markerScoped
    ? anchors.filter((anchor) => htmlHasSuggestionMarkers(html.slice(anchor.start, anchor.end)))
    : anchors;
  for (const anchor of anchorsToScan) {
    const anchorHtml = html.slice(anchor.start, anchor.end);
    for (const line of anchorHtml.matchAll(DIFF_LINE_REGEX)) {
      const absoluteIndex = anchor.start + (line.index ?? 0);
      const commentId = containingAnchorId(anchors, absoluteIndex);
      if (commentId !== anchor.id) {
        continue;
      }

      const prefix = line.groups?.kind === 'deletion' ? '-' : '+';
      const bucket = linesByCommentId.get(commentId) ?? [];
      for (const textLine of cellToText(line.groups?.cell ?? '').split('\n')) {
        if (isUnifiedDiffNoNewlineSentinel(textLine)) {
          continue;
        }

        bucket.push(`${prefix}${textLine}`);
      }
      linesByCommentId.set(commentId, bucket);
    }
  }

  for (const [commentId, lines] of linesByCommentId) {
    if (lines.length === 0) {
      continue;
    }

    suggestionsByCommentId.set(commentId, [
      {
        kind: 'changedLines',
        path: undefined,
        source,
        confidence: 'medium',
        value: lines.join('\n'),
      },
    ]);
  }

  return suggestionsByCommentId;
}

interface CommentAnchorSpan {
  id: string;
  /** Index of the comment element's opening `<tag …>`. */
  start: number;
  /** Index one past the element's matching close tag (or end of input). */
  end: number;
}

/**
 * Locates each comment anchor (`id="discussion_r…"` / `data-comment-id="…"`) and
 * computes the `[start, end)` span of the element that carries it, so diff rows
 * can be attributed by containment rather than by mere document position.
 */
function collectCommentAnchorSpans(html: string): CommentAnchorSpan[] {
  const spans: CommentAnchorSpan[] = [];
  for (const match of html.matchAll(COMMENT_ANCHOR_REGEX)) {
    const id = match.groups?.discussion ?? match.groups?.commentId ?? '';
    if (id === '') {
      continue;
    }

    const attributeIndex = match.index ?? 0;
    const tagStart = html.lastIndexOf('<', attributeIndex);
    if (tagStart < 0) {
      continue;
    }

    const tagName = readTagName(html, tagStart);
    if (tagName === undefined) {
      continue;
    }

    spans.push({ id, start: tagStart, end: elementEndIndex(html, tagStart, tagName) });
  }

  return spans;
}

/** Reads the lowercased element name from an opening tag at `tagStart` (a `<`). */
function readTagName(html: string, tagStart: number): string | undefined {
  const match = /^<([a-z][a-z0-9-]*)/iu.exec(html.slice(tagStart, tagStart + 64));
  return match === null ? undefined : match[1].toLowerCase();
}

/**
 * Computes the index one past the matching close tag for the element opened at
 * `tagStart`, tracking nesting depth of same-named tags. An explicit
 * self-closing opening tag (`<div … />`) yields a span ending at that tag's `>`,
 * so following siblings are never treated as descendants; paired empty elements
 * still end after their matching close tag.
 */
function elementEndIndex(html: string, tagStart: number, tagName: string): number {
  const openCloseRegex = new RegExp(`<(/?)${escapeRegExp(tagName)}\\b[^>]*?(/?)>`, 'giu');
  openCloseRegex.lastIndex = tagStart;
  let depth = 0;
  let match: RegExpExecArray | null;
  while ((match = openCloseRegex.exec(html)) !== null) {
    const isClose = match[1] === '/';
    const isSelfClosing = match[2] === '/';
    if (isClose) {
      depth -= 1;
      if (depth <= 0) {
        return match.index + match[0].length;
      }
    } else if (!isSelfClosing) {
      depth += 1;
    } else if (depth === 0) {
      // The anchor element itself is self-closing — its subtree is empty.
      return match.index + match[0].length;
    }
  }

  return html.length;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

/**
 * Reports whether `html` carries any GitHub suggested-change marker. Used to
 * distinguish "no suggestion on this page" from "a suggestion is present but the
 * markup changed and could not be parsed", so the caller can warn honestly.
 */
export function htmlHasSuggestionMarkers(html: string): boolean {
  return SUGGESTION_MARKER_REGEX.test(html);
}

/**
 * Returns the id of the *innermost* comment element whose `[start, end)` span
 * contains `position`, or `undefined` when the position is not inside any comment
 * (e.g. an unrelated main-file diff row). "Innermost" = smallest containing span,
 * so a diff row inside a nested suggestion blob is attributed to the comment that
 * encloses it rather than an outer ancestor.
 */
function containingAnchorId(anchors: readonly CommentAnchorSpan[], position: number): string | undefined {
  let best: CommentAnchorSpan | undefined;
  for (const anchor of anchors) {
    if (position < anchor.start || position >= anchor.end) {
      continue;
    }
    if (best === undefined || anchor.end - anchor.start < best.end - best.start) {
      best = anchor;
    }
  }

  return best?.id;
}

function cellToText(cell: string): string {
  const inner = /<span\b[^>]*class="[^"]*\bblob-code-inner\b[^"]*"[^>]*>(?<text>[\s\S]*?)<\/span>/iu.exec(cell);
  if (inner?.groups?.text !== undefined) {
    // The blob-code-inner span holds the exact code text — preserve its leading
    // indentation (significant in a diff); only nested formatting tags are stripped.
    return normalizeCellLineEndings(decodeHtmlEntities(inner.groups.text.replace(/<[^>]+>/gu, '')));
  }

  // No inner span: fall back to the whole cell and trim the HTML formatting
  // whitespace GitHub adds around the code.
  return normalizeCellLineEndings(decodeHtmlEntities(cell.replace(/<[^>]+>/gu, '')).trim());
}

/**
 * Normalizes CRLF/CR to LF so a `\r\n` embedded in a rendered code line never
 * survives into a joined diff value — parity with the JSON path's
 * {@link normalizeDiffLineText}.
 */
function normalizeCellLineEndings(text: string): string {
  return text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n');
}

export function attachWebSuggestedDiffs(
  records: ReviewThreadRecord[],
  suggestionsByCommentId: ReadonlyMap<string, SuggestedDiff[]>,
): number {
  let attachedCount = 0;
  for (const record of records) {
    for (const comment of record.comments) {
      const diffs = firstMatchingDiffs(comment, suggestionsByCommentId);
      if (diffs === undefined || diffs.length === 0) {
        continue;
      }

      const existing = new Set(comment.suggestedDiffs.map(suggestedDiffIdentity));
      for (const diff of diffs) {
        const identity = suggestedDiffIdentity(diff);
        if (existing.has(identity)) {
          continue;
        }

        comment.suggestedDiffs.push(diff);
        existing.add(identity);
        attachedCount++;
      }

      if (comment.suggestedDiffs.length > 0) {
        comment.unavailableReason = undefined;
        comment.unavailableSource = undefined;
        comment.unavailableConfidence = undefined;
        comment.diffHunk = undefined;
      }
    }
  }

  return attachedCount;
}

function extractJsonScriptPayloads(html: string): string[] {
  const payloads: string[] = [];
  const scriptRegex = /<script\b[^>]*>([\s\S]*?)<\/script>/giu;
  for (const match of html.matchAll(scriptRegex)) {
    const decoded = decodeHtmlEntities(match[1].trim());
    if (decoded.includes('automatedComment') || decoded.includes('diffEntries')) {
      payloads.push(decoded);
    }
  }

  return payloads;
}

function parseJsonCandidates(value: string): unknown[] {
  const parsed: unknown[] = [];
  const candidates = [value, decodeHtmlEntities(value)];
  const seen = new Set<string>();
  for (const candidate of candidates) {
    const trimmed = candidate.trim();
    if (trimmed === '' || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);

    try {
      parsed.push(JSON.parse(trimmed));
    } catch {
      // GitHub embeds many scripts; ignore non-JSON or unrelated fragments.
    }
  }

  return parsed;
}

function decodeHtmlEntities(value: string): string {
  return value
    .replace(/&quot;/gu, '"')
    .replace(/&#34;/gu, '"')
    .replace(/&amp;/gu, '&')
    .replace(/&lt;/gu, '<')
    .replace(/&gt;/gu, '>');
}

function collectAutomatedDiffs(
  value: unknown,
  output: Map<string, SuggestedDiff[]>,
  source: AutomatedSuggestionSource,
  depth = 0,
  keyHint?: string,
): void {
  if (depth > 12) {
    return;
  }

  if (typeof value === 'string') {
    if (!isNestedJsonWrapperKey(keyHint)) {
      return;
    }
    if (!value.includes('automatedComment') && !value.includes('diffEntries')) {
      return;
    }

    for (const parsed of parseJsonCandidates(value)) {
      collectAutomatedDiffs(parsed, output, source, depth + 1);
    }
    return;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      collectAutomatedDiffs(item, output, source, depth + 1, keyHint);
    }
    return;
  }

  if (!isRecord(value)) {
    return;
  }

  collectCandidate(value, output, source);
  for (const [key, child] of Object.entries(value)) {
    collectAutomatedDiffs(child, output, source, depth + 1, key);
  }
}

function collectCandidate(
  value: Record<string, unknown>,
  output: Map<string, SuggestedDiff[]>,
  source: AutomatedSuggestionSource,
): void {
  const comment = isRecord(value.comment) ? value.comment : value;
  const automatedComment = isRecord(comment.automatedComment) ? comment.automatedComment : undefined;
  if (automatedComment === undefined) {
    return;
  }

  const suggestion = isRecord(automatedComment.suggestion) ? automatedComment.suggestion : undefined;
  const diffEntries = Array.isArray(suggestion?.diffEntries) ? suggestion.diffEntries : undefined;
  if (diffEntries === undefined) {
    return;
  }

  const commentKey = readCommentKey(comment) ?? readCommentKey(automatedComment) ?? readCommentKey(value);
  if (commentKey === undefined) {
    return;
  }

  const diffs = diffEntries
    .map((entry) => toSuggestedDiff(entry, source))
    .filter((diff): diff is SuggestedDiff => diff !== undefined);
  if (diffs.length === 0) {
    return;
  }

  const existing = output.get(commentKey) ?? [];
  const seen = new Set(existing.map(suggestedDiffIdentity));
  for (const diff of diffs) {
    const identity = suggestedDiffIdentity(diff);
    if (!seen.has(identity)) {
      existing.push(diff);
      seen.add(identity);
    }
  }
  output.set(commentKey, existing);
}

function suggestedDiffIdentity(diff: SuggestedDiff): string {
  return JSON.stringify([
    normalizeSuggestedDiffPath(diff.path),
    diff.value,
  ]);
}

function normalizeSuggestedDiffPath(path: string | undefined): string | undefined {
  const normalized = path?.replace(/\\/gu, '/').trim();
  return normalized === '' ? undefined : normalized;
}

function toSuggestedDiff(entry: unknown, source: AutomatedSuggestionSource): SuggestedDiff | undefined {
  if (!isRecord(entry)) {
    return undefined;
  }

  const diffLines = Array.isArray(entry.diffLines) ? entry.diffLines : [];
  const changedLines: string[] = [];
  for (const line of diffLines) {
    if (!isRecord(line)) {
      continue;
    }

    const type = typeof line.type === 'string' ? line.type.toUpperCase() : '';
    if (type !== 'DELETION' && type !== 'ADDITION') {
      continue;
    }

    const text = typeof line.text === 'string' ? line.text : '';
    const prefix = type === 'DELETION' ? '-' : '+';
    for (const textLine of normalizeDiffLineText(text)) {
      if (isUnifiedDiffNoNewlineSentinel(textLine)) {
        continue;
      }

      changedLines.push(`${prefix}${textLine}`);
    }
  }

  if (changedLines.length === 0) {
    return undefined;
  }

  return {
    kind: 'changedLines',
    path: typeof entry.path === 'string' ? entry.path : undefined,
    source,
    confidence: 'medium',
    value: changedLines.join('\n'),
  };
}

function firstMatchingDiffs(
  comment: RenderableComment,
  suggestionsByCommentId: ReadonlyMap<string, SuggestedDiff[]>,
): SuggestedDiff[] | undefined {
  for (const key of commentKeyCandidates(comment)) {
    const diffs = suggestionsByCommentId.get(key);
    if (diffs !== undefined) {
      return diffs;
    }
  }

  return undefined;
}

function commentKeyCandidates(comment: RenderableComment): string[] {
  const candidates: string[] = [];
  if (comment.databaseId !== undefined) {
    const databaseId = String(comment.databaseId);
    candidates.push(databaseId);
    const discussionMatch = /^discussion_r(?<id>\d+)$/iu.exec(databaseId);
    if (discussionMatch?.groups?.id !== undefined) {
      // Already a `discussion_r<id>` string — its bare numeric form covers the
      // alternate id; prefixing again would yield a junk `discussion_rdiscussion_r<id>`.
      candidates.push(discussionMatch.groups.id);
    } else {
      candidates.push(`discussion_r${databaseId}`);
    }
  }

  if (comment.nodeId !== undefined && comment.nodeId.trim() !== '') {
    candidates.push(comment.nodeId.trim());
  }

  const urlId = readDiscussionIdFromUrl(comment.url);
  if (urlId !== undefined) {
    candidates.push(urlId);
    candidates.push(`discussion_r${urlId}`);
  }

  return [...new Set(candidates.filter((candidate) => candidate !== ''))];
}

/**
 * Returns the suggestion keys that no comment's id forms matched. Used to surface
 * a precise diagnostic when web suggested-change diffs were extracted
 * (`size > 0`) yet none attached to a review comment (`attached === 0`), instead
 * of silently dropping them.
 */
export function unmatchedSuggestionKeys(
  records: readonly ReviewThreadRecord[],
  suggestionsByCommentId: ReadonlyMap<string, SuggestedDiff[]>,
): string[] {
  const matchedKeys = new Set<string>();
  for (const record of records) {
    for (const comment of record.comments) {
      for (const key of commentKeyCandidates(comment)) {
        if (suggestionsByCommentId.has(key)) {
          matchedKeys.add(key);
        }
      }
    }
  }

  return [...suggestionsByCommentId.keys()].filter((key) => !matchedKeys.has(key));
}

function readCommentKey(value: Record<string, unknown>): string | undefined {
  const databaseId = value.databaseId;
  if (typeof databaseId === 'number' || typeof databaseId === 'string') {
    const text = String(databaseId).trim();
    if (text !== '') {
      return text;
    }
  }

  const url = typeof value.url === 'string' ? value.url : typeof value.html_url === 'string' ? value.html_url : undefined;
  return readDiscussionIdFromUrl(url);
}

function readDiscussionIdFromUrl(url: string | undefined): string | undefined {
  if (url === undefined) {
    return undefined;
  }

  const match = /(?:#discussion_r|discussion_r)(?<id>\d+)/iu.exec(url);
  return match?.groups?.id;
}

function isNestedJsonWrapperKey(key: string | undefined): boolean {
  return key !== undefined && /^(?:payload|data|json|embeddedData|embedded_data|initialPayload)$/iu.test(key);
}

function normalizeDiffLineText(text: string): string[] {
  return text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n').split('\n');
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
