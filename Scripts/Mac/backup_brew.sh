#!/bin/bash

# ===================================================================
# Script Name: backup_brew.sh
# Description: Backs up the current Homebrew setup using brew bundle.
# Usage: ./backup_brew.sh [backup_directory]
# If no backup_directory is provided, defaults to ~/brew_backups
# ===================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display usage
usage() {
    echo "Usage: $0 [backup_directory]"
    echo "If no backup_directory is provided, defaults to ~/brew_backups"
    exit 1
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

script_dir="$(dirname "${BASH_SOURCE[0]}")"

# Set backup directory
BACKUP_DIR="$script_dir/../../Config/Mac-Brew"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Define backup file name
BACKUP_FILE="brewfile_backup"

# Navigate to backup directory
cd "$BACKUP_DIR"

echo "Backing up Homebrew setup..."

# Dump the current Homebrew configuration to Brewfile
brew bundle dump --file="$BACKUP_FILE" --force

echo "Backup successful!"
echo "Backup file created at: $BACKUP_DIR/$BACKUP_FILE"

# Optional: Compress the backup file
# Uncomment the following lines if you wish to compress the backup
# tar -czf "${BACKUP_FILE}.tar.gz" "$BACKUP_FILE"
# rm "$BACKUP_FILE"
# echo "Backup compressed to: $BACKUP_DIR/${BACKUP_FILE}.tar.gz"

# Optional: Log the backup
# LOG_FILE="$BACKUP_DIR/backup_log.txt"
# echo "$(date +"%Y-%m-%d %H:%M:%S") - Backup created: $BACKUP_FILE" >> "$LOG_FILE"
