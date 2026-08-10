# Session 009: managed-dirty backup preflight

## Finding

The Windows backup command was run on a worktree containing four managed
`Config/` changes plus unrelated `PLAN.md` changes. The old all-or-nothing dirty
tree preflight did not distinguish those cases and gave no scoped recovery path.

## Changes

- `Scripts/Backup.ps1` now rejects out-of-scope pre-existing changes while
  allowing managed `Config/` drift to proceed.
- Managed drift is stashed before `git pull --ff-only origin main`, restored with
  `stash pop --index`, and protected by explicit stash/reference/restore failure
  diagnostics.
- README, repository context, and safety policy coverage document the contract.

## Verification

- `Backup.ps1` parses successfully.
- Script-safety Pester coverage passes after updating structural assertions.
- Targeted PowerShell compatibility checks pass with zero findings.
- Scoped pre-commit hooks pass after the formatter stabilized the script.
- The full validation wrapper reaches deep PowerShell validation, but its
  isolated repository fixture suite fails on the repository's existing
  simulated `.git/index.lock` recovery cases; this is unrelated to the backup
  change and is recorded in the validation artifact under `/tmp`.
- The current worktree still correctly fails because `PLAN.md` and the active
  implementation/test edits are out of scope; no backup mutation or stash occurs.
