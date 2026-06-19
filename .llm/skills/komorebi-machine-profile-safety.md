<!-- trigger: komorebi, machine profiles, machine-specific config, komorebi backup, komorebi restore | Keep Komorebi backup/restore profile-scoped across shared machines | Platform | skill-details/komorebi-machine-profile-safety.md -->

# Komorebi Machine Profile Safety

Lightweight skill card for Komorebi backup/restore changes that must preserve machine-specific profiles in `Config/Komorebi/profiles/<profile>/`.

- Expanded guide: [Komorebi Machine Profile Safety (Expanded)](../skill-details/komorebi-machine-profile-safety.md)

## Core concepts

- [Profile selection](../skill-details/komorebi-machine-profile-safety.md#profile-selection)
- [Repository layout](../skill-details/komorebi-machine-profile-safety.md#repository-layout)
- [Backup and restore invariants](../skill-details/komorebi-machine-profile-safety.md#backup-and-restore-invariants)
- Quick check: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/KomorebiProfileHelpers.Tests.ps1 -OutputVerbosity None`
