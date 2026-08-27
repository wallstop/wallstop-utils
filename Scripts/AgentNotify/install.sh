#!/usr/bin/env bash

# install.sh - Bootstrap agent-notify machine configuration and harness wiring.
#
# Secrets safety model:
#   The topic name IS the credential. This script generates it locally,
#   writes it to $HOME/.config/agent-notify/agent-notify.env (chmod 600),
#   and NEVER commits it: the repository tree is audited (--audit) so any
#   leaked topic/token fails loudly before publication.

set -euo pipefail
shopt -s nullglob

PROG="install.sh"
VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly SOURCE_BIN="$SCRIPT_DIR/bin/agent-notify"
readonly SOURCE_SHIM="$SCRIPT_DIR/adapters/nanocoder/notify-send"
readonly ADAPTER_CLAUDE="$SCRIPT_DIR/adapters/claude/settings-hooks.json"
readonly ADAPTER_CODEX="$SCRIPT_DIR/adapters/codex/hooks.json"
readonly ADAPTER_COPILOT="$SCRIPT_DIR/adapters/copilot/agent-notify.json"
readonly ADAPTER_OPENCODE="$SCRIPT_DIR/adapters/opencode/agent-notify.js"

DEFAULT_BIN_DIR="$HOME/.local/bin"
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-notify"
ENV_FILE="$ENV_DIR/agent-notify.env"

DRY_RUN=false
MODE="status"
WANT_ALL=false
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-}"
PROJECT_TARGET=""
declare -a WANT_HARNESS=()

status_line() {
  printf '%s\n' "$*"
}

diag() {
  printf '%s\n' "$*" >&2
}

usage() {
  cat << EOF
$PROG $VERSION - bootstrap agent-notify machine configuration and harness wiring.

Usage: $PROG [MODE] [TARGETS...] [OPTIONS]

Modes (default: --status):
  --status         report what is installed/configured; change nothing
  --install        install binaries plus env-file bootstrap (generates a
                   private ntfy topic on first run) and wire selected targets
  --uninstall      remove previously installed executables; copied adapters
                   are reported but left for manual removal; your env-file
                   (and therefore your topic subscription) is preserved
  --audit          verify secrets hygiene offline: env-file permissions and
                   topic shape, plus proof that no secrets are tracked in
                   this repository

Targets for --install/--uninstall (repeatable, or --all):
  --all            all five targets below
  --claude         merge hook block into ~/.claude/settings.json (non-destructive)
  --codex          copy hooks into ~/.codex/            (no-clobber)
  --copilot        copy hooks into ~/.copilot/hooks/    (no-clobber)
  --opencode       copy plugin into ~/.config/opencode/plugins (no-clobber)
  --nanocoder      install notify-send shim next to agent-notify

Options:
  --bin-dir DIR    executable install location (default: $DEFAULT_BIN_DIR)
  --project DIR    additionally wire repository-local copies (.codex/, .copilot/)
                   inside an arbitrary checkout at DIR (no-clobber)
  --show-topic     print the configured topic again (phone subscription input)
  --dry-run        print planned actions instead of performing them
  -h | --help      this message

Exit codes: 0 success; 1 actionable failure with stable E_AGENT_NOTIFY_* diagnostics on stderr.
EOF
}

