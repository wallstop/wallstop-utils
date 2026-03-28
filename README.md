# wallstop-utils

Personal utility scripts and configuration backup system for Windows, macOS, and Linux.

## Overview

This repository contains scripts to backup and restore various application configurations across different operating systems.

## Supported Applications

| Application | Windows | macOS | Linux |
|-------------|---------|-------|-------|
| PowerShell | ✅ | - | - |
| PowerToys | ✅ | - | - |
| Windows Terminal | ✅ | - | - |
| Komorebi | ✅ | - | - |
| Scoop | ✅ | - | - |
| WezTerm | -* | ✅ | ✅ |
| Homebrew | - | ✅ | - |

*WezTerm supports Windows, but backup/restore scripts are currently Linux/macOS only.

## WezTerm Configuration

### Overview

[WezTerm](https://wezfurlong.org/wezterm/) is a GPU-accelerated cross-platform terminal emulator. This repository includes backup and restore scripts for WezTerm configuration.

### Configuration Location

WezTerm supports multiple configuration file locations:

| Location | Platform | Priority |
|----------|----------|----------|
| `~/.config/wezterm/wezterm.lua` | Linux/macOS | Primary (XDG) |
| `~/.wezterm.lua` | macOS | Alternative |

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

## GitHub Utilities

The repository also includes standalone GitHub-focused helper scripts under [Scripts/Utils/GitHub](Scripts/Utils/GitHub).
These utilities do not modify backup/restore behavior.

Current utility:

- `Get-UnresolvedPRComments.ps1`: read unresolved PR review threads from GitHub and render plain-text or JSON output.

## Script Quality Platform

This repository uses a pre-commit-first quality platform for shell, PowerShell, Lua, JSON/YAML, GitHub workflows, and OS-specific script validation.

### Local quality gate

Local hooks are wrapper scripts in `.githooks/` that execute `pre-commit` when available.
Default local behavior is:

- `pre-commit` hook: staged-file checks and auto-fixes where applicable (including deterministic PowerShell formatting and `shellcheck`/`shfmt` for changed shell targets)
- `pre-push` hook: full-repo validation (`--all-files`) for the pre-push stage plus legacy PowerShell fallback when `pre-commit` is unavailable

Enable hooks:

```bash
python3 -m pip install --user pre-commit
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

### PowerShell utility gate (retained)

The existing utility validation gate remains and is integrated into pre-commit:

- `Invoke-Pester -Path Tests/Utils`
- `Invoke-Pester -Path Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1` (when relevant files are staged)
- `Invoke-ScriptAnalyzer -Path Scripts/Utils -Settings .psscriptanalyzer.psd1 -Recurse`

Install required modules:

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0
Install-Module PSScriptAnalyzer -Scope CurrentUser -MinimumVersion 1.21.0
```

One-off usage:

```powershell
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1 -All
```

### CI quality gate (full repository)

GitHub Actions workflow `.github/workflows/script-quality.yml` runs full-repo checks on PRs and pushes:

- Linux: deterministic full-repo pre-commit checks with shell debt hooks skipped, plus strict changed-file `shellcheck`/`shfmt`, and dirty-tree drift detection
- Windows: AutoHotkey runtime switch probing (`/validate` with `/iLib` fallback) + batch static smoke checks + dirty-tree drift detection
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

- See `Scripts/Utils/Quality/LLM-REMEDIATION-CONTRACT.md` for the required fix workflow, suppression template, and verification checklist for AI-generated shell changes.

Local debt cleanup commands:

```bash
pre-commit run --all-files --hook-stage pre-commit shellcheck
pre-commit run --all-files --hook-stage pre-commit shfmt
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
