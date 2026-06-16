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

Preserve raw Markdown/HTML comment markup instead of default cleanup:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -KeepMarkup
```

Copy output to clipboard and still print it to stdout:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -Copy
```

Fail if clipboard copy does not succeed:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -Copy -CopyStrict
```

Write output to a file and still print it to stdout:

```powershell
pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -PullRequestUrl "https://github.com/owner/repo/pull/123" -OutputPath ./tmp/unresolved-comments.txt
```

## Output Contract (Text)

Comment blocks are separated by a single `---` delimiter: one leading, one between each
block, and one trailing (no doubled `---` between blocks). When a comment contains a
suggested change, it is rendered verbatim under a `Suggested change:` label.

```text
---
(path/to/file.ext) lineStart-lineEnd
Comment message
Suggested change:
<verbatim suggested code, when present>
Latest reply summary: <text or (none)>
---
```

## Output Behavior

- Default behavior is full (untruncated) comment and latest reply text.
- JSON output includes `resolutionState`. Authenticated GraphQL records use `unresolved`;
  anonymous REST fallback records use `unknown`.
- Default rendering strips bot metadata and visual chrome from comment text, including HTML comments,
  image embeds, HTML tags, Cursor/Bugbot action buttons, Bugbot footers, and link URLs.
- Suggested-change blocks (GitHub/Copilot/Cursor `suggestion` code fences) are preserved verbatim and
  rendered under a `Suggested change:` label with original indentation and line breaks intact. They
  are extracted out of the single-line prose. `-KeepMarkup` keeps the raw block inline instead.
- Rendered output and clipboard copies are UTF-8 and byte-for-byte verbatim. `-Truncate` never splits
  a multi-byte character or a UTF-16 surrogate pair (for example an emoji) at the truncation boundary.
- UTF-8 terminal rendering is enabled only when the console is not already UTF-8, so a normal run adds
  no console code-page switch (which is slow on Windows) and no per-invocation terminal latency.
- `-KeepMarkup` preserves comment markup for debugging or archival workflows. Whitespace is still
  normalized to single-line output, and embedded bot locations are still parsed for range rendering.
- `-Truncate` restores legacy compact output limits:
  - top-level comments: 500 characters
  - latest replies: 300 characters
- `-Copy` copies the exact rendered output (`text` or `json`) to clipboard and still writes the same output to stdout.
- `-CopyStrict` turns clipboard copy failure into a terminating error when `-Copy` is used.
- `-OutputPath` writes rendered output to a UTF-8 file (creating parent directories when needed) and still writes the same output to stdout.
- Clipboard copy failures are non-fatal and emit a warning so normal output remains available.

Clipboard command fallback order (first reachable mechanism wins):

1. `Set-Clipboard` (Windows GUI clipboard — preferred on Windows because it is unbounded and Unicode-correct)
2. OSC52 terminal escape (when the terminal context is compatible: VS Code, SSH, Windows Terminal, and stdout is a live terminal). Emits an explicit, verbatim `ESC ] 52 ; c ; <utf-8 base64> BEL` sequence
3. `Set-Clipboard` (non-Windows provider, when present)
4. `pbcopy`
5. `xclip`
6. `xsel`
7. `wl-copy`

If no supported clipboard mechanism exists, the script warns and continues.

OSC52 is automatically disabled when stdout is redirected (for example `... -Copy > out.txt` or
`... -Copy | cat`), so terminal escape bytes never leak into a captured file or pipe; the rendered
output stays clean and verbatim.

OSC52 size note: terminals cap the OSC52 payload size and may silently truncate large clipboard
content (a common cause of corrupted trailing characters). When the rendered output exceeds the safe
budget (default `100000` bytes, overridable via `WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES`), the script
warns (`W_CLIPBOARD_OSC52_TRUNCATION_RISK`) and recommends `-OutputPath` for a fully verbatim capture.

Native clipboard tools (`pbcopy`/`xclip`/`xsel`/`wl-copy`) are run with fully redirected standard
streams and a kill-on-timeout bound. This prevents the classic "clipboard hangs the terminal" delay:
tools such as `xclip`/`xsel`/`wl-copy` fork a long-lived selection-server child, and if that child
inherited the terminal it would keep it open for seconds after the output already printed. Because the
child's stdio is detached, the command returns immediately and the terminal is never held. The stdin
write is also bounded, and on timeout the whole tool process tree is terminated so nothing lingers.

## PowerShell Completion

In PowerShell terminals, parameter value completion includes:

- `-OutputFormat`: `text`, `json`
- `-GitHubHost`: `github.com`

## Migration Note

Default text output now preserves full comment text. If an existing workflow expects compact bounded output,
add `-Truncate` to restore legacy clipping behavior.

## Authentication Order

1. `-Token` argument
2. `GH_TOKEN` environment variable
3. `GITHUB_TOKEN` environment variable
4. stored `gh auth token` credentials (with `GH_TOKEN`/`GITHUB_TOKEN` temporarily cleared)
5. `git credential fill` for `https://<host>`
6. `gh auth login` (interactive fallback)

