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

## Optional Pre-Commit Validation

This repository includes an opt-in local pre-commit validation flow for utility scripts.

### What it runs

- `Invoke-Pester -Path Tests/Utils`
- `Invoke-ScriptAnalyzer -Path Scripts/Utils -Settings .psscriptanalyzer.psd1 -Recurse`

### Local prerequisites

Install required PowerShell modules before enabling the hook:

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0
Install-Module PSScriptAnalyzer -Scope CurrentUser -MinimumVersion 1.21.0
```

If modules are missing, `Run-PreCommitValidation.ps1` fails with `E_CONFIG_ERROR` and an installation hint.

### Use as a one-off check

```powershell
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1
```

Use `-All` to run regardless of staged files, or `-SkipAnalyzer` if ScriptAnalyzer is not available.

```powershell
pwsh -File ./Scripts/Utils/Run-PreCommitValidation.ps1 -All
```

### Opt into git hook execution

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

The hook calls `Scripts/Utils/Run-PreCommitValidation.ps1` and fails the commit on test or lint errors.

## License

See [LICENSE](LICENSE) for details.
