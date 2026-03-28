# GitHub PR Unresolved Comment Summarizer

This utility reads unresolved review threads on a pull request and prints a compact text format suitable for copy/paste into notes, chat, or an LLM prompt.

## Scope Boundary

This folder is standalone GitHub tooling under `Scripts/Utils/GitHub`.
It does not participate in backup/restore workflows in this repository.

## Requirements

- PowerShell 7+
- Optional: `gh` CLI for auth token discovery/login fallback

## Usage

Text output from URL:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123"
```

Direct owner/repo/PR mode (including GHES host):

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -Owner owner -Repo repo -PullRequestNumber 123 -GitHubHost ghes.example.com
```

Interactive mode (asks for owner/repo and lets you pick open PR):

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -Interactive
```

JSON output:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -OutputFormat json
```

Legacy compact text mode (opt-in truncation):

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -Truncate
```

Copy output to clipboard and still print it to stdout:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -Copy
```

## Output Contract (Text)

```text
---
(path/to/file.ext) lineStart-lineEnd
Comment message
Latest reply summary: <text or (none)>
---
```

## Output Behavior

- Default behavior is full (untruncated) comment and latest reply text.
- `-Truncate` restores legacy compact output limits:
	- top-level comments: 500 characters
	- latest replies: 300 characters
- `-Copy` copies the exact rendered output (`text` or `json`) to clipboard and still writes the same output to stdout.
- Clipboard copy failures are non-fatal and emit a warning so normal output remains available.

Clipboard command fallback order:

1. `Set-Clipboard`
2. `pbcopy`
3. `xclip`
4. `xsel`
5. `wl-copy`

If no supported clipboard command exists, the script warns and continues.

## Migration Note

Default text output now preserves full comment text. If an existing workflow expects compact bounded output,
add `-Truncate` to restore legacy clipping behavior.

## Authentication Order

1. `-Token` argument
2. `GITHUB_TOKEN` environment variable
3. `GH_TOKEN` environment variable
4. `gh auth token`
5. `gh auth login` (interactive fallback)

Public repos can work without auth, but auth is preferred to avoid low rate limits.
Private repos require auth.
When auth is used, the script validates token access against repository metadata before querying review threads.
For `github.com`, the script also validates `X-OAuth-Scopes` and expects:

- private repositories: `repo`
- public repositories: `repo` or `public_repo`

## Host Safety Rules

- Non-global IP targets are rejected for safety, including loopback, RFC1918 private ranges,
	link-local ranges, carrier-grade NAT ranges, multicast ranges, reserved/documentation ranges,
	and IPv6 local/multicast equivalents.
- `-PullRequestUrl` hosts are validated using the same safety rules.
- If `-GitHubHost` is explicitly provided together with `-PullRequestUrl`, both hosts must
	match after normalization or the script fails with `E_INVALID_URL`.

Optional host allowlist controls:

- `-AllowedGitHubHosts` accepts one or more approved hosts.
- If `-AllowedGitHubHosts` is omitted, the script uses `WALLSTOP_GITHUB_ALLOWED_HOSTS`, then
	`GITHUB_ALLOWED_HOSTS` (comma/semicolon/whitespace separated) when present.
- When an allowlist is active, both target resolution and outbound request URIs must match
	the allowlist.

Example:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 `
	-PullRequestUrl "https://github.com/owner/repo/pull/123" `
	-AllowedGitHubHosts github.com
```

## Rate Limits and Retries

- Default request timeout is 60 seconds.
- Transient failures use exponential backoff with jitter.
- With `-WaitOnRateLimit`, the script waits until `X-RateLimit-Reset` when valid.
- Invalid or expired rate-limit reset headers fail fast with an `E_RATE_LIMIT` error.

## Line Range Edge Cases

- If both `startLine` and `line` are missing in a thread, output uses `?-?` for the range.
- Single-line comments are rendered as `N-N`.

## Error Handling Notes

- Tokens are redacted in error output.
- GHES hosts are derived from PR URL and use `https://<host>/api/graphql`.
- Retries use exponential backoff for transient failures.
