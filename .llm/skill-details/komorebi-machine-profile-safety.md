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

During startup or static-configuration reload, Komorebi pairs each connected display
with a `monitors[]` entry in two tiers
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
For single-monitor RDP, the `spicy` profile maps the observed device
`Default_Monitor-1&c528b8a&1&UID256` explicitly to `monitors[3]`, using `Scrolling`
with one visible column and zero workspace/container padding. Physical-display
preferences and layouts remain in slots 0–2. An unreserved `monitors[4]` entry uses
the same configuration for a single unknown monitor during startup or static
configuration reload. This scrolling behavior is limited to a single connected
monitor: v0.1.41 `StaticConfig::postload` replaces `Scrolling` with `Columns` when
more than one monitor is connected.

<!-- v0.1.41 StaticConfig::postload and monitor_reconciliator use different paths. -->
Sequential fallback during static configuration loading does not establish hotplug
behavior. In v0.1.41, a newly constructed monitor starts with BSP;
`monitor_reconciliator` restores cached configuration for preferred or previously
seen display IDs, rather than assigning the unreserved static fallback. Explicit
mapping therefore supports reconnecting the known RDP display. If its ID changes,
run `komorebic replace-configuration "$HOME/komorebi.json"` to apply the unreserved
fallback, then update the mapping for future starts. Obtain the new ID from
`komorebic monitor-information`; do not bind to the changing `DISPLAY*` name.

Existing whkd bindings provide `Alt+Left/Right` focus and `Alt+Shift+Left/Right`
reordering. Each ordinary tiled window fills the usable work area, preserving the
taskbar and title bar. Up/Down bindings retain their native behavior. Floating or
ignored windows and explicitly created multi-window stacks retain their semantics.

Cover the explicit single-monitor RDP assignment, single unknown-monitor
startup/reload fallback, and unchanged physical-display layouts in
`Tests/Utils/KomorebiProfileHelpers.Tests.ps1`. Assert the scrolling column count
and workspace/container padding alongside the layout. Static assignment tests do
not prove live reconnect behavior or upstream multi-monitor layout conversion;
validate those separately against the running Komorebi version. The live assertion
helper checks names/layouts, so also inspect `komorebic state` for layout options,
padding, focus, container order, and geometry when verifying scrolling behavior.
When window handling is asynchronous, wait for the expected live state before
issuing the next dependent command or asserting geometry; CLI completion alone
does not prove the transition has settled. Restore temporary floating state,
window order, and focus after live experiments.

The checked-in profiles under `Config/Komorebi/profiles/` are validated statically by the
same helper, so a bad `display_index_preferences` value cannot be committed.

## Validation

Run focused behavior and policy checks after Komorebi profile changes:

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/KomorebiProfileHelpers.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/ScriptSafetyConventions.Tests.ps1 -OutputVerbosity None
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
```
