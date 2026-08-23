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

Backup orchestration should stage only managed snapshot outputs under `Config/`; any out-of-scope mutations must fail fast rather than being auto-committed.

## Generator Nondeterminism And Whole-File Churn

When a managed snapshot shows whole-file diffs while the underlying data is unchanged,
suspect upstream generator nondeterminism (member/key order), not data drift: some
generators build output from unordered structures so member order varies per invocation
(example: `scoop export` builds each app object from a PowerShell hashtable). Normalize
at the writer rather than hand-sorting committed artifacts: route through
`ConvertTo-CanonicalJsonText -SortObjectKeys` (`Scripts/Utils/Common/CanonicalJsonHelpers.ps1`),
which rebuilds object members in Ordinal key order recursively while staying a
byte-identical fixed point of the `pretty-format-json --no-sort-keys` hook. Formatter
hooks stay order-preserving (`--no-sort-keys`); sorting happens only at the source.

## References

- `.pre-commit-config.yaml`
- `Config/.config/**`
- `README.md`
