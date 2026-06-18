# LLM Context

This file is the single source of truth for AI-agent behavior in this repository.
All front-end wrapper files must point here and should not duplicate policy text.

## Repository Snapshot

- Repo purpose: cross-platform config backup/restore utilities and quality tooling.
- Primary languages: PowerShell, shell, AppleScript, AutoHotkey, batch, JSON/YAML/Lua.
- Quality model: agentic targeted validation first, with pre-commit/CI parity as last-resort gating and policy tests.

## Authoritative Quality Rules

1. Keep patches minimal and behavior-preserving.
2. Prefer direct fixes over broad suppressions.
3. Keep shell governance strict; avoid global disable directives.
4. Preserve CI lane contracts:
   - Windows PR lane remains changed-file scoped for AHK and batch.
   - Windows PR lane keeps 180-second runtime budget.
   - Nightly deep lane remains available for full-repo checks.
   - AutoHotkey scripts in both `Scripts/AutoHotKey/` and `Config/.config/` remain v2-only (`#Requires AutoHotkey v2`); dependency-free static checks and safe `-Fix` recovery must run before optional runtime AutoHotkey probing.
   - Targeted Windows language checks must keep explicit scope semantics: `TargetFiles` input that resolves to zero existing targets must skip without silently widening to full-repo validation.
