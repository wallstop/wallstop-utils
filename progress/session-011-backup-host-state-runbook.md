# Session 011: backup host-state operator remediation

## Changes

- Added `docs/operator-runbooks/backup-host-state.md` with dry-run-first,
  Windows-host instructions for both reported backup failures.
- Added `Scripts/Powershell/Repair-PowerShellProfilePortability.ps1`, which
  validates the repository profile, previews by default, and on explicit
  `-Apply` creates a timestamped backup before transactional replacement and
  post-write validation.
- Added `Scripts/Komorebi/Repair-KomorebiBackupSource.ps1`, which requires an
  explicit profile name, previews by default, and delegates applied restores to
  the existing transactional Komorebi restore helper.
- Linked the stable PowerShell and Komorebi backup errors directly to the
  runbook and remediation commands.
- Added behavior and policy coverage in
  `Tests/Utils/BackupHostStateRemediation.Tests.ps1`.

## Verification

- New remediation Pester suite passed.
- ScriptSafety and CompatibilityConventions Pester suites passed.
- `Invoke-FullValidation.ps1 -PreflightOnly` passed.
- Targeted compatibility checks passed for all four affected PowerShell files
  with zero findings.
- Both remediation scripts ran successfully in preview mode without changing
  the Linux host.
