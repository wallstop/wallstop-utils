# Git and lazygit experience

This opt-in profile configures Git for all repositories owned by the current user.
It favors rebasing, recorded conflict reuse with automatic staging, and delta diffs.
Existing explicit preferences are preserved and reported. No commit, push, fetch,
history rewrite, or background service is started by installation.

## Install and remove

From the checkout root, in PowerShell:

```powershell
./Scripts/Git/Set-GitExperience.ps1 -Action Audit -WithDelta
./Scripts/Git/Set-GitExperience.ps1 -Action Apply -WithDelta -WhatIf
./Scripts/Git/Set-GitExperience.ps1 -Action Apply -WithDelta -InstallDependencies
./Scripts/Git/Set-GitExperience.ps1 -Action Remove
```

Audit is the default action. Audit and WhatIf do not create directories, install
dependencies, or modify configuration. Without `-WithDelta`, only Git is required.
Run with `pwsh -NoProfile -File` or `powershell -NoProfile -File` from other shells.

Supported floor: Git 2.38; delta integration additionally requires lazygit 0.65.1,
delta 0.19.2, and Python 3.9+. PowerShell 5.1 and 7+ are supported. `-InstallDependencies`
installs missing delta using existing Scoop (`delta`) or Homebrew (`git-delta`), and
provisions a dedicated Python virtual environment for the YAML helper. Other Linux
package managers: install `git-delta` yourself first. The script never bootstraps a
package manager or runs sudo. Existing outdated executables produce an upgrade diagnostic.

The YAML dependency is pinned in `requirements-git-experience.txt`; the root pip
Dependabot configuration covers it. CI uses it in a separate, path-scoped workflow;
delta and lazygit are not added to the Windows language fast lane. The desktop
executables remain managed and updated by Scoop/Homebrew or your OS package manager.

`-ReplaceConflicts` explicitly makes the profile override global Git preferences and
selects delta instead of an existing lazygit renderer. That choice persists on repeat
installation; remove and reinstall to return to preservation mode. Local/worktree
settings and command-line overrides still win. Audit shows actual effective values
and their origins in the current repository.

The default managed include precedes personal preferences, including conditional
includes that activate in other repositories. Identity, signing, credentials,
editors, hooks, line endings, and remote definitions are outside the profile.
The existing `.gitattributes` remains authoritative for this repository's line endings.

Configuration lives in `%LOCALAPPDATA%/wallstop-utils/git-experience` on Windows, or
`$XDG_STATE_HOME/wallstop-utils/git-experience` (`~/.local/state` fallback) on Unix.
It is copied rather than linked to the checkout. `-StateDirectory` overrides this
location. `GIT_CONFIG_GLOBAL` is honored. When both global files exist, preservation
mode registers in XDG's earlier layer; replacement mode uses `.gitconfig`'s later layer.
A change of target requires removal/reapplication rather than moving an installation
silently. Use the same state directory and Git environment for removal.

The installer discovers lazygit's config directory using `--print-config-dir` and
honors `LG_CONFIG_FILE`. For a comma-separated override, select the last layer with
`-LazygitConfigPath`. Repository-local lazygit config can still override the renderer.
Symlinked target files require an explicit resolved path; for Git, set `GIT_CONFIG_GLOBAL`.
If delta appears inactive, inspect `GIT_PAGER`: an inherited value such as `cat`
overrides pager selection, including lazygit's stdin renderer. Audit reports that override.
For an interactive terminal test, clear that variable in the test process and use a
color-capable terminal; automation environments often set `TERM=dumb` and `NO_COLOR`.

Backups contain original file bytes and stay in private user storage. They may contain
sensitive personal settings: do not commit them. Removal restores the original bytes
when possible; subsequent unrelated edits survive. Edits to the managed profile or
renderer cause a drift error instead of being discarded. Recovery journals remain
after removal. Installed programs and the helper environment are retained.

## Evidence and decisions

Research date: 2026-09-26. Baseline: Git 2.55.0.windows.3, lazygit 0.65.1,
empty lazygit configuration, no delta executable. The machine already had system-wide
`pull.rebase=true`, `core.autocrlf=true`, and `init.defaultBranch=master`.

