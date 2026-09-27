# Session 029 — Modern Git and lazygit experience

Date: 2026-09-26–27

## Objective

Research modern Git configuration, adopt the useful settings for this user, make the
setup reversible and reusable for other users of this repository, and finish with a
PR whose CI and reviewer feedback are fully green.

## Tasks and evidence

- [x] Researched Git, lazygit, and delta behavior using primary documentation and
  versioned source. Decisions and tradeoffs are in `docs/git-experience.md`.
- [x] Implemented `Scripts/Git/Set-GitExperience.ps1` with audit, apply, removal,
  preference preservation, recovery records, and optional delta integration.
- [x] Added isolated Git/YAML behavioral tests and PowerShell installer tests.
  Red runs caught include precedence, removal baseline, null-string binding, and
  UTC timestamp failures; each has a regression test and passing follow-up.
- [x] Applied the profile to this user's Git and lazygit configuration. Audit shows
  all 21 recommended Git keys active; delta is available. Lazygit rendering and
  partial staging were exercised in an isolated repository.
- [x] Final full local validation passed, including pre-commit, deep PowerShell
  tests, skills index, LLM harness, and workspace drift assertion. Both
  PowerShell editions passed 19 installer tests each after review fixes; Python
  passed 12 Git/YAML tests.
- [x] Independent review found and fixed case-sensitive Unix path identity,
  legacy config byte preservation, and UTF-8 BOM placement. Each has a red
  reproduction and green test. A second review found no remaining code issues.
- [x] Commit coherent changes and push the feature branch.
- [x] Open a PR and implement fixes for the first CI failure and review findings.
- [ ] Confirm all required checks green on the final PR head with no unresolved
  reviewer feedback.

## PR and CI iteration

- Opened [PR #86](https://github.com/wallstop/wallstop-utils/pull/86) after two
  coherent commits (`b4d2139` harness repair, `7cbea93` Git profile).
- The first Ubuntu behavior run exposed duplicate `Get-Command chmod` matches:
  `/usr/bin/chmod` and `/bin/chmod` became one invalid `.Source` path. Applied
  first-match selection to every executable lookup in the new installer, swept
  the same class through shared quality/Git helpers and tests, and added focused
  duplicate-PATH regressions. Final CI rerun is pending.
- Bugbot's first review flagged two valid installer recovery issues: a deleted
  managed profile blocked removal, and Unix file replacement tightened an
  existing config's mode to `600`. Added a red deleted-profile test, a Unix
  permission regression, and repaired both paths. Final review/CI is pending.
- Adversarial review found a temporary-file exposure window, a managed-profile
  preparation race, and state-directory symlink chmod risk. New tests caught the
  first two on a red run (2 failures); both PowerShell editions then passed all
  25 installer tests after the fixes. The symlink guard is covered on Unix.
- A further review identified owner/group and extended-attribute loss during
  atomic replacement on Unix. The replacement now copies native metadata and
  checks owner, group, and mode parity before publication. Extended attributes
  are not independently verified; docs state that limit. It also rejects a
  group-readable copy path that would briefly expose bytes to a different group;
  cross-platform CI rerun is pending.
- The first full validation rerun passed pre-commit but exposed a pre-push test
  fixture issue: its temporary Git index rejected an explicitly listed progress
  file because `/progress/` is ignored. Scoped force-add in that temporary-index
  fixture passed all 14 targeted tests. The full gate then passed: all-files
  pre-commit, deep PowerShell and GitHub utility suites, skills/harness checks,
  and workspace drift assertion.
- All CI jobs on `7c7a400` completed green or intentionally skipped, and both
  original Bugbot threads were resolved. A subsequent Bugbot review found that
  mandatory Linux xattr copying contradicted the documented best-effort policy
  on filesystems without xattr support. A one-test red run reproduced the
  abort. Safety review then caught an overly broad fallback; a second red test
  showed an unrelated I/O error could be hidden. The final fallback only retries
  when the error identifies an unsupported xattr operation, warns, and verifies
  owner/group/mode preservation. Both targeted tests passed green and adversarial
  review found no remaining blocker.
- Cross-platform review found the GNU-specific `cp --preserve` flags would fail
  on BusyBox/Alpine. A red test reproduced the unsupported-option failure;
  portable `cp -p` is now used for that case with the same metadata parity check.
  Both PowerShell editions passed all 30 installer tests, and full validation
  passed again before the follow-up commit.

## Environment finding

The host exposes WSL Bash before Git Bash. Repository test paths require Git Bash
and `cygpath` together; full validation passed with Git for Windows `usr/bin` and
`bin` prepended for that process. A separate timestamp failure in the native-tool
cache used a local-time conversion of the Unix epoch; a fixed-date red/green test
now pins UTC behavior on both PowerShell editions.
