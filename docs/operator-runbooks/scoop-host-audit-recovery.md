# Scoop host audit recovery runbook (2026-08-22)

Use this runbook when Scoop installs or updates fail with extraction errors,
`scoop status` reports `Install failed` / `Manifest removed`, or a Mozilla app
installed through Scoop stops resolving after a self-update. The failure modes
below were observed on the primary Windows host and tracked in issue #68.

## 1. innounp version deadlock ("setup files are corrupted")

Symptom: installing an Inno Setup-based package (for example
`extras/ollama-full`) fails during extraction with
`innounp ... Critical error: The setup files are corrupted.`

Root cause: the installed `innounp` version string can be a transitional
manifest name such as `2025`. Scoop's semver comparison treats `2025` as newer
than every real release (`2.71.0`), so `scoop update innounp` reports
`(latest version)` forever while the bucket offers a real upgrade. The stale
innounp then cannot unpack installers built with newer Inno Setup versions.

Recovery: reinstall the package to replace the dead version string:

```powershell
scoop uninstall innounp
scoop install innounp
scoop reset innounp
```

Then retry the original install. If a future audit finds an installed version
that is not valid semver but blocks a real bucket update, prefer the same
uninstall/reinstall cycle over manifest edits.

## 2. Thunderbird/Firefox junction corruption from the in-app updater

Symptom: `scoop status` shows `<app>: Manifest removed`; `scoop info <app>`
cannot resolve the manifest even though the bucket JSON exists.

Root cause: Mozilla's internal updater runs from inside the
`apps\<name>\current` junction, replaces it with a real directory, and guts the
real version directory (often only `updater.exe` survives). Scoop's
bookkeeping requires `<version>\install.json`, so the app becomes
unresolvable. Firefox processes launched by Thunderbird inherit the corrupted
directory as their CWD and block cleanup; orphaned helper processes
(`crashhelper.exe`, `updater.exe`, `pingsender.exe`) pin executables in the old
directory.

Recovery, in this order (closing browsers first matters because Windows child
processes inherit CWD handles):

```powershell
# 1. Close Thunderbird/Firefox, then kill orphaned Mozilla helpers.
Get-Process -Name "thunderbird*","firefox*","crashhelper","updater","pingsender" -ErrorAction SilentlyContinue |
    Stop-Process -Force

# 2. Purge the broken app installation.
scoop uninstall thunderbird

# 3. Remove leftover directories scoop could not delete.
Remove-Item -LiteralPath "$env:SCOOP\apps\thunderbird" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Reinstall.
scoop install thunderbird
```

Prevention: `Scripts/Scoop/ScoopRestore.ps1` deploys
`%SCOOP%\persist\<app>\distribution\policies.json` with `DisableAppUpdate` for
every installed `thunderbird*`/`firefox*` app. Verify the file exists after a
restore; without it the in-app updater will eventually corrupt the layout
again.

## 3. Profile downgrade guard after channel drift

Symptom: after reinstalling `thunderbird-esr` at an older ESR version,
Thunderbird refuses to start: "You have launched an older version of
Thunderbird."

Root cause: the live profile was written by a newer release channel build
(for example release `153.0.3` after ESR drift), and downgrading is blocked to
protect the profile. Additionally, per-install `[Install*]` sections in
`profiles.ini` can point new installs at fresh empty profiles instead of the
real one.

Recovery: forward-upgrade past the profile version (preferred), then re-point
the install default at the real profile:

1. Install the regular (non-ESR) package so the on-disk version is >= what the
   profile last ran: `scoop uninstall thunderbird-esr && scoop install
   thunderbird`.
2. Back up `%APPDATA%\Thunderbird\profiles.ini`, then rewrite its
   `[Install<HASH>]` `Default=` entries to the real profile directory. Keep the
   timestamped backup beside the file.
3. Start Thunderbird once and confirm the accounts load before deleting any
   backup.

The repository backs up `%APPDATA%\Thunderbird\profiles.ini` to
`Config/Thunderbird/profiles.ini` during each backup run
(`Scripts/Thunderbird/ThunderbirdBackup.ps1`); restore that copy first when
repairing profiles.ini on a damaged host.
