#!/bin/bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Enable nullglob so globs that match nothing expand to nothing
shopt -s nullglob

brew update
brew upgrade

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Execute Homebrew backup script
"$SCRIPT_DIR/backup_brew.sh"

# Execute WezTerm backup if config exists
WEZTERM_BACKUP="$REPO_ROOT/Scripts/Wezterm/WeztermBackup.sh"
if [[ -x "$WEZTERM_BACKUP" ]]; then
    echo "Running WezTerm backup..."
    "$WEZTERM_BACKUP" || echo "Warning: WezTerm backup skipped (no config found)"
fi

current_date=$(date)
git add --all
git commit -m "Backup for $current_date" || echo "No changes to commit"
git pull origin main
git push origin main

# Directory to store the backups
BACKUP_DIR="$REPO_ROOT/Config/Mac"
mkdir -p "$BACKUP_DIR"

dotfile_count=0
applescript_count=0
script_count=0

# Find all dotfiles in the home directory and copy them to the backup directory
for file in $HOME/.*; do
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
for file in $HOME/*.{scpt,applescript}; do
    # Check if the file exists to handle the case where no AppleScript files are present
    if [[ -e "$file" ]]; then
        cp -p "$file" "$BACKUP_DIR/"
        ((applescript_count++))
    fi
done

# Backup shell scripts in the home directory
for file in $HOME/*.{sh}; do
    # Check if the file exists to handle the case where no shell scripts are present
    if [[ -e "$file" ]]; then
        cp -p "$file" "$BACKUP_DIR/"
        ((script_count++))
    fi
done

echo "Backup completed. $dotfile_count dotfiles, $script_count shell scripts, and $applescript_count AppleScript files were copied to $BACKUP_DIR"

