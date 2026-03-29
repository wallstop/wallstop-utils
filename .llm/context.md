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
8. When a failure reveals a repeatable category, codify the invariant in skills/context/tests.

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

## Contribution Rules

1. Add or update skill files in `.llm/skills`.
2. Keep skill files lightweight and include a link to expanded content in `.llm/skill-details`.
3. Include a trigger metadata comment in each skill file.
4. Run index generation and harness validation.
5. Commit updated skills and generated index together.
6. If file length approaches 280 lines, split content before it reaches 300.
