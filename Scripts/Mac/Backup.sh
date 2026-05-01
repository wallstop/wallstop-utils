#!/usr/bin/env bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Enable nullglob so globs that match nothing expand to nothing
shopt -s nullglob

brew update
brew upgrade

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v git > /dev/null 2>&1; then
  echo "E_BACKUP_MAC_GIT_NOT_AVAILABLE: git is required for macOS backup but was not found on PATH." >&2
  exit 1
fi

assert_backup_git_branch() {
  local repo_root="$1"
  local expected_branch="$2"
  local current_branch

  current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2> /dev/null || true)"
  if [[ -z "$current_branch" ]]; then
    echo "E_BACKUP_GIT_BRANCH_DETECTION_FAILED: Unable to determine current branch for repository '$repo_root'." >&2
    return 1
  fi

  if [[ "$current_branch" == "HEAD" ]]; then
    echo "E_BACKUP_GIT_DETACHED_HEAD: git HEAD is detached for repository '$repo_root'. Backup requires branch '$expected_branch'." >&2
    return 1
  fi

  if [[ "$current_branch" != "$expected_branch" ]]; then
    echo "E_BACKUP_GIT_BRANCH_MISMATCH: current branch is '$current_branch' but backup requires '$expected_branch' (repositoryRoot='$repo_root')." >&2
    return 1
  fi
}

assert_backup_git_branch "$REPO_ROOT" "main"
git -C "$REPO_ROOT" pull --ff-only origin main

# Execute Homebrew backup script
"$SCRIPT_DIR/backup_brew.sh"

# Execute WezTerm backup if config exists
WEZTERM_BACKUP="$REPO_ROOT/Scripts/Wezterm/WeztermBackup.sh"
if [[ -x "$WEZTERM_BACKUP" ]]; then
  echo "Running WezTerm backup..."
  "$WEZTERM_BACKUP" || echo "Warning: WezTerm backup skipped (no config found)"
fi

current_date=$(date)
assert_backup_git_branch "$REPO_ROOT" "main"
git -C "$REPO_ROOT" add --all
git -C "$REPO_ROOT" commit -m "Backup for $current_date" || echo "No changes to commit"
assert_backup_git_branch "$REPO_ROOT" "main"
git -C "$REPO_ROOT" push origin main

# Directory to store the backups
BACKUP_DIR="$REPO_ROOT/Config/Mac"
mkdir -p "$BACKUP_DIR"

dotfile_count=0
applescript_count=0
script_count=0

# Find all dotfiles in the home directory and copy them to the backup directory
for file in "$HOME"/.*; do
  # Skip the special directories '.' and '..'
  # Skip special directories and any subdirectories
  if [[ "$file" == "$HOME/." || "$file" == "$HOME/.." || -d "$file" ]]; then
    continue
  fi

  # Copy each dotfile to the backup directory
  cp -p "$file" "$BACKUP_DIR/"
  ((dotfile_count++))
done

# Backup AppleScript files in the home directory
for file in "$HOME"/*.{scpt,applescript}; do
  # Check if the file exists to handle the case where no AppleScript files are present
  if [[ -e "$file" ]]; then
    cp -p "$file" "$BACKUP_DIR/"
    ((applescript_count++))
  fi
done

# Backup shell scripts in the home directory
for file in "$HOME"/*.sh; do
  # Check if the file exists to handle the case where no shell scripts are present
  if [[ -e "$file" ]]; then
    cp -p "$file" "$BACKUP_DIR/"
    ((script_count++))
  fi
done

echo "Backup completed. $dotfile_count dotfiles, $script_count shell scripts, and $applescript_count AppleScript files were copied to $BACKUP_DIR"
