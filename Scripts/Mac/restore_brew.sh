#!/bin/bash

# ===================================================================
# Script Name: restore_brew.sh
# Description: Restores the Homebrew setup from a Brewfile backup.
# Usage: ./restore_brew.sh [backup_file_path] [brew_backup_directory]
# If no backup_file_path is provided, restores the latest backup from ~/brew_backups
# ===================================================================

# Exit on errors, undefined variables, and failed pipelines
set -euo pipefail

# Function to display usage
usage() {
  echo "Usage: $0 [backup_file_path] [brew_backup_directory]"
  echo "If no backup_file_path is provided, restores the latest backup from ~/brew_backups"
  exit 1
}

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

script_dir="$(dirname "${BASH_SOURCE[0]}")"

# Set backup directory
BACKUP_DIR="$script_dir/../../Config/Mac-Brew"

# Ensure backup directory exists
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "Error: Backup directory '$BACKUP_DIR' does not exist."
  exit 1
fi
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

# Determine the backup file to restore
if [[ -n "${1:-}" ]]; then
  backup_input="${1:-}"
  candidate_path="$backup_input"
  if [[ ! -f "$candidate_path" ]]; then
    candidate_path="$BACKUP_DIR/$backup_input"
  fi

  # Check if the specified backup file exists.
  if [[ ! -f "$candidate_path" ]]; then
    echo "Error: Backup file '$backup_input' does not exist in '$BACKUP_DIR'."
    exit 1
  fi

  candidate_path_abs="$(cd "$(dirname "$candidate_path")" && pwd)/$(basename "$candidate_path")"
  case "$candidate_path_abs" in
    "$BACKUP_DIR"/*) ;;
    *)
      echo "Error: Backup file must be inside '$BACKUP_DIR'."
      exit 1
      ;;
  esac

  if [[ -L "$candidate_path_abs" ]]; then
    echo "Error: Symlinked backup files are not allowed: '$candidate_path_abs'."
    exit 1
  fi

  BACKUP_FILE="$(basename "$candidate_path_abs")"
  if [[ "$BACKUP_FILE" != brewfile_backup* ]]; then
    echo "Error: Backup file '$BACKUP_FILE' does not match expected pattern 'brewfile_backup*'."
    exit 1
  fi
else
  # Find the latest backup file
  backup_candidates=()
  while IFS= read -r -d '' candidate; do
    backup_candidates+=("$(basename "$candidate")")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'brewfile_backup*' -print0)

  if [[ ${#backup_candidates[@]} -eq 0 ]]; then
    echo "Error: No backup files found in '$BACKUP_DIR'."
    exit 1
  fi

  mapfile -t sorted_candidates < <(printf '%s\n' "${backup_candidates[@]}" | sort)
  BACKUP_FILE="${sorted_candidates[$((${#sorted_candidates[@]} - 1))]}"
fi

# Full path to the Brewfile
BREWFILE_PATH="$BACKUP_DIR/$BACKUP_FILE"

echo "Restoring Homebrew setup from '$BREWFILE_PATH'..."

# Require Homebrew to be installed before restore.
if ! command -v brew &> /dev/null; then
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_bin" ]]; then
      # This eval is scoped to known Homebrew install paths.
      eval "$($brew_bin shellenv)"
      break
    fi
  done
fi

if ! command -v brew &> /dev/null; then
  echo "Error: Homebrew is not installed or not available on PATH."
  echo "Install Homebrew first, then rerun this script."
  exit 1
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
