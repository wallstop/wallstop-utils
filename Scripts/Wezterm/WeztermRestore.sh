#!/bin/bash

# ===================================================================
# Script Name: WeztermRestore.sh
# Description: Restores the WezTerm configuration from the repository.
# Usage: ./WeztermRestore.sh [--xdg | --home]
# Supports: Linux and macOS
# ===================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Restores WezTerm configuration from the repository"
    echo ""
    echo "Options:"
    echo "  --xdg     Restore to ~/.config/wezterm/ (default on Linux)"
    echo "  --home    Restore to ~/.wezterm.lua (alternative, common on macOS)"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "If no option specified, uses platform default:"
    echo "  - Linux: ~/.config/wezterm/"
    echo "  - macOS: Prefers existing location, falls back to ~/.config/wezterm/"
    exit 1
}

# Parse arguments
FORCE_LOCATION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xdg)
            FORCE_LOCATION="xdg"
            shift
            ;;
        --home)
            FORCE_LOCATION="home"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR_REL="$SCRIPT_DIR/../../Config/Wezterm"

# Resolve to absolute path, with friendly error if it doesn't exist
if [[ ! -d "$BACKUP_DIR_REL" ]]; then
    echo "Error: Backup directory '$BACKUP_DIR_REL' does not exist."
    echo "Make sure you have backed up a WezTerm configuration first."
    exit 1
fi
BACKUP_DIR="$(cd "$BACKUP_DIR_REL" && pwd)"

# Define the config file
CONFIG_FILE="wezterm.lua"

# Detect OS
OS_TYPE="$(uname -s)"

# Ensure backup file exists
if [[ ! -f "$BACKUP_DIR/$CONFIG_FILE" ]]; then
    echo "Error: Backup file '$BACKUP_DIR/$CONFIG_FILE' does not exist."
    echo "Make sure you have backed up a WezTerm configuration first."
    exit 1
fi

# Determine destination based on OS and options
determine_destination() {
    if [[ "$FORCE_LOCATION" == "xdg" ]]; then
        echo "$HOME/.config/wezterm"
        return
    fi
    
    if [[ "$FORCE_LOCATION" == "home" ]]; then
        echo "$HOME"
        return
    fi
    
    # Auto-detect based on existing config or OS
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        # macOS: Check for existing config location
        if [[ -f "$HOME/.wezterm.lua" ]]; then
            echo "$HOME"
            return
        fi
    fi
    
    # Default to XDG location
    echo "$HOME/.config/wezterm"
}

# Get destination filename based on location
get_dest_filename() {
    local dest_dir="$1"
    if [[ "$dest_dir" == "$HOME" ]]; then
        echo ".wezterm.lua"
    else
        echo "$CONFIG_FILE"
    fi
}

DEST_DIR=$(determine_destination)
DEST_FILENAME=$(get_dest_filename "$DEST_DIR")
DEST_PATH="$DEST_DIR/$DEST_FILENAME"

echo "Detected OS: $OS_TYPE"
echo "Destination: $DEST_PATH"

# Create destination directory if it doesn't exist (not needed for home dir)
if [[ "$DEST_DIR" != "$HOME" && ! -d "$DEST_DIR" ]]; then
    echo "Creating WezTerm configuration directory at $DEST_DIR..."
    mkdir -p "$DEST_DIR"
fi

# Make a backup of the current config before overwriting (if it exists)
if [[ -f "$DEST_PATH" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_LOCATION="${DEST_PATH}.backup_$TIMESTAMP"
    cp -p "$DEST_PATH" "$BACKUP_LOCATION"
    echo "Current configuration backed up to: $BACKUP_LOCATION"
fi

echo "Restoring WezTerm configuration..."

# Copy the configuration file
cp -p "$BACKUP_DIR/$CONFIG_FILE" "$DEST_PATH"

echo "Restore successful!"
echo "Configuration restored to: $DEST_PATH"
