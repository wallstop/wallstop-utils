#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}" || exit 1

echo "[devcontainer] Bootstrapping tooling..."

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_log() { echo "[devcontainer] $*"; }
_warn() { echo "[devcontainer] WARNING: $*" >&2; }

WALLSTOP_TIMEOUT_WARNING_PREFIX="[devcontainer] WARNING: "
hook_timeout_helpers_path="${ROOT_DIR}/Scripts/Utils/Common/HookTimeout.sh"
if [[ ! -f "${hook_timeout_helpers_path}" ]]; then
  _warn "E_HOOK_TIMEOUT_HELPER_MISSING: timeout helper file not found at '${hook_timeout_helpers_path}'."
  exit 1
fi

# shellcheck source=Scripts/Utils/Common/HookTimeout.sh
. "${hook_timeout_helpers_path}"

_resolve_timeout_command() {
  wallstop_resolve_timeout_command
}

_validate_timeout_seconds() {
  local timeout_seconds="$1"

  if [[ ! "${timeout_seconds}" =~ ^[0-9]+$ ]] || [[ "${timeout_seconds}" -lt 30 ]]; then
    _warn "E_HOOK_TIMEOUT_CONFIG: timeout values must be integer seconds >= 30 (received '${timeout_seconds}')."
    return 1
  fi

  return 0
}

_resolve_absolute_directory() (
  cd "$1" 2> /dev/null || return 1
  pwd
)

_run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if ! _validate_timeout_seconds "${timeout_seconds}"; then
    return 2
  fi

  local timeout_command
  if timeout_command="$(_resolve_timeout_command)"; then
    set +e
    "$timeout_command" -k 2s "${timeout_seconds}s" "$@"
    local command_exit=$?
    set -e
    if [[ $command_exit -eq 124 || $command_exit -eq 137 ]]; then
      _warn "E_HOOK_TIMEOUT: command exceeded ${timeout_seconds}s: $*"
    fi
    return $command_exit
  fi

  _warn "timeout/gtimeout is unavailable; using shell watchdog timeout for command: $*"
  local timeout_flag_file
  timeout_flag_file="$(mktemp 2> /dev/null || true)"
  if [[ -z "${timeout_flag_file}" ]]; then
    timeout_flag_file="/tmp/wallstop-devcontainer-timeout.$$.$RANDOM.flag"
  fi
  rm -f "${timeout_flag_file}"

  set +e
  WALLSTOP_TIMEOUT_COMMAND_PID=""
  WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE=""
  wallstop_start_timeout_command "$*" "$@"
  local command_pid="${WALLSTOP_TIMEOUT_COMMAND_PID}"
  local command_process_group_mode="${WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE}"
  (
    sleep "${timeout_seconds}"
    if wallstop_is_timeout_command_alive "${command_pid}" "${command_process_group_mode}"; then
      : > "${timeout_flag_file}"
      wallstop_terminate_timeout_command "${command_pid}" "${command_process_group_mode}"
    fi
  ) &
  local watchdog_pid=$!

  wait "${command_pid}"
  local fallback_exit=$?
  kill "${watchdog_pid}" > /dev/null 2>&1 || true
  wait "${watchdog_pid}" > /dev/null 2>&1 || true
  wallstop_cleanup_timeout_command_processes "${command_pid}" "${command_process_group_mode}" "$*"
  set -e

  if [[ -f "${timeout_flag_file}" ]]; then
    rm -f "${timeout_flag_file}"
    _warn "E_HOOK_TIMEOUT: command exceeded ${timeout_seconds}s: $*"
    return 124
  fi

  rm -f "${timeout_flag_file}"
  return $fallback_exit
}

_apt_index_updated=0

# ---------------------------------------------------------------------------
# PATH persistence
# Adds ~/.local/bin to the current session and writes it into ~/.bashrc and
# ~/.profile so all future interactive shells inherit it without duplication.
# ---------------------------------------------------------------------------

