<!-- trigger: github api, unresolved comments, cursor bugbot, bot markup, embedded locations, host allowlist, retries, auth recovery, public rest fallback, git credential, GH_TOKEN, GITHUB_TOKEN, clipboard fallback, output file, powershell completion | Preserve GitHub utility safety and UX contracts | GitHub | skill-details/github-pr-unresolved-comments.md -->

# GitHub PR Unresolved Comments

Lightweight skill card for GitHub API safety and retry behavior.

- Expanded guide: [GitHub PR Unresolved Comments (Expanded)](../skill-details/github-pr-unresolved-comments.md)

## Core concepts

- [Host allowlist and input validation](../skill-details/github-pr-unresolved-comments.md#host-allowlist-and-input-validation)
- [Retry-safe GitHub request flow](../skill-details/github-pr-unresolved-comments.md#retry-safe-github-request-flow)
- [Actionable diagnostics and resilience tests](../skill-details/github-pr-unresolved-comments.md#actionable-diagnostics-and-resilience-tests)
- [Review thread range rendering](../skill-details/github-pr-unresolved-comments.md#review-thread-range-rendering)
- [Bot comment cleanup](../skill-details/github-pr-unresolved-comments.md#bot-comment-cleanup)
- [Clipboard fallback and strict mode](../skill-details/github-pr-unresolved-comments.md#clipboard-fallback-and-strict-mode)
- [Output file contract](../skill-details/github-pr-unresolved-comments.md#output-file-contract)
- [PowerShell completion contract](../skill-details/github-pr-unresolved-comments.md#powershell-completion-contract)
- Auth recovery invariant: resolve `GH_TOKEN` before `GITHUB_TOKEN`; stored `gh` lookup clears env tokens; Git credential probing is non-interactive; prompted fallback bypasses env tokens and excludes rejected values; direct mode never prompts but may use public REST fallback unless explicit `-Token` failed.
- Quick checks after script edits: targeted `Run-PreCommitValidation.ps1 -TargetFiles Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`, `Invoke-PesterQualityGate.ps1 -TestPath Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 -OutputVerbosity None`, and `Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None`.
