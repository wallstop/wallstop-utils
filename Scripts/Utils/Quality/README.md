# Script Quality Helpers

This folder contains quality helper scripts used by local hooks and CI:

- `Format-PowerShellFiles.ps1`: deterministic PowerShell formatting for staged or selected files.
- `Invoke-WindowsLanguageChecks.ps1`: Windows-only checks for AutoHotkey (runtime probing with `/validate`, then `/iLib` fallback) and best-effort batch smoke validation. AutoHotkey process execution uses explicit stdout/stderr capture via `Start-Process` to avoid ambiguous GUI-subsystem behavior in headless CI.

Batch smoke checks intentionally remain heuristic, but they now apply uniformly to both single-line and multi-line `.bat` files.
- `Invoke-MacOSLanguageChecks.sh`: macOS AppleScript validation with a source-first migration path and `.scpt` fallback.
- `Assert-CleanGitTree.ps1`: fails when formatting or checks mutate files in CI.
- `Invoke-FullValidation.ps1`: session-close full validation wrapper (pre-commit stage all-files, pre-push stage all-files, clean-tree assertion, optional PR CI watch).
- `Update-LlmSkillsIndex.ps1`: deterministically regenerates `.llm/skills-index.md` from `.llm/skills` metadata comments.
- `Test-LlmHarness.ps1`: validates wrapper pointers, line limits (300), trigger metadata coverage, lightweight skill cards, expanded-guide links, and index freshness (`-Check`).

These scripts are intentionally strict in CI and best-effort where platform tooling is optional.

Windows CI operating model:

- PR fast lane: Windows language validation runs only when `*.ahk` or `*.bat` targets change.
- PR budget: targeted Windows checks must complete within 180 seconds; CI fails fast on budget breach.
- Runtime source: PR lane must use the cached portable AutoHotkey runtime and must not depend on heavyweight package-manager installs.
- Nightly deep lane: full-repository Windows validation runs on schedule (and optional manual dispatch) to preserve comprehensive coverage.
- Fallback semantics: when baseline commit resolution is unavailable, CI validates all tracked Windows language targets in the current HEAD.

Windows lane triage playbook:

- `W_GIT_BASELINE_UNAVAILABLE`: baseline commit could not be resolved; review event context and fetch history.
- `E_AHK_RUNTIME_UNAVAILABLE`: portable AutoHotkey runtime was not set up correctly in CI.
- `E_AHK_UNAVAILABLE` / `E_AHK_VALIDATE_UNAVAILABLE`: AutoHotkey execution contract failed under required mode (includes switch-probing diagnostics and a runtime/capture hint when probe attempts return empty output).
- `E_CI_TIME_BUDGET`: PR lane exceeded 180-second runtime budget; investigate cache misses, download regressions, or broadened file scope.

Shell quality enforcement model:

- Local and PR/push enforcement is strict on changed shell targets (`Scripts/*.sh`, `.githooks/*`) via `shellcheck` and `shfmt`.
- Linux CI keeps deterministic full-repo checks for non-shell debt-heavy hooks.
- Full-repo shell debt cleanup is available via manual workflow dispatch (`run_shell_debt_audit=true`).

Shell suppression governance:

- Keep `.shellcheckrc` strict (`severity=style`) and avoid global disable directives.
- Use suppressions only when a code fix is unsafe or infeasible.
- Every suppression must include nearby rationale so reviewers can verify intent and risk.

AI remediation workflow:

- Follow `.llm/skill-details/shell-governance/llm-remediation-contract.md` when applying shell fixes.
- Required order: reproduce -> minimal fix -> formatter -> lint -> tests.
- Never bypass shell hooks with broad skips to land unresolved debt.

Major-change session-close workflow:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

LLM harness workflow:

- Keep `.llm/context.md` as the authoritative source for all vendor wrappers.
- Keep `.llm/skills-index.md` as the dedicated generated index artifact.
- Keep `.llm/skills/*.md` lightweight and point to expanded guides in `.llm/skill-details`.
- Keep every `.llm/*.md` file at or below 300 lines.
- After changing `.llm/skills/*.md`, regenerate and verify index state:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1
```
