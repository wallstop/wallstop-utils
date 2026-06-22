export type ReviewScope = 'unresolved' | 'all' | 'resolved';

export interface RepositoryRef {
  host: string;
  owner: string;
  repo: string;
}

export interface PullRequestSummary {
  number: number;
  title: string;
  state: 'OPEN' | 'CLOSED';
  isDraft: boolean;
  merged: boolean;
  author: string;
  headRefName: string;
  updatedAt: string;
  url: string;
}

export interface SuggestedChange {
  kind: 'suggestion';
  value: string;
  authorLogin?: string;
  commentIndex?: number;
  url?: string;
}

export interface SuggestedDiff {
  kind: 'changedLines';
  value: string;
  path?: string;
}

export interface ReviewComment {
  id?: string;
  nodeId?: string;
  databaseId?: number;
  body: string;
  authorLogin?: string;
  url?: string;
  diffHunk?: string;
  path?: string;
  line?: number;
  startLine?: number;
  originalLine?: number;
  originalStartLine?: number;
  suggestedDiffs?: SuggestedDiff[];
}

export interface ReviewThread {
  id: string;
  path: string;
  isResolved?: boolean;
  isOutdated?: boolean;
  line?: number;
  startLine?: number;
  originalLine?: number;
  originalStartLine?: number;
  comments: ReviewComment[];
}

export interface RenderableComment {
  databaseId?: number;
  body: string;
  suggestedChanges: SuggestedChange[];
  suggestedDiffs: SuggestedDiff[];
  unavailableReason?: string;
}

export interface ReviewThreadRecord {
  path: string;
  lineStart?: number;
  lineEnd?: number;
  comments: RenderableComment[];
}

export interface ReviewThreadResult {
  threads: ReviewThread[];
  warnings: string[];
}