require_cmd() {
  local name=$1 purpose=$2 symbolized
  symbolized=${name^^}
  symbolized=${symbolized//-/_}
  if ! command -v "$name" > /dev/null 2>&1; then
    diag "E_AGENT_NOTIFY_${symbolized}_NOT_AVAILABLE: '$name' is required for $purpose."
    return 1
  fi
}

random_hex() {
  local bytes=$1
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex "$bytes"
  elif command -v od > /dev/null 2>&1 && [[ -r /dev/urandom ]]; then
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    return 1
  fi
}

is_true() {
  [[ "$1" == "true" ]]
}

should_wire() {
  local h=$1
  if is_true "$WANT_ALL"; then
    return 0
  fi
  local w
  for w in "${WANT_HARNESS[@]}"; do
    if [[ "$w" == "$h" ]]; then
      return 0
    fi
  done
  return 1
}

install_executable() {
  local src=$1 dst=$2 label=$3
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would install $src -> $dst (chmod 755)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod 755 "$dst"
  status_line "installed: $dst ($label)"
}

copy_adapter_file() {
  local src=$1 dst_dir=$2
  local base
  base="$dst_dir/$(basename "$src")"
  if [[ -e "$base" ]]; then
    diag "W_AGENT_NOTIFY_DEST_EXISTS: '$base' already exists; left untouched. Compare with '$src' manually."
    return 0
  fi
  install_executable "$src" "$base" "adapter"
}

wire_copy_adapter() {
  local harness=$1 dest_dir=$2
  local src=""
  case "$harness" in
    codex) src="$ADAPTER_CODEX" ;;
    copilot) src="$ADAPTER_COPILOT" ;;
    opencode) src="$ADAPTER_OPENCODE" ;;
    *)
      diag "E_AGENT_NOTIFY_UNKNOWN_HARNESS: no copy-style adapter for '$harness'."
      return 1
      ;;
  esac
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would copy $src into $dest_dir/ (no-clobber)"
    return 0
  fi
  mkdir -p "$dest_dir"
  copy_adapter_file "$src" "$dest_dir"
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    status_line "env-file: preserved ($ENV_FILE)"
    return 0
  fi
  local topic
  if ! topic=$(random_hex 12); then
    diag "E_AGENT_NOTIFY_NO_ENTROPY_SOURCE: need openssl (or od reading /dev/urandom) to mint a private topic."
    return 1
  fi
  topic="agent-alerts-$topic"
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would create $ENV_FILE (chmod 600) with a freshly minted private topic"
    return 0
  fi
  local machine_label
  machine_label=$(hostname 2> /dev/null | tr -c 'A-Za-z0-9._-' '_' | cut -c1-32)
  [[ -n "$machine_label" ]] || machine_label=localhost
  mkdir -p "$ENV_DIR"
  {
    printf '# generated by Scripts/AgentNotify/install.sh\n'
    printf 'export AGENT_NOTIFY_URL=https://ntfy.sh\n'
    printf 'export AGENT_NOTIFY_TOPIC=%s\n' "$topic"
    printf 'export AGENT_NOTIFY_MACHINE_LABEL=%s\n' "$machine_label"
  } > "$ENV_FILE.tmp.$$"
  mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  status_line "env-file: created $ENV_FILE"
  status_line "TOPIC_NAME=$topic"
  status_line "next: subscribe your phone's ntfy app (https://ntfy.sh) to TOPIC_NAME above"
}

wire_claude() {
  local settings="$HOME/.claude/settings.json"
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would merge $ADAPTER_CLAUDE hooks into $settings (non-destructive)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  if [[ ! -f "$settings" ]]; then
    cp "$ADAPTER_CLAUDE" "$settings.new.$$"
    chmod 600 "$settings.new.$$"
    mv "$settings.new.$$" "$settings"
    status_line "created: $settings with agent-notify hooks"
    return 0
  fi
  local backup
  backup="$settings.bak.agent-notify.$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  local merged
  if ! merged="$(jq -s 'if (.[1].hooks // null) == null then .[1] * {hooks: .[0].hooks} else error("existing") end' \
    "$ADAPTER_CLAUDE" "$settings" 2> /dev/null)"; then
    diag "W_AGENT_NOTIFY_CLAUDE_HOOKS_PRESENT: $settings already defines a hooks section; left untouched. Merge $ADAPTER_CLAUDE manually if intended (backup: $backup)."
    return 0
  fi
  mv "$settings" "$backup"
  printf '%s\n' "$merged" > "$settings.new.$$"
  mv "$settings.new.$$" "$settings"
  chmod 600 "$settings"
  status_line "merged: $settings (prior copy retained as $backup)"
}

