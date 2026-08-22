# Plan

## Current milestone: green quality PR

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

## Current milestone: restore green main + issue #68 hardening

- [x] RCA and fix `pre-commit full repo (Linux)`: backup secret redaction corrupted `Config/Komorebi/profiles/spicy/applications.json`; anchor the key match, exclude structural characters, repair the file, add data-driven regression tests.
- [x] RCA and fix `PowerShell tests (PowerShell 7+)`: commit `06a1a3a` reverted `Config/.config/window-control.ahk` to AHK v1; commit the v2 restoration.
- [x] Harden hook tests against stderr-noisy git hosts (blob-SHA extraction by shape) and PTY tests against stripped-python hosts (capability probe with explicit skip).
- [x] Complete the devcontainer carry-forward: OpenCode bootstrap, post-start cache-ownership self-heal, node feature pinning, and lock-file validation in workflow plus tests.
- [x] Incorporate Dependabot pre-commit 4.6.1 → 4.6.2 (closes PR #67).
- [x] Issue #68: deploy Mozilla update-blocking policies on Scoop restore, back up Thunderbird `profiles.ini`, publish the scoop host audit recovery runbook.
- [ ] Open the PR aggregating this session and drive reviewer feedback/checks to green.
- [ ] Follow-up (needs GitHub auth or operator action): file remaining issue #68 item — `Scripts/Scoop/Invoke-ScoopHealthCheck.ps1` health-check script; redeploy v2 `window-control.ahk` on the primary host so backups stop re-committing the v1 regression.

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
