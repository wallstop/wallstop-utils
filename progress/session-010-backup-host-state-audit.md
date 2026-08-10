# Session 010: backup host-state audit

## Finding

The backup commit at `829e815` reports two expected fail-closed source checks:

- `PowershellBackup` rejects the live `CurrentUserCurrentHost` profile because
  its PSReadLine prediction options are not guarded for Windows PowerShell 5.1.
- `KomorebiBackup` rejects the live user profile because the required
  `applications.json` source is absent.

The repository snapshots and safety contracts are already aligned with these
requirements. The Linux workspace cannot repair the Windows/OneDrive profile or
regenerate Komorebi state under the Windows user profile. `gh auth status` also
confirms that this workspace has no GitHub credentials for issue/PR operations.

## Verification

- `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly` passed.
- Focused Pester gates for `KomorebiProfileHelpers.Tests.ps1`,
  `CompatibilityConventions.Tests.ps1`, and `ScriptSafetyConventions.Tests.ps1`
  completed without a reported failure.
- The Linux PowerShell host has no user profile files at either discovered
  `$PROFILE` path, so it cannot produce a meaningful Windows backup artifact.
- `PLAN.md` item “Refresh and publish a verified-current Scoop and PowerToys
  host-state snapshot” remains open because the checked-in timestamps are stale
  relative to the current workspace date.

## Required external follow-up

On the Windows host, first restore/update the source PowerShell profile so the
PSReadLine portability check passes, then restore the Komorebi source files (or
disable/remove that installation only through an explicitly scoped operational
decision). Re-run the full backup and capture a fresh Scoop/PowerToys export
before publishing the green PR.
