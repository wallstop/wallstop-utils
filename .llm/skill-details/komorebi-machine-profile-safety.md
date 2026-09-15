# Komorebi Machine Profile Safety (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/komorebi-machine-profile-safety/SKILL.md`.

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

## Monitor And Layout Invariants

Komorebi pairs each connected display with a `monitors[]` entry in two tiers
(`StaticConfig::postload`, komorebi v0.1.41):

1. A `display_index_preferences` entry whose value **exactly equals** the display's
   `serial_number_id` or `device_id`.
2. Otherwise, the first `monitors[]` index that is neither reserved by *any*
   `display_index_preferences` entry nor already consumed.

Two consequences drive the invariants below:

- **`display_index_preferences` values are display identifiers, never GDI display names.**
  `"DISPLAY1"` matches neither `serial_number_id` nor `device_id`, yet the entry still
  reserves `monitors[0]`. When every index is reserved by an unmatched entry, tier 2 finds
  nothing, **every** display silently falls back to the Komorebi defaults (unnamed
  workspaces, BSP layout), and nothing is logged. Read the real values from
  `komorebic monitor-information`; prefer `serial_number_id`, which survives a port change.
- **`monitors[]` order is display-enumeration order, not physical order.** Windows may
  enumerate a left-hand panel second, so a `monitors[]` array written left-to-right can put
  the "Right" workspace on the left-hand display.

Codified invariants (`Scripts/Komorebi/KomorebiProfileHelpers.ps1`, exercised by
`Tests/Utils/KomorebiProfileHelpers.Tests.ps1`):

| Error code | Invariant |
| --- | --- |
| `E_KOMOREBI_MONITOR_CONFIG_UNASSIGNED` | Every connected display resolves to a `monitors[]` entry. |
| `E_KOMOREBI_MONITOR_LAYOUT_POSITION_MISMATCH` | Positional workspace names (`Left`/`Middle`/`Center`/`Right`) follow the displays' physical left-to-right order. |
| `E_KOMOREBI_DISPLAY_PREFERENCE_INDEX_INVALID` | `display_index_preferences` keys are numeric and index an existing `monitors[]` entry. |
| `E_KOMOREBI_DISPLAY_PREFERENCE_DUPLICATE` | No display id is mapped to two `monitors[]` indexes. |
| `E_KOMOREBI_MONITOR_CONFIG_NOT_APPLIED` | The running Komorebi actually applied the configured workspace names and layouts. |

`Scripts/Komorebi/StartKomorebi.ps1` and `Scripts/Komorebi/RestartKomorebi.ps1` run
`Assert-KomorebiLiveConfiguration` after `komorebic start` (`komorebic monitor-information`
needs a running Komorebi) and print the resolved display-to-workspace mapping. A preference
that matches no connected display is *not* an error on its own - Komorebi caches that config
for reconnect - so docked and undocked setups still pass.

RDP can expose a display with no serial number and a `Default_Monitor-*` device id.
Physical-display preferences still reserve their indexes while those displays are
disconnected. The `spicy` profile therefore keeps an unreserved `monitors[3]` entry
with workspace name and layout `Grid`; one unmatched display receives it through
sequential fallback. This supports a single unknown display, including the observed
RDP display, and does not automatically switch profiles on RDP connection. Additional
unmatched displays require additional unreserved entries. Preserve the physical
preferences and cover both the RDP assignment and physical-display layouts in
`Tests/Utils/KomorebiProfileHelpers.Tests.ps1`.

The checked-in profiles under `Config/Komorebi/profiles/` are validated statically by the
same helper, so a bad `display_index_preferences` value cannot be committed.

## Validation

Run focused behavior and policy checks after Komorebi profile changes:

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/KomorebiProfileHelpers.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
```
