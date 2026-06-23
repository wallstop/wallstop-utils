# Dependency Update Automation (Expanded)

This guide supports `.llm/skills/dependency-update-automation.md`.

## Weekly Schedule And Grouping Policy

Repository policy uses a weekly Dependabot cadence to reduce noise while keeping drift controlled.

1. Interval: weekly.
2. Day/time: Monday 03:00 UTC.
3. Grouping target: one PR per ecosystem area for version updates.
4. Grouping target: one PR per ecosystem area for security updates.

This yields predictable review batches and avoids many tiny dependency PRs.

## Current Ecosystem Coverage

Current required ecosystems in `.github/dependabot.yml`:

Schema contract: `version: 2`.

1. `github-actions`
2. `pre-commit`
3. `pip`
4. `npm`
5. `devcontainers`

Policy tests in `Tests/Utils/ScriptSafetyConventions.Tests.ps1` enforce this exact baseline and fail if it drifts.

## Security Update Grouping Model

Security updates are grouped by area, not merged across ecosystems.

1. GitHub Actions security updates remain in a GitHub Actions group.
2. Pre-commit security updates remain in a pre-commit group.
3. Pip security updates remain in a pip group.
4. Npm security updates remain in an npm group.
5. Devcontainer security updates remain in a devcontainers group.

This keeps review ownership clear while still reducing PR volume.

## Group Naming Convention

Use a stable naming pattern so policy tests and PR triage remain predictable.

1. Version-updates group: `{ecosystem}-all`
2. Security-updates group: `{ecosystem}-security`

Examples:

1. `github-actions-all` and `github-actions-security`
2. `pre-commit-all` and `pre-commit-security`
3. `pip-all` and `pip-security`
4. `npm-all` and `npm-security`
5. `devcontainers-all` and `devcontainers-security`

If a new ecosystem is added, use the same suffixes to keep conventions and tests consistent.

## Open Pull Requests Limit

Dependabot uses `open-pull-requests-limit: 10` per configured ecosystem.

This keeps update queues bounded while still allowing concurrent version and security groups during busy weeks. If team review capacity changes, adjust the limit in `.github/dependabot.yml` and update matching policy tests in the same change.

## Adding New Ecosystems Safely

When a new dependency manifest appears (for example `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`), apply this sequence in one change:

1. Add the corresponding `package-ecosystem` block in `.github/dependabot.yml` with the same weekly cadence.
2. Add grouped rules for version and security updates in that new ecosystem block.
3. Update policy tests in `Tests/Utils/ScriptSafetyConventions.Tests.ps1` to encode the new invariant.
4. Update relevant `.llm` documentation/skills if behavior or scope changed.
5. Run index and harness checks.

## Validation Workflow

1. `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1`
2. `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1`
3. `pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path Tests/Utils/ScriptSafetyConventions.Tests.ps1 -Name '*Dependabot*'"`
4. `pre-commit run --all-files`
5. `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1`
