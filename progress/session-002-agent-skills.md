# Session 002: standard Agent Skills migration

## Findings

- Open issue #45 requires each repository skill to be recognizable as a standard Agent Skill: a directory containing `SKILL.md` with YAML `name` and `description` metadata.
- The existing `.llm/skills/*.md` cards used repository-specific trigger comments and were not directly discoverable by standard clients.
- Open PRs #40 and #41 still have historical CI failures, but GitHub CLI authentication is unavailable in this environment; public API metadata was used for triage only.

## Changes

- Added standard `SKILL.md` entrypoints for all 15 repository skills under `.llm/skills/<name>/`.
- Kept expanded guides in `.llm/skill-details/` and linked each entrypoint to its guide.
- Updated the generated index updater to read standard front matter and emit `SKILL.md` links, with legacy fixture compatibility for migration tests.
- Updated the LLM harness validator and tests to enforce valid skill names/descriptions, directory matching, guide links, and a 250-line entrypoint limit.
- Updated `PLAN.md` and recorded this session.

## Verification

- `Update-LlmSkillsIndex.ps1 -Check` passed.
- `Test-LlmHarness.ps1 -MaxLines 300 -WarningLines 280` passed.
- Targeted `LlmHarness.Tests.ps1` Pester gate passed.
- Targeted pre-commit validation passed after the ScriptAnalyzer declaration fix.
- Full validation reached all-files pre-commit but remains blocked by pre-existing dirty `Config/` snapshots being rewritten by format hooks; those user changes were not staged or intentionally changed.
