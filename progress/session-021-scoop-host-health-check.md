# Session 021 — Scoop host-health check (issue #70)

## Objective

Deliver the repo-side work from issue #70 (the only actionable open follow-up; issue #46 is
blocked on live Windows-host evidence and the remaining #70 item is an operator host action):
implement `Scripts/Scoop/Invoke-ScoopHealthCheck.ps1` so the failure modes found in the
2026-08-22 scoop audit (issue #68) are detected by tooling instead of tribal memory, and close
the `$env:SCOOP_GLOBAL` gap noted during PR #69 review.

## What shipped

1. **`Scripts/Scoop/Invoke-ScoopHealthCheck.ps1`** (new): five independent, low-noise sub-checks,
   each emitting stable-coded findings and a single concise summary; exit 1 when anything needs
   operator attention (surfaced through Backup.ps1's best-effort step summary):
   - `scoop status` anomalies: `Install failed`, `Manifest removed`, `???` missing-version rows
     (`W_SCOOP_HEALTH_STATUS_ANOMALY`); routine update rows are intentionally ignored to keep the
     daily signal clean. Wrapped `Format-Table` continuation rows are never misattributed.
   - Installed-vs-bucket **version inversion** (`E_SCOOP_HEALTH_VERSION_INVERSION_SUSPECTED`):
     detects the audit's `2025 > 2.71.0` semver deadlock by comparing `scoop export` versions with
     local bucket manifests (no network); recommends `scoop uninstall <app> && scoop install <app>`.
   - Junction integrity (Windows-only): missing `apps\<name>\current` (`E_..._CURRENT_LINK_MISSING`,
     the megatools half-install) and replaced-with-real-directory junctions
     (`E_..._JUNCTION_REPLACED`, the Thunderbird self-updater corruption), with per-app probe
     resilience so one locked app cannot abort the scan.
   - Mozilla channel drift (`W_SCOOP_HEALTH_MOZILLA_CHANNEL_DRIFT`): parses the real
     `compatibility.ini` shape `LastVersion=<version>_<buildId>/<prevBuildId>`, pairs Thunderbird
     profiles only with Thunderbird-family packages, flags channel switches AND any segment-wise
     newer profile (Mozilla's downgrade guard triggers on patch regressions too).
   - Orphaned Mozilla helpers under scoop roots with dead parents
     (`W_SCOOP_HEALTH_ORPHANED_MOZILLA_HELPER`) via Win32_Process resolved indirectly for
     cross-version compatibility.
   - Benign absence of `scoop` skips with `W_SCOOP_HEALTH_SCOOP_NOT_AVAILABLE` + exit 0
     (ThunderbirdBackup precedent) so the step never double-reports what ScoopUpdate already fails.
2. **`Scripts/Utils/Common/ScoopInstallRootHelpers.ps1`** (new): shared per-user (`SCOOP`)
   + admin/global (`SCOOP_GLOBAL`, default `ProgramData\scoop`) root resolution; consumed by both
   the health check and ScoopRestore (single-sourced, no drift between consumers).
3. **`Scripts/Scoop/ScoopRestore.ps1`**: Mozilla update-blocking policy deployment now covers
   global installs (previously user-root only), refactored into a per-app helper with unchanged
   merge semantics and stable diagnostics.
4. **`Scripts/Backup.ps1`**: new `ScoopHealthCheck` Windows-only step ordered before `ScoopUpdate`
   so pre-update state is observed.

## Tests

- `Tests/Scoop/Invoke-ScoopHealthCheck.Tests.ps1`: data-driven classifier tables (status parser,
  inversion matrix incl. Int32-overflow degradation, junction code map, Mozilla comparator against
  real-world LastVersion shapes, orphan finder, install-root resolution) plus child-process
  behavioral tests using PATH-shim fake `scoop` commands (unhealthy fixture exits 1 with all three
  seeded codes; healthy exits 0; missing scoop skips benignly; firefox-only installs skip TB drift;
  real NTFS junction layout covered on the Windows lane).
- `Tests/Scoop/ScoopRestoreMozillaPolicies.Tests.ps1`: child-process proof that policies.json lands
  under the user root and additionally under `SCOOP_GLOBAL` when present.

## Review loop

Adversarial reviewer found 10 issues (1 BLOCKER: fictional slash-only LastVersion fixture would
have caused daily ESR false positives; 3 MAJOR incl. a 5.1 strict-mode crash path on the export
sub-check). All 10 were fixed and re-verified by an adversarial verifier (parser-clean, all gates
green, zero rule-11/rule-18 violations).

## Validation evidence

- `Invoke-FullValidation.ps1 -PreflightOnly`: passed at session start.
- `Invoke-PesterQualityGate -TestPath Tests/Scoop`: pass (55+ It blocks).
- `Invoke-PesterQualityGate -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1`: pass.
- `Invoke-CompatibilityChecks -TargetFiles <changed files>`: pass, 0 findings across 5.1 + pwsh7
  profiles.
- Managed `pre-commit run` (repo `.tools/precommit-cli/uv-state` v4.6.2): all hooks Passed,
  including `powershell-format` (no formatting deltas) and the full staged validation wrapper.

## Follow-ups

- Operator (host-side, stays in issue #70): redeploy v2 `window-control.ahk` over
  `%USERPROFILE%\.config\window-control.ahk`; confirm next backup shows no diff for that file.
- Issue #46 remains blocked on a live Windows backup run capturing transport diagnostics.

## Addendum: CI RCA during PR review

1. **winps51 lane exit-1-after-success**: GitHub Actions wraps `shell: powershell|pwsh` run blocks
   with `$ErrorActionPreference='stop'` plus an appended
   `if (Test-Path variable:\LASTEXITCODE) { exit $LASTEXITCODE }`. On cache-miss runners the module
   bootstrap's PSGallery/NuGet native invocations left stale non-zero `LASTEXITCODE`, failing the
   step after "bootstrap passed." Fix: explicit `exit 0` inside the `-NoInvokeMain` guard
   (`Install-PowerShellQualityModules.ps1`), pinned by a structural convention test. Codified as
   context.md Authoritative Rule 29.
2. **pwsh7 lane empty shim capture**: `.ps1` fake CLIs must emit through the pipeline;
   `[Console]::Out.Write` bypasses it so `@(& shim 2>&1)` captures nothing. Shims now use
   `Write-Output`; `Find-ScoopStatusAnomalies` expands multi-line capture elements. Codified in the
   context.md PATH-shim bullet.
3. Bugbot review loop drove three real fixes: real-world `LastVersion=<version>_<buildId>/<prev>`
   parsing shape, per-shell quote escaping for shims, and equal-prefix precondition on the
   longer-profile downgrade rule.

Post-work self-improvement executed via proposer/adversarial-resolver loop; the adversarial pass
corrected the initial `$?`-poisoning narrative to the runner's `LASTEXITCODE` wrapper mechanics and
scoped Rule 29 forward-looking (five existing workflow-invoked scripts intentionally not swept).
