# Session 004: analyzer baseline for issue #43

## Inventory

Captured 2026-08-09 from the tracked repository scope used by pre-commit/full validation:

| Lane | Managed tool/version | Enforced scope | Baseline result | Intentional exclusions |
| --- | --- | ---: | --- | --- |
| PowerShell lint | PSScriptAnalyzer 1.21.0; `.psscriptanalyzer.psd1` | 77 `.ps1` targets under `Scripts/Utils`, `Scripts/Komorebi`, `Tests/Utils`, `Tests/GitHub`, and `Config/Powershell` | 0 findings | `PSUseShouldProcessForStateChangingFunctions` is excluded by the settings file |
| Shell format/lint | shfmt 3.13.0; ShellCheck 0.11.0 | 17 `.sh`/hook targets | both managed checks passed | no global ShellCheck disable; repository `.shellcheckrc` remains authoritative |
| Lua format | StyLua 2.5.2 | 1 `Config/Wezterm/wezterm.lua` target | managed check passed | no additional target exclusions |
| GitHub Actions lint | actionlint 1.7.12 | 4 workflow files | managed check passed | actionlint remains PR-targeted; deep lane is opt-in |

## Selection

PowerShell is the first warnings-as-errors lane because its current scope, settings, and zero-finding result are already deterministic and independently testable. A policy regression test now requires both `Error` and `Warning` severities and requires the validation path to fail on any ScriptAnalyzer finding.

## Commands and evidence

- `Invoke-ScriptAnalyzer -Path Scripts/Utils -Settings .psscriptanalyzer.psd1 -Recurse`: module `1.21.0`, `0` findings.
- `Invoke-ShellQualityChecks.ps1 -Tool All` over the 17 tracked shell targets: passed.
- `Invoke-NativeQualityChecks.ps1 -Tool All` over the Lua/workflow targets: passed.
- PR #50 Script Quality run #351: all required jobs and validation summary passed.
