#!/usr/bin/env bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Enable nullglob so globs that match nothing expand to nothing
shopt -s nullglob

if ! command -v git > /dev/null 2>&1; then
  echo "E_BACKUP_MAC_GIT_NOT_AVAILABLE: git is required for macOS backup but was not found on PATH." >&2
  exit 1
fi

if ! command -v brew > /dev/null 2>&1; then
  echo "E_BACKUP_MAC_BREW_NOT_AVAILABLE: Homebrew is required for macOS backup but was not found on PATH." >&2
  exit 1
fi

brew update
brew upgrade

# Get the directory where the script is located and resolve to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly BACKUP_MANAGED_PATH="Config/"

get_output_preview() {
  local raw_output="${1-}"
  local max_chars="${2:-240}"
  local normalized

  normalized="${raw_output//$'\r'/ }"
  normalized="${normalized//$'\n'/ | }"
  normalized="$(printf '%s' "$normalized" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  if [[ -z "$normalized" ]]; then
    printf '(none)'
    return
  fi

  if ((${#normalized} > max_chars)); then
    printf '%s…' "${normalized:0:max_chars}"
  else
    printf '%s' "$normalized"
  fi
}

assert_backup_git_branch() {
  local repo_root="$1"
  local expected_branch="$2"
  local current_branch
  local branch_output
  local branch_exit
  local branch_preview

  if branch_output="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>&1)"; then
    :
  else
    branch_exit=$?
    branch_preview="$(get_output_preview "$branch_output")"
    echo "E_BACKUP_GIT_BRANCH_DETECTION_FAILED: Unable to determine current branch (exitCode=$branch_exit; repositoryRoot='$repo_root'; outputPreview='$branch_preview')." >&2
    return "$branch_exit"
  fi

  current_branch="${branch_output//$'\n'/}"
  current_branch="${current_branch//$'\r'/}"

  if [[ "$current_branch" == "HEAD" ]]; then
    echo "E_BACKUP_GIT_DETACHED_HEAD: git HEAD is detached for repository '$repo_root'. Backup requires branch '$expected_branch'." >&2
    return 1
  fi

  if [[ "$current_branch" != "$expected_branch" ]]; then
    echo "E_BACKUP_GIT_BRANCH_MISMATCH: current branch is '$current_branch' but backup requires '$expected_branch' (repositoryRoot='$repo_root')." >&2
    return 1
  fi

  return 0
}

assert_backup_managed_scope_clean() {
  local repo_root="$1"
  local managed_path="$2"
  local outside_status_output
  local outside_count
  local outside_preview
  local status_exit

  if outside_status_output="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- . ":(exclude)$managed_path" 2>&1)"; then
    :
  else
    status_exit=$?
    outside_preview="$(get_output_preview "$outside_status_output")"
    echo "E_BACKUP_GIT_STATUS_FAILED: Unable to inspect out-of-scope repository changes (exitCode=$status_exit; repositoryRoot='$repo_root'; pathspec='.:(exclude)$managed_path'; outputPreview='$outside_preview')." >&2
    return "$status_exit"
  fi

  if [[ -n "$outside_status_output" ]]; then
    outside_count="$(printf '%s\n' "$outside_status_output" | awk 'NF { count++ } END { print count + 0 }')"
    outside_preview="$(get_output_preview "$outside_status_output")"
    echo "E_BACKUP_GIT_SCOPE_VIOLATION: Backup run produced out-of-scope repository changes outside managed path '$managed_path' (repositoryRoot='$repo_root'; outOfScopeCount=$outside_count; outputPreview='$outside_preview')." >&2
    return 1
  fi

  return 0
}

assert_backup_managed_scope_clean "$REPO_ROOT" "$BACKUP_MANAGED_PATH"
assert_backup_git_branch "$REPO_ROOT" "main"
if pull_output="$(git -C "$REPO_ROOT" pull --ff-only origin main 2>&1)"; then
  :
else
  pull_exit=$?
  pull_preview="$(get_output_preview "$pull_output")"
  echo "E_BACKUP_MAC_GIT_PULL_FAILED: git pull --ff-only origin main exited with code $pull_exit (repositoryRoot='$REPO_ROOT'; outputPreview='$pull_preview')." >&2
  exit "$pull_exit"
fi

# Execute Homebrew backup script
"$SCRIPT_DIR/backup_brew.sh"

# Execute WezTerm backup if config exists
WEZTERM_BACKUP="$REPO_ROOT/Scripts/Wezterm/WeztermBackup.sh"
if [[ -x "$WEZTERM_BACKUP" ]]; then
  echo "Running WezTerm backup..."
  if ! "$WEZTERM_BACKUP"; then
    echo "Warning: WezTerm backup skipped (no config found)" >&2
  fi
fi

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

assert_backup_managed_scope_clean "$REPO_ROOT" "$BACKUP_MANAGED_PATH"

current_date=$(date)
assert_backup_git_branch "$REPO_ROOT" "main"
if add_output="$(git -C "$REPO_ROOT" add -- "$BACKUP_MANAGED_PATH" 2>&1)"; then
  :
else
  add_exit=$?
  add_preview="$(get_output_preview "$add_output")"
  echo "E_BACKUP_MAC_GIT_ADD_FAILED: git add -- '$BACKUP_MANAGED_PATH' exited with code $add_exit (repositoryRoot='$REPO_ROOT'; outputPreview='$add_preview')." >&2
  exit "$add_exit"
fi

if staged_diff_output="$(git -C "$REPO_ROOT" diff --cached --quiet --exit-code 2>&1)"; then
  echo "No managed backup changes to commit"
else
  staged_diff_exit=$?
  if [[ $staged_diff_exit -ne 1 ]]; then
    staged_diff_preview="$(get_output_preview "$staged_diff_output")"
    echo "E_BACKUP_MAC_GIT_STAGED_DIFF_FAILED: Unable to inspect staged changes (exitCode=$staged_diff_exit; repositoryRoot='$REPO_ROOT'; outputPreview='$staged_diff_preview')." >&2
    exit "$staged_diff_exit"
  fi

  if commit_output="$(git -C "$REPO_ROOT" commit -m "Backup for $current_date" 2>&1)"; then
    :
  else
    commit_exit=$?
    commit_preview="$(get_output_preview "$commit_output")"
    echo "E_BACKUP_MAC_GIT_COMMIT_FAILED: git commit exited with code $commit_exit (repositoryRoot='$REPO_ROOT'; outputPreview='$commit_preview')." >&2
    exit "$commit_exit"
  fi

  assert_backup_git_branch "$REPO_ROOT" "main"
  if push_output="$(git -C "$REPO_ROOT" push origin main 2>&1)"; then
    :
  else
    push_exit=$?
    push_preview="$(get_output_preview "$push_output")"
    echo "E_BACKUP_MAC_GIT_PUSH_FAILED: git push origin main exited with code $push_exit (repositoryRoot='$REPO_ROOT'; outputPreview='$push_preview')." >&2
    exit "$push_exit"
  fi
fi

echo "Backup completed. $dotfile_count dotfiles, $script_count shell scripts, and $applescript_count AppleScript files were copied to $BACKUP_DIR"
