import MarkdownIt from 'markdown-it';

import { isCopilotPullRequestReviewerAuthor, isCursorBugbotAuthor } from './botAuthors';
import type { EmbeddedLocation, SuggestedChange, UnavailableSuggestionSource } from './types';

interface MarkdownToken {
  type: string;
  info: string;
  content: string;
  map: [number, number] | null;
  children: MarkdownToken[] | null;
}

const markdown = new MarkdownIt({
  html: false,
  linkify: false,
  typographer: false,
});

export function extractSuggestionBlocks(
  text: string | undefined,
  metadata: Omit<SuggestedChange, 'kind' | 'value' | 'source' | 'confidence'> = {},
): SuggestedChange[] {
  if (text === undefined || text.trim() === '') {
    return [];
  }

  return flattenTokens(markdown.parse(normalizeLineEndings(text), {}))
    .filter(isSuggestionFence)
    .map((token) => ({
      kind: 'suggestion',
      value: token.content.replace(/\n+$/u, ''),
      source: 'apiMarkdownSuggestion',
      confidence: 'high',
      ...metadata,
    } satisfies SuggestedChange));
}

export function cleanCommentText(text: string | undefined): string {
  if (text === undefined || text.trim() === '') {
    return '';
  }

  const withoutSuggestionFences = replaceFenceBlocks(
    normalizeLineEndings(text),
    (token) => isSuggestionFence(token),
    () => [],
  );
  const withoutFenceMarkers = replaceFenceBlocks(
    withoutSuggestionFences,
    (token) => token.type === 'fence',
    (token) => token.content.replace(/\n+$/u, '').split('\n'),
  );
  const withoutCursorButtons = removeHtmlBlocksContainingText(
    withoutFenceMarkers,
    'div',
    /cursor\.com\/(?:open|agents)|fix-in-(?:cursor|web)/iu,
  );
  const withoutCursorFooter = removeHtmlBlocksContainingText(
    withoutCursorButtons,
    'sup',
    /Reviewed by\s+\[?Cursor Bugbot|cursor\.com\/bugbot/iu,
  );

  return withoutCursorFooter
    .replace(/<!--[\s\S]*?-->/gu, ' ')
    .replace(/<details\b[^>]*>\s*<summary\b[^>]*>\s*Additional Locations[\s\S]*?<\/details>/giu, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/gu, ' ')
    .replace(/(?<!!)\[([^\]]+)\]\([^)]*\)/gu, '$1')
    .replace(/<\/?[A-Za-z][^>]*>/gu, ' ')
    .replace(/&nbsp;/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim();
}

export function extractEmbeddedCommentLocations(text: string | undefined): EmbeddedLocation[] {
  if (text === undefined || text.trim() === '') {
    return [];
  }

  const locations: EmbeddedLocation[] = [];
  const seen = new Set<string>();
  const blockRegex = /<!--\s*LOCATIONS\s+START\s+(?<payload>[\s\S]*?)\s+LOCATIONS\s+END\s*-->/giu;
  for (const block of text.matchAll(blockRegex)) {
    const payload = block.groups?.payload ?? '';
    const locationRegex = /(?<target>\S+?)#L(?<start>\d+)(?:-L?(?<end>\d+))?/gu;
    for (const location of payload.matchAll(locationRegex)) {
      const path = normalizeEmbeddedLocationPath(location.groups?.target ?? '');
      const start = Number.parseInt(location.groups?.start ?? '', 10);
      if (path === undefined || !Number.isInteger(start) || start < 1) {
        continue;
      }

      const parsedEnd = Number.parseInt(location.groups?.end ?? '', 10);
      let end = Number.isInteger(parsedEnd) && parsedEnd >= 1 ? parsedEnd : start;
      if (end < start) {
        end = start;
      }

      const key = `${path.toLowerCase()}|${start}|${end}`;
      if (seen.has(key)) {
        continue;
      }

      locations.push({ path, lineStart: start, lineEnd: end });
      seen.add(key);
    }
  }

  return locations;
}

export function isLikelyWebOnlySuggestedChangeset(input: {
  authorLogin?: string;
  body?: string;
  suggestionCount: number;
}): boolean {
  if (input.suggestionCount > 0) {
    return false;
  }

  const body = input.body ?? '';
  const author = input.authorLogin ?? '';
  return isCopilotPullRequestReviewerAuthor(author) && hasCopilotWebOnlySuggestionMarker(body);
}

