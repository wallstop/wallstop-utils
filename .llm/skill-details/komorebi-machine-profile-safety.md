# Komorebi Machine Profile Safety (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/komorebi-machine-profile-safety.md`.

## Profile Selection

Komorebi profile selection is deterministic:

1. explicit `-ProfileName`
2. `WALLSTOP_KOMOREBI_PROFILE`
3. sanitized machine name

Profile names must be path-safe and validated before they are used in repository paths.
Invalid names must fail with a stable `E_KOMOREBI_*` diagnostic instead of being normalized
into a different requested profile.

## Repository Layout

Machine-specific Komorebi snapshots live under:

```text
Config/Komorebi/profiles/<profile>/
  applications.json
  komorebi.bar.json
  komorebi.json
```

Legacy root snapshots under `Config/Komorebi/` may exist during migration, but scripts must not
write them and restore must not silently fall back to them.

## Backup And Restore Invariants

- Backup writes only `Config/Komorebi/profiles/<profile>/` for the selected profile.
- Restore reads only a complete selected profile; it must not silently fall back to another
  machine, a default profile, or legacy root snapshots.
- Source preflight must validate all required files and JSON parseability before any copy.
- Live restore must stage files and preserve rollback semantics so a mid-copy failure does not
  leave mixed old/new Komorebi files in the user profile.
- Legacy root snapshots can be migrated only through explicit migration tooling
  (`Scripts/Komorebi/InitializeKomorebiProfile.ps1`); do not reintroduce implicit root fallback.
- Thin entry scripts should dot-source `Scripts/Komorebi/KomorebiProfileHelpers.ps1` and keep
  profile resolution, validation, and copy behavior in that shared helper.

## Validation

Run focused behavior and policy checks after Komorebi profile changes:

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/KomorebiProfileHelpers.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
```
