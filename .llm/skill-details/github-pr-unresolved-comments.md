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

## Clipboard Fallback And Strict Mode

Keep clipboard behavior deterministic and non-breaking:

- `-Copy` is best-effort by default and must never suppress stdout output.
- Copy attempts use ordered fallback strategies, including OSC52-capable PowerShell path when available.
- Native clipboard tools (pbcopy, xclip, xsel, wl-copy) must check `$LASTEXITCODE` after invocation; non-zero means the attempt failed and the next strategy should be tried.
- `-CopyStrict` is opt-in and must fail fast if used without `-Copy`.
- When `-CopyStrict` is present and copy fails, throw `E_CLIPBOARD_COPY_FAILED`.
- Warning/error text must continue redacting sensitive tokens.
- Unit tests must assert OSC52-first failover behavior: when `Set-Clipboard -AsOSC52` fails, fallback must continue to plain `Set-Clipboard` and still succeed when possible.
- Safety conventions should enforce both OSC52 gating (`$supportsOsc52` + `Test-ShouldUseClipboardOsc52`) and OSC52-before-Set-Clipboard priority ordering in `Get-ClipboardCommandPriority`.

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
8. Preserve copy fallback order and strict mode behavior.
9. Preserve bot comment cleanup and embedded-location behavior with both behavioral and policy tests.
10. Preserve output-file write semantics and UTF-8 encoding.
11. Keep PowerShell completion metadata aligned with supported parameter values.
12. Run targeted lint, GitHub behavior, and policy Pester checks before relying on hook execution.

## References

- `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
