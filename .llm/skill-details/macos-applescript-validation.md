# macOS AppleScript Validation (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/macos-applescript-validation.md`.

## Source-First Validation With SCPT Fallback

Keep macOS AppleScript validation source-first while preserving migration-safe fallback behavior.

1. Validate text source files when present.
2. Use compiled `.scpt` fallback when source files are not yet present.

## Diagnostics And Strict Shell Behavior

Preserve explicit compile/decompile diagnostics and strict error handling in shell wrapper scripts.

Avoid shell feature drift that breaks CI runner portability.

## Workflow Parity With Policy Tests

Keep AppleScript validation behavior aligned with policy tests that enforce migration-safe rules.

## References

- `Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh`
- `.github/workflows/script-quality.yml`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
