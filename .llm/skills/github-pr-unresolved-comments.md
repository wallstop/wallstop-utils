<!-- trigger: github api, unresolved comments, github copilot, copilot reviewer, copilot-pull-request-reviewer, cursor bugbot, bot markup, prose-only bot comments, review diff hunk, diffHunk, suggested changeset, suggested diff unavailable, recommendation records, comment author metadata, embedded locations, host allowlist, retries, auth recovery, public rest fallback, git credential, GH_TOKEN, GITHUB_TOKEN, clipboard fallback, osc52, output encoding, utf-8 verbatim, suggested change, suggestion block, delimiter, surrogate pair, output file, powershell completion | Preserve GitHub utility safety and UX contracts | GitHub | skill-details/github-pr-unresolved-comments.md -->

# GitHub PR Unresolved Comments

Lightweight skill card for GitHub API safety and retry behavior.

- Expanded guide: [GitHub PR Unresolved Comments (Expanded)](../skill-details/github-pr-unresolved-comments.md)

## Core concepts

- [Host allowlist and input validation](../skill-details/github-pr-unresolved-comments.md#host-allowlist-and-input-validation)
- [Retry-safe GitHub request flow](../skill-details/github-pr-unresolved-comments.md#retry-safe-github-request-flow)
- [Actionable diagnostics and resilience tests](../skill-details/github-pr-unresolved-comments.md#actionable-diagnostics-and-resilience-tests)
- [Review thread range rendering](../skill-details/github-pr-unresolved-comments.md#review-thread-range-rendering)
- [Bot comment cleanup](../skill-details/github-pr-unresolved-comments.md#bot-comment-cleanup)
- [Verbatim output and suggested changes](../skill-details/github-pr-unresolved-comments.md#verbatim-output-and-suggested-changes)
- [Clipboard fallback and strict mode](../skill-details/github-pr-unresolved-comments.md#clipboard-fallback-and-strict-mode)
- [Output file contract](../skill-details/github-pr-unresolved-comments.md#output-file-contract)
- [PowerShell completion contract](../skill-details/github-pr-unresolved-comments.md#powershell-completion-contract)
- [VS Code extension companion contract](../skill-details/github-pr-unresolved-comments.md#vs-code-extension-companion-contract)
- Auth recovery invariant: resolve `GH_TOKEN` before `GITHUB_TOKEN`; stored `gh` lookup clears env tokens; Git credential probing is non-interactive; prompted fallback bypasses env tokens and excludes rejected values; direct mode never prompts but may use public REST fallback unless explicit `-Token` failed.
- Quick checks after script edits: targeted `Run-PreCommitValidation.ps1 -TargetFiles Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1`, `Invoke-PesterQualityGate.ps1 -TestPath Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 -OutputVerbosity None`, and `Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None`.
- Quick checks after VS Code extension edits: from `Extensions/WallstopPrComments`, run `npm ci` when `package.json` or the lockfile changed, then `npm test`; for installer/packager edits also run `npm run package:vsix` and, when a VS Code-family CLI is available, `node scripts/install-local.js --dry-run --skip-dependency-restore --skip-tests --code-cli <cli>`. Finish with `git diff --check`. Run repo governance validation only for accompanying `.llm` or quality-tooling changes it actually covers.
