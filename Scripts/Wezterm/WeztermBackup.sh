#!/bin/bash

# ===================================================================
# Script Name: WeztermBackup.sh
# Description: Backs up the WezTerm configuration to the repository.
# Usage: ./WeztermBackup.sh
# Supports: Linux and macOS
# ===================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0"
    echo "Backs up WezTerm configuration to the repository"
    echo ""
    echo "Supported config locations (checked in order):"
    echo "  - ~/.config/wezterm/wezterm.lua (Linux/macOS XDG)"
    echo "  - ~/.wezterm.lua (macOS home directory)"
    exit 1
}

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "$SCRIPT_DIR/../../Config/Wezterm" 2>/dev/null && pwd || echo "$SCRIPT_DIR/../../Config/Wezterm")"

# Define the config file name
CONFIG_FILE="wezterm.lua"

# Detect OS
OS_TYPE="$(uname -s)"

# Function to find WezTerm config
find_wezterm_config() {
    # Check XDG config location (Linux and macOS)
    if [[ -f "$HOME/.config/wezterm/$CONFIG_FILE" ]]; then
        echo "$HOME/.config/wezterm/$CONFIG_FILE"
        return 0
    fi
    
    # Check home directory location (common on macOS)
    if [[ -f "$HOME/.wezterm.lua" ]]; then
        echo "$HOME/.wezterm.lua"
        return 0
    fi
    
    return 1
}

# Find the source config file
SOURCE_CONFIG=$(find_wezterm_config) || {
    echo "Error: WezTerm configuration file not found."
    echo "Checked locations:"
    echo "  - $HOME/.config/wezterm/$CONFIG_FILE"
    echo "  - $HOME/.wezterm.lua"
    exit 1
}

echo "Detected OS: $OS_TYPE"
echo "Found WezTerm config at: $SOURCE_CONFIG"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Resolve backup directory to absolute path after creation
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

echo "Backing up WezTerm configuration..."

# Copy the configuration file
cp -p "$SOURCE_CONFIG" "$BACKUP_DIR/$CONFIG_FILE"

echo "Backup successful!"
echo "Configuration backed up to: $BACKUP_DIR/$CONFIG_FILE"
