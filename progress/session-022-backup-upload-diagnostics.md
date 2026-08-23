# Session 022 — Backup upload diagnostics (issue #46)

## Objective

Issue #46 ("research: Investigate partial git uploads — why?") was the only open issue with
repo-actionable work left (issues #68/#70 repo-side items are complete; their remaining items are
operator actions on the primary Windows host). Main CI was already green and no draft PRs were
open, so this session root-caused the visible upload pathology from repository data alone.

## RCA from repository evidence

1. **Unnamed partial failures.** Every unattended auto-backup since 2026-08-12 committed
   `backup steps failed: 2; 8/10 succeeded` — but the failing step names exist only in host console
   output. Ten days of partial-failure commits were undiagnosable from git history alone.
2. **Whole-file scoopfile.json churn.** Each daily backup rewrote all ~680 lines of
   `Config/scoopfile.json` with zero data change: `scoop export` builds each app object from a
   PowerShell hashtable whose member iteration order differs per invocation, so the member order
   changed every run (observed three distinct orderings across Aug 20–22 commits).
3. **Likely failing steps** (unconfirmed until tomorrow's run names them): `ScoopUpdate` and/or
   `WinGetUpdate`, consistent with the broken package state documented in issue #68 before the
   on-host fixes (thunderbird-esr manifest removed, megatools half-install) and WinGet's
   any-package-failure exit semantics.

## What shipped

1. **`Scripts/Backup.ps1`**: the partial-failure commit message now interpolates failed step names:
   `(backup steps failed: N [StepA, StepB]; X/Y succeeded)`. Future failures self-identify from
   `git log` with no host access.
2. **`Scripts/Utils/Common/CanonicalJsonHelpers.ps1`**: new opt-in `-SortObjectKeys` mode for
   `ConvertTo-CanonicalJsonText`, backed by a new recursive `ConvertTo-JsonNodeWithSortedObjectKeys`
   helper (System.Text.Json.Nodes.JsonNode; Ordinal insertion sort; arrays never reordered; leaves
   round-tripped through exact JSON text so timestamps/number tokens survive verbatim). Duplicate
   member names fail closed (`E_CANONICAL_JSON_SORT_FAILED`; JsonNode.Parse rejects them); missing
   Nodes support degrades loudly once (`W_CANONICAL_JSON_SORT_UNAVAILABLE`). Comma-wrapped returns
   prevent PowerShell pipeline unrolling of JsonObject/JsonArray.
3. **`Scripts/Scoop/ScoopBackup.ps1`**: wrapper passes `-SortObjectKeys`. Because
   `pretty-format-json` runs with `--no-sort-keys`, sorted output remains hook-identical;
   `Config/scoopfile.json` was regenerated once into sorted-canonical form (parsed data verified
   byte-identical to HEAD).

## Tests

- `Tests/Utils/CanonicalJsonHelpers.Tests.ps1`: sorted-order table (incl. empty-string keys and
  Ordinal case ordering), permutation invariance, nested recursion, array-order preservation, leaf
  fidelity, idempotence, JSONC tolerance, scalar-null, duplicate-key fail-closed throw, default-mode
  order preservation, and a committed-artifact guard that `Config/scoopfile.json` is a fixed point
  of BOTH canonicalizer modes.
- `Tests/Scoop/ScoopBackup.Tests.ps1`: key-permutation invariance fixture plus full deterministic
  shape pinning; 5.1-lane skip guards tightened.
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`: policy now pins the names-bearing commit-message
  format and its derivation from `$failedSteps`.

## Validation evidence

- `Invoke-FullValidation.ps1 -PreflightOnly`: pass.
- Pester gates (exit 0): `Tests/Utils/CanonicalJsonHelpers.Tests.ps1`, `Tests/Scoop`,
  `Tests/Utils/ScriptSafetyConventions.Tests.ps1`, `Tests/Utils/BackupDxMessaging.Tests.ps1`,
  `Tests/Utils/CompatibilityConventions.Tests.ps1`.
- `Invoke-CompatibilityChecks.ps1` over the three changed scripts: PASS across 5.1 + pwsh7 profiles.
- Managed `pre-commit run` (staged + full hook set): all hooks Passed, including
  `pretty format json` against the regenerated artifact.

## Review loop

Adversarial reviewer found 4 issues (1 MAJOR: duplicate-key comment documented nonexistent behavior;
silent unsorted degradation; dead defensive branch; coverage gaps). All four were fixed and an
adversarial verifier confirmed each RESOLVED with no new findings ("exceptional, zero issues").

## Follow-ups

- Tomorrow's backup commit will name the two persistently failing steps; if they are
  `ScoopUpdate`/`WinGetUpdate`, RCA continues under issue #46 with concrete evidence.
- Issue #68/#70 remaining items stay operator-side (window-control.ahk redeploy on the primary host).
