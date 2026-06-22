import {
  cleanCommentText,
  extractSuggestionBlocks,
  isLikelyWebOnlySuggestedChangeset,
  webOnlyUnavailableReason,
} from './markdownSuggestions';
import type { RenderableComment, ReviewComment, ReviewThread, ReviewThreadRecord } from './types';

export function reviewThreadToRecord(thread: ReviewThread): ReviewThreadRecord | undefined {
  const range = resolveLineRange(thread);
  const comments = thread.comments.map(toRenderableComment).filter((comment) => isRenderableComment(comment));
  if (comments.length === 0) {
    return undefined;
  }

  return {
    path: normalizePath(thread.path),
    lineStart: range.start,
    lineEnd: range.end,
    comments,
  };
}

export function scopeIncludesThread(thread: ReviewThread, scope: 'unresolved' | 'all' | 'resolved'): boolean {
  if (scope === 'all') {
    return true;
  }

  return scope === 'unresolved' ? thread.isResolved === false : thread.isResolved === true;
}

export function collectUnavailableSuggestionWarnings(records: readonly ReviewThreadRecord[]): string[] {
  const warnings: string[] = [];
  const seen = new Set<string>();
  for (const record of records) {
    for (const comment of record.comments) {
      if (comment.unavailableReason === undefined) {
        continue;
      }

      const warning = `${formatRecordLocation(record)}: ${comment.unavailableReason}`;
      if (!seen.has(warning)) {
        warnings.push(warning);
        seen.add(warning);
      }
    }
  }

  return warnings;
}

function toRenderableComment(comment: ReviewComment, commentIndex: number): RenderableComment {
  const suggestedChanges = extractSuggestionBlocks(comment.body, {
    authorLogin: comment.authorLogin,
    commentIndex,
    url: comment.url,
  });
  const body = cleanCommentText(comment.body);
  const suggestedDiffs = [...(comment.suggestedDiffs ?? [])];
  const unavailableReason =
    suggestedDiffs.length === 0 &&
    isLikelyWebOnlySuggestedChangeset({
      authorLogin: comment.authorLogin,
      body: comment.body,
      suggestionCount: suggestedChanges.length,
    })
      ? webOnlyUnavailableReason()
      : undefined;

  return {
    databaseId: comment.databaseId,
    body,
    suggestedChanges,
    suggestedDiffs,
    unavailableReason,
  };
}

function isRenderableComment(comment: RenderableComment): boolean {
  return (
    comment.body !== '' ||
    comment.suggestedChanges.length > 0 ||
    comment.suggestedDiffs.length > 0 ||
    comment.unavailableReason !== undefined
  );
}

function resolveLineRange(thread: ReviewThread): { start?: number; end?: number } {
  const currentStart = thread.startLine;
  const currentEnd = thread.line;
  const originalStart = thread.originalStartLine;
  const originalEnd = thread.originalLine;
  let start: number | undefined;
  let end: number | undefined;

  if (thread.isOutdated === true && (originalStart !== undefined || originalEnd !== undefined)) {
    start = originalStart ?? originalEnd;
    end = originalEnd ?? originalStart;
  } else if (currentStart !== undefined) {
    start = currentStart;
    end = currentEnd ?? originalEnd;
  } else if (currentEnd !== undefined) {
    start = originalStart ?? currentEnd;
    end = currentEnd;
  } else if (originalStart !== undefined) {
    start = originalStart;
    end = originalEnd;
  } else if (originalEnd !== undefined) {
    start = originalEnd;
    end = originalEnd;
  }

  if (start !== undefined && end !== undefined && end < start) {
    end = start;
  }

  return { start, end };
}

function normalizePath(path: string): string {
  return path.trim() === '' ? '<conversation>' : path.replace(/\\/gu, '/');
}

function formatRecordLocation(record: ReviewThreadRecord): string {
  if (record.lineStart === undefined && record.lineEnd === undefined) {
    return record.path;
  }

  const start = record.lineStart ?? record.lineEnd;
  const end = record.lineEnd ?? record.lineStart;
  return start === end ? `${record.path}:${start}` : `${record.path}:${start}-${end}`;
}
