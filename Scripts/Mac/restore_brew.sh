#!/bin/bash

# ===================================================================
# Script Name: restore_brew.sh
# Description: Restores the Homebrew setup from a Brewfile backup.
# Usage: ./restore_brew.sh [backup_file_path] [brew_backup_directory]
# If no backup_file_path is provided, restores the latest backup from ~/brew_backups
# ===================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display usage
usage() {
    echo "Usage: $0 [backup_file_path] [brew_backup_directory]"
    echo "If no backup_file_path is provided, restores the latest backup from ~/brew_backups"
    exit 1
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

# Set backup directory
BACKUP_DIR="../../Config/Mac-Brew"

# Ensure backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory '$BACKUP_DIR' does not exist."
    exit 1
fi

# Determine the backup file to restore
if [ -n "$1" ]; then
    BACKUP_FILE="$1"
    # Check if the specified backup file exists
    if [ ! -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        echo "Error: Backup file '$BACKUP_FILE' does not exist in '$BACKUP_DIR'."
        exit 1
    fi
else
    # Find the latest backup file
    BACKUP_FILE=$(ls -1 "$BACKUP_DIR"/brewfile_backup* 2>/dev/null | sort | tail -n 1 | xargs -n1 basename)
    if [ -z "$BACKUP_FILE" ]; then
        echo "Error: No backup files found in '$BACKUP_DIR'."
        exit 1
    fi
fi

# Full path to the Brewfile
BREWFILE_PATH="$BACKUP_DIR/$BACKUP_FILE"

echo "Restoring Homebrew setup from '$BREWFILE_PATH'..."

# Check if Homebrew is installed; if not, install it
if ! command -v brew &> /dev/null; then
    echo "Homebrew not found. Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add Homebrew to PATH for the current session
    eval "$(/opt/homebrew/bin/brew shellenv)"  # For Apple Silicon
    eval "$(/usr/local/bin/brew shellenv)"    # For Intel
fi

# Navigate to backup directory
cd "$BACKUP_DIR"

# Restore the Homebrew setup using brew bundle
brew bundle --file="$BREWFILE_PATH"

echo "Homebrew restoration complete!"

# Optional: Verify installation
echo "Verifying installed formulae and casks..."
brew doctor
brew update
brew upgrade
brew cleanup

echo "Restoration process finished successfully."