ensure_local_bin_on_path() {
  if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
  fi

  local profile_snippet
  # shellcheck disable=SC2016 # Intentional: $HOME must expand at shell startup, not now.
  profile_snippet='export PATH="$HOME/.local/bin:$PATH"'

  for rc_file in "${HOME}/.bashrc" "${HOME}/.profile"; do
    if [[ -f "${rc_file}" ]] && ! grep -qF 'HOME/.local/bin' "${rc_file}"; then
      printf '\n# Added by devcontainer post-create bootstrap\n%s\n' \
        "${profile_snippet}" >> "${rc_file}"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# ripgrep installation (via apt-get, skip if already present)
# ---------------------------------------------------------------------------

_install_ripgrep() {
  if command -v rg > /dev/null 2>&1; then
    _log "ripgrep is already available; skipping install."
    return 0
  fi

  if ! command -v apt-get > /dev/null 2>&1; then
    _warn "apt-get not available; cannot install ripgrep."
    return 1
  fi

  if ! _can_use_sudo_non_interactive; then
    _warn "sudo is unavailable or requires a password; cannot install ripgrep."
    return 1
  fi

  if ! _ensure_apt_index_updated; then
    return 1
  fi

  _log "Installing ripgrep via apt-get..."
  local install_output
  if install_output="$(sudo apt-get install -y --no-install-recommends ripgrep 2>&1)"; then
    :
  else
    _warn "apt-get install ripgrep failed: ${install_output}"
    return 1
  fi

  if ! command -v rg > /dev/null 2>&1; then
    _warn "ripgrep not found after installation."
    return 1
  fi

  return 0
}

_can_use_sudo_non_interactive() {
  if ! command -v sudo > /dev/null 2>&1; then
    return 1
  fi
  sudo -n true > /dev/null 2>&1
}

_ensure_apt_index_updated() {
  if ((${_apt_index_updated:-0})); then
    return 0
  fi

  _log "Refreshing apt package index..."
  local update_output
  if update_output="$(sudo apt-get update -qq 2>&1)"; then
    :
  else
    _warn "apt-get update failed: ${update_output}"
    return 1
  fi

  _apt_index_updated=1
  return 0
}

_ensure_npm_on_path() {
  if command -v npm > /dev/null 2>&1; then
    return 0
  fi

  local npm_candidate=''
  local npm_dir=''
  local node_path=''
  local node_real_path=''
  local node_dir=''
  local nvm_root=''
  local npm_version=''
  local best_npm_path=''
  local best_npm_version=''
  local -a nvm_roots=()

  if node_path="$(command -v node 2> /dev/null)"; then
    node_dir="$(dirname "${node_path}")"
    npm_candidate="${node_dir}/npm"
    if [[ -x "${npm_candidate}" ]]; then
      npm_dir="${node_dir}"
    else
      node_real_path="$(readlink -f "${node_path}" 2> /dev/null || true)"
      if [[ -n "${node_real_path}" ]]; then
        node_dir="$(dirname "${node_real_path}")"
        npm_candidate="${node_dir}/npm"
        if [[ -x "${npm_candidate}" ]]; then
          npm_dir="${node_dir}"
        fi
      fi
    fi
  fi

  if [[ -z "${npm_dir}" ]]; then
    if [[ -n "${NVM_DIR:-}" ]]; then
      nvm_roots+=("${NVM_DIR}")
    fi
    nvm_roots+=("${HOME}/.nvm" "/usr/local/share/nvm")

    for nvm_root in "${nvm_roots[@]}"; do
      if ! compgen -G "${nvm_root}/versions/node/*/bin/npm" > /dev/null; then
        continue
      fi

      for npm_candidate in "${nvm_root}/versions/node"/*/bin/npm; do
        if [[ ! -x "${npm_candidate}" ]]; then
          continue
        fi

        npm_version="${npm_candidate%/bin/npm}"
        npm_version="${npm_version##*/}"
        npm_version="${npm_version#v}"

        if [[ -z "${best_npm_version}" ]] || [[ "$(printf '%s\n%s\n' "${best_npm_version}" "${npm_version}" | sort -V | tail -n 1)" == "${npm_version}" ]]; then
          best_npm_version="${npm_version}"
          best_npm_path="${npm_candidate}"
        fi
      done
    done

    if [[ -n "${best_npm_path}" ]]; then
      npm_dir="$(dirname "${best_npm_path}")"
    fi
  fi

  if [[ -n "${npm_dir}" ]] && [[ ":${PATH}:" != *":${npm_dir}:"* ]]; then
    export PATH="${npm_dir}:${PATH}"
  fi

  if command -v npm > /dev/null 2>&1; then
    _log "npm restored on PATH via node-aligned discovery."
    return 0
  fi

  return 1
}

