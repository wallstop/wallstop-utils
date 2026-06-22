import type { RenderableComment, ReviewThreadRecord } from './types';

export function formatReviewThreadRecords(records: readonly ReviewThreadRecord[]): string {
  const renderableRecords = records
    .map((record) => ({
      ...record,
      comments: record.comments.filter(hasPublicText),
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
        addSuggestedChange(lines, suggestion.value);
      }

      for (const diff of comment.suggestedDiffs) {
        addSuggestedChange(lines, diff.value);
      }
    }
    lines.push('---');
  }

  return lines.join('\n');
}

function addSuggestedChange(lines: string[], value: string): void {
  lines.push('Suggested change:');
  lines.push(...value.split('\n'));
}

function hasPublicText(comment: RenderableComment): boolean {
  return comment.body !== '' || comment.suggestedChanges.length > 0 || comment.suggestedDiffs.length > 0;
}