5. Do not introduce heavyweight installs into PR fast lanes.
6. Keep generated content deterministic and reproducible.
7. After major changes, run full validation before ending a session.
8. Prefer PEP 668-safe pre-commit bootstrap guidance (`pipx` or dedicated venv); avoid `python3 -m pip install --user pre-commit`.
9. When a failure reveals a repeatable category, codify the invariant in skills/context/tests.
10. Third-party tooling dependencies must be covered by Dependabot weekly grouped updates (Monday 03:00 UTC; ecosystems: github-actions, pre-commit, pip, devcontainers; one PR per ecosystem area per update type), with policy tests that block regressions.
11. Keep quality-harness diagnostics low-noise: in `Run-PreCommitValidation.ps1`, `Scripts/Utils/Quality/*`, `Scripts/Utils/Common/QualityToolingHelpers.ps1`, and `Scripts/Utils/Remove-BOM.ps1`, use `Write-Verbose` for advisory telemetry (for example discovery diagnostics, probe details, and periodic progress) and reserve `Write-Warning` for actionable degradation only; keep `Write-Host` for concise high-level status summaries. Diagnostic strings that must preserve stable `E_*`/`W_*` codes must not call helper commands inside `$()` interpolation; precompute best-effort detail first so helper failures cannot mask the primary code.
12. Scripts that invoke `git` must preflight availability with `Get-Command -Name "git" -ErrorAction SilentlyContinue` before the first git call and emit a stable `E_*_GIT_NOT_AVAILABLE` diagnostic when missing.
13. Treat CI logs containing `files were modified by this hook` as autofix-required formatting drift (not a tool crash); emit explicit `E_CI_PRECOMMIT_AUTOFIX_REQUIRED` diagnostics and list modified files.
14. Prefer git-native ignore semantics over ad-hoc `.gitignore` wildcard conversion: `Scripts/Utils/Remove-BOM.ps1` file discovery must use `git ls-files --cached --others --exclude-standard` when available, and emit explicit `W_REMOVE_BOM_GIT_DISCOVERY_FALLBACK` diagnostics when it must degrade to filesystem traversal. Derive scoped pathspecs via `git rev-parse --show-prefix` (not `System.IO.Path.GetRelativePath`) to avoid symlink/canonical-path alias mismatches (for example `/var` vs `/private/var`) that can trigger `git ls-files` exit `128`. Canonicalize both scan roots and git roots through the same symlink-aware helper before `Test-IsPathUnderRoot` comparisons; do not mix alias-form and canonical-form roots. Canonicalization helpers must canonicalize the requested path directly (for example, resolved path + `Get-Item.FullName`) rather than traversing intermediate segments, and on Unix must normalize top-level symlink aliases (for example, `/var` to `/private/var`) before scope comparisons. Top-level alias resolution must be resilient across metadata variations: prefer `ResolveLinkTarget`, then provider `LinkTarget`/`Target` properties, then `Get-Item.FullName`, then `Resolve-Path` re-probe, then Unix `readlink` fallback, then a physical-path fallback (`/bin/pwd -P`) for providers that still surface alias identities; when a relative link target is resolved for a root-level segment, treat empty parent output as `/` before `Join-Path`. If `git rev-parse --show-prefix` returns an out-of-root path (for example `..` or `../outside`), or the derived prefix cannot be canonicalized under git root, discovery must degrade to git-root enumeration with post-filtering and emit `W_REMOVE_BOM_GIT_PREFIX_OUTSIDE_ROOT`. Git discovery diagnostics should include `relativeScanRootSource=...` to make prefix-derivation decisions explicit, and git stream failures should include processed/scope-filtered counters (`processedCandidates=... scopeFiltered=...`) for actionable triage. When git discovery is unavailable, fallback safety must reject traversal if `.gitignore` is present in the scan root or any ancestor up to the nearest `.git` repository boundary. If no `.git` boundary is detected, non-repository fallback remains intentionally scoped to the requested scan root only; diagnostics must report fallback scope, checked ancestor depth, and detected boundary identity (`fallbackScope=... checkedAncestors=... gitBoundary=...`).
15. Keep `Remove-BOM` discovery lazy: `Resolve-ScannableFileDiscovery` must not execute eager `git ls-files` counting probes; in the success path enumerate once via `Get-ScannableFileStream` and keep discovery diagnostics explicit (for example `listedPaths=deferred`). Error paths may issue a single follow-up probe only for actionable diagnostics.
16. PowerShell quality scripts that depend on gallery modules must resolve command availability through `Scripts/Utils/Common/ModuleHelpers.ps1`, enforce `Import-Module -MinimumVersion` before command invocation, and emit actionable `E_CONFIG_ERROR` diagnostics that include detected installed versions plus an explicit installation command. Because hooks run with `pwsh -NoProfile`, `Ensure-PortableUserModulePaths` in `ModuleHelpers.ps1` must keep cross-platform user/all-users discovery coverage (Windows documents paths for both `PowerShell/Modules` and `WindowsPowerShell/Modules`, non-Windows user scope, and `/usr/local/share/powershell/Modules`) so host-shell context drift does not hide installed modules. Module path candidate rejection reasons (empty path, missing directory, already-present path) must be emitted through `Write-Verbose` in `Add-ModulePathCandidate`, and minimum-version failures in `Invoke-PesterQualityGate.ps1` must include `PSModulePath` diagnostics (entry counts plus preview) for non-interactive triage. Local hook validation entrypoints (notably `Scripts/Utils/Run-PreCommitValidation.ps1`) must run Pester through `Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1` in an isolated `pwsh -NoProfile -NonInteractive` subprocess with explicit timeout, bounded output capture (line/character caps with explicit truncation diagnostics), and bounded stream-drain timeout handling; avoid in-process `Invoke-Pester` calls in hook wrappers. Use runspace-safe compiled event-handler capture for high-volume hook Pester output paths, and keep task-based `ReadToEndAsync` capture for smaller bounded utility command output paths. Timeout cleanup must call `Stop-ProcessTreePortably`; its Windows PowerShell 5.1 fallback must enumerate and kill descendants before the root process instead of killing only the parent. Timeout diagnostics must distinguish `E_TEST_TIMEOUT` (process runtime) from `E_TEST_CAPTURE_TIMEOUT` / `E_TEST_CAPTURE_FAILED` (stream-drain path). Avoid unbounded Process.WaitForExit() in isolated hook subprocess capture paths: post-capture bookkeeping waits must be explicitly bounded and timeout as `E_TEST_CAPTURE_TIMEOUT`.
17. Agentic workflow preflight is mandatory for hook/quality/validation work: run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly` near session start to catch missing dependencies before commit-time hooks, verify/repair local `.githooks` registration, and enforce the pinned pre-commit CLI from `requirements.txt`. For AHK/batch edits, also run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1 -TargetFiles <paths> -Fix` before hooks so static v2/directive drift is repaired while the agent is still active. When `pwsh` is available, the `.githooks/pre-commit` wrapper must additionally run `Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1` before `pre-commit` to perform safe staged-target `-Fix -StaticOnly` recovery for Windows-language drift without waiting for commit-time failures. Devcontainer bootstrap (`.devcontainer/post-create.sh`) must invoke the same preflight command in non-blocking mode so new containers surface prerequisite drift early. If preflight reports module prerequisites missing, run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1` in the same host shell, then rerun preflight before any hook execution. `Run-PreCommitValidation.ps1` must validate required modules in the host process before launching isolated Pester subprocesses, and pre-commit ScriptAnalyzer scope must remain staged-file targeted in non-`-All` mode. All GitHub workflow lanes (`.github/workflows/*.yml`) and devcontainer bootstrap that require Pester/PSScriptAnalyzer must route module installation through `Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1` (never inline `Set-PSRepository`/`Register-PSRepository`/`Get-PackageProvider`/`Install-Module` of Pester or PSScriptAnalyzer in workflow YAML); the shared bootstrap is the single source of PSGallery recovery -- when PSGallery is unregistered it must `Register-PSRepository -Default`, bootstrap the NuGet provider, and on Windows PowerShell 5.1 enable TLS 1.2 before `Set-PSRepository`/`Install-Module`, keeping installs idempotent. The normal trusted PSGallery path must install without `-SkipPublisherCheck`; use that switch only when `-SkipPSGalleryTrust` is explicit or PSGallery trust/registration setup degraded, with `W_MODULE_BOOTSTRAP_SKIP_PUBLISHER_CHECK_FALLBACK`.
    Shell formatter/linter tooling is part of this preflight: use `Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1 -Tool All -EnsureOnly` through `Invoke-FullValidation.ps1 -PreflightOnly` to bootstrap pinned `shfmt`/`shellcheck` assets before hooks. Do not add external Python-packaged `shfmt`/`shellcheck` hooks or PATH-only shell tool entries; local hooks must resolve repo-managed, SHA256-verified tools from `Scripts/Utils/Quality/shell-quality-tools.json`, fallback hook validation must not silently widen staged shell-file scope, and direct shell-quality invocations must filter resolved inputs to the same managed shell target scope as hooks before resolving tools.
    Compiled native hook tools that publish release assets (for example StyLua/actionlint) must use local PowerShell wrappers backed by `Scripts/Utils/Quality/native-quality-tools.json`; do not use remote pre-commit Rust/Go hook repos that compile during hook execution. `Invoke-FullValidation.ps1 -PreflightOnly` must run `Invoke-NativeQualityChecks.ps1 -Tool All -EnsureOnly`, prove the Bash hook fast resolver in `Scripts/Utils/Common/HookFastToolResolver.sh` can resolve the bootstrapped actionlint asset, and run `Invoke-PreCommitWithRecovery.ps1 -InstallHooksOnly` so agents catch missing native assets and pre-commit environment corruption before commit time. Native assets must be downloaded into ignored `.tools/native-quality`, SHA256-verified before extraction/use, version-probed, and resolved with explicit platform keys/fallback diagnostics. Native quality wrappers must apply per-tool target ownership in both `-Tool All` and single-tool modes, skipping unmatched direct targets before manifest/tool resolution. The shfmt/shellcheck/StyLua/actionlint infrastructure (manifest read, asset resolution, install/lock, download, extraction, version probe, target resolution) is single-sourced in `Scripts/Utils/Common/QualityToolingHelpers.ps1`; fast Bash hook marker/fingerprint resolution is single-sourced in `Scripts/Utils/Common/HookFastToolResolver.sh` and must handle Windows ARM64/x64 emulation without duplicating resolver code in `.githooks`. Both `Invoke-ShellQualityChecks.ps1` and `Invoke-NativeQualityChecks.ps1` must dot-source shared helpers and stay thin consumers (no `Invoke-WebRequest` or bare `WaitForExit()` in the consumers). Subprocess execution in these scripts must be bounded with explicit timeout + kill (never unbounded `WaitForExit()`); release-asset downloads must use bounded retry with backoff (3 attempts; shell default 180s, native 300s; `WALLSTOP_{SHELL,NATIVE}_TOOL_DOWNLOAD_TIMEOUT_SECONDS` overrides require `>= 30`); and repository-boundary target checks must compare case-insensitively (`OrdinalIgnoreCase`) only on Windows and ordinally (`Ordinal`) on Linux/macOS. Re-divergence is policy-tested in `Tests/Utils/ScriptSafetyConventions.Tests.ps1` ("Quality tooling shared-helper conventions").
18. Treat multiline PowerShell `-f` formatting as a binding-risk category when `-f` binds a single non-array right operand on a new line and that operand line ends with a comma (for example `"..." -f` newline `$arg,` or `"..." -f` newline `1,`, especially in method/command argument contexts). Safe examples: `"{0} {1}" -f $a, $b` and `"{0} {1}" -f @($a, $b)`. `Scripts/Utils/Common/FormatOperatorSafetyHelpers.ps1` is the authoritative static guard for this continuation pattern (token-based continuation-comma detection for non-`ArrayLiteralAst` right operands), and `Run-PreCommitValidation.ps1` plus `Invoke-FullValidation.ps1 -PreflightOnly` must enforce it before module-dependent checks.
19. Git hook wrappers (`.githooks/pre-commit`, `.githooks/pre-push`) and devcontainer bootstrap preflight/prewarm (`.devcontainer/post-create.sh`) must enforce bounded execution through `Scripts/Utils/Common/HookTimeout.sh` with stable diagnostics (`E_HOOK_TIMEOUT`, `E_HOOK_TIMEOUT_CONFIG`, `W_HOOK_RUNTIME_BUDGET`) and environment-variable overrides (`WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS`, `WALLSTOP_PREPUSH_TIMEOUT_SECONDS`, `WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS`, `WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS`) so stalled validation commands cannot hard-lock editor-hosted workflows; `timeout`/`gtimeout` paths must use kill-after cleanup (`-k`) and avoid `--foreground`, shell fallback watchdogs must terminate an isolated process group/session (not only the direct child) and clean up lingering descendants after the wrapper exits, and Codex npm bootstrap must resolve npm-managed candidates directly, exclude `~/.local/bin/codex` from PATH fallbacks, accept local-prefix Codex only when npm package metadata proves ownership, and verify link postconditions before reporting success. Default local hooks must stay last-resort and fast: use targeted staged/pushed pathspec discovery plus streamed `git cat-file blob ... | bash -n` for shell entrypoints, do not run workflow actionlint/ShellCheck by default, and keep workflow actionlint as explicit opt-in (`WALLSTOP_PRECOMMIT_FAST_WORKFLOW_LINT=1` / `WALLSTOP_PREPUSH_FAST_WORKFLOW_LINT=1`). `Invoke-FullValidation.ps1 -PreflightOnly` only proves repo-managed native assets and hook resolver availability; agentic edits to `.github/workflows/*.yml` or `.yaml` must also run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1 -Tool actionlint -TargetFiles <workflow paths>` before relying on hooks.
    When `pwsh` and `pre-commit` are available, hook wrappers should route pre-commit execution through `Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1` so cache/environment install failures are auto-cleaned, pre-warmed with `pre-commit install-hooks`, and retried once before emitting stable `E_PRECOMMIT_*` diagnostics; formatter-modified clean staged files should be auto-restaged and retried once, while files with pre-existing unstaged drift must fail with stable `E_PRECOMMIT_AUTOFIX_*` diagnostics instead of staging unrelated work.
    `Invoke-PreCommitWithRecovery.ps1 -TimeoutSeconds` is an overall recovery deadline, not a per-subprocess budget; shell hook wrappers must reserve a small shutdown buffer between their outer watchdog and the inner PowerShell timeout, plus setup slack before recovery starts. This makes pre-commit and pre-push recovery-backed outer timeout minimums 60s (30s inner recovery plus 15s buffer plus 15s setup slack).
    Hook-time git index lock contention (`.git/index.lock`) must be handled through `Scripts/Utils/Common/DiagnosticsHelpers.ps1` safe recovery helpers with signature-gated retry semantics, stable lock diagnostics (`W_PRECOMMIT_GIT_INDEX_LOCK_*`, `E_PRECOMMIT_GIT_INDEX_LOCK_*`), and bounded environment overrides (`WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE`, `WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS`, `WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT`, `WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS`); do not add ad-hoc lock-file deletion logic in individual hook scripts.
20. Copilot/agent-driven test execution must avoid direct `Invoke-Pester` terminal calls. For ad-hoc Pester runs, use timeout-bounded invocation of `Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1` with `-OutputVerbosity None` and a scoped `-TestPath`; this keeps terminal output bounded and avoids editor-host lock pressure.
21. GitHub GraphQL utilities must enforce case-sensitive variable payload alignment with declared operation variables (for example `$owner`/`$repo` requires `owner`/`repo` keys) before network calls, and keep both behavioral coverage in `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1` plus policy coverage in `Tests/Utils/ScriptSafetyConventions.Tests.ps1`. The unresolved-comments utility must also preserve default bot markup cleanup and Cursor/Bugbot embedded-location handling with the same behavioral plus policy coverage. Rendered output must be verbatim and copy-safe: clipboard copies of native tools (`pbcopy`/`xclip`/`xsel`/`wl-copy`) must run through `Invoke-NativeClipboardTool`, which detaches the child's standard streams (`UseShellExecute=$false`, `RedirectStandardInput/Output/Error=$true`) so a forked selection-server child cannot hold the terminal open (the "clipboard hangs the terminal for several seconds" bug), writes the payload as raw UTF-8 (no-BOM) bytes to the child stdin via a timeout-bounded `WriteAsync`, and bounds the call with `WaitForExit(timeout)` plus `Stop-ProcessTreePortably` tree-kill on overrun; `Invoke-Main` ensures UTF-8 terminal rendering via `Initialize-Utf8ConsoleOutputEncoding`, which reads `[System.Console]::OutputEncoding` first and only changes it when not already UTF-8 (code page 65001) so it never pays the slow Windows `SetConsoleOutputCP` code-page switch per invocation; the OSC52 clipboard bridge must emit an explicit-selector, UTF-8 base64 sequence via `ConvertTo-Osc52Sequence` (`ESC ] 52 ; c ; <base64> BEL`, never the ambiguous empty-selector `Set-Clipboard -AsOSC52`) with a size-budget warning (`W_CLIPBOARD_OSC52_TRUNCATION_RISK`, override `WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES`) and Windows-first clipboard priority; `-Truncate` must not split a UTF-16 surrogate pair at the boundary; the text renderer must use a single collapsed `---` delimiter between blocks (no doubled seam); GitHub/Copilot/Cursor `suggestion` code fences must be extracted verbatim into a `suggestions` record field via a single shared fence regex (reused by prose stripping) and rendered under a `Suggested change:` label, except under `-KeepMarkup`; GitHub web-exposed Copilot `automatedComment.suggestion.diffEntries` may be attached best-effort by comment `databaseId` (for private web HTML only via explicit `-GitHubWebCookie` / `WALLSTOP_GITHUB_WEB_COOKIE` / `GITHUB_WEB_COOKIE`), but only `DELETION`/`ADDITION` lines may become public `suggestedDiffs`; and GitHub review-comment `diffHunk` / REST `diff_hunk` must stay internal only because those hunks are review context, not suggested changes. Public text and JSON output should contain only file, line range, suggestion prose, and actual exposed suggested changes: JSON records use lower-camel `path`, `lineStart`, `lineEnd`, and `comments[]` entries with `suggestion` plus normalized `suggestedChanges[]` (`kind`, `value`), omitting author, URL, latest-reply, and context-hunk fields. The fast-exit behavior is on by default with a `-NoFastExit` opt-out: after rendering it may skip the slow .NET/PowerShell managed teardown by flushing the console then terminating immediately (`Invoke-FastProcessExit` -> `Stop-CurrentProcessImmediately`: runtime-gated libc `_exit` on non-Windows, `[System.Environment]::Exit` on Windows/fallback); it must flush before terminating, expose `-NoFastExit` to restore standard teardown, and be wired only inside the existing dot-source run guard so dot-sourced tests never terminate the host. Source-aware auth recovery is mandatory: environment token precedence is `GH_TOKEN` before `GITHUB_TOKEN`; rejected token values from recoverable auth failures must be excluded from later resolution in the same run; prompted login fallback must bypass environment tokens and rejected values to prevent long-running invalid-token loops; direct owner/repo mode remains non-prompting: explicit `-Token` auth failures fail fast, while missing auth or recoverable ambient-token failures may use non-interactive stored-credential resolution/retry and public REST fallback before failing. Agentic edits to `Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1` must run targeted `Run-PreCommitValidation.ps1 -TargetFiles`, `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`, and `Tests/Utils/ScriptSafetyConventions.Tests.ps1` validation before hooks.
22. Machine-readable PowerShell output contracts must keep stable key casing and shape: for `-OutputFormat json` payloads, output record keys must stay consistently lower-camel unless explicitly versioned, and JSON serialization must preserve array shape for singleton results (`ConvertTo-Json -AsArray`). Keep both behavioral coverage and policy-level convention checks for these contracts.
23. Backup orchestrators that perform remote git mutation (`pull`/`push`) must assert branch context before each remote operation: reject detached HEAD (`E_BACKUP_GIT_DETACHED_HEAD`) and reject unexpected branch targets (`E_BACKUP_GIT_BRANCH_MISMATCH`) with explicit diagnostics instead of relying on implicit current-branch behavior. Agent/automation branch publishing must use `Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1` instead of bare `git push`, so no-upstream branches get hook preflight plus safe `push -u` recovery.
24. Quality/status diagnostics that emit `repositoryRoot=...` must derive that value from an explicit git-root context (`git rev-parse --show-toplevel` or a validated caller-provided root) rather than `(Get-Location).Path`; include `workingDirectory=...` separately when helpful for triage.
25. Shell scripts that mutate git state (for example `Scripts/Mac/Backup.sh` and `Scripts/Utils/increment-version.sh`) must fail fast and avoid blanket suppression for mutating git commands: preflight `git` with `command -v git >/dev/null 2>&1` before the first side effect; emit a stable `E_*_BRANCH_RESTRICTED` diagnostic (and exit non-zero) when branch policy restricts mutations; route warning/error diagnostics (`E_*`, `W_*`, `Error:`, `Warning:`, `Unknown option:`) to stderr so stdout stays parseable; do not use `git add|commit|pull|push ... || true` or `... || echo ...` for control flow; do not force-push (`git push -f` or `git push --force`) in automation scripts; handle `nothing to commit` via staged diff state (`git diff --cached --quiet --exit-code`); avoid negated command-substitution exit capture (`if ! output="$(git ... )"; then code=$?`) because it reports the negated status instead of git's real exit code; and emit stable `E_*_GIT_*` diagnostics for staged diff, commit, pull, and push failures.
26. `Scripts/Mac/Backup.sh` must mirror the managed-pathspec backup safety contract used by orchestrators: stage only `Config/` (never `git add --all`), validate out-of-scope changes with `git status --porcelain=v1 --untracked-files=all -- . :^Config/` semantics before staging, and include `repositoryRoot` plus bounded `outputPreview` diagnostics on pull/add/commit/push failures.
27. `Scripts/Utils/increment-version.sh` must stage only managed version artifacts (for example `package.json` and lockfiles) after hook/formatter runs, assert staged scope excludes unrelated files before commit, and must not use blanket staging (`git add -A`) in commit automation flows. Git context must be resolved from the discovered package directory (`git -C "$package_json_dir" rev-parse --show-toplevel`) and subsequent repository-state git operations (`rev-parse`, `fetch`, `rev-list`, `pull`, `add`, `commit`, `push`) must execute through `git -C "$repo_root"`; lock cleanup traps must be registered before lock acquisition.
28. For edits touching shell git-mutation automation or its policy harness (`Scripts/**/*.sh`, `.githooks/pre-commit`, `.githooks/pre-push`, `Tests/Utils/ScriptSafetyConventions.Tests.ps1`), run timeout-bounded targeted safety validation via `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None` before handoff, and keep policy assertions semantic (fail-fast guard, stable `E_*_GIT_*` diagnostics, no `|| true`) rather than syntax-fragile exact command-shape matching.

## Working Agreement For Agents

1. Read relevant skills before editing files.
2. Run deterministic checks after edits.
3. Update generated index when skill metadata changes.
4. Do not hand-edit generated index sections.
5. Keep every .llm markdown file at or below 300 lines.
6. Treat failing tests/hooks/CI checks as current-session priority.
7. Prefer category-level guidance over brittle one-off rules.
8. Keep commits bisectable: each commit must pass all gates independently.
9. **Mandatory post-work self-improvement**: after any significant work, execute the [post-work self-improvement workflow](./skills/post-work-self-improvement.md) using sub-agents with adversarial consensus to analyze work done, extract new knowledge, and update `.llm/` guidance. This is a session-close gate, not optional. See [expanded guide](./skill-details/post-work-self-improvement.md) for trigger criteria and protocol.

## Primary Commands

```bash
pre-commit run
pre-commit run --all-files
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1
```

Canonical session-close workflow: [validation-workflow.md](./validation-workflow.md)

## Repo-Aware Skill Usage

- Use skills in `.llm/skills` to apply localized best practices.
- Trigger metadata in each skill drives a dedicated generated index file.
- Skill cards should stay lightweight and point to expanded guides in `.llm/skill-details`.

## Skill Categories

- Core: baseline patterns that apply broadly.
- Quality: quality gates, linting, and remediation process.
- Platform: OS/runtime-specific behavior and constraints.
- GitHub: repository-hosted workflow and API utility patterns.

## Generated Skills Index

- Generated index file: [`.llm/skills-index.md`](./skills-index.md)
- This file is produced by `Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1`.
- Do not hand-edit generated sections in the index file.

## Wrapper Contract

The following wrapper files are thin pointers and must remain non-authoritative:

- `AGENTS.md`
- `.github/copilot-instructions.md`
- `CLAUDE.md`

LLM harness staged-file wrapper triggers are routed through `Run-PreCommitValidation.ps1`
and must be derived from this list at runtime. Do not hardcode wrapper filenames in
static hook regex patterns.
All Wrapper Contract parsing must go through
`Scripts/Utils/Common/LlmWrapperContractHelpers.ps1` (`Get-WrapperContractEntries`).
Do not duplicate inline parser logic in scripts or tests.

## Cross-Platform Line Ending Safety

Repository enforces LF via `.gitattributes` (`* text=auto eol=lf`).
When writing tests that use `Get-Content -Raw` with `(?m)...$` multiline regex:

- Always normalize: `$content = (Get-Content -Path $path -Raw) -replace "\r", ''`
- The `$` anchor in `(?m)` mode fails with CRLF because `\r` sits between text and `\n`.
- Patterns using `\b`, `\w`, `\S` etc. instead of `$` are not affected.
- String comparisons across files must also normalize both sides.

## Windows File-Handle Safety

PowerShell's `Get-Content -Raw` can hold file handles open longer than expected on Windows,
causing `IOException: The process cannot access the file` when another read follows quickly.

- In production scripts that read temp/generated files, prefer `[System.IO.File]::ReadAllText()`:
  `[System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)`
- This opens with `FileShare.Read` and closes immediately after reading.
- Always pass resolved absolute paths (e.g., from `.FullName` or `Resolve-Path`).
- Always specify `[System.Text.Encoding]::UTF8` explicitly for consistency.

## OpenRead Stream Disposal Safety

`[System.IO.File]::OpenRead(...)` returns a `FileStream` and must never rely on manual
`.Close()` without guaranteed cleanup.

- Every `OpenRead` usage in `Scripts/*.ps1` must be protected by either:
  `using (...) { ... }` or `try { ... } finally { $stream.Dispose() }`.
- Prefer centralized helper functions for repeated prefix-read logic to avoid copy/paste
  stream handling and disposal drift.
- Conventions are policy-tested in `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
  under "File stream safety conventions".

## Test Temp Directory Canonicalization

On macOS, `[System.IO.Path]::GetTempPath()` returns `/var/folders/...` (symlink) but
`FileInfo.FullName` resolves to `/private/var/folders/...` (canonical). When tests create
temp directories and later compute relative paths with `GetRelativePath`, the base and
target paths use different canonical forms, producing `../../../../../../private/var/...`
instead of correct relative paths.

- After creating a temp directory, canonicalize it: `$root = Resolve-CanonicalTempRoot -Path $root`
- `Resolve-CanonicalTempRoot` uses `(Get-Item -LiteralPath $Path).FullName` to match
  the resolution that `FileInfo.FullName` applies on each platform.
- On Linux/Windows this is a no-op; on macOS it resolves the `/var` symlink.
- Convention enforced in `ScriptSafetyConventions.Tests.ps1` under "Path derivation safety conventions".

## Start-Process Exit Code Race Condition

`Start-Process -Wait -PassThru` on Windows has a known race where `.ExitCode` may not
be populated when the cmdlet returns, especially under heavy I/O.

- Always call `$process.WaitForExit($timeoutMs)` after `Start-Process -Wait -PassThru`.
- Check the boolean return to detect timeouts.
- Do not gate on `$process.HasExited` — it can race with the same underlying issue.

## Start-Process Argument Mangling

`Start-Process -ArgumentList` on Windows mangles arguments containing curly braces,
double quotes, and other special characters. Prefer `System.Diagnostics.Process` with
`Set-PortableProcessArguments`, which escapes arguments portably across supported editions.

## PowerShell Empty Array Return Safety

`return @()` inside a function silently returns `$null` instead of an empty array.

`return @(<pipeline>)` has the same risk when the pipeline emits no values.
Use a comma-wrapped return (`return , @(<expression>)`) whenever callers depend on
array semantics in empty-result paths.

- Use `return , @()` (comma operator) when callers access `.Count` directly on the result.
- If callers always wrap with `@()`, the bare `return @()` is safe — add `# array-unwrap-safe`.
- Do not comma-wrap already materialized arrays returned to call sites that already use `@(...)`; `return , $array` in that case creates nested arrays and breaks `foreach` step iteration.
- For array-return helpers with multiple call sites, keep one explicit contract end-to-end: either bare returns + `@(...)` at every call site, or comma-wrapped returns + non-wrapped call sites; do not mix contracts.
- Add both behavioral and structural coverage for high-risk array-return helpers: behavior tests for empty/non-empty flattening plus AST/pattern checks that call-site wrapper usage matches the helper's return contract.
- A convention test in `ScriptSafetyConventions.Tests.ps1` enforces this in `Scripts/`.

## Cross-Platform And Cross-Version PowerShell Portability

All repository PowerShell (`Scripts/**`, `Config/Powershell/**`, `Tests/**`) must run on BOTH Windows PowerShell 5.1 (Desktop edition / .NET Framework) AND PowerShell 7+ (Core), across Windows, macOS, and Linux. The cross-version contract is enforced statically by `Scripts/Utils/Quality/Invoke-CompatibilityChecks.ps1` (PSScriptAnalyzer `PSUseCompatible*` rules over 5.1 + 7 profiles, plus an AST scan for 5.1-undefined automatic variables) and at runtime by the `powershell-tests-winps51` / `powershell-tests-pwsh7` CI lanes. PowerShell 7 runs the full Pester suite; Windows PowerShell 5.1 runs a focused compatibility-critical subset so the lane stays fast while still exercising a focused 5.1 runtime smoke test, module bootstrap, GitHub utility behavior, and compatibility helper/convention coverage under Desktop edition. Re-divergence is policy-tested in `Tests/Utils/CompatibilityConventions.Tests.ps1` and `Tests/Utils/CompatibilityHelpers.Tests.ps1`.

Portable idioms are single-sourced in `Scripts/Utils/Common/CompatibilityHelpers.ps1`
(dot-source it; never reintroduce the raw construct):

- `$IsWindows`/`$IsMacOS`/`$IsLinux` are undefined on 5.1 and THROW under `Set-StrictMode`;
  use `Test-IsWindowsPlatform`/`Test-IsMacOSPlatform`/`Test-IsLinuxPlatform`.
- `[System.IO.Path]::GetRelativePath` is absent on .NET Framework; use `Get-RelativePathCompat`.
- `ConvertTo-Json -AsArray` (6+) → `ConvertTo-JsonArrayCompat`; `ConvertFrom-Json -Depth/-NoEnumerate`
  (6+) → `ConvertFrom-JsonCompat`. `New-Item -LiteralPath` is invalid on every edition; create
  directories with `[System.IO.Directory]::CreateDirectory($path)` (literal, idempotent).
- `ProcessStartInfo` argument and environment mutations must use `Set-PortableProcessArguments` / `Set-PortableProcessEnvironmentVariable`; PATH-shim harnesses must preflight `command -v` for fake commands.
- `[ArgumentCompletions()]`, ternary `?:`, `??`/`??=`, `&&`/`||`, `clean{}`, `$PSStyle` are 7+-only;
  use `[ValidateSet]`, `if/else`, `try/finally`. Interactive profiles must guard PSReadLine 2.2+
  options (`-PredictionSource`/`-PredictionViewStyle`) behind a capability probe.
- Runtime-guarded/floor-safe constructs (for example `Set-Clipboard -AsOSC52`,
  `RuntimeInformation::ProcessArchitecture`) keep an inline justified `SuppressMessageAttribute`;
  external executables and Pester DSL live in `compatibility-allowlist.psd1`. Never allowlist a
  real cmdlet whose parameters differ across editions.

The portability rules below also apply (PowerShell 7+ remains the primary cross-platform target):

1. Use `Join-Path` and `[System.IO.Path]` for path construction; never hardcode `\` or `/`.
2. Use the `Test-IsWindowsPlatform`/`Test-IsMacOSPlatform`/`Test-IsLinuxPlatform` helpers for OS branching (never bare `$IsWindows`/`$IsMacOS`/`$IsLinux`, which throw on 5.1; never `$env:OS`).
3. Write files with explicit UTF-8 no-BOM encoding via `[System.IO.File]::WriteAllText(..., [System.Text.UTF8Encoding]::new($false))`. This includes `$GITHUB_OUTPUT`/`$GITHUB_ENV` writes from `shell: powershell` (Windows PowerShell 5.1) workflow steps, where `>`/`>>`/`Out-File` emit UTF-16LE (or a BOM) and corrupt the value; use `[System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "key=value`n", [System.Text.UTF8Encoding]::new($false))` (`>>`stays fine only under`shell: pwsh`).
4. Normalize line endings (`-replace "\r", ''`) before regex matching or string comparison.
5. Normalize path separators to `/` in generated output for deterministic cross-OS comparison. For custom output objects that include a `Path` field (for example violation and diagnostics records), normalize immediately after `Get-RelativePathCompat` (the portable relative-path helper) before returning or logging.
6. Policy tests that validate code structure must be formatter-tolerant: avoid exact-literal `.Contains(...)` checks for syntax-sensitive snippets (for example spacing around operators), prefer semantic/regex assertions that tolerate whitespace drift while still enforcing behavior, and when extracting `FunctionDefinitionAst` nodes in tests, collect all matches and assert `Count -eq 1` before dot-sourcing or inspecting a function; do not hide duplicates with `Select-Object -First 1`.
7. Use `[System.IO.Path]::GetTempPath()` instead of `$env:TEMP` for portable temp directories.
8. Use exact file name casing; Linux file systems are case-sensitive.
9. Split `$env:PATH` with `;` on Windows and `:` on Unix; never assume one separator.
10. Keep Windows-only scripts in platform-specific directories (e.g., `Scripts/Komorebi/`).
11. Use `-LiteralPath` for user-supplied or config-sourced paths; reserve `-Path` for intentional wildcard expansion.
12. Use `Test-Path` (`-PathType` where relevant) for existence/type checks. Use `Resolve-Path` to canonicalize existing paths before comparison or persistence.
13. For `Get-ChildItem`, prefer `-Filter` on FileSystem for provider-side filtering; use `-Depth` as an optional bound for deep traversals, not as a universal requirement.
14. For nested location workflows, use named stacks with `Push-Location -StackName` and restore via `Pop-Location` in `finally` blocks.
15. For deterministic sorting with `Sort-Object -Culture`, pass a culture name string (for example `[System.Globalization.CultureInfo]::InvariantCulture.Name`) instead of a `CultureInfo` object.
16. Follow `.editorconfig` indentation for PowerShell files (`*.ps1`, `*.psm1`, `*.psd1`): spaces only (no leading tab indentation).
17. Keep PowerShell formatter settings in `.psscriptanalyzer.format.psd1` with `PSUseConsistentIndentation` (`Kind='space'`, `IndentationSize=4`) and fail fast when formatter output still contains leading tabs.
18. Use `$HOME` for the user home directory instead of `$env:USERPROFILE`; `$env:USERPROFILE` is Windows-only and may be empty on macOS and Linux.

## Cross-Platform Shell Tooling (Bash grep awk sed)

For shell automation under `Scripts/`, keep commands portable, deterministic, and safe for AI-assisted edits.

1. Start Bash scripts with strict mode (`#!/usr/bin/env bash` and `set -euo pipefail`); this baseline is Bash-specific, so strict POSIX `sh` scripts should omit `pipefail` and handle pipeline failures explicitly.
2. Quote variable expansions (`"$var"`) and prefer `printf` over `echo` for portable output formatting.
3. Keep data on stdout and diagnostics on stderr (`>&2`) so pipelines remain predictable.
4. Use null-delimited file flows for path safety: `find ... -print0 | xargs -0 ...` or `while IFS= read -r -d ''`.
5. Prefer modern grep forms: use `grep -E` and `grep -F`; do not introduce deprecated `egrep` or `fgrep`.
6. Account for GNU vs BSD differences by avoiding non-portable in-place edits like bare `sed -i`, and prefer temp-file rewrite patterns when scripts must run on both Linux and macOS.
7. For large ASCII-heavy text processing, consider `LC_ALL=C` with grep/awk/sed/sort for deterministic collation and possible speedups.
8. Keep performance claims contextual. Optimize only after measuring; avoid premature rewrites that reduce readability.
9. For agentic and unattended execution, add dry-run support for mutating scripts, make operations idempotent, and bound long-running external calls with an explicit timeout strategy appropriate to the host.
10. Preflight-check external dependencies with `command -v` and fail fast with actionable errors.
11. Validate shell changes with syntax + lint + tests where available (`bash -n`, `shellcheck`, `bats`).
12. When invoking Unix tools from PowerShell on Windows, convert paths for the target runtime (`cygpath` for Git Bash, `wslpath` for WSL) or skip with an explicit diagnostic; do not pass raw Windows paths to `bash`.
13. Prefer script files over large inline one-liners when logic is non-trivial; keep behavior reviewable and testable.

See:

- Skill card: [`.llm/skills/shell-tooling-portability-and-agentic-safety.md`](./skills/shell-tooling-portability-and-agentic-safety.md)
- Expanded guide: [`.llm/skill-details/shell-tooling-portability-and-agentic-safety.md`](./skill-details/shell-tooling-portability-and-agentic-safety.md)

## Backup/Restore Safety Contract

Backup and restore scripts under `Scripts/` must prioritize data safety and deterministic behavior.

1. Source Validation: validate all required source files/directories before any destructive mutation (clear/remove/overwrite) of destination paths.
2. Destructive operations: clear destination content only after source preflight succeeds; avoid partially destructive flows when prerequisites are missing.
3. Error signaling: emit explicit stable error codes (for example `E_*`) for actionable failure triage in CI and local runs.
4. Encoding: when writing machine-readable artifacts (for example JSON), use explicit UTF-8 no-BOM via `[System.Text.UTF8Encoding]::new($false)` and `[System.IO.File]::WriteAllText(...)`.
5. Robocopy Exit Codes: handle robocopy return semantics explicitly; treat exit codes `>= 8` as failures and `0..7` as success/warning classes with diagnostics.
6. Best-Effort Orchestrators: orchestrator scripts may continue after step failures, but must record per-step outcomes, print a failure summary, and make partial success explicit before commit/push operations.
7. Process isolation: invoke child scripts in isolated processes when those scripts may call `exit`, and classify non-zero exits as failed steps.
8. Location safety: pair path changes with `try/finally` to guarantee location restoration even on failure. Use `Push-Location -StackName` for nested workflows.
9. Path safety: use `-LiteralPath` for user/config-driven paths (including `Test-Path`, `New-Item`, and `Copy-Item` sources) and `Test-Path -PathType` for existence/type checks before mutation.
10. Orchestrator step roots: derive backup/restore step roots from canonical `$PSScriptRoot` (for example `Resolve-Path -LiteralPath $PSScriptRoot`) and do not append an extra `Scripts` segment.
11. Backup/restore utility scripts: always declare `Set-StrictMode -Version Latest` at script entry to prevent silent failures from uninitialized variables and typoed references.
12. Nested utility scripts under `Scripts/*/`: when targeting repository-level assets such as `Config/`, resolve repository root explicitly (two parent traversals from `$PSScriptRoot`) before composing destination/source paths.
13. Git sequencing safety in backup orchestrators: once any git step fails (for example `git commit`), subsequent remote-mutating steps (`git pull --ff-only`, `git push`) must be explicitly skipped with stable diagnostics to avoid operating on a dirty or inconsistent local state.
14. Backup git preflight: first verify git availability with `Get-Command -Name "git"` and emit `E_*_GIT_NOT_AVAILABLE` when missing, then validate `git rev-parse --is-inside-work-tree` before git mutation (`add`/`commit`/`pull`/`push`) and fail with an explicit `E_*` code when not in a repository.
15. Cross-platform orchestrators (`Backup.ps1`, `Restore.ps1`, `Update.ps1`) must annotate steps with `SupportedPlatforms` metadata, execute only platform-applicable steps, and emit stable `W_*_STEP_SKIPPED_PLATFORM` diagnostics for skipped Windows-only steps. `Backup.ps1` and `Restore.ps1` must resolve child-script runtime via `Resolve-PowerShellExecutablePath` (prefer `pwsh`, Windows fallback to `powershell.exe`) instead of hard `Get-Command pwsh` assumptions.
16. `Backup.ps1` must run a clean-tree preflight before any backup step executes and fail with `E_BACKUP_GIT_TREE_DIRTY_PREFLIGHT` when pre-existing tracked/untracked changes are present.
17. `Backup.ps1` must scope staging to managed backup outputs (`Config/`) and must not use `git add --all`; out-of-scope changes must fail with `E_BACKUP_GIT_SCOPE_VIOLATION`.
18. Backup commit retries are allowed only for attended hook-autofix cases (`files were modified by this hook`) and must use bounded restage-and-retry loops with explicit `E_BACKUP_GIT_RESTAGE_FAILED` / `E_BACKUP_GIT_COMMIT_RETRY_LIMIT` diagnostics. Retry logic must not restage on the final allowed attempt, and retry-limit diagnostics must report actual commit attempts performed plus configured attempt/retry bounds. Unattended mode (`-Unattended` or `WALLSTOP_BACKUP_UNATTENDED=1|true|yes|on`) is an explicit opt-in and is the only allowed path for `git commit --no-verify`.
19. `Backup.ps1` and `Update.ps1` must not run `FormatPowershellScripts.ps1`; source-code formatting is governed by pre-commit hooks and explicit formatter workflows.
20. Git status/diff failure diagnostics in backup and quality orchestrators (notably `Backup.ps1`, `Invoke-FullValidation.ps1`, and `Assert-CleanGitTree.ps1`) must preserve clean stdout in success paths while including actionable context on failure (`repositoryRoot`, pathspec where applicable, and bounded `outputPreview`).
21. Shared diagnostics output-preview helpers in utility scripts must be centralized under `Scripts/Utils/Common/DiagnosticsHelpers.ps1`; consuming scripts (notably `Backup.ps1`, `Run-PreCommitValidation.ps1`, `Invoke-FullValidation.ps1`, `Assert-CleanGitTree.ps1`, and `Invoke-WindowsLanguageChecks.ps1`) must source that helper and avoid duplicate local `Get-OutputPreview` implementations.
22. `Backup.ps1` must run managed-path secret hygiene before staging/commit: redact known secret keys in text `Config/` outputs, skip binary files, then run a high-confidence unknown-secret scan; remaining hits must fail with `E_BACKUP_SECRET_SCAN_FAILED` using bounded redacted previews (never raw secrets).

## Contribution Rules

1. Add or update skill files in `.llm/skills`.
2. Keep skill files lightweight and include a link to expanded content in `.llm/skill-details`.
3. Include a trigger metadata comment in each skill file.
4. Run index generation and harness validation.
5. Commit updated skills and generated index together.
6. If file length approaches 280 lines, split content before it reaches 300.
7. Retire unused skills: delete card + detail + index entry when a skill no longer applies. _(Process rule; validated by index regeneration removing stale entries.)_
8. Prefer testable rules: if a new context.md rule cannot be enforced by a Pester test, justify why.
9. Record non-obvious architectural decisions as comments in the relevant skill-detail file. _(Review-enforced; not mechanically testable because comment relevance is subjective.)_
