# GitHub PR Unresolved Comments (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/github-pr-unresolved-comments.md`.

## Host Allowlist And Input Validation

Preserve GitHub utility safety, host allowlist checks, and retry semantics.

Validate host and owner/repo parameters before any network calls.

## Retry-Safe GitHub Request Flow

Keep HTTP calls inside approved wrappers and preserve retry behavior for transient status codes.

## Actionable Diagnostics And Resilience Tests

Keep diagnostics explicit and maintain coverage for URI safety, retries, and host restrictions.

- GraphQL variable payload keys must match operation variable names exactly (case-sensitive), for example `owner`/`repo` rather than `Owner`/`Repo`.
- Enforce this contract in-script before each GraphQL request via `Assert-GraphQLVariableMap` (or equivalent), so mismatches fail with deterministic `E_CONFIG_ERROR` diagnostics before reaching the API.
- Tests should assert serialized request payload key casing for GraphQL variables to prevent silent regressions.
- Keep a static policy guard in `Tests/Utils/ScriptSafetyConventions.Tests.ps1` that asserts the unresolved-comments script keeps lowercase GraphQL variable keys and invokes the runtime variable-map assertion.
- Resolve environment tokens in GH CLI precedence order: `GH_TOKEN` before `GITHUB_TOKEN`.
- After environment-token handling, stored `gh` lookup must clear `GH_TOKEN`/`GITHUB_TOKEN`; Git credential probing must be bounded and non-interactive.
- In PR URL and interactive flows, recoverable token-auth failures should retry non-interactive stored credentials, then use public REST fallback before prompting login when exact GraphQL access is still needed.
- Track rejected token values from recoverable auth failures and exclude them from later token resolution in the same run. Prompted login fallback must bypass environment-token sources and rejected-token values so stale env credentials are not reused in long-running shells.
- Direct owner/repo mode remains non-prompting: explicit `-Token` auth failures fail fast, while missing auth or recoverable ambient-token failures may use stored-credential resolution/retry and public REST fallback.
- Public REST fallback cannot determine review-thread resolution; it must emit `W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN` and output lower-camel `resolutionState = "unknown"`.
- After editing `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`, run targeted agentic validation before hooks: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Run-PreCommitValidation.ps1 -TargetFiles Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`, `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 -OutputVerbosity None`, and `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None`. This catches ScriptAnalyzer regressions such as unused variables plus behavioral/policy drift while the edit is still in progress.

## Review Thread Range Rendering

Preserve this utility's displayed range contract for review-thread locations:

- When a comment body contains Cursor/Bugbot `LOCATIONS` metadata, parse it before comment cleanup and use the first matching embedded location for displayed `path`/`lineStart`/`lineEnd`; preserve the current GitHub anchor when available, falling back to original metadata, in `githubPath`/`githubLineStart`/`githubLineEnd`, and expose `locationSource` plus `embeddedLocations` for JSON consumers.
- Combine current/original GitHub line metadata (`startLine`, `line`, `originalStartLine`, `originalLine`) using the script's min-start/max-end fallback behavior; avoid unused GraphQL fields.
- Keep regressions for mixed current/original fallback cases, including original-start/current-end and original-start/larger-original-end ranges.
- In thread/comment conversion paths, use the script's property-access helper so `[pscustomobject]` responses and dictionary-backed fixtures both work.

## Bot Comment Cleanup

Rendered comments strip markup by default. Keep coverage that removes HTML comments, markdown images, link URLs, bare HTML tags, Cursor/Bugbot action-button blocks, Bugbot footers, and Additional Locations details while preserving the actual finding text. `-KeepMarkup` is the opt-out for raw archival/debug comment text; embedded-location parsing still runs for range rendering.

## Verbatim Output And Suggested Changes

Rendered output is a verbatim, copy-safe artifact. Keep these contracts with behavioral plus policy coverage:

- GitHub/Copilot/Cursor suggested-change fences (` ```suggestion `) are extracted verbatim into a `suggestions` record field and rendered under a `Suggested change:` label with original indentation/line breaks intact. Empty suggestion blocks denote deletions.
- A single shared fence regex (`Get-SuggestionFenceRegex`) is the source of truth used by both `Get-CommentSuggestionBlocks` (extraction) and `Remove-MarkupFromCommentText` (prose stripping) so the two never drift; suggestion code must not be whitespace-collapsed into prose.
- `-KeepMarkup` keeps the raw block inline and skips suggestion extraction.
- The text renderer (`Format-UnresolvedThreadsAsText`) collapses block delimiters to a single `---` (one leading, one between blocks, one trailing); never re-introduce the doubled `---` seam.
- `-Truncate` must not split a UTF-16 surrogate pair at the boundary (`[System.Char]::IsHighSurrogate` back-off) so emoji and astral characters never become U+FFFD.

