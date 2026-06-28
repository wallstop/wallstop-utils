const UNIFIED_DIFF_NO_NEWLINE_SENTINEL = '\\ No newline at end of file';

export function isUnifiedDiffNoNewlineSentinel(line: string): boolean {
  return line === UNIFIED_DIFF_NO_NEWLINE_SENTINEL;
}

export function dropUnifiedDiffMetadataLines(lines: readonly string[]): string[] {
  return lines.filter((line) => !isUnifiedDiffNoNewlineSentinel(line));
}
