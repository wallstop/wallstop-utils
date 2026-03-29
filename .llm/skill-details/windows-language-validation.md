# Windows Language Validation (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/windows-language-validation.md`.

## Fast-Lane Scope And Runtime Budget

Preserve Windows CI lane contracts for targeted PR checks and deep nightly coverage.

1. PR lane remains changed-file scoped for AutoHotkey and batch targets.
2. PR lane enforces the 180-second runtime budget.

## AutoHotkey Runtime Probing And Output Capture

Keep runtime probing order deterministic and preserve explicit stdout/stderr capture for reliable headless execution diagnostics.

## Nightly Deep-Lane Coverage

Retain full-repository Windows validation in nightly/manual deep lanes.

## Required Invariants

1. Nightly lane retains full-repository validation.
2. AutoHotkey command execution uses deterministic stdout/stderr capture.
3. Non-Windows command capture keeps stdout/stderr draining asynchronous with bounded timeouts to avoid pipe-buffer deadlocks.
4. Timeout and stream-capture failures emit distinct `E_AHK_*` diagnostics so CI logs stay actionable.

## Notes

- Keep runtime cache in runner temporary paths.
- Avoid heavyweight package-manager installation in fast lanes.
- Keep fallback behavior when git baseline cannot be determined.

## References

- `.github/workflows/script-quality.yml`
- `Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1`
- `Tests/Utils/Invoke-WindowsLanguageChecks.Tests.ps1`
