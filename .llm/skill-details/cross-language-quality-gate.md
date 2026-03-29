# Cross-Language Quality Gate (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/cross-language-quality-gate.md`.

## Session-Close Full Validation Loop

Keep local and CI quality behavior aligned, deterministic, and clean-tree safe across scripting languages.

1. Run the single full-validation entrypoint after major changes.
2. Push branch updates so CI checks run on current code.
3. Watch PR checks to completion and remediate failures immediately.

## CI Parity And Drift Detection

Use the same command family locally and in CI to reduce environment drift and false confidence.

Preserve deterministic drift checks so automation cannot silently mutate files.

## Codify Repeatable Failure Categories

When a failure pattern repeats, encode it in skills, context, and tests instead of one-off exceptions.

Current invariants to preserve:

1. Keep `.gitattributes` and pre-commit line-ending policy aligned. If batch/cmd files require CRLF, the LF-forcing hook must exclude those file types.
2. Keep generated artifact ordering deterministic across operating systems by using culture-invariant sorting in generator scripts.
3. Keep stale-artifact checks actionable by emitting first-mismatch diagnostics and content hashes when comparisons fail.

## Commands

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

## References

- `.pre-commit-config.yaml`
- `.github/workflows/script-quality.yml`
- `Scripts/Utils/Quality/Assert-CleanGitTree.ps1`