export function webOnlyUnavailableReason(): string {
  return 'GitHub web-only suggested changeset could not be extracted from the public API.';
}

export function externalBotUnavailableReason(): string {
  return 'External bot suggested fix was not exposed by the GitHub API.';
}

export interface SuggestedDiffUnavailable {
  reason: string;
  source: UnavailableSuggestionSource;
  confidence: 'unavailable';
}

export function suggestedDiffUnavailable(input: {
  authorLogin?: string;
  body?: string;
  suggestionCount: number;
}): SuggestedDiffUnavailable | undefined {
  if (input.suggestionCount > 0) {
    return undefined;
  }

  const body = input.body ?? '';
  const author = input.authorLogin ?? '';
  if (isCursorBugbotAuthor(author) && hasCursorBugbotExternalFixMarker(body)) {
    return {
      reason: externalBotUnavailableReason(),
      source: 'externalBotUnavailable',
      confidence: 'unavailable',
    };
  }

  if (isCopilotPullRequestReviewerAuthor(author) && hasCopilotWebOnlySuggestionMarker(body)) {
    return {
      reason: webOnlyUnavailableReason(),
      source: 'webOnlyUnavailable',
      confidence: 'unavailable',
    };
  }

  return undefined;
}

function hasCursorBugbotExternalFixMarker(body: string): boolean {
  return /BUGBOT_BUG_ID|cursor\.com\/(?:open|agents)/iu.test(body);
}

function hasCopilotWebOnlySuggestionMarker(body: string): boolean {
  return /Copilot suggested|suggested changeset|web-only suggested|suggested change.*GitHub web UI/iu.test(body);
}

function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n');
}

function removeHtmlBlocksContainingText(text: string, elementName: string, marker: RegExp): string {
  if (text.trim() === '') {
    return text;
  }

  const escapedName = escapeRegExp(elementName);
  const blockRegex = new RegExp(`<${escapedName}\\b[^>]*>[\\s\\S]*?<\\/${escapedName}>`, 'giu');
  return text.replace(blockRegex, (block) => (marker.test(block) ? ' ' : block));
}

function normalizeEmbeddedLocationPath(target: string): string | undefined {
  let candidate = target.trim();
  if (candidate === '') {
    return undefined;
  }

  if (/^https?:\/\//iu.test(candidate)) {
    try {
      const url = new URL(candidate);
      const segments = url.pathname.split('/').filter((segment) => segment !== '');
      const blobIndex = segments.findIndex((segment) => segment === 'blob');
      if (blobIndex >= 0 && segments.length > blobIndex + 2) {
        candidate = segments.slice(blobIndex + 2).join('/');
      } else {
        candidate = url.pathname;
      }
    } catch {
      return undefined;
    }
  }

  try {
    candidate = decodeURIComponent(candidate);
  } catch {
    // Keep the original text when percent-decoding is malformed.
  }

  const normalized = candidate.replace(/\\/gu, '/').trim().replace(/^\/+/u, '');
  return normalized === '' ? undefined : normalized;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function firstInfoWord(info: string): string {
  return info.trim().split(/\s+/u)[0]?.toLowerCase() ?? '';
}

function isSuggestionFence(token: MarkdownToken): boolean {
  return token.type === 'fence' && firstInfoWord(token.info) === 'suggestion';
}

function flattenTokens(tokens: readonly MarkdownToken[]): MarkdownToken[] {
  const flattened: MarkdownToken[] = [];
  for (const token of tokens) {
    flattened.push(token);
    if (token.children !== null) {
      flattened.push(...flattenTokens(token.children));
    }
  }

  return flattened;
}

function replaceFenceBlocks(
  source: string,
  predicate: (token: MarkdownToken) => boolean,
  replacement: (token: MarkdownToken) => string[],
): string {
  const replacements = flattenTokens(markdown.parse(source, {}))
    .filter((token) => token.map !== null && predicate(token))
    .map((token) => ({
      start: token.map![0],
      end: token.map![1],
      lines: replacement(token),
    }))
    .sort((left, right) => right.start - left.start);

  if (replacements.length === 0) {
    return source;
  }

  const lines = source.split('\n');
  for (const item of replacements) {
    lines.splice(item.start, item.end - item.start, ...item.lines);
  }

  return lines.join('\n');
}
