# Session 015: production PowerShell analyzer lane

## Scope

Advance issue #43 by covering every tracked production PowerShell script under
`Scripts/` with the existing PSScriptAnalyzer warnings-as-errors lane. Test
fixtures remain outside this production lane because their current baseline
contains intentional/generated mock data that requires a separate remediation
scope.

## Changes

- Changed full validation from `Scripts/Utils` to the complete `Scripts`
  production tree.
- Changed staged analyzer targeting from only `Scripts/Utils` and
  `Scripts/Komorebi` to all existing `Scripts/**/*.ps1` paths.
- Expanded the pre-commit validation trigger to cover all `Scripts/**/*.ps1`
  files while retaining staged-file fast-path behavior.
- Updated structural policy coverage and `PLAN.md`.

## Verification

- PSScriptAnalyzer 1.21.0 over 58 tracked production scripts: 0 findings.
- Compatibility gate over the changed validator and policy test: pass, 0
  findings.
- ScriptSafetyConventions Pester gate completed successfully.

## Remaining issue #43 scope

PowerShell test fixtures, encrypted/configuration snapshots, and platform
languages still need inventory or separately justified lanes. They are not
silently folded into this production-script gate.
