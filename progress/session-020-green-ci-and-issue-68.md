# Session 020: Green main CI, issue #68 hardening, devcontainer completion

## Objective

Restore a green `main` (two failing Script Quality lanes), carry forward the
uncommitted devcontainer/OpenCode work, incorporate the open Dependabot
dependency, and advance issue #68 follow-ups.

## Main CI RCA and fixes

### 1. `pre-commit full repo (Linux)` — corrupted Komorebi profile JSON

- Failure: `E_CI_PRECOMMIT_HOOK_FAILURE: Non-autofix hook failure(s):
  check-json pretty-format-json` on every push since 2026-08-12.
- Root cause chain:
  1. Commit `06a1a3a` introduced
     `Config/Komorebi/profiles/spicy/applications.json` with
     `"1Password": [REDACTED]` in place of `"1Password": {` — invalid JSON.
  2. The corruption came from the backup secret-redaction pattern
     (`Get-BackupSecretHygieneKnownSecretFieldPattern`): the key-name match was
     unanchored, so it matched the substring `Password` inside the key
     `1Password`, and its unquoted-value branch `[^\s,\r\n#;]+` consumed the
     structural `{`. Backup commits run `git commit --no-verify`, so the drift
     landed directly on `main`.
- Fixes:
  - `Scripts/Utils/Common/BackupSecretHygieneHelpers.ps1`: key match now
    requires no preceding `[A-Za-z0-9]` (blocks mid-word matches while still
    redacting snake_case keys like `DB_PASSWORD`); unquoted-value branch now
    excludes `{`, `}`, `[`, `]` so structural JSON/YAML characters are never
    rewritten.
  - Repaired `Config/Komorebi/profiles/spicy/applications.json` (verified valid
    JSON and a byte-exact fixed point of the canonicalizer).
  - Data-driven regression tests in `Tests/Utils/BackupSecretHygiene.Tests.ps1`
    cover the corruption class (structural positions survive sanitization) and
    continued redaction across quoted-JSON/env/snake_case/YAML shapes.

### 2. `PowerShell tests (PowerShell 7+)` — AHK v1 regression

- The same backup commit reverted `Config/.config/window-control.ahk` to v1
  syntax without `#Requires AutoHotkey v2.0`; policy test "all repository AHK
  scripts ... declare #Requires AutoHotkey v2" fails deterministically.
- Fix: the working tree already held the prior session's v2 repair; validated
  it against CI content via a clean `git archive` simulation (274/274 pass) and
  committed it.

### Local-environment test robustness (same failure class)

