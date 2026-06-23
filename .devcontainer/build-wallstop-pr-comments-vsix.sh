#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_log() { echo "[devcontainer:extension] $*"; }
_warn() { echo "[devcontainer:extension] WARNING: $*" >&2; }

extension_dir="${ROOT_DIR}/Extensions/WallstopPrComments"
vsix_relative_path="dist/wallstop-pr-comments-devcontainer.vsix"
vsix_path="${extension_dir}/${vsix_relative_path}"

if [[ ! -f "${extension_dir}/package.json" ]]; then
  _warn "E_DEVCONTAINER_EXTENSION_PACKAGE_MISSING: expected package.json at '${extension_dir}/package.json'."
  exit 1
fi

if ! command -v npm > /dev/null 2>&1; then
  _warn "E_DEVCONTAINER_EXTENSION_NPM_NOT_AVAILABLE: npm is required to package Wallstop PR Comments."
  exit 1
fi

_log "Restoring Wallstop PR Comments extension dependencies..."
cd "${extension_dir}"
npm ci

_log "Packaging Wallstop PR Comments VSIX..."
mkdir -p "$(dirname "${vsix_path}")"
npm run package:vsix -- --out "${vsix_relative_path}"

if ! test -s "${vsix_relative_path}"; then
  _warn "E_DEVCONTAINER_EXTENSION_VSIX_MISSING: package step completed but '${vsix_path}' is missing or empty."
  exit 1
fi

_log "Wallstop PR Comments VSIX ready: ${vsix_path}"
