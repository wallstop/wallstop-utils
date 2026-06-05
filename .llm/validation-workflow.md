# Validation Workflow

This document is the session-close quality workflow for major changes.

## Goal

After significant work, run deterministic local gates, then confirm CI status. If any gate fails, treat remediation as current-session priority before starting new work.

## What Counts As Major

Treat a session as major when one or more apply:

1. Changes touch quality gates, hooks, CI workflows, or validator scripts.
2. Changes touch `.llm/` skills, context, or harness tooling.
3. Changes span multiple subsystems or multiple script languages.
4. Changes alter validation, safety, or runtime contract behavior.

## Major Change Session-Close Loop

When a session touches hooks, quality gates, or validation scripts, run one early preflight invocation at session start (or immediately after environment/bootstrap updates) so tooling dependency drift is caught before commit-time hooks.

- Run lightweight dependency preflight first:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly
```

- In devcontainer sessions, `.devcontainer/post-create.sh` runs this preflight automatically once at bootstrap in non-blocking mode; rerun it manually after dependency or quality-tooling updates.

- Run full local validation:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
```

- Push your branch so CI jobs execute:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1
```

- Watch PR checks to completion:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

- If any check fails, fix immediately in the same session and rerun the loop.

## What Full Validation Runs

`Invoke-FullValidation.ps1` runs these in order:

1. `pre-commit` stage for all files (format and stage-level hooks)
2. deep PowerShell validation via `Run-PreCommitValidation.ps1 -All` (full-repo tests/policy checks)
3. explicit LLM index and harness checks
4. workspace drift assertion (before/after git-status snapshot comparison)
5. optional CI watch via `gh pr checks --watch`

`Run-PreCommitValidation.ps1 -All` executes Pester through the centralized `Invoke-PesterQualityGate.ps1` wrapper in an isolated `pwsh -NoProfile -NonInteractive` subprocess with explicit timeout, bounded/truncated output capture, and bounded stream-drain timeout handling to avoid host/terminal lockups. In fast local mode (non-`-All`), ScriptAnalyzer targets must remain staged-file or target-file scoped (`Scripts/Utils/*.ps1`) to keep hook checks fast and reduce editor-host pressure; full-repo analyzer scope remains in `-All` paths.
When `pwsh` is available, `.githooks/pre-commit` runs `Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1` before pre-commit execution so staged AHK/batch drift can be safely auto-repaired (`-Fix -StaticOnly`) and restaged before last-resort hook gating.

For Copilot/agent-driven ad-hoc test runs, do not call `Invoke-Pester` directly in terminal sessions. Use a timeout-bounded quality-gate invocation with low output verbosity:

```bash
timeout -k 5s 300s pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None -DiagnosticsPrefix AgentSafe
```

On macOS hosts, use `gtimeout` if `timeout` is unavailable.

## Failure Handling

Use the first failing gate as the active remediation target.

- `E_VALIDATION_PRECOMMIT_FAILED`: fix formatter/lint findings, rerun.
- `E_VALIDATION_DEEP_POWERSHELL_FAILED`: fix tests/analyzer/policy failures from `Run-PreCommitValidation.ps1 -All`, rerun.
- `E_VALIDATION_POWERSHELL_MODULES_MISSING`: run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1` in the current host shell (`pwsh`), rerun `Invoke-FullValidation.ps1 -PreflightOnly`, then continue validation in the same session.
- `E_PRECOMMIT_VALIDATION_MODULES_MISSING`: run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1` before running commit hooks, then rerun preflight and hooks in the same shell session.
- Linker/compiler errors while pre-commit is "Installing environment" for a native tool: treat this as a hook architecture defect, not a developer toolchain task. Verify `.pre-commit-config.yaml` uses local `stylua`/`actionlint` hook IDs that invoke `Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1`, confirm the tool is pinned in `Scripts/Utils/Quality/native-quality-tools.json`, then run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1 -Tool All -EnsureOnly` and the standard preflight before retrying hooks.
- `E_TEST_FAILURE`: isolated Pester suite failed; use `W_TEST_FAILURE_OUTPUT_PREVIEW` for compact head/tail context and `W_TEST_FAILURE_ARTIFACT` (`logPath` under temp root) for bounded, redacted stdout/stderr and failure metadata (`suite`, `exitCode`, `rootCode`).
- `E_TEST_TIMEOUT` or `E_TEST_CAPTURE_*`: isolated Pester subprocess exceeded runtime or stream-capture bounds; treat as execution-path instability and remediate before rerunning.
- `E_AHK_STATIC_VALIDATION_FAILED`, `E_AHK_REQUIRES_V2_*`, or `E_AHK_V1_SYNTAX_DETECTED`: run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1 -TargetFiles <paths> -Fix`; if v1 syntax remains, migrate the script to AHK v2 and rerun the targeted command before hooks.
- `W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SKIPPED_UNSTAGED`: pre-hook auto-repair skipped one or more staged Windows-language files because they had unstaged drift; either stage/stash the unstaged changes or rerun the targeted fixer on the intended scope.
- `W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SOURCE_UNSTAGED`: pre-hook auto-repair skipped config snapshot refresh because the mapped `Scripts/AutoHotKey/<name>.ahk` source had unstaged drift; stage/stash source changes first, then rerun commit.
- `E_PRECOMMIT_AUTOREPAIR_*`: pre-hook safe auto-repair failed before pre-commit execution; fix the reported git/config issue and rerun commit.
- `W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED` / `W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING`: hook-time stale index lock recovery ran automatically; if failures continue, inspect concurrent git activity in the same repository.
- `W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED`: safe recovery was intentionally skipped (for example active git process detected, lock too new, or recovery mode disabled); resolve the reported reason and rerun.
- `E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED` / `E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED`: lock recovery could not safely resolve `.git/index.lock`; check for active git processes in this repo, then rerun after contention clears.
- `E_PRECOMMIT_WINDOWS_LANGUAGE_RESTAGE_REQUIRED`: a staged AHK/batch target differs from the repaired working tree; stage the repaired target files and rerun pre-commit validation.
- `E_VALIDATION_CI_FAILED`: fix failing workflow checks, rerun with `-WatchCi`.
- `E_VALIDATION_PR_MISSING`: open a PR, then rerun with `-WatchCi`.
- `E_CONFIG_ERROR` from PowerShell hooks: install or update required modules using the command in the diagnostic, then rerun in the same session.
- `E_VALIDATION_ARG_CONFLICT`: remove invalid flag combinations (for example `-PreflightOnly` with `-WatchCi`) and rerun with a valid workflow stage.
- `E_HOOK_TIMEOUT` / `E_HOOK_TIMEOUT_CONFIG` from hooks or devcontainer bootstrap: raise timeout guardrail values only when needed (`WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS`, `WALLSTOP_PREPUSH_TIMEOUT_SECONDS`, `WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS`, `WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS`), then rerun with the same command path. Recovery-backed pre-commit and pre-push hooks must leave 30s for inner recovery plus a 15s shutdown buffer plus 15s setup slack, so their override minimum is 60s.
- `W_HOOK_RUNTIME_BUDGET` from `.githooks/*`: hook phase exceeded the <=1s fast-path target; treat this as a performance regression signal and investigate the specific phase before widening budgets.
- Hook-time index-lock recovery knobs: adjust only when needed (`WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE`, `WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS`, `WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT`, `WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS`), then rerun with the same command path.
- `E_GIT_PUSH_DETACHED_HEAD`, `E_GIT_PUSH_REMOTE_MISSING`, or `E_GIT_PUSH_REMOTE_BRANCH_DIVERGED` from `Invoke-GitPushWithUpstream.ps1`: fix branch/remote state explicitly; do not force-push from automation.

## Codify New Knowledge (Forest-Not-Trees)

When a failure reveals a repeatable category, codify the invariant rather than a one-off rule:

1. Update the relevant skill card under [skills](./skills) with generalized guidance.
2. Update expanded guidance under [skill-details](./skill-details) with examples and rationale.
3. If the rule is repo-wide, update [context.md](./context.md) authoritative rules.
4. Add or update a regression test to prevent recurrence.
5. Regenerate and verify the skills index:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1
```

## Notes

- Keep rules category-level and durable. Avoid brittle path-specific mandates unless required by runtime constraints.
- Prefer deterministic checks and explicit error codes over implicit conventions.

## Mandatory Pre-Merge Checklist

- [ ] Ran `Invoke-FullValidation.ps1` locally.
- [ ] Ran an early `Invoke-FullValidation.ps1 -PreflightOnly` pass for hook/quality changes before commit/push.
- [ ] Local validation gates are green.
- [ ] Pushed branch updates for CI execution.
- [ ] Ran `Invoke-FullValidation.ps1 -WatchCi` (or equivalent PR check watch) and reached green CI.
- [ ] Any failure encountered in this session was fixed and revalidated in this session.
- [ ] If a new issue category was discovered, generalized it in `.llm` skills/context/tests and revalidated harness/index.
- [ ] **Executed post-work self-improvement workflow** with adversarial sub-agent consensus (see [post-work-self-improvement](./skill-details/post-work-self-improvement.md)).
