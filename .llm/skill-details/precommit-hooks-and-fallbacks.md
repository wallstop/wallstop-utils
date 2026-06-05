# Pre-Commit Hooks And Fallbacks (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/precommit-hooks-and-fallbacks.md`.

## Last-Resort Hook Behavior

Keep local hook wrappers as last-resort gates while preserving deterministic fallback behavior.

During agentic work, run targeted validators and safe fixers before invoking hooks. When hook wrappers do run, use pre-commit as the default execution path for pre-commit and pre-push stages.
When `pwsh` is available, the pre-commit wrapper should run `Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1` first so staged Windows-language drift can be repaired with `-Fix -StaticOnly` and restaged before last-resort gate execution.

Shell formatter/linter hooks must stay repo-managed. Use local `shellcheck` and `shfmt` hook IDs that invoke `Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1`; do not use external Python-packaged shell hook repositories such as `pre-commit-shfmt` or `shellcheck-py`, and do not rely on PATH-only `shfmt`/`shellcheck` entries.

Compiled native hooks that publish release assets must also stay repo-managed. Use local `stylua` and `actionlint` hook IDs that invoke `Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1`; do not use remote pre-commit Rust/Go hook repositories for these tools because they compile during hook execution and can fail on host linker/toolchain drift.

Hook wrappers must capture `git rev-parse --show-toplevel` stdout separately from stderr under `set +e` before `cd`, then emit stage-specific stable diagnostics such as `E_PRECOMMIT_REPO_ROOT_UNAVAILABLE` or `E_PREPUSH_REPO_ROOT_UNAVAILABLE` with `exitCode`, `workingDirectory`, `gitCommand`, and Git output before exiting with the Git status.

## Fast Local Hook Contract

Local hooks optimize for changed-file feedback. They must not run full validation, Pester, or all-files pre-commit flows by default.

`.githooks/pre-push` must parse Git pre-push stdin, resolve changed files from pushed refs, write the resolved list to a temp file owned by the parent hook process, and pass that file through `Invoke-PreCommitWithRecovery.ps1 -HookStage pre-push -FileListPath ...`. Existing remote refs use `remote_oid..local_oid`; new refs choose a baseline from upstream, then `origin/HEAD`, then the pushed commit parent, and fall back to tracked files only when no baseline exists. The temp file path must be visible to the parent `EXIT` trap so recovery and fallback paths clean it up.

The pre-push local hook entry in `.pre-commit-config.yaml` must route through `Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation.ps1` with `pass_filenames: true`. That wrapper captures all pre-commit filenames as remaining positional arguments and then splats them into `Run-PreCommitValidation.ps1 -TargetFiles` as one array; do not append `-TargetFiles` directly in the pre-commit entry because `pwsh -File` misbinds the second filename to later positional parameters.

`Run-PreCommitValidation.ps1` non-`-All` mode is the fast local mode. It may use staged files or explicit target files, but it must avoid Pester, full-repo scans, cross-version compatibility scans, and duplicate shell/native checks already owned by dedicated pre-commit hooks. `-All` remains the deep mode for full validation and CI parity.

Full Pester/full validation belongs to CI and explicit session-close validation via `Scripts/Utils/Quality/Invoke-FullValidation.ps1`.

## Deterministic Fallback Path

Keep a fallback PowerShell validation path for environments where pre-commit is unavailable.

Always propagate fallback exit status so failures cannot be hidden.

Fallback validation must preserve the same scope contract as the local hook that selected it. Non-`-All` fallback must consume staged or explicit target files without widening to full-repo scans.

In fast local mode, keep ScriptAnalyzer scope target-file based for `Scripts/Utils/*.ps1`; reserve full-repo analyzer scans for explicit `-All` flows.

Hook-side validation must not hide stale staged content by mutating only the working tree. If a staged target has unstaged repair drift, fail with an explicit restage-required diagnostic instead of passing.

## Backup/Update Formatter Boundary

Do not run `Scripts/Utils/FormatPowershellScripts.ps1` inside `Scripts/Backup.ps1` or `Scripts/Update.ps1`.

Formatting ownership belongs to pre-commit hooks and explicit quality commands, not backup/update orchestration.

When commit hooks autofix files (`files were modified by this hook`), backup orchestration may restage managed backup paths and retry commit in a bounded loop.

## Timeout-Guarded Hook Execution

