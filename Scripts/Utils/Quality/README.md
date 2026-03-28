# Script Quality Helpers

This folder contains quality helper scripts used by local hooks and CI:

- `Format-PowerShellFiles.ps1`: deterministic PowerShell formatting for staged or selected files.
- `Invoke-WindowsLanguageChecks.ps1`: Windows-only checks for AutoHotkey (`/validate` when available) and best-effort batch smoke validation.
- `Invoke-MacOSLanguageChecks.sh`: macOS AppleScript validation with a source-first migration path and `.scpt` fallback.
- `Assert-CleanGitTree.ps1`: fails when formatting or checks mutate files in CI.

These scripts are intentionally strict in CI and best-effort where platform tooling is optional.

Shell quality enforcement model:

- Local and PR/push enforcement is strict on changed shell targets (`Scripts/*.sh`, `.githooks/*`) via `shellcheck` and `shfmt`.
- Linux CI keeps deterministic full-repo checks for non-shell debt-heavy hooks.
- Full-repo shell debt cleanup is available via manual workflow dispatch (`run_shell_debt_audit=true`).

Shell suppression governance:

- Keep `.shellcheckrc` strict (`severity=style`) and avoid global disable directives.
- Use suppressions only when a code fix is unsafe or infeasible.
- Every suppression must include nearby rationale so reviewers can verify intent and risk.

AI remediation workflow:

- Follow `LLM-REMEDIATION-CONTRACT.md` when applying shell fixes.
- Required order: reproduce -> minimal fix -> formatter -> lint -> tests.
- Never bypass shell hooks with broad skips to land unresolved debt.
