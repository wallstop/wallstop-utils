#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
workspace_folder="${1:-${ROOT_DIR}}"

_log() { echo "[devcontainer:init] $*"; }
_warn() { echo "[devcontainer:init] WARNING: $*" >&2; }

_resolve_powershell_command() {
  local candidate
  for candidate in pwsh pwsh.exe powershell.exe; do
    if command -v "${candidate}" > /dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done

  return 1
}

_is_windows_powershell_bridge() {
  local powershell_command="$1"
  [[ "${powershell_command}" == *.exe ]]
}

_to_powershell_path() {
  local powershell_command="$1"
  local path_value="$2"

  if _is_windows_powershell_bridge "${powershell_command}" && command -v wslpath > /dev/null 2>&1; then
    wslpath -w "${path_value}"
    return 0
  fi

  printf '%s\n' "${path_value}"
}

_lowercase_windows_drive_letter() {
  local path_value="$1"
  local drive_letter="${path_value:0:1}"
  if [[ "${path_value}" =~ ^[A-Z]:\\ ]]; then
    printf '%s%s\n' "$(printf '%s' "${drive_letter}" | tr '[:upper:]' '[:lower:]')" "${path_value:1}"
    return 0
  fi

  printf '%s\n' "${path_value}"
}

_to_devcontainer_label_path() {
  local powershell_command="$1"
  local path_value="$2"

  if _is_windows_powershell_bridge "${powershell_command}" && command -v wslpath > /dev/null 2>&1; then
    _lowercase_windows_drive_letter "$(wslpath -w "${path_value}")"
    return 0
  fi

  _lowercase_windows_drive_letter "${path_value}"
}

if powershell_command="$(_resolve_powershell_command)"; then
  powershell_script_path="$(_to_powershell_path "${powershell_command}" "${SCRIPT_DIR}/Initialize-DevcontainerHost.ps1")"
  workspace_label_path="$(_to_devcontainer_label_path "${powershell_command}" "${workspace_folder}")"
  powershell_args=(-NoLogo -NoProfile)
  if _is_windows_powershell_bridge "${powershell_command}"; then
    powershell_args+=(-ExecutionPolicy Bypass)
  fi
  powershell_args+=(
    -NonInteractive
    -File "${powershell_script_path}"
    -WorkspaceFolder "${workspace_label_path}"
  )
  "${powershell_command}" "${powershell_args[@]}" ||
    _warn "W_DEVCONTAINER_HOST_CLEANUP_FAILED: stale-container cleanup failed; continuing so Dev Containers can attempt normal startup."
else
  _warn "W_DEVCONTAINER_HOST_POWERSHELL_NOT_AVAILABLE: PowerShell is unavailable; stale-container cleanup skipped."
fi

_log "Building Wallstop PR Comments VSIX for devcontainer extension install..."
if bash "${SCRIPT_DIR}/build-wallstop-pr-comments-vsix.sh"; then
  :
else
  build_exit=$?
  if [[ "${WALLSTOP_DEVCONTAINER_REQUIRE_CUSTOM_EXTENSION:-0}" == "1" ]]; then
    exit "${build_exit}"
  fi

  _warn "W_DEVCONTAINER_EXTENSION_VSIX_BUILD_FAILED: Wallstop PR Comments VSIX build failed; continuing so the devcontainer can still start. Install host node/npm or run '.devcontainer/build-wallstop-pr-comments-vsix.sh' to enable the custom extension."
fi
