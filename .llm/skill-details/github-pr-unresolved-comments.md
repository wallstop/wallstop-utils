# GitHub PR Unresolved Comments (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/github-pr-unresolved-comments.md`.

## Host Allowlist And Input Validation

Preserve GitHub utility safety, host allowlist checks, and retry semantics.

Validate host and owner/repo parameters before any network calls.

## Retry-Safe GitHub Request Flow

Keep HTTP calls inside approved wrappers and preserve retry behavior for transient status codes.

## Actionable Diagnostics And Resilience Tests

Keep diagnostics explicit and maintain coverage for URI safety, retries, and host restrictions.

## Clipboard Fallback And Strict Mode

Keep clipboard behavior deterministic and non-breaking:

- `-Copy` is best-effort by default and must never suppress stdout output.
- Copy attempts use ordered fallback strategies, including OSC52-capable PowerShell path when available.
- `-CopyStrict` is opt-in and must fail fast if used without `-Copy`.
- When `-CopyStrict` is present and copy fails, throw `E_CLIPBOARD_COPY_FAILED`.
- Warning/error text must continue redacting sensitive tokens.

## Output File Contract

When `-OutputPath` is supplied:

- Resolve to an absolute path deterministically.
- Create missing parent directories.
- Write UTF-8 content via `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::UTF8)`.
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
4. Keep non-global IP blocks and host allowlist checks active.
5. Preserve copy fallback order and strict mode behavior.
6. Preserve output-file write semantics and UTF-8 encoding.
7. Keep PowerShell completion metadata aligned with supported parameter values.

## References

- `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
