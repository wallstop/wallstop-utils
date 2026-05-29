# wallstop-utils

Personal utility scripts and configuration backup system for Windows, macOS, and Linux.

## Overview

This repository contains scripts to backup and restore various application configurations across different operating systems.

## Supported Applications

| Application      | Windows | macOS | Linux |
| ---------------- | ------- | ----- | ----- |
| PowerShell       | ✅      | -     | -     |
| PowerToys        | ✅      | -     | -     |
| Windows Terminal | ✅      | -     | -     |
| Komorebi         | ✅      | -     | -     |
| Scoop            | ✅      | -     | -     |
| WezTerm          | -\*     | ✅    | ✅    |
| Homebrew         | -       | ✅    | -     |

\*WezTerm supports Windows, but backup/restore scripts are currently Linux/macOS only.

## WezTerm Configuration

### Overview

[WezTerm](https://wezfurlong.org/wezterm/) is a GPU-accelerated cross-platform terminal emulator. This repository includes backup and restore scripts for WezTerm configuration.

### Configuration Location

WezTerm supports multiple configuration file locations:

| Location                        | Platform    | Priority      |
| ------------------------------- | ----------- | ------------- |
| `~/.config/wezterm/wezterm.lua` | Linux/macOS | Primary (XDG) |
| `~/.wezterm.lua`                | macOS       | Alternative   |

### Scripts

#### Backup (`Scripts/Wezterm/WeztermBackup.sh`)

Backs up your WezTerm configuration to the repository.

```bash
# Run from anywhere
./Scripts/Wezterm/WeztermBackup.sh

# Show help
./Scripts/Wezterm/WeztermBackup.sh --help
```

The script automatically detects your configuration location and copies it to `Config/Wezterm/wezterm.lua`.

#### Restore (`Scripts/Wezterm/WeztermRestore.sh`)

Restores your WezTerm configuration from the repository.

```bash
# Auto-detect destination (platform default)
./Scripts/Wezterm/WeztermRestore.sh

# Force XDG location (~/.config/wezterm/)
./Scripts/Wezterm/WeztermRestore.sh --xdg

# Force home directory location (~/.wezterm.lua)
./Scripts/Wezterm/WeztermRestore.sh --home

# Show help
./Scripts/Wezterm/WeztermRestore.sh --help
```

The restore script:

- Automatically detects your OS and existing configuration
- Creates a timestamped backup of your current config before overwriting
- Supports explicit destination selection via flags

### Configuration Features

The included `wezterm.lua` configuration provides:

- **Cross-platform shell detection**: Automatically finds zsh/bash across macOS and Linux
- **Pane splitting**: `Ctrl+Shift++` (horizontal), `Ctrl+Shift+-` (vertical)
- **Pane navigation**: `Ctrl+Arrow keys` to move between panes
- **Close pane**: `Ctrl+Shift+W`
- **Copy/Paste**: `Ctrl+C` (context-aware), `Ctrl+V`
- **Scrollback**: 10,000 lines with scroll bar enabled

### Installation

1. Install WezTerm from [wezfurlong.org/wezterm](https://wezfurlong.org/wezterm/installation.html)
2. Clone this repository
3. Run the restore script:
   ```bash
   ./Scripts/Wezterm/WeztermRestore.sh
   ```

## Directory Structure

```
Config/           # Backed up configuration files
  Wezterm/        # WezTerm configuration
  Mac/            # macOS-specific configs
  PowerToys/      # PowerToys settings
  ...

Scripts/          # Backup and restore scripts
  Wezterm/        # WezTerm scripts (Linux/macOS)
  Mac/            # macOS-specific scripts
  Powershell/     # PowerShell profile scripts
  ...
```

## Usage

### Quick Backup (All)

**Windows:**

```powershell
.\Scripts\Backup.ps1
```

**macOS:**

```bash
./Scripts/Mac/Backup.sh
```

### Quick Restore (All)

**Windows:**

```powershell
.\Scripts\Restore.ps1
```

**macOS:**

```bash
# Run individual restore scripts as needed
./Scripts/Wezterm/WeztermRestore.sh
./Scripts/Mac/restore_brew.sh
```

## VS Code Dev Container

This repository includes a ready-to-use VS Code development container at `.devcontainer/devcontainer.json`.

What it provides:

- Ubuntu 24.04 base container
- PowerShell, Python, Node.js (LTS), and GitHub CLI
- Pre-commit bootstrap and hook installation on first create
- PowerShell quality module bootstrap (`Pester`, `PSScriptAnalyzer`)
- Curated extension pack for script-heavy workflows plus polished themes/icons

Open it in VS Code:

```text
Dev Containers: Reopen in Container
```

After the container is created, quality commands are ready to run:

```bash
pre-commit run
pre-commit run --all-files
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1
```

## GitHub Utilities

The repository also includes standalone GitHub-focused helper scripts under [Scripts/Utils/GitHub](Scripts/Utils/GitHub).
These utilities do not modify backup/restore behavior.

Current utility:

- `Get-UnresolvedPRComments.ps1`: read unresolved PR review threads from GitHub and render plain-text or JSON output.
  - Cleans noisy bot comment markup by default and uses embedded Cursor/Bugbot locations when available.
  - Supports clipboard export with `-Copy` and strict failure mode via `-CopyStrict`.
  - Supports writing output to UTF-8 files with `-OutputPath` while still emitting stdout.

## Script Quality Platform

This repository uses targeted agent validation first, with pre-commit and CI as last-resort parity gates for shell, PowerShell, Lua, JSON/YAML, GitHub workflows, and OS-specific script validation.

### Local quality gate

Local hooks are wrapper scripts in `.githooks/` that execute `pre-commit` when available.
Default local behavior is:

- `pre-commit` hook: staged-file checks and auto-fixes where applicable (including deterministic PowerShell formatting, `shellcheck`/`shfmt` for changed shell targets, and pinned native StyLua/actionlint checks)
- `pre-push` hook: runs `Scripts/Utils/Quality/Invoke-FullValidation.ps1` when `pwsh` is available (full pre-commit + pre-push + harness + drift checks), with legacy fallback when `pre-commit` is unavailable

Shell `shfmt` and `shellcheck` hooks use repo-managed PowerShell wrappers instead of Python-packaged hook environments. `Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1` downloads pinned upstream release assets into ignored `.tools/shell-quality`, verifies SHA256 and tool versions, and reuses the same executables on Linux, macOS, and Windows hosts.

Compiled native tools that publish release binaries follow the same contract. `Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1` manages pinned StyLua and actionlint assets in ignored `.tools/native-quality`, verifies SHA256 before extraction/use, validates tool versions, and handles Windows ARM64 only with explicit manifest-backed fallback when upstream does not publish a native asset. The pre-commit wrapper also auto-cleans and pre-warms hook environments once when pre-commit cache or nodeenv-style setup failures are detected.

Hook troubleshooting is intentionally automated first:

- `WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS` and `WALLSTOP_PREPUSH_TIMEOUT_SECONDS` bound hook runtime; values must be integers of at least 30 seconds.
- `WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS` overrides the native binary download timeout when a slow network needs more than the default 300 seconds.
- `.tools/shell-quality` and `.tools/native-quality` are ignored caches. Delete them only when deliberately forcing a fresh verified download; normal version/hash drift repairs itself.
- If pre-commit reports environment installation corruption, run `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1 -InstallHooksOnly` to trigger the same clean + `install-hooks` repair path used by preflight.

Enable hooks:

```bash
pipx install pre-commit
# or use a dedicated pre-commit venv when pipx is unavailable:
python3 -m venv ~/.local/venvs/pre-commit
~/.local/venvs/pre-commit/bin/pip install pre-commit
mkdir -p ~/.local/bin
ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit
export PATH="$HOME/.local/bin:$PATH"
# persist PATH for future shells:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
pre-commit install --hook-type pre-commit --hook-type pre-push
```

If you add or replace hook files, ensure executable mode is tracked in git:

```bash
git update-index --chmod=+x .githooks/pre-commit .githooks/pre-push
```

Run manually:

```bash
pre-commit run
pre-commit run --all-files
```

### Major change session-close workflow

For major changes, use the single full-validation entrypoint and follow the canonical workflow:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
```

Then watch CI checks for the active PR:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -WatchCi
```

If any gate fails, fix within the same session and rerun until all checks pass.
See [.llm/validation-workflow.md](.llm/validation-workflow.md) for the full remediation and codification loop.

### PowerShell utility gate (retained)

The existing utility validation gate remains and is integrated into pre-commit:

- `Tests/Utils` Pester suite (isolated `pwsh -NoProfile -NonInteractive` process)
- `Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1` Pester suite (when relevant files are staged)
- `Invoke-ScriptAnalyzer -Path Scripts/Utils -Settings .psscriptanalyzer.psd1 -Recurse`

Bootstrap required modules (recommended on a new host shell):

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1
```

Manual fallback commands:

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Pester -Repository PSGallery -Scope CurrentUser -MinimumVersion 5.5.0 -Force
Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion 1.21.0 -Force
```

Host-shell preflight (recommended before first commit/push from a new shell context):

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly
```

The preflight also repairs missing shell formatter/linter binaries, native StyLua/actionlint binaries, and pre-commit hook environments automatically. If you need to pre-warm only those repo-managed binaries, run:

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1 -Tool All -EnsureOnly
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1 -Tool All -EnsureOnly
```

Windows host note:

- Run these commands from `pwsh` (PowerShell 7+), not from legacy Windows PowerShell.
- Windows PowerShell ships with Pester 3.4.0, which is incompatible with this repository's Pester 5 test syntax.

One-off usage:

```powershell
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1 -All
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1
```

### CI quality gate (full repository)

GitHub Actions workflow `.github/workflows/script-quality.yml` runs full-repo checks on PRs and pushes:

- Linux: deterministic full-repo pre-commit checks with shell debt hooks skipped, plus strict changed-file `shellcheck`/`shfmt`, and dirty-tree drift detection
- Windows: AutoHotkey runtime switch probing (`/validate` with `/iLib` fallback) with process-level stdout/stderr capture for headless CI reliability + batch static smoke checks + dirty-tree drift detection
- macOS: AppleScript compile checks using text-source-first validation with `.scpt` fallback + dirty-tree drift detection

### Shell debt management path

To avoid a permanently-red baseline while keeping strict enforcement on new changes:

- PRs/pushes enforce `shellcheck` and `shfmt` on changed shell targets only.
- Local `pre-push` still runs non-shell full-repo quality gates (`pre-commit --hook-stage pre-push --all-files` + PowerShell utility checks).
- Full-repo deterministic CI checks exclude shell debt-heavy hooks.
- A manual non-blocking debt audit job is available in `.github/workflows/script-quality.yml` via `workflow_dispatch` input `run_shell_debt_audit=true`.

Shell suppression governance:

- Keep shell linting strict (`severity=style`) so style/info findings block regressions.
- Prefer code fixes over suppressions.
- If a suppression is unavoidable, it must be inline and include an adjacent reason comment.
- Broad suppressions (for example `disable=all`) are not allowed.

LLM remediation contract:

- See `.llm/skill-details/shell-governance/llm-remediation-contract.md` for the required fix workflow, suppression template, and verification checklist for AI-generated shell changes.

LLM harness architecture:

- `.llm/context.md` is the authoritative repository AI context file.
- `.llm/skills-index.md` is a dedicated generated index artifact.
- `.llm/skills/*.md` are lightweight skill cards with trigger metadata.
- `.llm/skill-details/*.md` contain expanded guidance linked from lightweight skill cards.

LLM harness commands:

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1 -Check
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Test-LlmHarness.ps1
```

Local debt cleanup commands:

```bash
pre-commit run --all-files --hook-stage pre-commit shellcheck
pre-commit run --all-files --hook-stage pre-commit shfmt
```

Equivalent direct PowerShell entrypoint:

```powershell
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1 -Tool All -Fix <paths>
```

### AppleScript migration path

AppleScript validation is source-first but non-breaking while migration is in progress:

- If `.applescript`/`.osascript` sources exist under `Scripts/Mac` or `Config/Mac`, CI compiles those text sources.
- If no text sources exist yet, CI validates current `.scpt` artifacts by decompiling and recompiling.

### Batch validation limitations

Batch validation is intentionally best effort:

- checks unresolved merge markers, whitespace/editorconfig-aligned issues, and simple parenthesis-balance smoke checks
- handles both single-line and multi-line batch files for those checks
- does not provide a complete `cmd.exe` parser-level static analysis

## License

See [LICENSE](LICENSE) for details.
