# Config Snapshot Safety (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/config-snapshot-safety.md`.

## Scope Exclusions For Encrypted Snapshots

Avoid corrupting app-owned state snapshots during generic formatting and validation.

Keep encrypted and app-managed snapshot paths out of generic JSON structural validators.

## Formatter Boundary Control

Preserve targeted formatter scope for curated source files and avoid broad normalization for opaque snapshots.

## Validation Safety Checks

Treat snapshot-like JSON as data artifacts unless ownership and schema are repository-controlled.

Run focused checks before widening any validator include patterns.

## References

- `.pre-commit-config.yaml`
- `Config/.config/**`
- `README.md`
