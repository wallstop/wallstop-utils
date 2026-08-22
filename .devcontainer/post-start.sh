#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# post-start.sh: volume-mounted cache ownership self-heal.
#
# The devcontainer mounts persistent named volumes directly at
# /home/vscode/.npm and /home/vscode/.cache/*. When a mount target is absent
# from the base image, Docker provisions the mount point as root-owned, and
# because the volumes persist across rebuilds (${devcontainerId}-*), the
# root-owned content survives forever. Non-root npm/pip/pre-commit/opencode
# then fail with EACCES (for example: mkdir /home/vscode/.npm/_cacache).
#
# This script runs on every container start (postStartCommand) and restores
# user ownership of those cache trees before the first tool touches them. It
# is non-blocking: failures warn but never break the session.
# ---------------------------------------------------------------------------

_log() { echo "[devcontainer] $*"; }
_warn() { echo "[devcontainer] WARNING: $*" >&2; }

_can_use_sudo_non_interactive() {
  if ! command -v sudo > /dev/null 2>&1; then
    return 1
  fi
  sudo -n true > /dev/null 2>&1
}

_find_root_owned_cache_mounts() {
  local uid="$1"
  local cache_path=''
  while IFS= read -r cache_path; do
    [[ -d "${cache_path}" ]] || continue
    if [[ -n "$(find "${cache_path}" -maxdepth 3 ! -user "${uid}" -print -quit 2> /dev/null)" ]]; then
      printf '%s\n' "${cache_path}"
    fi
  done < <(printf '%s\n' "${HOME}/.npm" "${HOME}/.cache")
}

_repair_cache_mount_ownership() {
  local uid=''
  local gid=''
  uid="$(id -u)"
  gid="$(id -g)"

  local stale_paths=''
  stale_paths="$(_find_root_owned_cache_mounts "${uid}")"
  if [[ -z "${stale_paths}" ]]; then
    _log "Cache mount ownership already OK for uid ${uid}; no repair needed."
    return 0
  fi

  local stale_display="${stale_paths//$'\n'/, }"
  if ! _can_use_sudo_non_interactive; then
    _warn "E_DEVCONTAINER_CACHE_OWNERSHIP_UNREPAIRABLE: root-owned files under '${stale_display}' but passwordless sudo is unavailable; npm/pip/opencode may fail with EACCES."
    return 1
  fi

  _log "Repairing root-owned cache mounts: ${stale_display}..."
  # shellcheck disable=SC2086 # Intentional word split: newline-delimited absolute paths contain no spaces.
  if ! sudo -n chown -R "${uid}:${gid}" ${stale_paths}; then
    _warn "E_DEVCONTAINER_CACHE_OWNERSHIP_FAILED: unable to chown '${stale_display}' to uid ${uid}."
    return 1
  fi

  _log "Cache mount ownership repaired."
}

_repair_cache_mount_ownership || _warn "Cache ownership repair failed on start (non-blocking); rerun 'bash .devcontainer/post-start.sh' after fixing sudo access."

_log "post-start complete."
