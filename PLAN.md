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

## Follow-up

- Issue #46 (partial git uploads) now has explicit post-push remote-head verification and commit wording that distinguishes failed backup steps from Git publication. A live backup run remains required to close the operational investigation safely.
- Issue #43 (warnings-as-errors and static-analyzer research) is complete for the repository's supported managed quality surface: tracked production and test PowerShell, ShellCheck/shfmt, StyLua, actionlint, and TypeScript compiler lanes now have deterministic enforcement documented in sessions 004–007, 013, 015, and 017. Intentional PowerShell profile files under `Config/Powershell/` remain outside the managed script lane.
- Issue #62 (JavaScript and macOS static analyzer coverage) is complete: the three JavaScript utility scripts have a dependency-free `node --check` gate in the extension workflow, while the existing macOS `osacompile`/`osadecompile` migration-safe validator remains the appropriate AppleScript check. No heavyweight third-party analyzer was added for this small utility surface.

## Next milestone: analyzer baseline for #43

- [x] Capture the current analyzer inventory, versions, scopes, warning counts, and intentional suppressions in a reviewable artifact.
- [x] Select the first lane for warnings-as-errors using the smallest independently verifiable scope.
- [x] Add a failing baseline test for newly introduced warnings while remediation proceeds separately.
- [x] Expand warnings-as-errors to the managed ShellCheck lane, preserving its style-level blocking policy and wrapper failure diagnostic.
- [x] Expand warnings-as-errors to the managed native analyzer lane with fail-closed StyLua/actionlint regression coverage.
- [x] Expand warnings-as-errors to the TypeScript extension compiler with unused-local and unused-parameter checks.
- [x] Expand PowerShell warnings-as-errors to all tracked production scripts under `Scripts/` with staged-file targeting preserved for fast hooks.
- [x] Characterize and safely govern the dynamic Pester-fixture analyzer surface tracked in issue #59 without weakening the production `Scripts/` lane.
- [x] Evaluate the remaining JavaScript utility and AppleScript analyzer surface tracked in issue #62, adding only bounded enforcement that preserves extension CI timing.

Evidence: [session-004 analyzer baseline](./progress/session-004-analyzer-baseline.md), [session-005 dependency and shell lane](./progress/session-005-dependency-and-shell-lane.md), [session-007 native analyzer lane](./progress/session-007-native-analyzer-lane.md), [session-013 TypeScript analyzer lane](./progress/session-013-typescript-analyzer-lane.md), [session-015 production PowerShell lane](./progress/session-015-production-powershell-lane.md), [session-016 test-fixture inventory](./progress/session-016-test-fixture-inventory.md), [session-017 test-fixture remediation](./progress/session-017-test-fixture-remediation.md), and [session-019 small-language analyzer evaluation](./progress/session-019-small-language-analyzer-evaluation.md). The production and test PowerShell ScriptAnalyzer, managed ShellCheck, StyLua, actionlint, TypeScript compiler, JavaScript syntax, and AppleScript validation lanes now have explicit coverage; native checks remain separately gated to preserve CI timing.

Evidence for the host-state snapshot: [session-008 config snapshot](./progress/session-008-config-snapshot.md), [session-010 backup host-state audit](./progress/session-010-backup-host-state-audit.md), [session-011 backup host-state runbook](./progress/session-011-backup-host-state-runbook.md), and [session-012 verified snapshot](./progress/session-012-verified-host-state-snapshot.md).
