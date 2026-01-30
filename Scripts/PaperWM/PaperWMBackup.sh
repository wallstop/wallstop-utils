#!/bin/bash

# ===================================================================
# Script Name: PaperWMBackup.sh
# Description: Backs up the PaperWM configuration to the repository.
# Usage: ./PaperWMBackup.sh
# Supports: Linux (GNOME Shell with PaperWM extension)
# ===================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0"
    echo "Backs up PaperWM configuration to the repository"
    echo ""
    echo "Backs up:"
    echo "  - dconf settings from /org/gnome/shell/extensions/paperwm/"
    echo "  - ~/.config/paperwm/user.css (if exists)"
    echo ""
    echo "Note: user.js is deprecated in GNOME 45+ (PaperWM now uses dconf)"
    exit 1
}

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

# Check if we're on Linux
OS_TYPE="$(uname -s)"
if [[ "$OS_TYPE" != "Linux" ]]; then
    echo "Error: PaperWM is only supported on Linux with GNOME Shell."
    exit 1
fi

# Check if dconf is available
if ! command -v dconf &> /dev/null; then
    echo "Error: dconf command not found. Please install dconf-cli."
    exit 1
fi

# Pre-flight checks (warnings only, don't block backup)
echo "Running environment checks..."

# Check if GNOME Shell is available
if ! command -v gnome-shell &> /dev/null; then
    echo "Warning: gnome-shell command not found."
    echo "         PaperWM requires GNOME Shell to function."
    echo ""
fi

# Check if PaperWM extension is installed
PAPERWM_USER_DIR="$HOME/.local/share/gnome-shell/extensions/paperwm@paperwm.github.com"
PAPERWM_SYSTEM_DIR="/usr/share/gnome-shell/extensions/paperwm@paperwm.github.com"

if [[ ! -d "$PAPERWM_USER_DIR" && ! -d "$PAPERWM_SYSTEM_DIR" ]]; then
    echo "Warning: PaperWM extension not found."
    echo "         Checked: $PAPERWM_USER_DIR"
    echo "         Checked: $PAPERWM_SYSTEM_DIR"
    echo "         Backup will proceed, but there may be no settings to back up."
    echo ""
fi

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "$SCRIPT_DIR/../../Config/PaperWM" 2>/dev/null && pwd || echo "$SCRIPT_DIR/../../Config/PaperWM")"

# Define config paths
DCONF_PATH="/org/gnome/shell/extensions/paperwm/"
DCONF_BACKUP_FILE="paperwm-dconf.conf"
USER_CSS_SOURCE="$HOME/.config/paperwm/user.css"
USER_CSS_BACKUP="user.css"

echo "Starting PaperWM configuration backup..."

# Check if PaperWM dconf settings exist
DCONF_DUMP=$(dconf dump "$DCONF_PATH" 2>/dev/null || true)
if [[ -z "$DCONF_DUMP" ]]; then
    echo "Warning: No PaperWM dconf settings found at $DCONF_PATH"
    echo "Make sure PaperWM extension is installed and has been configured."
else
    echo "Found PaperWM dconf settings"
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Resolve backup directory to absolute path after creation
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

echo "Backup directory: $BACKUP_DIR"

# Backup dconf settings
if [[ -n "$DCONF_DUMP" ]]; then
    echo "Backing up dconf settings..."
    dconf dump "$DCONF_PATH" > "$BACKUP_DIR/$DCONF_BACKUP_FILE"
    echo "  -> $BACKUP_DIR/$DCONF_BACKUP_FILE"
else
    echo "Skipping dconf backup (no settings found)"
fi

# Backup user.css if it exists
if [[ -f "$USER_CSS_SOURCE" ]]; then
    echo "Backing up user.css..."
    cp -p "$USER_CSS_SOURCE" "$BACKUP_DIR/$USER_CSS_BACKUP"
    echo "  -> $BACKUP_DIR/$USER_CSS_BACKUP"
else
    echo "Note: No user.css found at $USER_CSS_SOURCE (using default styles)"
fi

# Check for deprecated user.js (informational only)
if [[ -f "$HOME/.config/paperwm/user.js" ]]; then
    echo ""
    echo "Note: Found deprecated user.js file at $HOME/.config/paperwm/user.js"
    echo "      Since GNOME 45+, PaperWM uses dconf for configuration instead."
    echo "      The user.js file is no longer used and can be removed."
fi

echo ""
echo "Backup successful!"
echo ""
echo "Backed up files:"
[[ -f "$BACKUP_DIR/$DCONF_BACKUP_FILE" ]] && echo "  - $DCONF_BACKUP_FILE (dconf settings)"
[[ -f "$BACKUP_DIR/$USER_CSS_BACKUP" ]] && echo "  - $USER_CSS_BACKUP (custom styles)"
