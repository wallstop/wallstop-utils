# Session 007: native analyzer lane

## Scope

Advance issue #43's warnings-as-errors milestone by making the existing managed
StyLua and actionlint non-zero exit contract explicit and regression-tested.

## Changes

- Added focused Pester coverage for non-zero StyLua check and fix runs.
- Added focused Pester coverage for non-zero actionlint runs.
- Updated `PLAN.md` to mark the managed native analyzer lane complete.

The implementation already failed closed with stable `E_STYLUA_FORMAT_REQUIRED`,
`E_STYLUA_FAILED`, and `E_ACTIONLINT_FAILED` diagnostics; this session codifies
that behavior without changing tool scope, timing, or pinned assets.

## Verification

- Targeted native quality suite passed.
- Script-safety suite passed.
- Repository preflight passed.
- Full-suite audit exposed and the Pester 4-to-5 mock assertion sweep fixed 104 legacy calls; the affected suites pass, including the GitHub suite after adding default `Get-Command` mocks required by Pester 5.
- Full repository Pester suite passed with `GIT_CONFIG_GLOBAL=/dev/null`; the clean Git config avoids unrelated invalid Windows `safe.directory` entries injected by the host environment.
