# Pre-Commit Hooks And Fallbacks (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/precommit-hooks-and-fallbacks.md`.

## Pre-Commit-First Wrapper Behavior

Keep local hook wrappers pre-commit-first while preserving deterministic fallback behavior.

Use pre-commit as the default execution path for pre-commit and pre-push stages.

## Deterministic Fallback Path

Keep a fallback PowerShell validation path for environments where pre-commit is unavailable.

Always propagate fallback exit status so failures cannot be hidden.

## Executable Mode And Hook Hygiene

Track executable bit changes for hook wrapper scripts and keep trailing newline formatting stable.

## Workflow

1. Use pre-commit if available for pre-commit and pre-push stages.
2. Keep fallback PowerShell validation path available.
3. Ensure fallback path propagates exit status.
4. Use the full-validation wrapper for major session-close checks.

## References

- `.githooks/pre-commit`
- `.githooks/pre-push`
- `.pre-commit-config.yaml`
- `Scripts/Utils/Run-PreCommitValidation.ps1`
