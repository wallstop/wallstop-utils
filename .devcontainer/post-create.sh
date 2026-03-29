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
}

# ---------------------------------------------------------------------------
# pre-commit install strategies (ordered by preference)
# ---------------------------------------------------------------------------

# Strategy 1: use pipx if it is already present on PATH.
_install_via_existing_pipx() {
  if ! command -v pipx > /dev/null 2>&1; then
    return 1
  fi
  _log "Strategy 1: using existing pipx to install pre-commit..."
  pipx install pre-commit --force
}

# Strategy 2: install pipx via apt-get, then use it.
_install_via_apt_pipx() {
  if ! command -v apt-get > /dev/null 2>&1; then
    return 1
  fi
  _log "Strategy 2: installing pipx via apt-get..."
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends pipx
  pipx ensurepath || true
  pipx install pre-commit --force
}

# Strategy 3: create a dedicated venv and symlink the binary into ~/.local/bin.
_install_via_venv() {
  if ! command -v python3 > /dev/null 2>&1; then
    return 1
  fi
  # Ensure the venv module is available (not always installed by default on Ubuntu 24.04).
  if ! python3 -c 'import venv' 2> /dev/null; then
    _log "venv module not found; attempting to install python3-venv via apt-get..."
    if command -v apt-get > /dev/null 2>&1; then
      sudo apt-get install -y --no-install-recommends python3-venv 2> /dev/null || true
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
  "${venv_dir}/bin/pip" install --quiet --upgrade pip pre-commit
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${venv_dir}/bin/pre-commit" "${HOME}/.local/bin/pre-commit"
  _log "pre-commit installed via venv and symlinked to ~/.local/bin."
}

# Strategy 4 (nuclear fallback): override the PEP 668 externally-managed marker.
# This is a last-resort option; prefer the strategies above on Ubuntu 24.04.
_install_via_break_system_packages() {
  if ! command -v python3 > /dev/null 2>&1; then
    return 1
  fi
  _warn "Strategy 4 (nuclear fallback): using --break-system-packages."
  python3 -m pip install --user --break-system-packages --upgrade pip pre-commit
}

_install_precommit() {
  if _install_via_existing_pipx; then
    return 0
  fi
  if _install_via_apt_pipx; then
    return 0
  fi
  if _install_via_venv; then
    return 0
  fi
  if _install_via_break_system_packages; then
    return 0
  fi
  _warn "All pre-commit install strategies failed."
  return 1
}

# ---------------------------------------------------------------------------
# Install pre-commit (skip if already present)
# ---------------------------------------------------------------------------

ensure_local_bin_on_path

if command -v pre-commit > /dev/null 2>&1; then
  _log "pre-commit is already available; skipping install."
else
  _install_precommit || true
  # Refresh PATH in case a new install landed in ~/.local/bin.
  ensure_local_bin_on_path
fi

# ---------------------------------------------------------------------------
# Register git hooks via pre-commit
# ---------------------------------------------------------------------------

if command -v pre-commit > /dev/null 2>&1; then
  git config --local core.hooksPath .githooks || true
  if pre-commit install --hook-type pre-commit --hook-type pre-push; then
    _log "pre-commit hooks installed."
  else
    _warn "pre-commit install returned non-zero; hooks may not be fully registered."
  fi
else
  _warn "pre-commit not found after install step; git hooks not registered."
fi

# ---------------------------------------------------------------------------
# PowerShell quality modules (non-blocking)
# ---------------------------------------------------------------------------

if command -v pwsh > /dev/null 2>&1; then
  _log "Installing PowerShell modules (Pester, PSScriptAnalyzer)..."
  # shellcheck disable=SC2016 # Intentional: $_ is a PowerShell variable, not a bash one.
  pwsh -NoLogo -NoProfile -Command '
    try {
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
      Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -ErrorAction Stop
      Install-Module PSScriptAnalyzer -Scope CurrentUser -MinimumVersion 1.21.0 -Force -ErrorAction Stop
      Write-Host "[devcontainer] PowerShell modules installed."
    } catch {
      Write-Warning ("[devcontainer] PowerShell module bootstrap skipped: " + $_.Exception.Message)
    }
  ' || _warn "pwsh exited non-zero during module install; container is still usable."
else
  _warn "pwsh is unavailable; skipping PowerShell module install."
fi

_log "Ready."