_test_codex_path_is_local_bin_entry() {
  local codex_path="$1"
  local codex_dir=''
  local codex_dir_real=''
  local local_bin_path="${HOME}/.local/bin"
  local local_bin_real_path=''

  if [[ -z "${codex_path}" || "$(basename "${codex_path}")" != "codex" ]]; then
    return 1
  fi

  codex_dir="$(dirname "${codex_path}")"
  if [[ ! -d "${codex_dir}" || ! -d "${local_bin_path}" ]]; then
    return 1
  fi

  codex_dir_real="$(cd -P "${codex_dir}" && pwd -P)"
  local_bin_real_path="$(cd -P "${local_bin_path}" && pwd -P)"
  [[ "${codex_dir_real}" == "${local_bin_real_path}" ]]
}

_resolve_codex_npm_package_bin() {
  local npm_root_output=''
  local npm_root=''
  local package_dir=''
  local package_manifest_path=''
  local package_bin_path=''

  if ! command -v node > /dev/null 2>&1; then
    return 1
  fi

  if ! npm_root_output="$(npm root --global 2> /dev/null)"; then
    return 1
  fi

  while IFS= read -r npm_root; do
    if [[ -z "${npm_root}" || "${npm_root}" == "undefined" || "${npm_root}" == "null" ]]; then
      continue
    fi

    if [[ "${npm_root}" != /* ]]; then
      if ! npm_root="$(_resolve_absolute_directory "${npm_root}")"; then
        continue
      fi
    fi

    package_dir="${npm_root}/@openai/codex"
    package_manifest_path="${package_dir}/package.json"
    if [[ ! -f "${package_manifest_path}" ]]; then
      continue
    fi

    package_bin_path="$(
      node -e '
const fs = require("fs");
const path = require("path");
const manifestPath = process.argv[1];
const packageDir = path.dirname(manifestPath);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const bin = typeof manifest.bin === "string" ? manifest.bin : manifest.bin && manifest.bin.codex;
if (!bin) {
  process.exit(1);
}
const resolved = path.resolve(packageDir, bin);
const relative = path.relative(packageDir, resolved);
if (relative.startsWith("..") || path.isAbsolute(relative)) {
  process.exit(1);
}
process.stdout.write(resolved);
' "${package_manifest_path}" 2> /dev/null || true
    )"

    if [[ -n "${package_bin_path}" && -x "${package_bin_path}" ]]; then
      printf '%s\n' "${package_bin_path}"
      return 0
    fi
  done <<< "${npm_root_output}"

  return 1
}

_test_codex_local_bin_is_npm_managed() {
  local codex_path="$1"
  local package_bin_path=''
  local codex_real_path=''
  local package_bin_real_path=''

  if [[ ! -x "${codex_path}" ]]; then
    return 1
  fi

  if ! _test_codex_path_is_local_bin_entry "${codex_path}"; then
    return 1
  fi

  if ! package_bin_path="$(_resolve_codex_npm_package_bin)"; then
    return 1
  fi

  codex_real_path="$(readlink -f "${codex_path}" 2> /dev/null || true)"
  package_bin_real_path="$(readlink -f "${package_bin_path}" 2> /dev/null || true)"
  [[ -n "${codex_real_path}" && -n "${package_bin_real_path}" && "${codex_real_path}" == "${package_bin_real_path}" ]]
}

_resolve_codex_npm_global_bin() {
  local npm_prefix_output=''
  local npm_prefix=''
  local npm_prefix_command=''
  local existing_prefix=''
  local prefix_codex_path=''
  local codex_link_path="${HOME}/.local/bin/codex"
  local -a npm_prefixes=()

  for npm_prefix_command in "prefix --global" "config get prefix"; do
    case "${npm_prefix_command}" in
      "prefix --global")
        if ! npm_prefix_output="$(npm prefix --global 2> /dev/null)"; then
          continue
        fi
        ;;
      "config get prefix")
        if ! npm_prefix_output="$(npm config get prefix 2> /dev/null)"; then
          continue
        fi
        ;;
    esac

    while IFS= read -r npm_prefix; do
      if [[ -z "${npm_prefix}" || "${npm_prefix}" == "undefined" || "${npm_prefix}" == "null" ]]; then
        continue
      fi

      if [[ "${npm_prefix}" != /* ]]; then
        if ! npm_prefix="$(_resolve_absolute_directory "${npm_prefix}")"; then
          continue
        fi
      fi

      for existing_prefix in "${npm_prefixes[@]}"; do
        if [[ "${existing_prefix}" == "${npm_prefix}" ]]; then
          continue 2
        fi
      done

      npm_prefixes+=("${npm_prefix}")
    done <<< "${npm_prefix_output}"
  done

  for npm_prefix in "${npm_prefixes[@]}"; do
    prefix_codex_path="${npm_prefix}/bin/codex"
    if _test_codex_path_is_local_bin_entry "${prefix_codex_path}"; then
      if _test_codex_local_bin_is_npm_managed "${prefix_codex_path}"; then
        printf '%s\n' "${codex_link_path}"
        return 0
      fi
      continue
    fi

    if [[ -x "${prefix_codex_path}" ]]; then
      printf '%s\n' "${prefix_codex_path}"
      return 0
    fi
  done

  return 1
}

_resolve_codex_path_without_local_bin() {
  local codex_link_path="${HOME}/.local/bin/codex"
  local local_bin_path="${HOME}/.local/bin"
  local local_bin_real_path="${local_bin_path}"
  local path_entry=''
  local path_entry_real=''
  local filtered_path=''
  local codex_path=''
  local codex_path_dir=''
  local codex_path_dir_real=''
  local codex_real_path=''
  local codex_link_real_path=''
  local old_ifs="${IFS}"
  local -a path_entries=()
  local -a filtered_path_entries=()

  if [[ -d "${local_bin_path}" ]]; then
    local_bin_real_path="$(cd -P "${local_bin_path}" && pwd -P)"
  fi

  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  IFS="${old_ifs}"
  for path_entry in "${path_entries[@]}"; do
    if [[ -z "${path_entry}" ]]; then
      continue
    fi

    path_entry_real="${path_entry}"
    if [[ -d "${path_entry}" ]]; then
      path_entry_real="$(cd -P "${path_entry}" && pwd -P)"
    fi

    if [[ "${path_entry}" == "${local_bin_path}" || "${path_entry_real}" == "${local_bin_real_path}" ]]; then
      continue
    fi

    filtered_path_entries+=("${path_entry}")
  done

  if ((${#filtered_path_entries[@]} == 0)); then
    return 1
  fi

  IFS=':'
  filtered_path="${filtered_path_entries[*]}"
  IFS="${old_ifs}"

  codex_path="$(PATH="${filtered_path}" command -v codex 2> /dev/null || true)"
  if [[ -z "${codex_path}" || "${codex_path}" == "${codex_link_path}" || ! -x "${codex_path}" ]]; then
    return 1
  fi

  codex_path_dir="$(dirname "${codex_path}")"
  codex_path_dir_real="${codex_path_dir}"
  if [[ -d "${codex_path_dir}" ]]; then
    codex_path_dir_real="$(cd -P "${codex_path_dir}" && pwd -P)"
  fi
  if [[ "${codex_path_dir_real}" == "${local_bin_real_path}" ]]; then
    return 1
  fi

  codex_real_path="$(readlink -f "${codex_path}" 2> /dev/null || true)"
  codex_link_real_path="$(readlink -f "${codex_link_path}" 2> /dev/null || true)"
  if [[ -n "${codex_real_path}" && -n "${codex_link_real_path}" && "${codex_real_path}" == "${codex_link_real_path}" ]]; then
    return 1
  fi

  printf '%s\n' "${codex_path}"
  return 0
}

_link_codex_into_local_bin() {
  local codex_source_path="$1"
  local codex_link_path="${HOME}/.local/bin/codex"

  if [[ -z "${codex_source_path}" ]]; then
    _warn "E_DEVCONTAINER_CODEX_LINK_FAILED: Codex source path is empty; cannot update ${codex_link_path}."
    return 1
  fi

  if [[ "${codex_source_path}" != /* ]]; then
    local codex_source_dir
    if codex_source_dir="$(_resolve_absolute_directory "$(dirname "${codex_source_path}")")"; then
      codex_source_path="${codex_source_dir}/$(basename "${codex_source_path}")"
    fi
  fi

  mkdir -p "${HOME}/.local/bin"

  if [[ "${codex_source_path}" == "${codex_link_path}" ]]; then
    _warn "E_DEVCONTAINER_CODEX_LINK_FAILED: refusing to use ${codex_link_path} as its own link source."
    return 1
  fi

  if [[ ! -x "${codex_source_path}" ]]; then
    _warn "E_DEVCONTAINER_CODEX_SOURCE_NOT_EXECUTABLE: Codex source '${codex_source_path}' is missing or not executable."
    return 1
  fi

  if ! ln -sfn "${codex_source_path}" "${codex_link_path}"; then
    _warn "E_DEVCONTAINER_CODEX_LINK_FAILED: failed to link ${codex_link_path} to '${codex_source_path}'."
    return 1
  fi

  local linked_target=''
  linked_target="$(readlink "${codex_link_path}" 2> /dev/null || true)"
  if [[ -n "${linked_target}" && "${linked_target}" != /* ]]; then
    linked_target="$(cd "$(dirname "${codex_link_path}")" && pwd)/${linked_target}"
  fi

  if [[ "${linked_target}" != "${codex_source_path}" ]]; then
    _warn "E_DEVCONTAINER_CODEX_LINK_FAILED: ${codex_link_path} points to '${linked_target}' after link; expected '${codex_source_path}'."
    return 1
  fi

  if [[ ! -x "${codex_link_path}" ]]; then
    _warn "E_DEVCONTAINER_CODEX_LINK_FAILED: ${codex_link_path} is not executable after linking to '${codex_source_path}'."
    return 1
  fi

  return 0
}

_install_codex_cli() {
  local package_spec='@openai/codex@latest'

  if ! _ensure_npm_on_path; then
    _warn "npm is unavailable; cannot install Codex CLI (${package_spec})."
    return 1
  fi

  _log "Installing/updating Codex CLI via npm (${package_spec})..."
  local max_attempts=3
  local attempt=1
  local retry_delay_seconds=2
  local npm_install_timeout_seconds="${WALLSTOP_DEVCONTAINER_CODEX_NPM_TIMEOUT_SECONDS:-180}"

  while ((attempt <= max_attempts)); do
    local install_output
    set +e
    install_output="$(_run_with_timeout "${npm_install_timeout_seconds}" npm install --global "${package_spec}" 2>&1)"
    local install_exit=$?
    set -e

    if ((install_exit == 0)); then
      local codex_path=''
      if codex_path="$(_resolve_codex_npm_global_bin)"; then
        if _test_codex_path_is_local_bin_entry "${codex_path}"; then
          _log "Codex CLI available at ${codex_path}."
          return 0
        fi

        if _link_codex_into_local_bin "${codex_path}"; then
          _log "Codex CLI available at ${codex_path}."
          return 0
        fi
      fi

      if codex_path="$(_resolve_codex_path_without_local_bin)" && _link_codex_into_local_bin "${codex_path}"; then
        _log "Codex CLI available at ${codex_path}."
        return 0
      fi

      _warn "E_DEVCONTAINER_CODEX_BINARY_UNRESOLVED: Codex CLI install succeeded but no executable npm-managed codex binary could be resolved outside stale local-bin fallbacks."
      return 1
    fi

    if ((install_exit == 124)); then
      _warn "Codex CLI npm install attempt ${attempt}/${max_attempts} timed out after ${npm_install_timeout_seconds}s: ${install_output}"
    else
      _warn "Codex CLI npm install attempt ${attempt}/${max_attempts} failed: ${install_output}"
    fi
    if ((attempt < max_attempts)); then
      _log "Retrying Codex CLI npm install in ${retry_delay_seconds}s..."
      sleep "${retry_delay_seconds}"
      retry_delay_seconds=$((retry_delay_seconds * 2))
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

_should_enable_codex_bootstrap() {
  local codex_toggle="${WALLSTOP_DEVCONTAINER_ENABLE_CODEX:-0}"
  codex_toggle="$(printf '%s' "${codex_toggle}" | tr '[:upper:]' '[:lower:]')"

  case "${codex_toggle}" in
    1 | true | yes | on)
      return 0
      ;;
    0 | false | no | off | '')
      return 1
      ;;
    *)
      _warn "WALLSTOP_DEVCONTAINER_ENABLE_CODEX has unsupported value '${WALLSTOP_DEVCONTAINER_ENABLE_CODEX}'; treating Codex bootstrap as disabled."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pre-commit install strategies (ordered by preference)
# ---------------------------------------------------------------------------

_required_precommit_version() {
  local requirements_path="${ROOT_DIR}/requirements.txt"
  if [[ ! -f "${requirements_path}" ]]; then
    _warn "requirements.txt missing; cannot determine pinned pre-commit version."
    return 1
  fi

  local version=''
  version="$(awk -F'==' '/^[[:space:]]*pre-commit==/ { gsub(/[[:space:]].*$/, "", $2); print $2; exit }' "${requirements_path}")"
  if [[ -z "${version}" ]]; then
    _warn "requirements.txt does not contain a pre-commit==<version> pin."
    return 1
  fi

  printf '%s\n' "${version}"
}

_precommit_version_matches_pin() {
  local required_version="$1"
  local current_version=''
  local current_output=''
  local version_exit=0

  set +e
  current_output="$(pre-commit --version 2> /dev/null)"
  version_exit=$?
  set -e

  if ((version_exit != 0)); then
    return 1
  fi

  current_version="$(awk '/^pre-commit[[:space:]]+/ { print $2; exit }' <<< "${current_output}")"
  [[ "${current_version}" == "${required_version}" ]]
}

# Strategy 1: use pipx if it is already present on PATH.
_install_via_existing_pipx() {
  local required_version="$1"

  if ! command -v pipx > /dev/null 2>&1; then
    return 1
  fi
  _log "Strategy 1: using existing pipx to install pre-commit ${required_version}..."
  pipx install "pre-commit==${required_version}" --force
}

# Strategy 2: install pipx via apt-get, then use it.
_install_via_apt_pipx() {
  local required_version="$1"

  if ! command -v apt-get > /dev/null 2>&1; then
    return 1
  fi

  if ! _can_use_sudo_non_interactive; then
    _warn "Strategy 2 skipped: sudo is unavailable or requires a password."
    return 1
  fi

  if ! _ensure_apt_index_updated; then
    _warn "Strategy 2 skipped: apt package index refresh failed."
    return 1
  fi

  _log "Strategy 2: installing pipx via apt-get..."
  local install_output
  if install_output="$(sudo apt-get install -y --no-install-recommends pipx 2>&1)"; then
    :
  else
    _warn "Strategy 2 failed to install pipx: ${install_output}"
    return 1
  fi
  pipx ensurepath || true
  if ! pipx install "pre-commit==${required_version}" --force; then
    _warn "Strategy 2 failed to install pre-commit via pipx."
    return 1
  fi
}

# Strategy 3: create a dedicated venv and symlink the binary into ~/.local/bin.
_install_via_venv() {
  local required_version="$1"

  if ! command -v python3 > /dev/null 2>&1; then
    return 1
  fi
  # Ensure the venv module is available (not always installed by default on Ubuntu 24.04).
  if ! python3 -c 'import venv' 2> /dev/null; then
    _log "venv module not found; attempting to install python3-venv via apt-get..."
    if command -v apt-get > /dev/null 2>&1; then
      if ! _can_use_sudo_non_interactive; then
        _warn "Strategy 3 skipped apt fallback: sudo is unavailable or requires a password."
      elif ! _ensure_apt_index_updated; then
        _warn "Strategy 3 skipped apt fallback: apt package index refresh failed."
      else
        local install_output
        if install_output="$(sudo apt-get install -y --no-install-recommends python3-venv 2>&1)"; then
          :
        else
          _warn "Strategy 3 could not install python3-venv: ${install_output}"
        fi
      fi
    fi
    if ! python3 -c 'import venv' 2> /dev/null; then
      _warn "python3-venv is not available; cannot use venv strategy."
      return 1
    fi
  fi
  _log "Strategy 3: creating dedicated venv at ~/.local/venvs/pre-commit..."
  local venv_dir
  venv_dir="${HOME}/.local/venvs/pre-commit"
  python3 -m venv "${venv_dir}"
  "${venv_dir}/bin/pip" install --quiet --upgrade pip
  "${venv_dir}/bin/pip" install --quiet --requirement "${ROOT_DIR}/requirements.txt"
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${venv_dir}/bin/pre-commit" "${HOME}/.local/bin/pre-commit"
  _log "pre-commit ${required_version} installed via venv and symlinked to ~/.local/bin."
}

# Strategy 4 (nuclear fallback): override the PEP 668 externally-managed marker.
# This is a last-resort option; prefer the strategies above on Ubuntu 24.04.
_install_via_break_system_packages() {
  local required_version="$1"

  if ! command -v python3 > /dev/null 2>&1; then
    return 1
  fi
  _warn "Strategy 4 (nuclear fallback): using --break-system-packages."
  python3 -m pip install --user --break-system-packages --upgrade pip
  python3 -m pip install --user --break-system-packages --requirement "${ROOT_DIR}/requirements.txt"
  _log "pre-commit ${required_version} installed with --break-system-packages fallback."
}

_install_precommit() {
  local required_version="$1"

  if _install_via_existing_pipx "${required_version}"; then
    return 0
  fi
  if _install_via_apt_pipx "${required_version}"; then
    return 0
  fi
  if _install_via_venv "${required_version}"; then
    return 0
  fi
  if _install_via_break_system_packages "${required_version}"; then
    return 0
  fi
  _warn "All pre-commit install strategies failed."
  return 1
}

_ensure_precommit_cli_ready() {
  local required_version="$1"

  if [[ -z "${required_version}" ]]; then
    _warn "pre-commit install skipped because the pinned version could not be determined."
    return 1
  fi

  if command -v pre-commit > /dev/null 2>&1 && _precommit_version_matches_pin "${required_version}"; then
    _log "pre-commit ${required_version} is already available; skipping install."
    return 0
  fi

  if command -v pre-commit > /dev/null 2>&1; then
    _warn "pre-commit is available but does not match pinned version ${required_version}; reinstalling."
  else
    _log "pre-commit is not available; installing pinned version ${required_version}."
  fi

  if ! _install_precommit "${required_version}"; then
    ensure_local_bin_on_path || _warn "PATH refresh failed after pre-commit install attempt; continuing without profile updates."
    _warn "E_DEVCONTAINER_PRECOMMIT_INSTALL_FAILED: unable to install pinned pre-commit ${required_version}; hooks will not be registered with an unverified CLI."
    return 1
  fi

  ensure_local_bin_on_path || _warn "PATH refresh failed after pre-commit install; continuing without profile updates."
  if command -v pre-commit > /dev/null 2>&1 && _precommit_version_matches_pin "${required_version}"; then
    _log "pre-commit ${required_version} verified after install."
    return 0
  fi

  _warn "E_DEVCONTAINER_PRECOMMIT_VERSION_DRIFT: pre-commit install completed but the CLI on PATH does not match pinned version ${required_version}; hooks will not be registered with an unverified CLI."
  return 1
}

# ---------------------------------------------------------------------------
# Install pre-commit (skip if already present)
# ---------------------------------------------------------------------------

ensure_local_bin_on_path || _warn "PATH setup failed; continuing without profile updates."

# ---------------------------------------------------------------------------
# Install ripgrep (skip if already present)
# ---------------------------------------------------------------------------

_install_ripgrep || _warn "ripgrep installation failed (non-blocking)."

required_precommit_version="$(_required_precommit_version || true)"
precommit_cli_ready=0
if _ensure_precommit_cli_ready "${required_precommit_version}"; then
  precommit_cli_ready=1
fi

# ---------------------------------------------------------------------------
# Install/update OpenAI Codex CLI (non-blocking)
# ---------------------------------------------------------------------------

if _should_enable_codex_bootstrap; then
  _install_codex_cli || _warn "Codex CLI install/update failed (non-blocking)."
else
  _log "Codex CLI bootstrap disabled (set WALLSTOP_DEVCONTAINER_ENABLE_CODEX=1 to enable)."
fi
ensure_local_bin_on_path || _warn "PATH refresh failed after Codex install; continuing without profile updates."

# ---------------------------------------------------------------------------
# Register git hooks via pre-commit
# ---------------------------------------------------------------------------

if [[ "${precommit_cli_ready}" -eq 1 ]]; then
  if command -v pwsh > /dev/null 2>&1; then
    if pwsh -NoLogo -NoProfile -Command "& { . './Scripts/Utils/Common/GitHookRegistrationHelpers.ps1'; Assert-GitHookRegistration -RepositoryRoot '.' -Repair | Out-Null }"; then
      _log "git hooksPath verified via shared hook registration preflight."
    else
      _warn "shared hook registration preflight failed; falling back to direct core.hooksPath repair."
      git -C "${ROOT_DIR}" config --local core.hooksPath .githooks || true
    fi
  else
    git -C "${ROOT_DIR}" config --local core.hooksPath .githooks || true
  fi

  if pre-commit install --hook-type pre-commit --hook-type pre-push; then
    _log "pre-commit hooks installed."
  else
    _warn "pre-commit install returned non-zero; hooks may not be fully registered."
  fi

  precommit_prewarm_timeout_seconds="${WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS:-180}"
  precommit_prewarm_inner_timeout_seconds=""
  if ! _validate_timeout_seconds "${precommit_prewarm_timeout_seconds}"; then
    _warn "pre-commit hook environment prewarm skipped because WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS is invalid."
  else
    precommit_prewarm_shutdown_buffer_seconds=15
    precommit_prewarm_inner_timeout_seconds=$((precommit_prewarm_timeout_seconds - precommit_prewarm_shutdown_buffer_seconds))
  fi

  if [[ -z "${precommit_prewarm_inner_timeout_seconds:-}" ]]; then
    :
  elif [[ "${precommit_prewarm_inner_timeout_seconds}" -lt 30 ]]; then
    _warn "E_HOOK_TIMEOUT_CONFIG: WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS must leave at least 30s for inner pre-commit recovery after a ${precommit_prewarm_shutdown_buffer_seconds}s shutdown buffer (received '${precommit_prewarm_timeout_seconds}')."
  elif command -v pwsh > /dev/null 2>&1; then
    if _run_with_timeout "${precommit_prewarm_timeout_seconds}" pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1 -InstallHooksOnly -TimeoutSeconds "${precommit_prewarm_inner_timeout_seconds}"; then
      _log "pre-commit hook environments pre-warmed."
    else
      _warn "pre-commit hook environment prewarm failed; validation preflight will retry later."
    fi
  elif _run_with_timeout "${precommit_prewarm_timeout_seconds}" pre-commit install-hooks; then
    _log "pre-commit hook environments pre-warmed."
  else
    _warn "pre-commit install-hooks returned non-zero; validation preflight will retry later."
  fi
else
  _warn "pre-commit CLI is not verified against requirements.txt; git hooks not registered."
fi

# ---------------------------------------------------------------------------
# PowerShell quality modules (non-blocking)
# ---------------------------------------------------------------------------

if command -v pwsh > /dev/null 2>&1; then
  _log "Installing PowerShell modules (Pester, PSScriptAnalyzer)..."
  pwsh -NoLogo -NoProfile -File ./Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules Pester,PSScriptAnalyzer || _warn "pwsh exited non-zero during module install; container is still usable."
else
  _warn "pwsh is unavailable; skipping PowerShell module install."
fi

# ---------------------------------------------------------------------------
# Validation preflight (non-blocking)
# ---------------------------------------------------------------------------

if command -v pwsh > /dev/null 2>&1; then
  _log "Running validation preflight (non-blocking)..."
  preflight_timeout_seconds="${WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS:-180}"
  if _run_with_timeout "$preflight_timeout_seconds" pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly; then
    _log "Validation preflight passed."
  else
    _warn "Validation preflight failed or timed out (timeout=${preflight_timeout_seconds}s); run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly' before commit/push."
  fi
else
  _warn "pwsh is unavailable; skipping validation preflight."
fi

_log "Ready."
