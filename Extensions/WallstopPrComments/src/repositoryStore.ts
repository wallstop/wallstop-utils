import type { AccessibleRepository, PullRequestSummary, RepositoryRef } from './types';

export interface MementoLike {
  get<T>(key: string, fallback: T): T;
  update(key: string, value: unknown): Thenable<void> | Promise<void>;
}

const REPOSITORIES_KEY = 'wallstopPrComments.repositories';

export class RepositoryStore {
  constructor(private readonly state: MementoLike) {}

  list(): RepositoryRef[] {
    const persisted = this.state.get<unknown>(REPOSITORIES_KEY, []);
    if (!Array.isArray(persisted)) {
      return [];
    }

    const repositories: RepositoryRef[] = [];
    const seen = new Set<string>();
    for (const value of persisted) {
      const repository = tryNormalizePersistedRepository(value);
      if (repository === undefined) {
        continue;
      }

      const key = repositoryKey(repository);
      if (seen.has(key)) {
        continue;
      }

      repositories.push(repository);
      seen.add(key);
    }

    return repositories;
  }

  async add(repository: RepositoryRef): Promise<void> {
    const normalized = normalizeRepositoryHost(repository);
    const repositories = this.list();
    if (!repositories.some((existing) => repositoryKey(existing) === repositoryKey(normalized))) {
      repositories.push(normalized);
      await this.state.update(REPOSITORIES_KEY, repositories);
    }
  }

  async remove(repository: RepositoryRef): Promise<void> {
    const key = repositoryKey(repository);
    await this.state.update(
      REPOSITORIES_KEY,
      this.list().filter((candidate) => repositoryKey(candidate) !== key),
    );
  }
}

export function groupPullRequests(pullRequests: readonly PullRequestSummary[]): {
  open: PullRequestSummary[];
  closed: PullRequestSummary[];
} {
  return {
    open: pullRequests.filter(isOpenPullRequest),
    closed: pullRequests.filter((pullRequest) => !isOpenPullRequest(pullRequest)),
  };
}

export function isOpenPullRequest(pullRequest: PullRequestSummary): boolean {
  return pullRequest.state === 'OPEN' && !pullRequest.merged;
}

/** A QuickPick item for the "Add Repository" picker; structurally a `vscode.QuickPickItem`. */
export interface AddRepoQuickPickItem {
  label: string;
  description?: string;
  detail?: string;
  alwaysShow?: boolean;
  repository?: RepositoryRef;
  manualEntry?: boolean;
}

/**
 * The "filtered intelligently" step for the Add Repository picker: drops archived repos and any
 * already pinned (compared by {@link repositoryKey}), de-duplicates, and orders most-recently-pushed
 * first (repos without a push timestamp sort last, preserving input order among themselves).
 */
export function selectableRepositories(
  accessible: readonly AccessibleRepository[],
  alreadyAdded: readonly RepositoryRef[],
): AccessibleRepository[] {
  const addedKeys = new Set(alreadyAdded.map(repositoryKey));
  const seen = new Set<string>();
  const result: AccessibleRepository[] = [];
  for (const repository of accessible) {
    if (repository.archived) {
      continue;
    }

    const key = repositoryKey(repository);
    if (addedKeys.has(key) || seen.has(key)) {
      continue;
    }

    seen.add(key);
    result.push(repository);
  }

  return result.sort((left, right) => comparePushedAtDescending(left.pushedAt, right.pushedAt));
}

/** Shapes accessible repositories into picker items, with a manual-entry escape hatch pinned first. */
export function buildAddRepoQuickPickItems(repositories: readonly AccessibleRepository[]): AddRepoQuickPickItem[] {
  const manualEntry: AddRepoQuickPickItem = {
    label: '$(edit) Enter owner/repo or URL…',
    alwaysShow: true,
    manualEntry: true,
  };
  const items = repositories.map(
    (repository) =>
      ({
        label: `${repository.owner}/${repository.repo}`,
        description: describeAccessibleRepository(repository),
        detail: repository.description,
        repository: { host: repository.host, owner: repository.owner, repo: repository.repo },
      }) satisfies AddRepoQuickPickItem,
  );

  return [manualEntry, ...items];
}