install_core() {
  local bin_dir=$1
  if [[ ! -x "$SOURCE_BIN" ]]; then
    diag "E_AGENT_NOTIFY_SOURCE_MISSING: expected executable $SOURCE_BIN."
    return 1
  fi
  install_executable "$SOURCE_BIN" "$bin_dir/agent-notify" "core"
  case ":$PATH:" in
    *":$bin_dir:"*) : ;;
    *) diag "W_AGENT_NOTIFY_PATH_HINT: '$bin_dir' is not on PATH; add it to your shell profile." ;;
  esac
}

wire_project() {
  local target_repo=$1
  if [[ ! -d "$target_repo" ]]; then
    diag "E_AGENT_NOTIFY_PROJECT_MISSING: --project directory '$target_repo' does not exist."
    return 1
  fi
  if should_wire codex; then
    wire_copy_adapter codex "$target_repo/.codex"
  fi
  if should_wire copilot; then
    wire_copy_adapter copilot "$target_repo/.copilot/hooks"
  fi
  status_line "project wiring finished for $target_repo"
}

do_install() {
  local bin_dir="${INSTALL_BIN_DIR:-$DEFAULT_BIN_DIR}"
  local step_failures=0
  install_core "$bin_dir" || return 1
  ensure_env_file || return 1
  if should_wire nanocoder; then
    install_executable "$SOURCE_SHIM" "$bin_dir/notify-send" "nanocoder shim" ||
      step_failures=$((step_failures + 1))
  fi
  if should_wire claude; then
    wire_claude || step_failures=$((step_failures + 1))
  fi
  if should_wire codex; then
    wire_copy_adapter codex "$HOME/.codex" || step_failures=$((step_failures + 1))
  fi
  if should_wire copilot; then
    wire_copy_adapter copilot "$HOME/.copilot/hooks" || step_failures=$((step_failures + 1))
  fi
  if should_wire opencode; then
    wire_copy_adapter opencode "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins" ||
      step_failures=$((step_failures + 1))
  fi
  if [[ -n "$PROJECT_TARGET" ]]; then
    wire_project "$PROJECT_TARGET" || step_failures=$((step_failures + 1))
  fi
  if ((step_failures > 0)); then
    diag "E_AGENT_NOTIFY_INSTALL_PARTIAL: $step_failures wiring target(s) failed; see diagnostics above."
    return 1
  fi
}

do_uninstall() {
  local bin_dir="${INSTALL_BIN_DIR:-$DEFAULT_BIN_DIR}"
  local t
  for t in "$bin_dir/agent-notify" "$bin_dir/notify-send"; do
    if [[ -f "$t" ]]; then
      if is_true "$DRY_RUN"; then
        status_line "[dry-run] would remove $t"
      else
        rm -f "$t"
        status_line "removed: $t"
      fi
    fi
  done
  for t in "$HOME/.codex/hooks.json" "$HOME/.copilot/hooks/agent-notify.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/agent-notify.js"; do
    if [[ -f "$t" ]]; then
      status_line "note: adapter left in place: $t (remove manually after checking other hooks)"
    fi
  done
  status_line "uninstall finished; machine-local config deliberately preserved ($ENV_FILE)"
}

file_permission_octal() {
  local f=$1
  if stat -c '%a' "$f" > /dev/null 2>&1; then
    stat -c '%a' "$f"
  elif stat -f '%Lp' "$f" > /dev/null 2>&1; then
    stat -f '%Lp' "$f"
  else
    printf ''
  fi
}

