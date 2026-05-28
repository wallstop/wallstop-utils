# Pre-Commit Hooks And Fallbacks (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/precommit-hooks-and-fallbacks.md`.

## Last-Resort Hook Behavior

Keep local hook wrappers as last-resort gates while preserving deterministic fallback behavior.

During agentic work, run targeted validators and safe fixers before invoking hooks. When hook wrappers do run, use pre-commit as the default execution path for pre-commit and pre-push stages.

## Deterministic Fallback Path

Keep a fallback PowerShell validation path for environments where pre-commit is unavailable.

Always propagate fallback exit status so failures cannot be hidden.

In pre-commit mode, keep ScriptAnalyzer scope staged-file targeted for `Scripts/Utils/*.ps1`; reserve full-repo analyzer scans for explicit `-All` flows (pre-push/full validation).

Hook-side validation must not hide stale staged content by mutating only the working tree. If a staged target has unstaged repair drift, fail with an explicit restage-required diagnostic instead of passing.

## Backup/Update Formatter Boundary

Do not run `Scripts/Utils/FormatPowershellScripts.ps1` inside `Scripts/Backup.ps1` or `Scripts/Update.ps1`.

Formatting ownership belongs to pre-commit hooks and explicit quality commands, not backup/update orchestration.

When commit hooks autofix files (`files were modified by this hook`), backup orchestration may restage managed backup paths and retry commit in a bounded loop.

## Timeout-Guarded Hook Execution

Keep hook wrappers bounded so stalled commands cannot lock editor-hosted workflows.

- `.githooks/pre-commit` must run primary/fallback commands through timeout guards and emit stable timeout diagnostics.
- `.githooks/pre-push` must run `Invoke-FullValidation.ps1` (or fallback commands) through timeout guards.
- `.devcontainer/post-create.sh` preflight should stay non-blocking and timeout-bounded.
- Allow controlled overrides via environment variables when intentionally running slower sessions:
  - `WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS`
  - `WALLSTOP_PREPUSH_TIMEOUT_SECONDS`
  - `WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS`
- For Copilot/agent ad-hoc tests, do not run direct `Invoke-Pester` terminal commands. Use timeout-bounded `Invoke-PesterQualityGate.ps1` with `-OutputVerbosity None` and a narrow `-TestPath` scope.

## Failure Artifact Diagnostics

When isolated Pester runs fail in `Run-PreCommitValidation.ps1`, keep throw messages compact and triage through warnings:

- `W_TEST_FAILURE_OUTPUT_PREVIEW` provides bounded head+tail context.
- `W_TEST_FAILURE_ARTIFACT` provides a temp-root `logPath` (`wallstop-precommit-validation`) with bounded, redacted stdout/stderr and metadata (`suite`, `exitCode`, `rootCode`).

## Executable Mode And Hook Hygiene

Track executable bit changes for hook wrapper scripts and keep trailing newline formatting stable.

## Workflow

1. Agentic early parity command: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly`.
2. Run targeted validators/safe fixers for edited domains before hooks.
3. Use pre-commit if available for pre-commit and pre-push stages.
4. Keep fallback PowerShell validation path available.
5. Ensure fallback path propagates exit status.
6. Use the full-validation wrapper for major session-close checks.

## References

- `.githooks/pre-commit`
- `.githooks/pre-push`
- `.pre-commit-config.yaml`
- `Scripts/Utils/Run-PreCommitValidation.ps1`
