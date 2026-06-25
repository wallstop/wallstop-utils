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

  return suggestionsByCommentId;
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
      candidates.push(discussionMatch.groups.id);
    }
  }

  const urlId = readDiscussionIdFromUrl(comment.url);
  if (urlId !== undefined) {
    candidates.push(urlId);
    candidates.push(`discussion_r${urlId}`);
  }

  return [...new Set(candidates)];
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
