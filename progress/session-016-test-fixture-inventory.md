# Session 016: Test-fixture analyzer inventory

Date: 2026-08-10

## Scope

After PR #58 expanded the strict PowerShell analyzer lane to all tracked production scripts under `Scripts/`, quantify the remaining PowerShell test surface for issue #43.

## Findings

- `Tests/**/*.ps1`: 38 files.
- Repository PSScriptAnalyzer settings: 318 findings.
- Every finding is `PSUseDeclaredVarsMoreThanAssignments`.
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1` accounts for 313 findings.
- The dominant pattern is test-local setup consumed by dynamically scoped `Invoke-Main` calls and Pester mocks; static analysis does not reliably resolve those uses.

## Decision

Do not weaken the production `Scripts/` warnings-as-errors lane or add a blanket suppression based on this inventory. Open issue #59 to characterize each finding and select the narrowest safe treatment: refactor genuine unused locals, use narrowly justified suppressions where dynamic scope is intentional, or define a separately governed fixture profile.

## Verification

The inventory used `Invoke-ScriptAnalyzer -Path Tests -Settings .psscriptanalyzer.psd1 -Recurse` with PSScriptAnalyzer 1.21.0. The production lane remains independently verified at zero findings in PR #58.

## References

- Issue [#43](https://github.com/wallstop/wallstop-utils/issues/43)
- Follow-up issue [#59](https://github.com/wallstop/wallstop-utils/issues/59)
- Production lane PR [#58](https://github.com/wallstop/wallstop-utils/pull/58)
