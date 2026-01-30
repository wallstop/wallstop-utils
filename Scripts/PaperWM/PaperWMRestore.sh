#!/bin/bash

# ===================================================================
# Script Name: PaperWMRestore.sh
# Description: Restores the PaperWM configuration from the repository.
# Usage: ./PaperWMRestore.sh [--dconf-only | --css-only]
# Supports: Linux (GNOME Shell with PaperWM extension)
# ===================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Restores PaperWM configuration from the repository"
    echo ""
    echo "Options:"
    echo "  --dconf-only    Only restore dconf settings"
    echo "  --css-only      Only restore user.css"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Restores:"
    echo "  - dconf settings to /org/gnome/shell/extensions/paperwm/"
    echo "  - user.css to ~/.config/paperwm/"
    echo ""
    echo "Note: After restoring, you may need to disable and re-enable"
    echo "      the PaperWM extension for changes to take effect."
    exit 1
}

# Parse arguments
RESTORE_DCONF=true
RESTORE_CSS=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dconf-only)
            RESTORE_CSS=false
            shift
            ;;
        --css-only)
            RESTORE_DCONF=false
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

# Pre-flight checks (warnings only, don't block restore)
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
    echo "         Settings will be restored, but PaperWM must be installed to use them."
    echo ""
fi

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR_REL="$SCRIPT_DIR/../../Config/PaperWM"

# Resolve to absolute path, with friendly error if it doesn't exist
if [[ ! -d "$BACKUP_DIR_REL" ]]; then
    echo "Error: Backup directory '$BACKUP_DIR_REL' does not exist."
    echo "Make sure you have backed up a PaperWM configuration first."
    exit 1
fi
BACKUP_DIR="$(cd "$BACKUP_DIR_REL" && pwd)"

# Define config paths
DCONF_PATH="/org/gnome/shell/extensions/paperwm/"
DCONF_BACKUP_FILE="paperwm-dconf.conf"
USER_CSS_BACKUP="user.css"
USER_CSS_DEST="$HOME/.config/paperwm/user.css"
PRE_RESTORE_BACKUP_DIR="$HOME/.config/paperwm/backups"

# Generate timestamp once for consistent backup naming
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Starting PaperWM configuration restore..."
echo "Backup directory: $BACKUP_DIR"
echo ""

RESTORED_SOMETHING=false
RESTORED_DCONF=false
RESTORED_CSS=false

# Restore dconf settings
if [[ "$RESTORE_DCONF" == true ]]; then
    if [[ -f "$BACKUP_DIR/$DCONF_BACKUP_FILE" ]]; then
        echo "Restoring dconf settings..."
        
        # Create a backup of current settings before overwriting
        CURRENT_SETTINGS=$(dconf dump "$DCONF_PATH" 2>/dev/null || true)
        if [[ -n "$CURRENT_SETTINGS" ]]; then
            mkdir -p "$PRE_RESTORE_BACKUP_DIR"
            DCONF_BACKUP_LOCATION="$PRE_RESTORE_BACKUP_DIR/${DCONF_BACKUP_FILE}.backup_$TIMESTAMP"
            echo "$CURRENT_SETTINGS" > "$DCONF_BACKUP_LOCATION"
            echo "  Current settings backed up to: $DCONF_BACKUP_LOCATION"
        fi
        
        # Load the settings
        dconf load "$DCONF_PATH" < "$BACKUP_DIR/$DCONF_BACKUP_FILE"
        echo "  -> dconf settings restored to $DCONF_PATH"
        RESTORED_SOMETHING=true
        RESTORED_DCONF=true
    else
        echo "Warning: dconf backup file not found at $BACKUP_DIR/$DCONF_BACKUP_FILE"
    fi
fi

# Restore user.css
if [[ "$RESTORE_CSS" == true ]]; then
    if [[ -f "$BACKUP_DIR/$USER_CSS_BACKUP" ]]; then
        echo "Restoring user.css..."
        
        # Create destination directory if it doesn't exist
        mkdir -p "$(dirname "$USER_CSS_DEST")"
        
        # Backup current user.css if it exists
        if [[ -f "$USER_CSS_DEST" ]]; then
            mkdir -p "$PRE_RESTORE_BACKUP_DIR"
            CSS_BACKUP_LOCATION="$PRE_RESTORE_BACKUP_DIR/${USER_CSS_BACKUP}.backup_$TIMESTAMP"
            cp -p "$USER_CSS_DEST" "$CSS_BACKUP_LOCATION"
            echo "  Current user.css backed up to: $CSS_BACKUP_LOCATION"
        fi
        
        # Copy the user.css file
        cp -p "$BACKUP_DIR/$USER_CSS_BACKUP" "$USER_CSS_DEST"
        echo "  -> user.css restored to $USER_CSS_DEST"
        RESTORED_SOMETHING=true
        RESTORED_CSS=true
    else
        echo "Note: No user.css backup found (will use default styles)"
    fi
fi

if [[ "$RESTORED_SOMETHING" == true ]]; then
    echo ""
    echo "Restore successful!"
    echo ""
    echo "To apply changes:"
    if [[ "$RESTORED_CSS" == true ]]; then
        echo "  1. Open GNOME Extensions app (or run: gnome-extensions prefs paperwm@paperwm.github.com)"
        echo "  2. Disable PaperWM"
        echo "  3. Re-enable PaperWM"
    else
        # Only dconf was restored
        echo "  - Some settings may apply immediately"
        echo "  - For full effect, you may need to log out and log back in"
        echo "  - Alternatively, disable and re-enable PaperWM in GNOME Extensions"
    fi
    echo ""
    echo "Alternatively, log out and log back in."
else
    echo ""
    echo "No files were restored. Make sure backup files exist in $BACKUP_DIR"
fi