Keep hook wrappers bounded so stalled commands cannot lock editor-hosted workflows.

- `.githooks/pre-commit` must run primary/fallback commands through timeout guards and emit stable timeout diagnostics.
- `.githooks/pre-commit` must run safe Windows-language auto-repair before pre-commit execution, and skip files with unstaged drift (`W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SKIPPED_UNSTAGED`) instead of staging extra content.
- `.githooks/pre-push` must run changed-file pre-push validation through timeout guards; do not route local pre-push through `Invoke-FullValidation.ps1`, `-All`, or `--all-files`.
- `.devcontainer/post-create.sh` preflight and pre-commit environment prewarm should stay non-blocking and timeout-bounded.
- Shell timeout behavior must use `Scripts/Utils/Common/HookTimeout.sh`; `timeout`/`gtimeout` paths should use kill-after cleanup (`-k`) and avoid `--foreground`, while shell watchdog fallbacks must launch commands in an isolated process group/session when possible and clean up lingering descendants after the wrapper returns; never signal only the direct child.
- `WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS` and `WALLSTOP_PREPUSH_TIMEOUT_SECONDS` must be at least 60 seconds because recovery-backed hook paths reserve 30s for `Invoke-PreCommitWithRecovery.ps1` plus a 15s shutdown buffer plus 15s setup slack.
- Allow controlled overrides via environment variables when intentionally running slower sessions:
  - `WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS`
  - `WALLSTOP_PREPUSH_TIMEOUT_SECONDS`
  - `WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS`
  - `WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS`
- For Copilot/agent ad-hoc tests, do not run direct `Invoke-Pester` terminal commands. Use timeout-bounded `Invoke-PesterQualityGate.ps1` with `-OutputVerbosity None` and a narrow `-TestPath` scope.

## Pinned Native Hook Tools

Native tool wrappers must download only manifest-pinned upstream release assets into ignored `.tools/native-quality`, verify SHA256 before extraction or execution, reject unsafe archive entries, probe the expected version, and use explicit platform keys. Windows ARM64 may fall back to Windows x64 only when upstream lacks an ARM64 asset and the fallback is encoded in resolver diagnostics.

Run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1 -Tool All -EnsureOnly` to pre-warm StyLua/actionlint without running checks. `Invoke-FullValidation.ps1 -PreflightOnly` must call this automatically before hooks.

When pre-commit itself reports cache/environment installation failures, route through `Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1`; it cleans hook environments, runs `pre-commit install-hooks`, and retries once before failing with stable `E_PRECOMMIT_*` diagnostics.

`Invoke-FullValidation.ps1 -PreflightOnly` must also verify local `.githooks` registration and the pinned pre-commit CLI from `requirements.txt`. Agents should publish branches through `Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1` instead of bare `git push`; the helper runs hook registration preflight first and safely applies `push -u origin HEAD` only when the remote branch is absent or an ancestor of `HEAD`.

## Failure Artifact Diagnostics

When isolated Pester runs fail in `Run-PreCommitValidation.ps1`, keep throw messages compact and triage through warnings:

- `W_TEST_FAILURE_OUTPUT_PREVIEW` provides bounded head+tail context.
- `W_TEST_FAILURE_ARTIFACT` provides a temp-root `logPath` (`wallstop-precommit-validation`) with bounded, redacted stdout/stderr and metadata (`suite`, `exitCode`, `rootCode`).

## Executable Mode And Hook Hygiene

Track executable bit changes for hook wrapper scripts and keep trailing newline formatting stable.

## Workflow

1. Agentic early parity command: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly`.
2. Confirm shell/native tools are ready via preflight, or directly with `Invoke-ShellQualityChecks.ps1 -Tool All -EnsureOnly` and `Invoke-NativeQualityChecks.ps1 -Tool All -EnsureOnly`.
3. Run targeted validators/safe fixers for edited domains before hooks.
4. Use pre-commit if available for pre-commit and changed-file pre-push stages.
5. Keep fallback PowerShell validation path available.
6. Ensure fallback path propagates exit status.
7. Use `Invoke-GitPushWithUpstream.ps1` for branch pushes.
8. Use the full-validation wrapper for major session-close checks.

## References

- `.githooks/pre-commit`
- `.githooks/pre-push`
- `.pre-commit-config.yaml`
- `Scripts/Utils/Run-PreCommitValidation.ps1`