do_audit() {
  local failures=0
  if [[ ! -f "$ENV_FILE" ]]; then
    diag "E_AGENT_NOTIFY_ENV_MISSING: $ENV_FILE not found; run '$PROG --install --all' first."
    failures=$((failures + 1))
  else
    local perm
    perm=$(file_permission_octal "$ENV_FILE")
    if [[ "$perm" =~ ^[67]00$ ]]; then
      status_line "audit ok: env-file permissions '$perm' ($ENV_FILE)"
    else
      diag "E_AGENT_NOTIFY_ENV_PERMS: expected owner-only permissions on $ENV_FILE, got '${perm:-unknown}'."
      failures=$((failures + 1))
    fi
    local topic_value
    topic_value=$(grep -E '^export AGENT_NOTIFY_TOPIC=' "$ENV_FILE" 2> /dev/null | tail -n 1 | cut -d= -f2- || true)
    if [[ ${#topic_value} -ge 24 && "$topic_value" =~ ^agent-alerts-[A-Za-z0-9_-]+$ ]]; then
      status_line "audit ok: topic present with expected shape and entropy (${#topic_value} chars)"
    else
      diag "E_AGENT_NOTIFY_TOPIC_SHAPE: topic in $ENV_FILE does not look machine-generated (details withheld)."
      failures=$((failures + 1))
    fi
  fi
  if command -v git > /dev/null 2>&1; then
    local hits
    hits=$(git -C "$REPO_ROOT" ls-files 'Scripts/AgentNotify/**' |
      grep -Ev '\.md$' |
      xargs -r grep -lE '(^|[[:space:]])export AGENT_NOTIFY_TOPIC=agent-alerts-[A-Za-z0-9_-]{8,}|tk_[A-Za-z0-9]{16,}' 2> /dev/null || true)
    if [[ -z "$hits" ]]; then
      status_line "audit ok: no tracked secrets under Scripts/AgentNotify/"
    else
      diag "E_AGENT_NOTIFY_SECRET_IN_TREE: potential secrets tracked under Scripts/AgentNotify/:"
      local p
      while IFS= read -r p; do
        diag "  violation: $p"
      done <<< "$hits"
      failures=$((failures + 1))
    fi
  else
    diag "W_AGENT_NOTIFY_GIT_NOT_AVAILABLE: skipped repository-tree secret scan (git missing)."
  fi
  if ((failures > 0)); then
    diag "audit FAILED with $failures finding(s)."
    return 1
  fi
  status_line "audit PASSED"
}

do_status() {
  local bin_dir="${INSTALL_BIN_DIR:-$DEFAULT_BIN_DIR}"
  if [[ -x "$bin_dir/agent-notify" ]]; then
    status_line "core: installed ($bin_dir/agent-notify)"
  else
    status_line "core: not installed"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    status_line "env-file: $ENV_FILE"
  else
    status_line "env-file: absent (a private topic gets minted on first --install)"
  fi
  local p
  for p in "$HOME/.codex/hooks.json" "$HOME/.copilot/hooks/agent-notify.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/agent-notify.js"; do
    if [[ -f "$p" ]]; then
      status_line "adapter: $p"
    fi
  done
  status_line "hint: $PROG --install --all | $PROG --audit | $PROG --help"
}

while (($#)); do
  case "$1" in
    --status) MODE="status" ;;
    --install) MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    --audit) MODE="audit" ;;
    --all) WANT_ALL=true ;;
    --claude | --codex | --copilot | --opencode | --nanocoder)
      WANT_HARNESS+=("${1#--}")
      ;;
    --bin-dir)
      INSTALL_BIN_DIR="${2:?missing value for --bin-dir}"
      shift
      ;;
    --project)
      PROJECT_TARGET="${2:?missing value for --project}"
      shift
      ;;
    --show-topic)
      require_cmd grep "reading the env-file" || exit 1
      if [[ -f "$ENV_FILE" ]]; then
        grep -E '^export AGENT_NOTIFY_TOPIC=' "$ENV_FILE" | cut -d= -f2-
        exit 0
      fi
      diag "E_AGENT_NOTIFY_ENV_MISSING: nothing to show yet; run --install first."
      exit 1
      ;;
    --dry-run) DRY_RUN=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      diag "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

case "$MODE" in
  status) do_status ;;
  install)
    require_cmd jq "adapter wiring" || exit 1
    do_install
    ;;
  uninstall) do_uninstall ;;
  audit) do_audit ;;
esac
