# Windows Language Validation (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/windows-language-validation.md`.

## Fast-Lane Scope And Runtime Budget

Preserve Windows CI lane contracts for targeted PR checks and deep nightly coverage.

1. PR lane remains changed-file scoped for AutoHotkey and batch targets.
2. PR lane enforces the 180-second runtime budget.

## Static AutoHotkey v2 Gate And Safe Fixes

Run dependency-free AHK static validation before runtime probing on every host. This catches policy drift even when AutoHotkey is unavailable locally.

1. Every `.ahk` file under `Scripts/AutoHotKey/` and `Config/.config/` must declare `#Requires AutoHotkey v2` or `v2.x` as the first non-comment, non-blank line.
2. Static v1 syntax markers fail as `E_AHK_V1_SYNTAX_DETECTED` before runtime lookup.
3. Agent workflows that touch AHK files should run the targeted fixer immediately:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1 -TargetFiles <paths> -Fix
```

`-Fix` may insert a missing v2 directive only when no v1 markers are present. For managed config snapshots, it may refresh `Config/.config/<name>.ahk` from the same-named validated `Scripts/AutoHotKey/<name>.ahk` source. Arbitrary v1-to-v2 migration remains an explicit code change.

## AutoHotkey Runtime Probing And Output Capture

Keep runtime probing order deterministic and preserve explicit stdout/stderr capture for reliable headless execution diagnostics.

## Nightly Deep-Lane Coverage

Retain full-repository Windows validation in nightly/manual deep lanes.

## Required Invariants

1. Nightly lane retains full-repository validation.
2. Static AutoHotkey v2 directive and v1 syntax checks run before `Get-AutoHotkeyExecutablePath`.
3. AutoHotkey command execution uses deterministic stdout/stderr capture.
4. Non-Windows command capture keeps stdout/stderr draining asynchronous with bounded timeouts to avoid pipe-buffer deadlocks.
5. Timeout and stream-capture failures emit distinct `E_AHK_*` diagnostics so CI logs stay actionable.

## Notes

- Keep runtime cache in runner temporary paths.
- Avoid heavyweight package-manager installation in fast lanes.
- Keep fallback behavior when git baseline cannot be determined.

## References

- `.github/workflows/script-quality.yml`
- `Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1`
- `Tests/Utils/Invoke-WindowsLanguageChecks.Tests.ps1`
