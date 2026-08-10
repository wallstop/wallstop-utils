# Session 018: Analyzer surface inventory

Date: 2026-08-10

## Scope

Audit issue #43 after the test-fixture remediation and identify any remaining language surfaces that need a separate analyzer decision.

## Verified managed coverage

- 101 tracked PowerShell files: PSScriptAnalyzer 1.21.0 with `.psscriptanalyzer.psd1`, `Scripts/` and `Tests/` each at zero findings; changed files also pass the cross-version compatibility gate.
- Managed shell targets: pinned ShellCheck/shfmt enforcement through the shared quality wrappers.
- Lua: pinned StyLua enforcement for `Config/Wezterm/wezterm.lua`.
- GitHub Actions: pinned actionlint enforcement for tracked workflow files.
- TypeScript: extension `tsc` lane with `noUnusedLocals` and `noUnusedParameters` enabled and regression-tested.
- AutoHotkey/batch: dedicated Windows-language static/runtime validation with v2 directive policy checks.
- AppleScript: dedicated macOS migration-safe compile/decompile validation.

## Remaining decision surface

The repository has three tracked JavaScript utility scripts and four AppleScript files. JavaScript utilities are covered by the extension/package test workflow but do not have a dedicated ESLint lane; AppleScript has platform validation but no separate third-party linter. Follow-up issue [#62](https://github.com/wallstop/wallstop-utils/issues/62) captures the bounded evaluation without weakening fast-lane timing.

## Decision

Close the staged warnings-as-errors milestone for the managed surface in issue #43. Keep the small-language analyzer evaluation separate and explicit in #62.

## Evidence

- [PR #57](https://github.com/wallstop/wallstop-utils/pull/57)
- [PR #58](https://github.com/wallstop/wallstop-utils/pull/58)
- [PR #61](https://github.com/wallstop/wallstop-utils/pull/61)