- `Tests/Utils/PreCommitPrePushValidationHook.Tests.ps1`: five sites captured
  `git hash-object` output with `2>&1` and took `Select-Object -First 1` as the
  blob SHA; on hosts where git prints warnings (for example this workspace's
  Windows-path `safe.directory` entries), the SHA is not the first line and
  `update-index --cacheinfo` fails with exit 128. Added
  `Get-TestBlobShaFromGitHashOutput` (SHA-shaped extraction + explicit throw)
  used by all five sites.
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1`: PTY end-to-end tests
  failed opaquely ("got: ") because this container's `python3` has a stripped
  standard library (no `pty`). Added a capability probe requiring the exact
  driver imports so such hosts skip explicitly while healthy hosts keep full
  enforcement.

## Devcontainer/OpenCode carry-forward (audited by sub-agent)

- Verified post-start.sh ownership self-heal wiring, OpenCode bootstrap mirroring
  the Codex contract, node-feature pinning, docs consistency, and bounded
  HookTimeout execution.
- Gap fixed: `.devcontainer/devcontainer-lock.json` was orphaned (zero repo
  references). The devcontainer-validate workflow now validates existence,
  feature pinning parity with `devcontainer.json`, digest shape, and
  integrity/resolved agreement; Pester coverage asserts the contract.
- Validation: `Tests/Devcontainer` 117 passed / 0 failed; `bash -n` both shell
  entrypoints; actionlint clean on the workflow.

## Issue #68 follow-ups implemented

- `Scripts/Scoop/ScoopRestore.ps1`: after a successful import, deploys
  `%SCOOP%\persist\<app>\distribution\policies.json`
  (`DisableAppUpdate`/`DisableTelemetry`) for every installed
  `thunderbird*`/`firefox*` app; idempotent, non-fatal per-app failures with
  `W_SCOOP_RESTORE_MOZILLA_POLICY_FAILED`.
- New `Scripts/Thunderbird/ThunderbirdBackup.ps1` step: backs up
  `%APPDATA%\Thunderbird\profiles.ini` to `Config/Thunderbird/profiles.ini`;
  missing source is `W_THUNDERBIRD_BACKUP_SOURCE_MISSING` + exit 0 (never a
  failed backup step), copy failures are `E_THUNDERBIRD_BACKUP_COPY_FAILED`.
  Registered as a Windows step in `Scripts/Backup.ps1`.
- Runbook: `docs/operator-runbooks/scoop-host-audit-recovery.md` covering the
  innounp semver deadlock workaround, junction-corruption recovery ordering,
  and profile-downgrade/channel-drift recovery.
- Policy coverage added in `Tests/Utils/ScriptSafetyConventions.Tests.ps1`.

## Dependency

- Incorporated Dependabot PR #67 into this branch:
  `requirements.txt` pre-commit 4.6.1 → 4.6.2.

## Follow-ups / open items

- Scoop health-check script (`scoop status` triage, version-inversion
  detection, junction integrity, Mozilla channel drift, orphaned helpers) from
  issue #68 remains open — intentionally deferred to keep this PR reviewable.
- Operational: redeploy the v2 `window-control.ahk` on the primary host;
  otherwise future backups can re-commit the v1 regression (same mechanism that
  broke the pwsh7 lane). Restore-from-repo is the fix path.
- No GitHub API credentials were available in this environment, so issue
  creation/commenting had to be documented here instead of filed remotely.

## Validation summary

- Targeted Pester gates: secret hygiene 10/0 (two added corruption-vector
  cases plus residue fail-closed case), devcontainer 117/0,
  PreCommitPrePushValidationHook green, Get-UnresolvedPRComments green,
  ScriptSafetyConventions green (policy additions included).
- `Run-PreCommitValidation -TargetFiles` over changed PowerShell: pass.
- Full validation (`Invoke-FullValidation.ps1`) executed at session close.

## PR review cycle

- Published as PR #69 (`agent/green-main-ci-and-scoop-hardening`); follow-up
  issue #70 filed for the deferred Scoop health-check script and the host-side
  v2 `window-control.ahk` redeploy.
- Adversarial sub-agent review found additional members of the redaction
  corruption class; fixed in-session:
  - escaped quotes inside JSON string values (`\"`) now terminate correctly;
  - YAML doubled-quote values and block-scalar indicators no longer corrupt;
  - comma-truncated unquoted redactions now fail closed via a new
    `known-field-redaction-residue` high-confidence scan pattern;
  - Mozilla `policies.json` deployment merges into existing enterprise
    policies through strict-mode-safe `PSObject.Properties` access (Cursor
    Bugbot finding) instead of clobbering or throwing under
    `Set-StrictMode`;
  - Thunderbird profiles.ini copy normalizes to hook-canonical text (LF,
    single trailing newline, UTF-8 no BOM) because unattended backups bypass
    hooks.
- First PR CI run caught one more environment-class failure: the new PTY
  python capability probe ran on Windows PowerShell 5.1, where native stderr
  under EAP=Stop becomes a terminating error inside BeforeAll. Probe is now
  Unix-gated so Windows hosts take the explicit skip path.
- Final PR head: all Script Quality lanes green (pwsh7, winps51,
  pre-commit-linux, windows-language, macOS AppleScript, devcontainer,
  github-utility-coverage, Validation summary). Copilot reviewer reported its
  own quota exhaustion (not a code finding); Cursor Bugbot's single Medium
  finding was fixed as described above.
