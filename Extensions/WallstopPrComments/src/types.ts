export type ReviewScope = 'unresolved' | 'all' | 'resolved';
export type AutomatedSuggestionSource = 'githubWebAutomatedDiff' | 'browserDomAutomatedDiff';
export type UnavailableSuggestionSource = 'externalBotUnavailable' | 'webOnlyUnavailable';
export type WebSuggestedDiffProvenance = AutomatedSuggestionSource | 'webOnlyUnavailable';
export type SuggestionSource =
  | 'apiMarkdownSuggestion'
  | AutomatedSuggestionSource
  | UnavailableSuggestionSource;
export type SuggestionConfidence = 'high' | 'medium' | 'unavailable';

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
  source: 'apiMarkdownSuggestion';
  confidence: 'high';
  authorLogin?: string;
  commentIndex?: number;
  url?: string;
}

export interface SuggestedDiff {
  kind: 'changedLines';
  value: string;
  source: AutomatedSuggestionSource;
  confidence: 'medium';
  path?: string;
}

export interface ReviewComment {
  id?: string;
  nodeId?: string;
  databaseId?: number | string;
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
  databaseId?: number | string;
  url?: string;
  body: string;
  suggestedChanges: SuggestedChange[];
  suggestedDiffs: SuggestedDiff[];
  unavailableReason?: string;
  unavailableSource?: UnavailableSuggestionSource;
  unavailableConfidence?: 'unavailable';
}

export interface EmbeddedLocation {
  path: string;
  lineStart: number;
  lineEnd: number;
}

export interface ReviewThreadRecord {
  path: string;
  lineStart?: number;
  lineEnd?: number;
  locationSource?: 'github' | 'embedded';
  githubPath?: string;
  githubLineStart?: number;
  githubLineEnd?: number;
  embeddedLocations?: EmbeddedLocation[];
  comments: RenderableComment[];
}

export interface ReviewThreadResult {
  threads: ReviewThread[];
  warnings: string[];
}

export interface WebSuggestedDiffResult {
  suggestions: Map<string, SuggestedDiff[]>;
  provenance: WebSuggestedDiffProvenance;
}
