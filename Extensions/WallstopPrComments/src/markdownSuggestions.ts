import MarkdownIt from 'markdown-it';

import type { SuggestedChange } from './types';

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
  metadata: Omit<SuggestedChange, 'kind' | 'value'> = {},
): SuggestedChange[] {
  if (text === undefined || text.trim() === '') {
    return [];
  }

  return flattenTokens(markdown.parse(normalizeLineEndings(text), {}))
    .filter(isSuggestionFence)
    .map((token) => ({
      kind: 'suggestion',
      value: token.content.replace(/\n+$/u, ''),
      ...metadata,
    }));
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

  return withoutFenceMarkers
    .replace(/<!--[\s\S]*?-->/gu, ' ')
    .replace(/<details\b[^>]*>\s*<summary\b[^>]*>\s*Additional Locations[\s\S]*?<\/details>/giu, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/gu, ' ')
    .replace(/(?<!!)\[([^\]]+)\]\([^)]*\)/gu, '$1')
    .replace(/<\/?[A-Za-z][^>]*>/gu, ' ')
    .replace(/&nbsp;/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim();
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
  const botAuthor = /\b(copilot|cursor|bugbot)\b|copilot-pull-request-reviewer/iu.test(author);
  const bodyLooksLikeWebSuggestion = /suggested changeset|web-only suggested|suggested change.*GitHub web UI|Copilot suggested/iu.test(body);
  return bodyLooksLikeWebSuggestion && (botAuthor || /suggested changeset/iu.test(body));
}

export function webOnlyUnavailableReason(): string {
  return 'GitHub web-only suggested changeset could not be extracted from the public API.';
}

function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n');
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
