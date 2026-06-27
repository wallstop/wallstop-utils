import {
  cleanCommentText,
  extractEmbeddedCommentLocations,
  extractSuggestionBlocks,
  suggestedDiffUnavailable,
} from './markdownSuggestions';
import { extractNewSideLinesInRange, reconstructSuggestionDiff, trimDiffHunkToRange } from './suggestionDiff';
import { isCursorBugbotAuthor } from './botAuthors';
import type { EmbeddedLocation, RenderableComment, ReviewComment, ReviewThread, ReviewThreadRecord } from './types';

export interface ReviewThreadToRecordOptions {
  includeDiffHunks?: boolean;
}

export function reviewThreadToRecord(
  thread: ReviewThread,
  options: ReviewThreadToRecordOptions = {},
): ReviewThreadRecord | undefined {
  const githubPath = normalizePath(thread.path);
  const githubRange = resolveLineRange(thread);
  const topComment = thread.comments[0];
  const embeddedLocations = isTrustedEmbeddedLocationAuthor(topComment?.authorLogin)
    ? extractEmbeddedCommentLocations(topComment?.body)
    : [];
  const outputLocation = resolveOutputLocation(githubPath, githubRange, embeddedLocations);
  const includeDiffHunks = options.includeDiffHunks ?? true;
  const comments = thread.comments
    .map((comment, commentIndex) =>
      toRenderableComment(comment, commentIndex, {
        lineStart: githubRange.start,
        lineEnd: githubRange.end,
        includeDiffHunks,
      }),
    )
    .filter((comment) => hasRenderableCommentContent(comment));
  if (comments.length === 0) {
    return undefined;
  }

  return {
    path: outputLocation.path,
    lineStart: outputLocation.start,
    lineEnd: outputLocation.end,
    locationSource: outputLocation.source,
    githubPath,
    githubLineStart: githubRange.start,
    githubLineEnd: githubRange.end,
    embeddedLocations,
    comments,
  };
}

export function hasRenderableCommentContent(comment: RenderableComment): boolean {
  return (
    comment.body !== '' ||
    comment.suggestedChanges.length > 0 ||
    comment.suggestedDiffs.length > 0 ||
    (comment.diffHunk !== undefined && comment.diffHunk !== '') ||
    comment.unavailableReason !== undefined
  );
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

interface RenderContext {
  lineStart?: number;
  lineEnd?: number;
  includeDiffHunks: boolean;
}

function toRenderableComment(
  comment: ReviewComment,
  commentIndex: number,
  context: RenderContext,
): RenderableComment {
  // Only reconstruct a suggestion into a diff when the comment has a resolvable line anchor; without
  // one, the lines the suggestion replaces are unknowable and a diff against the whole hunk would
  // fabricate unrelated deletions, so the suggestion renders as raw text instead.
  const hasAnchorRange = context.lineStart !== undefined || context.lineEnd !== undefined;
  const beforeContext = hasAnchorRange
    ? extractNewSideLinesInRange(comment.diffHunk, context.lineStart, context.lineEnd)
    : '';
  const suggestedChanges = extractSuggestionBlocks(comment.body, {
    authorLogin: comment.authorLogin,
    commentIndex,
    url: comment.url,
  }).map((change) => {
    const diff = beforeContext === '' ? undefined : reconstructSuggestionDiff(beforeContext, change.value);
    return diff === undefined ? change : { ...change, diff };
  });
  const body = cleanCommentText(comment.body);
  const suggestedDiffs = [...(comment.suggestedDiffs ?? [])];
  const unavailable = suggestedDiffs.length === 0
    ? suggestedDiffUnavailable({
        authorLogin: comment.authorLogin,
        body: comment.body,
        url: comment.url,
        suggestionCount: suggestedChanges.length,
      })
    : undefined;
  const hasHigherConfidence = suggestedChanges.length > 0 || suggestedDiffs.length > 0;
  const diffHunk = context.includeDiffHunks && !hasHigherConfidence
    ? trimDiffHunkToRange(comment.diffHunk, context.lineStart, context.lineEnd)
    : '';

  return {
    databaseId: comment.databaseId,
    nodeId: comment.nodeId ?? comment.id,
    url: comment.url,
    authorLogin: comment.authorLogin,
    body,
    suggestedChanges,
    suggestedDiffs,
    diffHunk: diffHunk === '' ? undefined : diffHunk,
    unavailableReason: unavailable?.reason,
    unavailableSource: unavailable?.source,
    unavailableConfidence: unavailable?.confidence,
  };
}

function resolveOutputLocation(
  githubPath: string,
  githubRange: { start?: number; end?: number },
  embeddedLocations: readonly EmbeddedLocation[],
): { path: string; start?: number; end?: number; source: 'github' | 'embedded' } {
  const preferred = selectEmbeddedLocation(githubPath, embeddedLocations);
  if (preferred !== undefined) {
    return {
      path: preferred.path,
      start: preferred.lineStart,
      end: preferred.lineEnd,
      source: 'embedded',
    };
  }

  return {
    path: githubPath,
    start: githubRange.start,
    end: githubRange.end,
    source: 'github',
  };
}

function selectEmbeddedLocation(
  githubPath: string,
  embeddedLocations: readonly EmbeddedLocation[],
): EmbeddedLocation | undefined {
  if (embeddedLocations.length === 0) {
    return undefined;
  }

  if (githubPath !== '<conversation>') {
    const exact = embeddedLocations.find((location) => location.path === githubPath);
    if (exact !== undefined) {
      return exact;
    }

    const insensitive = embeddedLocations.find((location) => location.path.toLowerCase() === githubPath.toLowerCase());
    if (insensitive !== undefined) {
      return insensitive;
    }

    return undefined;
  }

  return embeddedLocations[0];
}

function isTrustedEmbeddedLocationAuthor(authorLogin: string | undefined): boolean {
  return isCursorBugbotAuthor(authorLogin);
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
