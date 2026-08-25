# Session 023 — Backup upload RCA: push-blocking blob, snapshot self-heal, failure artifact (issue #46)

## Objective

Continue issue #46 with the evidence session-022 set up: the 2026-08-23 backup commit was the
first to name its failing steps. Also drive open dependency PR #73 and keep main green.

## Evidence read from the named-steps commit (5f9086c, local-only)

1. **Failing steps**: `PowershellBackup`, `WinGetUpdate` (10/12 succeeded). Session-022's
   prediction was half right (`WinGetUpdate`); `ScoopUpdate` now passes, corroborating the
   issue #68 host fixes visible in the same commit's scoopfile data (innounp `2025` → `2.71.0`
   deadlock resolved, megatools installed, thunderbird-esr → thunderbird migrated).
2. **Why uploads stayed partial — root cause**: the same commit added
   `Config/.config/vllm/nccl/cu12/libnccl.so.2.18.1` at **291,649,520 bytes (~278MB)**, nearly 3x
   GitHub's 100MiB blob limit. Every `git push origin main` since 2026-08-23 fails at upload,
   while later backups keep stacking commits on the unpushable tip. This is the mechanism behind
   "latest main auto-uploads look partial".
3. **Regression riding along**: the backup also clobbered `Config/.config/window-control.ahk`
   back to AHK v1 host drift (the exact failure class fixed in session-020). Attended commits
   self-heal via the pre-commit auto-repair hook; unattended backups use `--no-verify` and skip it.

## What shipped

1. **Repaired main directly** (automation artifact, unpushed so amend-safe): dropped the vllm
   blob from the backup commit, restored the v2 AHK mirror, pushed `50f345b`. Largest tracked
   file is now ~442KB.
2. **`Scripts/Backup.ps1` fail-closed oversize guard**: `Get-BackupOversizedManagedFileErrors`
   scans managed changed files before staging — fail >95MB (`E_BACKUP_MANAGED_FILE_OVERSIZE`,
   skips commit/push), warn >10MB (`W_BACKUP_MANAGED_FILE_LARGE`). No unpushable commit can ever
   be created again.
3. **Unattended AHK snapshot self-heal**: `Repair-BackupManagedAhkSnapshots` runs the existing
   `Invoke-WindowsLanguageChecks.ps1 -Fix -StaticOnly` over managed changed
   `Config/.config/*.ahk` files before staging (single-sourced policy with the attended hook).
   Unfixable drift fails closed via `E_BACKUP_SNAPSHOT_REFRESH_FAILED`.
4. **Persistent failure-reason artifact**: `Config/backup-step-failures.json` records failed step
   names, error messages, and bounded output previews (40 lines / 4000 chars head+tail) in
   canonical JSON (no timestamps; deterministic), written before staging so the next successful
   run commits it; removed after a fully successful run. Step runner now captures output
   (`2>&1`) and echoes it, preserving attended visibility while making failures diagnosable from
   git history alone. Phase failures (snapshot-refresh/oversize) land in the same artifact.
5. **`.gitignore`**: `Config/.config/vllm/` ignored as machine-generated ML runtime cache.
6. **PR #73 incorporated**: devcontainers node feature `1.7.1` → `2.1.0` (major bump `:1`→`:2`);
   updated the hardcoded pins in `Tests/Devcontainer/Devcontainer-Config.Tests.ps1` and
   `.github/workflows/devcontainer-validate.yml`; Devcontainer-Config suite green.
7. **Runbook**: `docs/operator-runbooks/backup-host-state.md` gained "Reading failure reasons
   after an unattended run" covering the artifact and both git-phase guards.
8. **Conventions suite**: two new policy Its pinning output capture, artifact schema/removal,
   refresh-gate invocation/fail-closed behavior, and oversize thresholds.

## Validation

- Pester: ScriptSafetyConventions 278/278, Devcontainer-Config 22/22, CanonicalJson/ScoopBackup/BackupDxMessaging/BackupHostStateRemediation 60/60.
- PSScriptAnalyzer (repo settings): Backup.ps1 zero findings; AST unused-function check passes.
- Behavioral probes: canonical artifact JSON round-trip/fixed-point verified; scratch in-repo drift pair refreshed from v2 source via the exact checker invocation Backup now uses; staged-only drift proven visible to HEAD-relative enumeration but invisible to index-relative diffs.

## Review loops

1. **Adversarial reviewer** (sub-agent) found 4 MAJOR + minors; all fixed in `26db3d8`:
   `-File` array misbinding broke the refresh gate for >=2 drifted snapshots (targets now
   ';'-joined into one argument); index-relative enumeration let staged-only drift bypass
   oversize/AHK/secret guards (now diffs against HEAD); the artifact bypassed secret hygiene
   (now sanitized/scanned/redacted before any commit); git-phase reasons were stranded when
   guards failed closed (artifact now committed and pushed by itself, path-limited).
2. **Cursor Bugbot** round 1 reviewed the pre-fix commit with 5 findings; all fixed in
   `369a7ce`: path-limited diagnostics commit (index-wide commit would have published exactly
   what guards rejected), hygiene text-cache reset before re-scan (stale cache always deleted
   the redacted artifact), scalar-composed JSON serialization (5.1 collapses single-element
   arrays), skip persistence when hygiene deleted the artifact, EAP=Continue scoping for
   artifact git captures. **Bugbot round 2 on `369a7ce`: success, zero findings.**
3. Sub-agent verifier was unavailable twice (provider outage); verification ran on the main
   thread per GOAL fallback, including empirical probes of each claimed fix.

## Final state

- PR [#75](https://github.com/wallstop/wallstop-utils/pull/75): all workflow checks green
  (PS 5.1, PS 7+, pre-commit Linux, devcontainer post-create, Windows language fast lane,
  compat gate, validation summary); Cursor Bugbot clean; PR mergeable. The only non-success
  check is `copilot-pull-request-reviewer`, which reports a Copilot quota limit on the
  account ("unable to review... reached their quota limit") - external bot limitation, not a
  code check, and it does not gate mergeability.
- Main repaired and pushed ahead of this branch (`50f345b`) so tonight's scheduled host
  backup can push again.
- Issue #46 RCA comment posted linking evidence and fixes.

## Open items

- Next host backup should be fully green or hand us `PowershellBackup`/`WinGetUpdate` reasons via
  the new artifact (PLAN tracks this).
- Issue #70 operator action (redeploy v2 `window-control.ahk` on the host) still pending; until
  then each backup shows a transient mirror diff that self-heals before commit.
- Copilot code review never ran on PR #75 due to account quota; if a human review is desired
  later, re-request once quota resets.
