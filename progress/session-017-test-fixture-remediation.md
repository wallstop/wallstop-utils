# Session 017: Test-fixture analyzer remediation

Date: 2026-08-10

## Scope

Resolve the dynamic-scope PowerShell analyzer findings identified in issue #59 without excluding tests or weakening the production `Scripts/` warnings-as-errors lane.

## Changes

- Refactored `Invoke-Main` in `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1` to accept its runtime inputs explicitly; the script entrypoint forwards the original bound parameter set.
- Added an explicit test invocation helper and passed configured values from all `Invoke-Main` scenarios instead of relying on dynamic scope.
- Removed a small set of genuine test-only unused locals and made the symbolic-link-cycle test assign its result outside a scriptblock so the analyzer can verify the use.

## Verification

- PSScriptAnalyzer 1.21.0 with `.psscriptanalyzer.psd1`: `Tests/` = 0 findings; production `Scripts/` = 0 findings.
- `Get-UnresolvedPRComments.Tests.ps1` quality-gate suite passed.
- `Tests/Utils` quality-gate suite passed.
- Compatibility checks for the changed GitHub production/test scripts passed with zero findings.
- Full validation preflight and `git diff --check` remain required before PR publication.

## References

- Issue [#43](https://github.com/wallstop/wallstop-utils/issues/43)
- Follow-up issue [#59](https://github.com/wallstop/wallstop-utils/issues/59)
