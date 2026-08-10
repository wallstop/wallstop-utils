# Session 012: verified host-state snapshot

## Finding

Issue #53's required fresh Windows export is present on `origin/main` in backup
commit `829e815f0970f7027c8c6653d80ef4400dc5d760` (August 9, 2026 at
20:19:22 -07:00). The commit contains the four host-generated artifacts that
establish the Scoop and PowerToys refresh:

- `Config/scoopfile.json`
- `Config/.config/scoop/config.json`
- `Config/PowerToys/UpdateState.json`
- `Config/PowerToys/settings-telemetry.json`

The embedded values, rather than checkout filesystem mtimes, verify freshness:

- Scoop's `last_update` is `2026-08-09T20:00:10.2076691-07:00`.
- The Scoop export includes bucket refreshes through August 9, including main
  and extras.
- PowerToys' update-check epoch `1786308792` resolves to
  `2026-08-09T20:53:12Z`.
- PowerToys telemetry `last_send_time` is `1786293709`, also from August 9.

The backup commit reported two unrelated fail-closed source checks (8/10
steps succeeded), but the Scoop and PowerToys artifacts above were included in
that commit and are independently valid JSON. The repository now records the
snapshot as complete; issue #53 can be closed after the green PR merges.

## Verification

- Confirmed `829e815` is an ancestor of `origin/main`.
- Confirmed the four artifacts changed in that commit and remain present on
  `origin/main`.
- Parsed all four files with `jq`.
- Confirmed the embedded timestamps are August 9, 2026 and not materialization
  timestamps from the Linux workspace.
