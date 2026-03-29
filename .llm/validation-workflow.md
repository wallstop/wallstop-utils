# Validation Workflow

This document is the session-close quality workflow for major changes.

## Goal

After significant work, run deterministic local gates, then confirm CI status. If any gate fails, treat remediation as current-session priority before starting new work.

## What Counts As Major

Treat a session as major when one or more apply:

1. Changes touch quality gates, hooks, CI workflows, or validator scripts.
2. Changes touch `.llm/` skills, context, or harness tooling.
3. Changes span multiple subsystems or multiple script languages.
4. Changes alter validation, safety, or runtime contract behavior.

## Major Change Session-Close Loop

- Run full local validation:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
```

- Push your branch so CI jobs execute.
- Watch PR checks to completion:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

- If any check fails, fix immediately in the same session and rerun the loop.

## What Full Validation Runs

`Invoke-FullValidation.ps1` runs these in order:

1. `pre-commit` stage for all files (format and stage-level hooks)
2. `pre-push` stage for all files (full-repo tests/policy checks)
3. explicit LLM index and harness checks
4. workspace drift assertion (before/after git-status snapshot comparison)
5. optional CI watch via `gh pr checks --watch`

## Failure Handling

Use the first failing gate as the active remediation target.

- `E_VALIDATION_PRECOMMIT_FAILED`: fix formatter/lint findings, rerun.
- `E_VALIDATION_PREPUSH_FAILED`: fix tests/analyzer/policy failures, rerun.
- `E_VALIDATION_CI_FAILED`: fix failing workflow checks, rerun with `-WatchCi`.
- `E_VALIDATION_PR_MISSING`: open a PR, then rerun with `-WatchCi`.

## Codify New Knowledge (Forest-Not-Trees)

When a failure reveals a repeatable category, codify the invariant rather than a one-off rule:

1. Update the relevant skill card under [skills](./skills) with generalized guidance.
2. Update expanded guidance under [skill-details](./skill-details) with examples and rationale.
3. If the rule is repo-wide, update [context.md](./context.md) authoritative rules.
4. Add or update a regression test to prevent recurrence.
5. Regenerate and verify the skills index:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1
```

## Notes

- Keep rules category-level and durable. Avoid brittle path-specific mandates unless required by runtime constraints.
- Prefer deterministic checks and explicit error codes over implicit conventions.

## Mandatory Pre-Merge Checklist

- [ ] Ran `Invoke-FullValidation.ps1` locally.
- [ ] Local validation gates are green.
- [ ] Pushed branch updates for CI execution.
- [ ] Ran `Invoke-FullValidation.ps1 -WatchCi` (or equivalent PR check watch) and reached green CI.
- [ ] Any failure encountered in this session was fixed and revalidated in this session.
- [ ] If a new issue category was discovered, generalized it in `.llm` skills/context/tests and revalidated harness/index.
