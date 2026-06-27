export type ReviewScope = 'unresolved' | 'all' | 'resolved';
export type AutomatedSuggestionSource = 'githubWebAutomatedDiff' | 'browserDomAutomatedDiff';
export type UnavailableSuggestionSource = 'externalBotUnavailable' | 'webOnlyUnavailable';
/**
 * Outcome of attempting to derive suggested-change diffs from a GitHub web page:
 * suggestions were parsed (one of {@link AutomatedSuggestionSource}); the page was
 * fetched but carried no suggestion markers ({@link WebSuggestedDiffProvenance} value
 * `webOnlyUnavailable`); or suggestion markers were present but in a markup the
 * extractor could not parse (`webSuggestionMarkersUnparseable`) — distinct so the
 * caller can warn that a diff exists but the format changed, rather than implying
 * none exists.
 */
export type WebSuggestedDiffProvenance =
  | AutomatedSuggestionSource
  | 'webOnlyUnavailable'
  | 'webSuggestionMarkersUnparseable';
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

/**
 * A repository the authenticated user can access (from GitHub's `GET /user/repos`),
 * carrying the {@link RepositoryRef} identity plus the metadata used to filter, rank,
 * and label entries in the "Add Repository" picker.
 */
export interface AccessibleRepository {
  host: string;
  owner: string;
  repo: string;
  fullName: string;
  private: boolean;
  archived: boolean;
  fork: boolean;
  pushedAt?: string;
  description?: string;
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
  /**
   * A reconstructed `-`/`+` unified diff for this suggestion, derived from the
   * comment's `diffHunk` (the "before") and {@link value} (the "after"). Present
   * only when the anchored before-context is available.
   */
  diff?: string;
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
  /**
   * The comment's GraphQL/REST node id, retained so web suggested-change diffs can
   * be matched by node id when no numeric/database id is available.
   */
  nodeId?: string;
  url?: string;
  authorLogin?: string;
  body: string;
  suggestedChanges: SuggestedChange[];
  suggestedDiffs: SuggestedDiff[];
  /**
   * The comment's `diff_hunk`, trimmed to the comment's line range, surfaced as
   * focused diff context when no higher-confidence suggestion/diff is present
   * and `includeDiffHunks` is enabled.
   */
  diffHunk?: string;
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
