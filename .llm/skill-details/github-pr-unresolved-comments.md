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
- In PR URL and interactive flows, recoverable token-auth failures should attempt one anonymous retry before prompting login so public-repo access remains resilient when cached tokens expire.

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
6. Retry recoverable auth failures anonymously once before interactive login prompts in PR URL/interactive flows.
7. Keep non-global IP blocks and host allowlist checks active.
8. Preserve copy fallback order and strict mode behavior.
9. Preserve output-file write semantics and UTF-8 encoding.
10. Keep PowerShell completion metadata aligned with supported parameter values.

## References

- `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