## Clipboard Fallback And Strict Mode

Keep clipboard behavior deterministic, non-breaking, and byte-for-byte verbatim:

- `-Copy` is best-effort by default and must never suppress stdout output.
- Copy attempts use ordered fallback strategies. Priority is Windows-first: on Windows the unbounded GUI `Set-Clipboard` precedes the OSC52 terminal bridge; elsewhere OSC52 (when the terminal context supports it) precedes a non-Windows `Set-Clipboard` provider; native CLI tools follow.
- OSC52 must be emitted as an explicit-selector, UTF-8 base64 escape via `ConvertTo-Osc52Sequence` (`ESC ] 52 ; c ; <base64> BEL`) written through the `Write-ConsoleHostSequence` seam. Never use the ambiguous empty-selector `Set-Clipboard -AsOSC52` (some terminals, including VS Code, do not map the empty selector to the system clipboard).
- OSC52 must be disabled when stdout is redirected (`Test-IsConsoleOutputRedirected` over `[System.Console]::IsOutputRedirected`); otherwise the escape bytes leak into a captured file/pipe (for example `-Copy > out.txt`) and corrupt rendered output.
- OSC52 payloads above the byte budget (`Get-Osc52MaxClipboardByteBudget`, default `100000`, override `WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES`) emit `W_CLIPBOARD_OSC52_TRUNCATION_RISK` and recommend `-OutputPath`, because terminals silently truncate oversize OSC52 and corrupt trailing characters.
- Native clipboard tools (pbcopy/xclip/xsel/wl-copy) must run through `Invoke-NativeClipboardTool`, which uses `System.Diagnostics.Process` with `UseShellExecute=$false` and `RedirectStandardInput/Output/Error=$true`, writes the payload as raw UTF-8 (no-BOM) bytes to the child's stdin base stream via a timeout-bounded `WriteAsync` (verbatim, code-page independent, 5.1-safe), bounds the call with `WaitForExit(timeout)`, and on overrun terminates the whole process tree with `Stop-ProcessTreePortably` (the sanctioned portable `Kill($true)` shim). Detaching the child's stdio is the fix for the "clipboard hangs the terminal for several seconds" bug: tools like xclip/xsel/wl-copy fork a long-lived selection-server child that, if it inherited the terminal's stdout/stderr, would hold the terminal open after the script's output already printed. Never revert to `$value | & tool` piping (it both relies on the ambient `$OutputEncoding` and lets the tool inherit the terminal).
- `Invoke-Main` ensures UTF-8 terminal rendering via `Initialize-Utf8ConsoleOutputEncoding`, which reads the current `[System.Console]::OutputEncoding` (cheap, side-effect-free) and only sets it when it is not already UTF-8 (code page 65001). The unconditional setter must NOT be reintroduced: on Windows the setter triggers `SetConsoleOutputCP`, a slow/flickery code-page switch that adds per-invocation terminal latency. Both the read and the write are best-effort (guarded), since they throw when no console is attached.
- `-CopyStrict` is opt-in and must fail fast if used without `-Copy`. When `-CopyStrict` is present and copy fails, throw `E_CLIPBOARD_COPY_FAILED`.
- Warning/error text must continue redacting sensitive tokens.
- Unit tests must assert OSC52-first failover: when the OSC52 strategy fails, fallback continues to `Set-Clipboard` and still succeeds when possible.
- Safety conventions enforce OSC52 terminal-context gating (`Test-ShouldUseClipboardOsc52`), Windows-first vs OSC52 priority ordering in `Get-ClipboardCommandPriority`, explicit-selector UTF-8 OSC52 emission, detached/bounded native-tool execution (`Invoke-NativeClipboardTool`), and UTF-8 console encoding in `Invoke-Main`.
- By default the script skips the slow .NET/PowerShell managed teardown (finalizers + HTTP connection pool) that dominates wall time when a fresh `pwsh` is spawned per call on slow container filesystems; `-NoFastExit` opts out and restores the standard managed teardown. After rendering, `Invoke-FastProcessExit` flushes the console (`Invoke-ConsoleFlush`) then calls `Stop-CurrentProcessImmediately`, which on non-Windows P/Invokes libc `_exit` (a clean exit preserving the exit code, runtime-gated by `Test-IsWindowsPlatform` and idempotent `Add-Type`) and on Windows / fallback uses `[System.Environment]::Exit`. The flush-before-terminate order and the run-guard wiring (default-on success exit 0, failure exit 1, unless `-NoFastExit`, inside the existing dot-source guard so dot-sourced tests never terminate the host) are policy-tested. The primary remedy remains running the script inside a warm `pwsh` session.

