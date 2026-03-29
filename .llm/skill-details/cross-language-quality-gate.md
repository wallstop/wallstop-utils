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
4. Keep cross-platform generated-index checks deterministic by using explicit UTF-8 file reads and normalizing path separators to `/` before generating or validating markdown links.
5. For multi-OS matrix quality workflows, prefer `fail-fast: false` when preserving complete diagnostics is more valuable than early cancellation.
6. Prefer `Invoke-Pester -Configuration` in CI over legacy `-Path`/`-CodeCoverage` parameter sets to avoid deprecation drift and warning noise.
7. In GitHub Actions PowerShell steps, import Pester in every step that configures tests and use `New-PesterConfiguration`; avoid raw `[PesterConfiguration]::Default` type literals because step isolation can leave module types unloaded.
8. Keep Pester CI wiring centralized through `Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1` so diagnostics, version guards, and coverage-gate behavior stay consistent across workflow steps.

## Commands

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

## References

- `.pre-commit-config.yaml`
- `.github/workflows/script-quality.yml`
- `Scripts/Utils/Quality/Assert-CleanGitTree.ps1`