/** github.com is always enumerated; any additional host already pinned is included too (lowercased). */
export function enumerationHosts(repositories: readonly RepositoryRef[]): string[] {
  const hosts = new Set<string>(['github.com']);
  for (const repository of repositories) {
    hosts.add(assertSafeGitHubHost(repository.host));
  }

  return [...hosts];
}

function describeAccessibleRepository(repository: AccessibleRepository): string {
  const parts = [repository.host, repository.private ? 'private' : 'public'];
  if (repository.pushedAt !== undefined) {
    parts.push(`pushed ${repository.pushedAt.slice(0, 10)}`);
  }

  return parts.join(' · ');
}

function comparePushedAtDescending(left: string | undefined, right: string | undefined): number {
  const leftTime = parseTimestamp(left);
  const rightTime = parseTimestamp(right);
  if (leftTime !== undefined && rightTime !== undefined) {
    return rightTime - leftTime;
  }

  if (leftTime !== undefined) {
    return -1;
  }

  if (rightTime !== undefined) {
    return 1;
  }

  return 0;
}

function parseTimestamp(value: string | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function parseRepositoryInput(input: string): RepositoryRef {
  const trimmed = input.trim();
  if (/^https:\/\//iu.test(trimmed)) {
    const rawHost = readRawHttpsUrlHost(trimmed);
    const url = new URL(trimmed);
    if (url.username !== '' || url.password !== '' || url.port !== '') {
      throw new Error('Repository URLs must not include user info or a port.');
    }

    const segments = url.pathname.split('/').filter((segment) => segment !== '');
    if (segments.length < 2) {
      throw new Error('Repository URLs must include owner and repository path segments.');
    }

    return normalizeRepositoryHost({
      host: rawHost,
      owner: segments[0],
      repo: segments[1].replace(/\.git$/iu, ''),
    });
  }

  const ownerRepoMatch = /^([^/\s]+)\/([^/\s]+)$/u.exec(trimmed);
  if (ownerRepoMatch !== null) {
    return {
      host: 'github.com',
      owner: ownerRepoMatch[1],
      repo: ownerRepoMatch[2],
    };
  }

  throw new Error('Enter a repository as owner/repo or as a GitHub HTTPS URL.');
}

export function repositoryKey(repository: RepositoryRef): string {
  return `${assertSafeGitHubHost(repository.host)}/${repository.owner.toLowerCase()}/${repository.repo.toLowerCase()}`;
}

export function assertSafeGitHubHost(host: string): string {
  const normalized = host.trim().toLowerCase();
  if (normalized === '') {
    throw new Error('GitHub host cannot be empty.');
  }

  if (normalized === 'localhost' || normalized.endsWith('.localhost')) {
    throw new Error('Localhost GitHub hosts are not allowed.');
  }

  if (normalized.includes(':')) {
    return normalizeIPv6Host(normalized);
  }

  const ipv4Parts = parseIPv4(normalized);
  if (ipv4Parts !== undefined) {
    assertAllowedIPv4Host(ipv4Parts);
    return normalized;
  }

  assertDnsHostFormat(normalized);
  assertNoUrlHostnameReinterpretation(normalized);
  return normalized;
}

function normalizeRepositoryHost(repository: RepositoryRef): RepositoryRef {
  return {
    ...repository,
    host: assertSafeGitHubHost(repository.host),
  };
}

function tryNormalizePersistedRepository(value: unknown): RepositoryRef | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const host = readString(value.host);
  const owner = readRepositorySegment(value.owner);
  const repo = readRepositorySegment(value.repo);
  if (host === undefined || owner === undefined || repo === undefined) {
    return undefined;
  }

  try {
    return normalizeRepositoryHost({ host, owner, repo });
  } catch {
    return undefined;
  }
}

function readString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function readRepositorySegment(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed === '' || /[\/\s]/u.test(trimmed) ? undefined : trimmed;
}