Exact unresolved-thread state uses GitHub GraphQL and requires auth.
For public PRs, when no token is available or a recoverable token failure occurs, the script falls
back to anonymous REST review-comment retrieval before prompting. REST fallback cannot know whether a
thread is resolved, so those JSON records use `resolutionState: "unknown"` and may include comments
from resolved threads.
Private repos require auth.
Anonymous REST requests use GitHub's lower unauthenticated limit (typically 60 requests/hour per IP);
authenticated requests have higher limits.
For PR URL and interactive flows, recoverable auth failures retry stored `gh`/Git credentials and then
anonymous REST before prompting for login.
When interactive fallback is used after an auth failure, the script ignores `GH_TOKEN`/`GITHUB_TOKEN` for the prompted token refresh and excludes the token value that already failed in this run.
Direct owner/repo mode remains non-prompting: explicit `-Token` failures fail fast, while missing auth or recoverable environment/stored-credential failures can use non-interactive stored-credential retry and anonymous REST.
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
  the allowlist. For `github.com`, outbound requests to the canonical public API host
  `api.github.com` are also allowed; GHES outbound hosts remain exact.

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

## Performance Notes

- The script's own work is fast: typically ~1.5-2.5 seconds (git/`gh` token lookup, one repo-access
  validation call, one authenticated GraphQL call, rendering, and copy). `-Copy` itself adds no
  measurable time: the OSC52 clipboard write is sub-millisecond, and the clipboard-tool probe is
  negligible. This is verified by running the script repeatedly inside one PowerShell session.
- Almost all of the wall-clock time of `pwsh ./Get-UnresolvedPRComments.ps1 ...` is the **PowerShell
  process lifecycle**, not this script:
  - **Startup (before output):** the .NET runtime + PowerShell engine cold start (assembly load +
    JIT). In a dev container on a slow overlay filesystem this is several seconds.
  - **Teardown (after output — the "renders, then hangs" part):** .NET/PowerShell managed shutdown.
    It runs after the comments have already printed, which is why it feels like a post-output hang.
    Making network calls (the HTTPS/TLS connection pool) and a slow container filesystem both inflate
    this shutdown. It happens with or without `-Copy`.
- Because the cost is the per-process spawn/teardown, the effective fix is to **not spawn a fresh
  `pwsh` per call.** Run the script from inside an already-open PowerShell session instead of from a
  non-PowerShell shell:

  ```powershell
  # From a bash/zsh prompt this pays full pwsh startup + teardown every time (slow):
  #   pwsh ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -Copy <url>

  # Instead, start pwsh once, then run the script in-process (measured ~8x faster):
  pwsh
  ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -Copy "https://github.com/owner/repo/pull/123"
  ./Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1 -Copy "https://github.com/owner/repo/pull/456"
  ```

  Running the `.ps1` from a live `pwsh` prompt executes it in-process (a child scope), so it pays the
  engine startup/teardown only once for the whole session rather than on every invocation.

## Line Range Edge Cases

- Cursor/Bugbot comments that include embedded `LOCATIONS` metadata use the first matching embedded
  location for displayed `path`, `lineStart`, and `lineEnd` so the text header points at the real
  diagnostic range instead of the nearest GitHub review anchor.
- JSON records preserve the current GitHub review anchor when available, falling back to original
  GitHub line metadata, in `githubPath`, `githubLineStart`, and `githubLineEnd`. They also expose
  the selected source as `locationSource` and include parsed `embeddedLocations` when present.
- If both `startLine` and `line` are missing in a thread, output uses `?-?` for the range.
- Single-line comments are rendered as `N-N`.

## Error Handling Notes

- Tokens are redacted in error output.
- GHES hosts are derived from PR URL and use `https://<host>/api/graphql`.
- Retries use exponential backoff for transient failures.
