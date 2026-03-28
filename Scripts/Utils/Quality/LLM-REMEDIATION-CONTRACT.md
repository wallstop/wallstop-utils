# LLM Remediation Contract

This contract defines how AI-generated shell changes must be produced and validated in this repository.

## Core rules

- Fix first: prefer direct code remediation over suppression.
- Keep strict linting: do not relax `.shellcheckrc` severity or broad-disable checks.
- Suppress narrowly: only inline suppressions for unavoidable cases, with nearby reason comments.
- Preserve behavior: use smallest possible patches and avoid unrelated refactors.

## Required workflow

1. Reproduce: run the failing hook(s) and collect exact findings.
2. Patch minimally: implement targeted fixes for reported codes.
3. Format: run `shfmt` on touched shell files.
4. Re-lint: run `shellcheck` on touched files (or all files when needed).
5. Validate policy tests: run shell-related safety convention tests.
6. Re-run hooks: verify `pre-commit` shell hooks pass.

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
