# LLM Remediation Contract

This contract defines how AI-generated shell changes must be produced and validated in this repository.

## Core rules

- Fix first: prefer direct code remediation over suppression.
- Keep strict linting: do not relax `.shellcheckrc` severity or broad-disable checks.
- Suppress narrowly: only inline suppressions for unavoidable cases, with nearby reason comments.
- Preserve behavior: use smallest possible patches and avoid unrelated refactors.
- Preserve CI lane contracts: keep PR fast-lane checks lightweight and nightly deep-lane checks comprehensive.

## CI invariants

- Windows PR lane must remain changed-file scoped for `*.ahk` and `*.bat` targets.
- Windows PR lane must enforce a 180-second runtime budget.
- Do not introduce heavyweight package-manager installation paths into the PR lane.
- Keep nightly deep-lane Windows validation (scheduled + optional manual trigger).
- Keep fallback full-scan behavior when baseline commit resolution is unavailable.
- Workflow edits that alter CI behavior must include policy-test updates in `Tests/Utils/ScriptSafetyConventions.Tests.ps1`.

## Required workflow

1. Reproduce: run the failing hook(s) and collect exact findings.
2. Patch minimally: implement targeted fixes for reported codes.
3. Format: run `shfmt` on touched shell files.
4. Re-lint: run `shellcheck` on touched files (or all files when needed).
5. Validate policy tests: run safety convention tests covering workflow and helper-script contracts.
6. Re-run hooks: verify `pre-commit` hooks pass.
7. Re-check CI runtime assumptions: verify Windows PR-lane timing and scope contracts are still true.

## Major-change session-close loop

For significant sessions, run the full workflow gate before stopping:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

If any gate fails, remediation is current-session priority. Do not start unrelated work before returning to green.

## Knowledge codification policy

When a failure reveals a repeatable category, codify the invariant broadly:

1. Update or add guidance in `.llm/skills/*.md` and `.llm/skill-details/*.md`.
2. Update `.llm/context.md` when the rule is repository-wide.
3. Add or update regression tests to enforce the category.
4. Regenerate and validate the skills index/harness.

Avoid fragile one-off mandates tied to a single file path unless runtime constraints require them.

## Suppression template

If suppression is unavoidable, use this pattern:

```bash
# shellcheck disable=SCXXXX
# Reason: <why this is safe and why code rewrite is unsuitable>
```

## Disallowed patterns

- `# shellcheck disable=all`
- Disabling multiple unrelated codes without explanation
- Skipping shell hooks to force green commits

## Final verification checklist

- [ ] Targeted shell findings resolved
- [ ] No new shellcheck findings introduced
- [ ] `shfmt` is clean
- [ ] Related policy tests pass
- [ ] Docs/tests updated when new exceptions are introduced
- [ ] Windows PR lane remains changed-file scoped and budgeted (<180s)
- [ ] Nightly Windows deep lane remains enabled
