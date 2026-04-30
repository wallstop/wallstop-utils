<!-- trigger: pre-commit, git hooks, fallback, pre-push | Maintain pre-commit-first hooks with legacy fallback | Quality | skill-details/precommit-hooks-and-fallbacks.md -->

# Pre-Commit Hooks And Fallbacks

Lightweight skill card for hook wrapper flow and fallback behavior.

- Expanded guide: [Pre-Commit Hooks And Fallbacks (Expanded)](../skill-details/precommit-hooks-and-fallbacks.md)

## Core concepts

- [Pre-commit-first wrapper behavior](../skill-details/precommit-hooks-and-fallbacks.md#pre-commit-first-wrapper-behavior)
- [Deterministic fallback path](../skill-details/precommit-hooks-and-fallbacks.md#deterministic-fallback-path)
- [Timeout-guarded hook execution](../skill-details/precommit-hooks-and-fallbacks.md#timeout-guarded-hook-execution)
- [Failure artifact diagnostics](../skill-details/precommit-hooks-and-fallbacks.md#failure-artifact-diagnostics)
- [Executable mode and hook hygiene](../skill-details/precommit-hooks-and-fallbacks.md#executable-mode-and-hook-hygiene)
- Agentic early parity command: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly`
- Keep pre-commit ScriptAnalyzer staged-file scoped; reserve full-repo analyzer scans for `-All` paths.