## Output File Contract

When `-OutputPath` is supplied (capture `$PSBoundParameters` at script scope into `$script:TopLevelBoundParameters` and use `.ContainsKey("OutputPath")` to detect, not `IsNullOrWhiteSpace`):

- Resolve to an absolute path deterministically.
- Create missing parent directories.
- Write UTF-8 content without BOM via `[System.IO.File]::WriteAllText(..., [System.Text.UTF8Encoding]::new($false))`.
- Keep stdout output unchanged for automation compatibility.
- Use explicit `E_INVALID_OUTPUT_PATH` / `E_OUTPUT_WRITE_FAILED` diagnostics.

## PowerShell Completion Contract

For PowerShell terminal usage, keep value discovery aids in the script parameter block:

- `-OutputFormat` keeps completions for `text` and `json`.
- `-GitHubHost` keeps completion hint for `github.com`.
- Completion metadata is additive and must not weaken validation constraints.

## Workflow

1. Validate host and owner/repo parameters early.
2. Keep HTTP calls inside approved wrappers.
3. Preserve retry behavior for transient status codes.
4. Keep GraphQL variable keys aligned with declared variable names and casing.
5. Assert GraphQL variable-map/query alignment in-script before request dispatch.
6. Apply source-aware auth recovery: enforce `GH_TOKEN` before `GITHUB_TOKEN`, retry stored credentials before public REST fallback, track rejected token values after recoverable auth failures, and bypass env/rejected values during prompted login fallback.
7. Keep non-global IP blocks and host allowlist checks active.
8. Preserve copy fallback order and strict mode behavior, including Windows-first/OSC52 priority and explicit-selector UTF-8 OSC52 emission.
9. Preserve bot comment cleanup and embedded-location behavior with both behavioral and policy tests.
10. Preserve verbatim output: UTF-8 clipboard/native-pipe/console encoding, surrogate-safe truncation, single collapsed `---` delimiter, and verbatim suggested-change rendering.
11. Preserve output-file write semantics and UTF-8 encoding.
12. Keep PowerShell completion metadata aligned with supported parameter values.
13. Run targeted lint, GitHub behavior, and policy Pester checks before relying on hook execution.

## References

- `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
