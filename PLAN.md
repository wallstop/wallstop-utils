# Plan

## Completed milestone: issue #81 cleanup, carry-forward, and CI RCA (session-027)

- [x] Delete stray root `image.png` (issue #81); forward delete, file unreferenced.
- [x] Land the carried-forward `sst-dev.opencode` devcontainer extension addition.
- [x] RCA the 2026-09-02 nightly `Script Quality` failure: GitHub-hosted runner lost
  communication (check-run annotation); same commit passed on push and the full local suite
  passed (1515 tests, 0 failures). No code change; no auto-retry scaffolding for a
  non-recurring infra blip.
- [x] Correct stale `features` doc drift: README + `.llm/context.md` said `node:1` while the
  devcontainer and its policy tests pin `ghcr.io/devcontainers/features/node:2`.

Evidence: [PR #82](https://github.com/wallstop/wallstop-utils/pull/82) — all checks green (including Cursor Bugbot), zero review findings; issue #68 verified complete and closed.

## Completed milestone: agent notification integration (PR #79)

- [x] Add a secrets-safe, local-first `agent-notify` toolkit with adapters for Claude, Codex, Copilot, OpenCode, and Nanocoder; keep offline tests hermetic and notification hooks best-effort.
- [x] Add idempotent machine bootstrap/audit tooling and repository documentation without committing ntfy topics or tokens.
- [x] Address all four Cursor review findings with regression coverage: make the Pester gate discoverable from the actual repository root, preserve Nanocoder's original desktop-notification arguments, stream leading-`@` bodies to curl literally through stdin, and make the installed Nanocoder shim prefer only its managed sibling instead of an unrelated parent-derived core.
- [x] Run the full repository validation loop after incorporating current `main`.
- [x] Complete the three-round adversarial/self-improvement protocol and resolve every reported finding with regression coverage; the final independent pass found eight additional issues that were fixed after the protocol cap.
- [x] Push the updated branch and drive PR #79 required checks to green; Cursor completed neutral with no new findings, while Copilot's non-code review check remains externally quota-failed.

Evidence: [PR #79](https://github.com/wallstop/wallstop-utils/pull/79)

## Completed milestone: backup upload diagnostics (issue #46)

- [x] RCA the recurring `backup steps failed: 2` auto-backup commits from repository evidence: failing step names were console-only, so ten days of partial-failure uploads (2026-08-12..2026-08-22) were undiagnosable from git history.
- [x] Name failing steps in the backup commit message (`(backup steps failed: N [StepA, StepB]; X/Y succeeded)`), policy-pinned in the conventions suite.
- [x] Eliminate the daily whole-file `Config/scoopfile.json` churn caused by `scoop export`'s non-deterministic app-member ordering: opt-in `-SortObjectKeys` canonicalization (Ordinal member sort, arrays untouched, fail-closed duplicate handling), ScoopBackup opts in, committed artifact regenerated as a fixed point of both modes.
- [x] Read named failing steps from the 2026-08-23 backup commit: `PowershellBackup`, `WinGetUpdate` (`ScoopUpdate` now passes; issue #68 host fixes confirmed via scoopfile data: innounp 2.71.0, megatools installed, thunderbird migrated).
- [x] RCA why uploads stayed partial: the same commit added `Config/.config/vllm/nccl/cu12/libnccl.so.2.18.1` (~278MB > GitHub's 100MiB blob limit), so every push since 2026-08-23 failed while later backups stacked on the unpushable commit. Repair: dropped the blob from the unpushed commit, restored the v2 AHK mirror it had regressed, pushed repaired main.
- [x] Prevent recurrence repo-side: fail-closed oversize guard (`E_BACKUP_MANAGED_FILE_OVERSIZE` at 95MB, warn at 10MB) before staging; `Config/.config/vllm/` ignored as machine-generated cache; unattended path now self-heals `Config/.config/*.ahk` snapshot drift from v2 sources (same repair the attended pre-commit hook applies); persistent `Config/backup-step-failures.json` artifact records failed-step errors plus bounded output previews so future failures are diagnosable from git alone, passes secret hygiene, and is committed+pushed by itself when git-phase guards fail closed.
- [x] Read failure reasons from the 2026-08-25 backup commit's artifact and fix both failing steps by design (session 024 / PR #76): `WinGetUpdate` now classifies `UPDATE_ALL_HAS_FAILURE` aggregates — consent/elevation-blocked installers (1602/1223/0x80073d28 observed) defer with `W_WINGET_UPGRADE_DEFERRED_INTERACTIVE` while genuine/unattributable failures stay fail-closed; `PowershellBackup` self-heals drifted host profiles from the validated repository profile via the single-sourced `Restore-PowerShellProfileFromValidatedSource` helper (timestamped backup preserved; manual repair tool consumes the same semantic).
- [x] Fix the classifier misattribution proven by the 2026-08-26 artifact (session 025 / PR #78): winget dependency-resolution reprints of an open `(N/M) Found <id>` block no longer enqueue a phantom duplicate that shifted every later terminal onto the wrong package (WSL's 0x80073d28 had been attributed to Plex); regression tests pin per-package attribution over the verbatim production shape.
- [x] Read the next two host runs: 2026-08-27 improved to `10/12` (temporary `ScoopUpdate` plus `WinGetUpdate`), and 2026-08-28 improved to `11/12` with only `WinGetUpdate`; Scoop and PowerShell profile recovery are now confirmed green.
- [x] Fix the 2026-08-28 WinGet attribution failure: Windows PowerShell flattened redirected progress markers into one space-joined physical line, so line-anchored parsing found zero outcomes. Enumerate ordered markers within each physical line; the persisted production artifact now resolves Plex as upgraded and WSL's `0x80073d28` as deferred interactive.
- [x] Confirm clean end-to-end state: five consecutive host backup runs committed and pushed with `12/12 succeeded` (2026-08-28 through 2026-09-01); `Config/backup-step-failures.json` no longer records failures. Issue #46's repo-side work is complete; only optional host-side hygiene remains tracked in issue #70.

Evidence: [session-022](./progress/session-022-backup-upload-diagnostics.md), [session-023](./progress/session-023-backup-upload-rca.md), [PR #76](https://github.com/wallstop/wallstop-utils/pull/76), [PR #78](https://github.com/wallstop/wallstop-utils/pull/78)

## Completed milestone: headless Update with elevation opt-in (issue #77)

- [x] Keep default `Update.ps1` runs fully headless/no-prompt and fix their latent POSIX crash: zero applicable steps after platform-skipping all Windows-only steps no longer trips mandatory-param binding on empty arrays.
- [x] Add `-WithAdmin`: single UAC relaunch through ProcessStartInfo + Set-PortableProcessArguments (decline fails closed via pure `Resolve-UpdateElevationStartFailure` seam separating `E_UPDATE_ELEVATION_DECLINED` from `E_UPDATE_ELEVATION_START_FAILED`); non-Windows warns `W_UPDATE_ELEVATION_UNSUPPORTED_PLATFORM` and continues headless; dot-source run guard emits `W_UPDATE_DOT_SOURCE_NO_OP`.
- [x] Sandbox behavioral suite (`Tests/Update/Update.Tests.ps1`) executes the real orchestrator against stub step scripts with zero host mutation on every CI platform.

## Completed milestone: scoop host-health tooling (issue #70)

- [x] Implement `Scripts/Scoop/Invoke-ScoopHealthCheck.ps1` covering every audited failure mode: `scoop status` anomalies (Install failed / Manifest removed / missing versions), installed-vs-bucket version inversion (the `2025 > 2.71.0` deadlock), junction integrity (`current` reparse-point checks), Mozilla channel drift against real `compatibility.ini` `LastVersion=<version>_<buildId>/<prev>` shapes, and orphaned Mozilla helper processes.
- [x] Honor `$env:SCOOP_GLOBAL` (admin/global installs) in both the health check and ScoopRestore's Mozilla policy deployment, single-sourced through `Scripts/Utils/Common/ScoopInstallRootHelpers.ps1` (closes the gap noted during PR #69 review).
- [x] Wire `ScoopHealthCheck` into the `Backup.ps1` step list as a Windows-only best-effort step so audit-class drift surfaces in daily backup summaries instead of tribal memory.
- [x] Data-driven Pester coverage: pure classifiers plus child-process behavioral tests using PATH-shim fake scoop commands; adversarial review loop applied (real-world LastVersion format fix, Thunderbird-only pairing, 5.1 strict-mode crash path, per-app junction resilience).
- [ ] Operator action on the primary Windows host (tracked in issue #70): redeploy v2 `window-control.ahk` over `%USERPROFILE%\.config\window-control.ahk` and confirm the next backup shows no diff.

Evidence: [session-021](./progress/session-021-scoop-host-health-check.md)

## Completed milestone: green quality PR

- [x] Triage the repository's open pull requests and current CI failures.
- [x] Carry the in-progress DxMessaging backup reliability work with focused tests.
- [x] Make action-version policy tests compatible with exact semver Dependabot pins.
- [x] Run local targeted validation and extension tests; record the local Pester-major limitation from the full-suite audit.
- [x] Run the full repository suite under the CI-supported Pester 5 environment.
- [x] Publish one branch/PR containing this session's coherent changes.
- [x] Recheck PR CI and address reviewer or check failures.
- [x] Migrate repository skills to standard Agent Skills `SKILL.md` entrypoints with a 250-line hard limit (issue #45).
- [x] Remove duplicate Scoop update execution and make Update.ps1 continue through all steps before reporting partial failure (issues #47/#48).
- [x] Make Backup.ps1 distinguish managed snapshot drift from out-of-scope worktree changes and preserve managed drift through pull (issue #53 follow-up).
- [x] Refresh and publish a verified-current Scoop and PowerToys host-state snapshot for issue #53.

## Completed milestone: restore green main + issue #68 hardening

- [x] RCA and fix `pre-commit full repo (Linux)`: backup secret redaction corrupted `Config/Komorebi/profiles/spicy/applications.json`; anchor the key match, exclude structural characters, repair the file, add data-driven regression tests.
- [x] RCA and fix `PowerShell tests (PowerShell 7+)`: commit `06a1a3a` reverted `Config/.config/window-control.ahk` to AHK v1; commit the v2 restoration.
- [x] Harden hook tests against stderr-noisy git hosts (blob-SHA extraction by shape) and PTY tests against stripped-python hosts (capability probe with explicit skip).
- [x] Complete the devcontainer carry-forward: OpenCode bootstrap, post-start cache-ownership self-heal, node feature pinning, and lock-file validation in workflow plus tests.
- [x] Incorporate Dependabot pre-commit 4.6.1 → 4.6.2 (closes PR #67).
- [x] Issue #68: deploy Mozilla update-blocking policies on Scoop restore, back up Thunderbird `profiles.ini`, publish the scoop host audit recovery runbook.
- [x] Open the PR aggregating this session and drive reviewer feedback/checks to green (PR #69: all lanes green, Bugbot finding fixed, mergeable state clean).
- [x] Issue #70 repo-side follow-up delivered in session-021 (`Invoke-ScoopHealthCheck.ps1` + SCOOP_GLOBAL-aware policy deployment); the remaining host-side `window-control.ahk` redeploy stays open in issue #70 and the current milestone above.

Evidence: [session-020](./progress/session-020-green-ci-and-issue-68.md)

## Completed milestone: analyzer baseline for #43

- [x] Capture the current analyzer inventory, versions, scopes, warning counts, and intentional suppressions in a reviewable artifact.
- [x] Select the first lane for warnings-as-errors using the smallest independently verifiable scope.
- [x] Add a failing baseline test for newly introduced warnings while remediation proceeds separately.
- [x] Expand warnings-as-errors to the managed ShellCheck lane, preserving its style-level blocking policy and wrapper failure diagnostic.
- [x] Expand warnings-as-errors to the managed native analyzer lane with fail-closed StyLua/actionlint regression coverage.
- [x] Expand warnings-as-errors to the TypeScript extension compiler with unused-local and unused-parameter checks.
- [x] Expand PowerShell warnings-as-errors to all tracked production scripts under `Scripts/` with staged-file targeting preserved for fast hooks.
- [x] Characterize and safely govern the dynamic Pester-fixture analyzer surface tracked in issue #59 without weakening the production `Scripts/` lane.
- [x] Evaluate the remaining JavaScript utility and AppleScript analyzer surface tracked in issue #62, adding only bounded enforcement that preserves extension CI timing.

Issue #43 (warnings-as-errors) is complete for the repository's supported managed quality surface; issue #62 is complete with dependency-free gates for the small-language surface.

Evidence: [session-004 analyzer baseline](./progress/session-004-analyzer-baseline.md), [session-005 dependency and shell lane](./progress/session-005-dependency-and-shell-lane.md), [session-007 native analyzer lane](./progress/session-007-native-analyzer-lane.md), [session-013 TypeScript analyzer lane](./progress/session-013-typescript-analyzer-lane.md), [session-015 production PowerShell lane](./progress/session-015-production-powershell-lane.md), [session-016 test-fixture inventory](./progress/session-016-test-fixture-inventory.md), [session-017 test-fixture remediation](./progress/session-017-test-fixture-remediation.md), and [session-019 small-language analyzer evaluation](./progress/session-019-small-language-analyzer-evaluation.md). The production and test PowerShell ScriptAnalyzer, managed ShellCheck, StyLua, actionlint, TypeScript compiler, JavaScript syntax, and AppleScript validation lanes now have explicit coverage; native checks remain separately gated to preserve CI timing.

Evidence for the host-state snapshot: [session-008 config snapshot](./progress/session-008-config-snapshot.md), [session-010 backup host-state audit](./progress/session-010-backup-host-state-audit.md), [session-011 backup host-state runbook](./progress/session-011-backup-host-state-runbook.md), and [session-012 verified snapshot](./progress/session-012-verified-host-state-snapshot.md).
