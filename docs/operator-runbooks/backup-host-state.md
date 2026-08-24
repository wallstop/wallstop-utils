# Backup host-state recovery runbook

Use this runbook when `Scripts/Backup.ps1` reports a PowerShell profile
portability failure or a missing Komorebi source file. The backup checks are
intentionally fail-closed: do not bypass them with `--no-verify`, by editing the
error text, or by copying a different machine's snapshot.

Run these commands from the repository root in an elevated or normal Windows
PowerShell session as appropriate for the destination paths. `pwsh` is
preferred; use `powershell.exe` when PowerShell 7 is unavailable.

## Reading failure reasons after an unattended run

Unattended backups commit with `--no-verify`, so console output is lost on the
host. Two persistent diagnostics survive in git history instead:

- The commit message names failing steps:
  `(backup steps failed: N [StepA, StepB]; X/Y succeeded)`.
- `Config/backup-step-failures.json` records each failed step's error message
  plus a bounded output preview, and is committed alongside the snapshot on the
  next successful run. A fully successful run deletes it again.

To diagnose a partial backup, read the artifact from the first commit that
shows no failures after the bad run:

```powershell
git show HEAD:Config/backup-step-failures.json
```

Git-phase guards also record into that artifact (recovered on a later
successful run): `E_BACKUP_SNAPSHOT_REFRESH_FAILED` means a `Config/.config`
AutoHotkey snapshot drifted to AHK v1 and could not be refreshed from its
`Scripts/AutoHotKey` source (fix the source), and
`E_BACKUP_MANAGED_FILE_OVERSIZE` means a managed file exceeded 95MB — GitHub
rejects blobs over 100MiB, which would strand the entire backup push. Remove
the offending host file or add a targeted `.gitignore` rule for genuine
machine-generated state (see the `Config/.config/vllm/` rule for precedent).

## 1. Repair the PowerShell profile

Preview the repair first. The default destination is the current user's
current-host profile, and preview mode does not write anything:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Powershell\Repair-PowerShellProfilePortability.ps1
```

Apply the repair only after confirming the destination. The script creates a
timestamped copy of the existing profile beside it, then replaces it with the
validated repository profile and validates the result:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Powershell\Repair-PowerShellProfilePortability.ps1 -Apply
```

To target a specific profile path:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Powershell\Repair-PowerShellProfilePortability.ps1 `
    -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1" `
    -Apply
```

This replaces the selected profile with the repository's guarded PSReadLine
profile. Review the timestamped backup if the live profile contained custom
commands that need to be merged manually.

## 2. Restore a Komorebi source profile

List the repository profiles and choose the intended machine profile. Do not
use `default` unless it is actually the desired host configuration:

```powershell
Get-ChildItem .\Config\Komorebi\profiles -Directory | Select-Object -ExpandProperty Name
```

Preview the selected profile restore:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Komorebi\Repair-KomorebiBackupSource.ps1 `
    -ProfileName workstation-42
```

Apply it only with the explicit `-Apply` switch. The existing transactional
restore helper validates all three JSON files and rolls back if replacement
fails:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Komorebi\Repair-KomorebiBackupSource.ps1 `
    -ProfileName workstation-42 `
    -Apply
```

Use `-UserProfileRoot` when Komorebi is configured under a deliberately
different user-profile directory. The selected repository profile must be
complete and valid; the remediation never falls back to another profile.

## 3. Verify and rerun the backup

After both repairs, run the backup in the same host context used by Task
Scheduler:

```powershell
pwsh -NoLogo -NoProfile -File .\Scripts\Backup.ps1 -Unattended
```

The expected result is zero failed backup steps. Confirm that generated Scoop
and PowerToys artifacts contain current embedded timestamps, then run the
repository validation/pre-commit workflow before publishing changes.

If either source check still fails, stop and investigate the reported path.
The repository must not silently substitute a stale profile or a different
machine's Komorebi configuration.

## Non-Windows hosts

`Config/.config` is a Windows host-state snapshot. `ConfigBackup.ps1` exits
successfully with a warning on Linux and macOS without modifying that snapshot;
run the backup on Windows when it needs to be refreshed. This prevents a
partial container or developer-environment `.config` directory from replacing
the Windows snapshot.
