const cursorBugbotAuthorLogins = new Set([
  'bugbot[bot]',
  'cursor-bugbot[bot]',
  'cursor[bot]',
]);

export function isCursorBugbotAuthor(authorLogin: string | undefined): boolean {
  const normalized = normalizeAuthorLogin(authorLogin);
  return normalized !== undefined && cursorBugbotAuthorLogins.has(normalized);
}

export function isCopilotPullRequestReviewerAuthor(authorLogin: string | undefined): boolean {
  const normalized = normalizeAuthorLogin(authorLogin);
  return normalized === 'copilot-pull-request-reviewer' ||
    normalized === 'copilot-pull-request-reviewer[bot]';
}

function normalizeAuthorLogin(authorLogin: string | undefined): string | undefined {
  const normalized = authorLogin?.trim().toLowerCase();
  return normalized === '' ? undefined : normalized;
}