[Scott Chacon's article](https://blog.gitbutler.com/how-git-core-devs-configure-git)
describes personal preferences and a Git mailing-list experiment. It is not an official
universal profile. The linked original lore archive was unavailable during research;
the adoption decisions below were checked against primary documentation and versioned source.

| Change | Reason and lazygit effect |
| --- | --- |
| `diff.algorithm=histogram`, `diff.colorMoved=plain` | Better cues for moved code; lazygit's native diff generation honors these. Readability is workload-dependent. |
| `merge.conflictStyle=zdiff3` | Adds base context while trimming shared edges of conflict regions. |
| `rerere.enabled=true`, `rerere.autoupdate=true` | Reuses prior conflict resolutions and stages the result. Review staged changes before continuing. |
| `pull.rebase=true` | Reconciles divergent pulls by rebasing local commits. Explicit `--ff-only` in repository automation still applies. |
| `rebase.autoSquash=true`, `rebase.autoStash=true`, `rebase.updateRefs=true` | Supports fixups, tracked dirty changes, and stacked local branches. Autostash does not protect untracked files. |
| `push.autoSetupRemote=true` | Sets upstream on a default push when missing; existing push modes/remotes still control destination. |
| `push.useForceIfIncludes=true` | Adds an integration check to applicable implicit force-with-lease operations. |
| `fetch.prune=true` | Removes stale remote tracking refs under normal branch refspecs. |
| Branch/tag sorting, columns, verbose commits, prompted autocorrect, `main` initial branch | CLI conveniences. Lazygit has its own branch sorting and commit UI. |
| delta CLI pager and lazygit renderer | Syntax highlighting, word-level changes, moved-line colors; automatic terminal theme, unified layout. |

Primary references:

- [Git config](https://git-scm.com/docs/git-config),
  [merge conflict styles](https://git-scm.com/docs/git-merge),
  [rerere](https://git-scm.com/docs/git-rerere).
- [Rebase](https://git-scm.com/docs/git-rebase): updateRefs also moves other local
  branches pointing into rewritten history, excluding branches checked out in worktrees.
  Autostash restoration can conflict; inspect `git status` and `git stash list` before proceeding.
- [Push](https://git-scm.com/docs/git-push) and
  [lazygit maintainer discussion](https://github.com/jesseduffield/lazygit/discussions/4068):
  background fetches can weaken implicit force-with-lease expectations. The additional
  includes check is not a replacement for reviewing remote changes or an explicit expected SHA.
- [Fetch pruning](https://git-scm.com/docs/git-fetch#_pruning): pruning follows refspecs,
  so explicit tag-mapping refspecs can prune tags even without `fetch.pruneTags`.
- [Lazygit 0.65.1 rebase source](https://github.com/jesseduffield/lazygit/blob/v0.65.1/pkg/commands/git_commands/rebase.go):
  ordinary interactive rebases use `--autostash --no-autosquash`; its dedicated fixup
  action uses `--autosquash`. Global autosquash is not a promise that every UI action squashes fixups.
- [Lazygit configuration](https://github.com/jesseduffield/lazygit/blob/v0.65.1/docs/Config.md)
  and [renderer setup](https://github.com/jesseduffield/lazygit/blob/v0.65.1/docs/Custom_DiffRenderers.md):
  `git.autoStageResolvedConflicts` remains at its existing/default value (true).
- [Delta setup](https://github.com/dandavison/delta/tree/0.19.2): CLI uses `core.pager=delta`,
  `interactive.diffFilter=delta --color-only`, and `delta.navigate=true`. Lazygit uses
  `delta --paging=never` with colored input. The staging panel keeps its native controls.

Excluded: automatic tag pruning, automatic annotated-tag publication, global fetch-all,
experimental feature bundles, automatic maintenance registration, and fsmonitor.
`push.default=simple` and rename detection already default on modern Git; existing
choices are preserved. A global ignores file, aliases, mnemonic diff prefixes, or a
new grep dialect would add personal assumptions without clear lazygit benefit.

For slow large repositories, measure status/fetch timings first, then assess
[maintenance](https://git-scm.com/docs/git-maintenance) and
[fsmonitor platform/filesystem support](https://git-scm.com/docs/git-fsmonitor--daemon).
Difftastic remains an optional structural renderer; delta was selected for this profile.

## Experiments and red-green validation

The initial installer tests failed because the entrypoint did not exist. Subsequent
tests exposed a PowerShell null-string/.NET file-replace binding issue; the implementation
now uses an explicit null string. Repeat-install, removal, drift, lock, malformed-input,
conditional-include, and injected-publication-failure cases guard the installer contract.
Review also reproduced an include-ordering bug and an outdated removal baseline after
personal edits/reapplication. Regression cases cover both; defaults remain independent
of the repository from which installation is invoked.

`Tests/Git/test_git_experience.py` creates isolated repositories and bare local remotes.
It verifies conflict reuse/staging, base conflict context, autosquash, autostash conflict
recovery, branch updates/worktree exclusion, upstream setup, pruning, valid patches,
and force-with-lease behavior with a background-fetch simulation. YAML tests check
comments, preferences, repeat application, drift, malformed input, and removal.

```powershell
./Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1 -TestPath Tests/Utils/GitExperience.Tests.ps1 -OutputVerbosity None
# Use the helper venv's Python after dependency provisioning:
python -m unittest discover -s Tests/Git -p 'test_*.py' -v
python Scripts/Git/measure_git_diffs.py
```

The benchmark prints commit IDs, raw measurements, versions, and UTC time as JSON.
It alternates algorithm order, discards one warm-up round, and measures three rounds
over eight non-merge commits touching Scripts. Empty diffs fail the experiment.
Initial PowerShell measurements were 42.25 ms median Myers and 39.05 ms histogram
(24 samples each). Process startup dominates; this is evidence of no obvious regression
on this small sample, not a general speed claim. CI asserts behavior, not timing.

## Useful workflows

```sh
# Work on another branch without disturbing the current checkout
git worktree add ../project-fix -b fix/topic
git worktree list

# Record a targeted correction, then fold fixups into unpublished history
git commit --fixup=<commit>
git rebase -i <base>

# Review what changed through a rebase
git range-diff <old-base>..<old-tip> <new-base>..<new-tip>

# Find an earlier tip and preserve it before attempting recovery
git reflog
git branch recovered-topic <old-tip>
```

Use lazygit's worktree and fixup actions for the same workflows. After rewriting
published personal branches, inspect remote changes before a force-with-lease push;
shared branch history needs coordination. To override the profile for one operation,
use `git -c rebase.updateRefs=false rebase ...` or `git rebase --no-autostash ...`.
