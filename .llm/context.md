# LLM Context

This file is the single source of truth for AI-agent behavior in this repository.
All front-end wrapper files must point here and should not duplicate policy text.

## Repository Snapshot

- Repo purpose: cross-platform config backup/restore utilities and quality tooling.
- Primary languages: PowerShell, shell, AppleScript, AutoHotkey, batch, JSON/YAML/Lua.
- Quality model: pre-commit-first local gating with CI parity and policy tests.

## Authoritative Quality Rules

1. Keep patches minimal and behavior-preserving.
2. Prefer direct fixes over broad suppressions.
3. Keep shell governance strict; avoid global disable directives.
4. Preserve CI lane contracts:
   - Windows PR lane remains changed-file scoped for AHK and batch.
   - Windows PR lane keeps 180-second runtime budget.
   - Nightly deep lane remains available for full-repo checks.
5. Do not introduce heavyweight installs into PR fast lanes.
6. Keep generated content deterministic and reproducible.
7. After major changes, run full validation before ending a session.
8. Prefer PEP 668-safe pre-commit bootstrap guidance (`pipx` or dedicated venv); avoid `python3 -m pip install --user pre-commit`.
9. When a failure reveals a repeatable category, codify the invariant in skills/context/tests.

## Working Agreement For Agents

1. Read relevant skills before editing files.
2. Run deterministic checks after edits.
3. Update generated index when skill metadata changes.
4. Do not hand-edit generated index sections.
5. Keep every .llm markdown file at or below 300 lines.
6. Treat failing tests/hooks/CI checks as current-session priority.
7. Prefer category-level guidance over brittle one-off rules.

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

## Start-Process Exit Code Race Condition

`Start-Process -Wait -PassThru` on Windows has a known race where `.ExitCode` may not
be populated when the cmdlet returns, especially under heavy I/O.

- Always call `$process.WaitForExit($timeoutMs)` after `Start-Process -Wait -PassThru`.
- Check the boolean return to detect timeouts.
- Do not gate on `$process.HasExited` — it can race with the same underlying issue.

## Start-Process Argument Mangling

`Start-Process -ArgumentList` on Windows mangles arguments containing curly braces,
double quotes, and other special characters. Prefer `System.Diagnostics.Process` with
`ProcessStartInfo.ArgumentList.Add()` which properly escapes arguments on all platforms.

## PowerShell Empty Array Return Safety

`return @()` inside a function silently returns `$null` instead of an empty array.

- Use `return , @()` (comma operator) when callers access `.Count` directly on the result.
- If callers always wrap with `@()`, the bare `return @()` is safe — add `# array-unwrap-safe`.
- A convention test in `ScriptSafetyConventions.Tests.ps1` enforces this in `Scripts/`.

## Contribution Rules

1. Add or update skill files in `.llm/skills`.
2. Keep skill files lightweight and include a link to expanded content in `.llm/skill-details`.
3. Include a trigger metadata comment in each skill file.
4. Run index generation and harness validation.
5. Commit updated skills and generated index together.
6. If file length approaches 280 lines, split content before it reaches 300.
