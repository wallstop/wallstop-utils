<!-- trigger: pre-commit, git hooks, fallback, pre-push | Maintain last-resort hooks with deterministic fallback | Quality | skill-details/precommit-hooks-and-fallbacks.md -->

# Pre-Commit Hooks And Fallbacks

Lightweight skill card for hook wrapper flow and fallback behavior.

- Expanded guide: [Pre-Commit Hooks And Fallbacks (Expanded)](../skill-details/precommit-hooks-and-fallbacks.md)

## Core concepts

- [Last-resort hook behavior](../skill-details/precommit-hooks-and-fallbacks.md#last-resort-hook-behavior)
- [Deterministic fallback path](../skill-details/precommit-hooks-and-fallbacks.md#deterministic-fallback-path)
- [Timeout-guarded hook execution](../skill-details/precommit-hooks-and-fallbacks.md#timeout-guarded-hook-execution)
- [Failure artifact diagnostics](../skill-details/precommit-hooks-and-fallbacks.md#failure-artifact-diagnostics)
- [Executable mode and hook hygiene](../skill-details/precommit-hooks-and-fallbacks.md#executable-mode-and-hook-hygiene)
- Agentic early parity command: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly`
- Run targeted validators and safe fixers during agent work before invoking hooks.
- Keep pre-commit ScriptAnalyzer staged-file scoped; reserve full-repo analyzer scans for `-All` paths.
