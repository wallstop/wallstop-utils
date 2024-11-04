#!/bin/bash

brew update
brew upgrade

# Get the directory where the script is located
script_dir="$(dirname "${BASH_SOURCE[0]}")"
# Execute another script in the same directory
"$script_dir/backup_brew.sh"

current_date=$(date)
git add --all
git commit -m "Backup for $current_date"
git pull origin main
git push origin main

# Directory to store the backups
BACKUP_DIR="%script_dir/../../Config/Mac"
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

# Backup bash files in the home directory
for file in $HOME/*.{sh}; do
    # Check if the file exists to handle the case where no AppleScript files are present
    if [[ -e "$file" ]]; then
        cp -p "$file" "$BACKUP_DIR/"
        ((script_count++))
    fi
done

echo "Backup completed. $dotfile_count dotfiles, $script_count shell scripts, and $applescript_count AppleScript files were copied to $BACKUP_DIR"

