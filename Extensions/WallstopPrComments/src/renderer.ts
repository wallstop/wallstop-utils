import type { ReviewThreadRecord } from './types';
import { hasPublicCommentText, hasRenderableCommentContent } from './records';

export function formatReviewThreadRecords(records: readonly ReviewThreadRecord[]): string {
  const renderableRecords = records
    .map((record) => ({
      ...record,
      comments: record.comments.filter(hasRenderableCommentContent),
    }))
    .filter((record) => record.comments.length > 0);
  if (renderableRecords.length === 0) {
    return 'No review comments found.';
  }

  const lines: string[] = [];
  for (const record of renderableRecords) {
    if (lines.length === 0) {
      lines.push('---');
    }

    lines.push(`(${record.path}) ${record.lineStart ?? '?'}-${record.lineEnd ?? '?'}`);
    for (const comment of record.comments) {
      if (comment.body !== '') {
        lines.push('Comment:');
        lines.push(...comment.body.split('\n'));
      }

      for (const suggestion of comment.suggestedChanges) {
        addSuggestedChange(lines, suggestion.diff ?? suggestion.value);
      }

      for (const diff of comment.suggestedDiffs) {
        addSuggestedChange(lines, diff.value, suggestedDiffLabel(record.path, diff.path));
      }

      const hasPublicText = hasPublicCommentText(comment);
      const hasSuggestedOutput = comment.suggestedChanges.length > 0 || comment.suggestedDiffs.length > 0;
      if (comment.diffHunk !== undefined && comment.diffHunk !== '' && !hasSuggestedOutput && comment.unavailableReason === undefined) {
        addSuggestedChange(lines, comment.diffHunk, 'Diff context:');
      }

      if (!hasPublicText && comment.unavailableReason !== undefined) {
        lines.push('Suggestion unavailable:');
        lines.push(comment.unavailableReason);
      }
    }
    lines.push('---');
  }

  return lines.join('\n');
}

function addSuggestedChange(lines: string[], value: string, label = 'Suggested change:'): void {
  lines.push(label);
  lines.push(...value.split('\n'));
}

function suggestedDiffLabel(recordPath: string, diffPath: string | undefined): string {
  if (diffPath === undefined) {
    return 'Suggested change:';
  }

  const normalizedDiffPath = normalizePath(diffPath);
  return normalizedDiffPath === normalizePath(recordPath)
    ? 'Suggested change:'
    : `Suggested change (${normalizedDiffPath}):`;
}

function normalizePath(path: string): string {
  return path.replace(/\\/gu, '/').replace(/[\r\n]+/gu, ' ').trim();
}
