import type { ReviewThreadRecord, SuggestedDiff } from './types';

export function extractAutomatedSuggestedDiffsFromHtml(html: string): Map<string, SuggestedDiff[]> {
  const suggestionsByCommentId = new Map<string, SuggestedDiff[]>();
  for (const payload of extractJsonScriptPayloads(html)) {
    try {
      collectAutomatedDiffs(JSON.parse(payload), suggestionsByCommentId);
    } catch {
      // GitHub embeds many scripts; ignore non-JSON or unrelated fragments.
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
      if (comment.databaseId === undefined) {
        continue;
      }

      const diffs = suggestionsByCommentId.get(String(comment.databaseId));
      if (diffs === undefined || diffs.length === 0) {
        continue;
      }

      const existing = new Set(comment.suggestedDiffs.map((diff) => diff.value));
      for (const diff of diffs) {
        if (existing.has(diff.value)) {
          continue;
        }

        comment.suggestedDiffs.push(diff);
        existing.add(diff.value);
        attachedCount++;
      }

      if (comment.suggestedDiffs.length > 0) {
        comment.unavailableReason = undefined;
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

function decodeHtmlEntities(value: string): string {
  return value
    .replace(/&quot;/gu, '"')
    .replace(/&#34;/gu, '"')
    .replace(/&amp;/gu, '&')
    .replace(/&lt;/gu, '<')
    .replace(/&gt;/gu, '>');
}

function collectAutomatedDiffs(value: unknown, output: Map<string, SuggestedDiff[]>): void {
  if (Array.isArray(value)) {
    for (const item of value) {
      collectAutomatedDiffs(item, output);
    }
    return;
  }

  if (!isRecord(value)) {
    return;
  }

  collectCandidate(value, output);
  for (const child of Object.values(value)) {
    collectAutomatedDiffs(child, output);
  }
}

function collectCandidate(value: Record<string, unknown>, output: Map<string, SuggestedDiff[]>): void {
  const comment = isRecord(value.comment) ? value.comment : value;
  const automatedComment = isRecord(comment.automatedComment) ? comment.automatedComment : undefined;
  const source = automatedComment ?? value;
  const suggestion = isRecord(source.suggestion) ? source.suggestion : undefined;
  const diffEntries = Array.isArray(suggestion?.diffEntries) ? suggestion.diffEntries : undefined;
  if (diffEntries === undefined) {
    return;
  }

  const databaseId = readDatabaseId(comment) ?? readDatabaseId(source) ?? readDatabaseId(value);
  if (databaseId === undefined) {
    return;
  }

  const diffs = diffEntries
    .map(toSuggestedDiff)
    .filter((diff): diff is SuggestedDiff => diff !== undefined);
  if (diffs.length === 0) {
    return;
  }

  const key = String(databaseId);
  const existing = output.get(key) ?? [];
  const seen = new Set(existing.map((diff) => diff.value));
  for (const diff of diffs) {
    if (!seen.has(diff.value)) {
      existing.push(diff);
      seen.add(diff.value);
    }
  }
  output.set(key, existing);
}

function toSuggestedDiff(entry: unknown): SuggestedDiff | undefined {
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
    changedLines.push(`${type === 'DELETION' ? '-' : '+'}${text}`);
  }

  if (changedLines.length === 0) {
    return undefined;
  }

  return {
    kind: 'changedLines',
    path: typeof entry.path === 'string' ? entry.path : undefined,
    value: changedLines.join('\n'),
  };
}

function readDatabaseId(value: Record<string, unknown>): number | undefined {
  const databaseId = value.databaseId;
  return typeof databaseId === 'number' ? databaseId : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