function readRawHttpsUrlHost(input: string): string {
  const match = /^https:\/\/(?<authority>[^/?#]*)/iu.exec(input);
  const authority = match?.groups?.authority ?? '';
  if (authority === '') {
    throw new Error('Repository URLs must include a GitHub host.');
  }

  const withoutUserInfo = authority.includes('@') ? authority.slice(authority.lastIndexOf('@') + 1) : authority;
  if (withoutUserInfo.startsWith('[')) {
    const end = withoutUserInfo.indexOf(']');
    if (end < 0) {
      throw new Error(`Invalid GitHub host '${withoutUserInfo}'.`);
    }

    return withoutUserInfo.slice(0, end + 1);
  }

  const colon = withoutUserInfo.indexOf(':');
  return colon < 0 ? withoutUserInfo : withoutUserInfo.slice(0, colon);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function assertDnsHostFormat(host: string): void {
  if (host.length > 253 || host.endsWith('.') || host.startsWith('.')) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  const labels = host.split('.');
  for (const label of labels) {
    if (
      label.length === 0 ||
      label.length > 63 ||
      !/^[a-z0-9-]+$/u.test(label) ||
      label.startsWith('-') ||
      label.endsWith('-')
    ) {
      throw new Error(`Invalid GitHub host '${host}'.`);
    }
  }
}

function assertNoUrlHostnameReinterpretation(host: string): void {
  let parsed: URL;
  try {
    parsed = new URL(`https://${host}/`);
  } catch {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  if (parsed.hostname !== host) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }
}

function parseIPv4(host: string): [number, number, number, number] | undefined {
  const parts = host.split('.');
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/u.test(part))) {
    return undefined;
  }

  if (parts.some((part) => part.length > 1 && part.startsWith('0'))) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  const numbers = parts.map((part) => Number(part));
  if (numbers.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  return numbers as [number, number, number, number];
}

function assertAllowedIPv4Host(parts: [number, number, number, number]): void {
  const [first, second] = parts;
  const blocked =
    first === 0 ||
    first === 10 ||
    first === 127 ||
    (first === 169 && second === 254) ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) ||
    (first === 100 && second >= 64 && second <= 127) ||
    first >= 224;

  if (blocked) {
    throw new Error('Local, private, link-local, and non-global GitHub IP hosts are not allowed.');
  }
}

function assertAllowedIPv6Host(host: string): void {
  const normalized = host.replace(/^\[/u, '').replace(/\]$/u, '');
  const mappedIPv4 = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/iu.exec(normalized);
  if (mappedIPv4 !== null) {
    const parts = parseIPv4(mappedIPv4[1]);
    if (parts === undefined) {
      throw new Error(`Invalid GitHub host '${host}'.`);
    }

    assertAllowedIPv4Host(parts);
    return;
  }

  const mappedIPv4Hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/iu.exec(normalized);
  if (mappedIPv4Hex !== null) {
    const high = Number.parseInt(mappedIPv4Hex[1], 16);
    const low = Number.parseInt(mappedIPv4Hex[2], 16);
    assertAllowedIPv4Host([(high >> 8) & 255, high & 255, (low >> 8) & 255, low & 255]);
    return;
  }

  if (
    normalized === '::' ||
    normalized === '::1' ||
    isIPv6LinkLocal(normalized) ||
    /^f[cd][0-9a-f]{2}:/iu.test(normalized) ||
    /^ff[0-9a-f]{2}:/iu.test(normalized)
  ) {
    throw new Error('Local, private, link-local, and non-global GitHub IP hosts are not allowed.');
  }

  if (!/^[0-9a-f:.]+$/iu.test(normalized)) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  try {
    new URL(`https://[${normalized}]/`);
  } catch {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }
}

function normalizeIPv6Host(host: string): string {
  const hasOpeningBracket = host.startsWith('[');
  const hasClosingBracket = host.endsWith(']');
  if (hasOpeningBracket !== hasClosingBracket) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  const normalized = hasOpeningBracket ? host.slice(1, -1) : host;
  if (normalized.includes('[') || normalized.includes(']')) {
    throw new Error(`Invalid GitHub host '${host}'.`);
  }

  assertAllowedIPv6Host(normalized);
  return `[${normalized}]`;
}

function isIPv6LinkLocal(host: string): boolean {
  const firstHextetText = host.split(':', 1)[0];
  if (!/^[0-9a-f]{1,4}$/iu.test(firstHextetText)) {
    return false;
  }

  const firstHextet = Number.parseInt(firstHextetText, 16);
  return (firstHextet & 0xffc0) === 0xfe80;
}
