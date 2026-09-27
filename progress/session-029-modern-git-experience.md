# Session 029 — Modern Git and lazygit experience

Date: 2026-09-26

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
- [ ] Commit coherent changes and push the feature branch.
- [ ] Open a PR and address every substantive review finding and CI failure.
- [ ] Confirm all required checks green on the final PR head with no unresolved
  reviewer feedback.

## Environment finding

The host exposes WSL Bash before Git Bash. Repository test paths require Git Bash
and `cygpath` together; full validation passed with Git for Windows `usr/bin` and
`bin` prepended for that process. A separate timestamp failure in the native-tool
cache used a local-time conversion of the Unix epoch; a fixed-date red/green test
now pins UTC behavior on both PowerShell editions.
