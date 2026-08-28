#!/usr/bin/env bash

# install.sh - Bootstrap agent-notify machine configuration and harness wiring.
#
# Secrets safety model:
#   The topic name IS the credential. This script generates it locally,
#   writes it to $HOME/.config/agent-notify/agent-notify.env (chmod 600),
#   and NEVER commits it: --audit scans the complete tracked index so any
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
  --audit         verify secrets hygiene offline: env-file permissions and
                  topic shape, plus a complete tracked-index scan
                  proving no credentials are committed anywhere in this repo

Targets for --install (repeatable, or --all; --uninstall intentionally rejects them):
  --all            all five targets below
  --claude         merge hook block into ~/.claude/settings.json (non-destructive)
  --codex          copy hooks into ~/.codex/            (no-clobber)
  --copilot        copy hooks into ~/.copilot/hooks/    (no-clobber)
  --opencode       copy plugin into ~/.config/opencode/plugins (no-clobber)
  --nanocoder      install notify-send shim next to agent-notify

Options:
  --bin-dir DIR    executable location rendered into adapters (default: $DEFAULT_BIN_DIR)
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
  local src=$1 dst=$2 label=$3 owner=${4:-} tmp
  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ -z "$owner" || -L "$dst" ]] ||
      ! grep -qF -- "# agent-notify-managed: $owner" "$dst" 2> /dev/null; then
      diag "E_AGENT_NOTIFY_DEST_EXISTS: '$dst' already exists and is not owned by agent-notify; left untouched."
      return 1
    fi
  fi
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would install $src -> $dst (chmod 755)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if ! tmp=$(mktemp "$dst.tmp.XXXXXX"); then
    diag "E_AGENT_NOTIFY_TEMP_CREATE_FAILED: could not create a temporary file beside '$dst'."
    return 1
  fi
  if ! cp "$src" "$tmp" || ! chmod 755 "$tmp" || ! mv "$tmp" "$dst"; then
    rm -f "$tmp"
    diag "E_AGENT_NOTIFY_INSTALL_WRITE_FAILED: could not atomically install '$dst'."
    return 1
  fi
  status_line "installed: $dst ($label)"
}

render_adapter() {
  local harness=$1 bin_dir=$2 output=$3 bin_path bin_command js_path default_bin_reference
  bin_path="$bin_dir/agent-notify"
  printf -v default_bin_reference '\176/.local/bin/agent-notify'
  case "$harness" in
    claude | codex | copilot)
      printf -v bin_command '%q' "$bin_path"
      jq --arg old "$default_bin_reference" --arg new "$bin_command" \
        'walk(if type == "string" then split($old) | join($new) else . end)' \
        "$(adapter_source "$harness")" > "$output"
      ;;
    opencode)
      js_path=$(jq -Rn --arg path "$bin_path" '$path')
      printf -v default_bin_reference '\140\044{home}/.local/bin/agent-notify\140'
      jq -Rrs --arg old "$default_bin_reference" --arg new "$js_path" \
        'split($old) | join($new)' "$ADAPTER_OPENCODE" > "$output"
      ;;
    *)
      diag "E_AGENT_NOTIFY_UNKNOWN_HARNESS: no renderable adapter for '$harness'."
      return 1
      ;;
  esac
}

adapter_source() {
  case "$1" in
    claude) printf '%s\n' "$ADAPTER_CLAUDE" ;;
    codex) printf '%s\n' "$ADAPTER_CODEX" ;;
    copilot) printf '%s\n' "$ADAPTER_COPILOT" ;;
    opencode) printf '%s\n' "$ADAPTER_OPENCODE" ;;
    *) return 1 ;;
  esac
}

copy_adapter_file() {
  local src=$1 dst_dir=$2 requested_name=${3:-}
  local base
  if [[ -n "$requested_name" ]]; then
    base="$dst_dir/$requested_name"
  else
    base="$dst_dir/$(basename "$src")"
  fi
  if [[ -e "$base" ]]; then
    diag "W_AGENT_NOTIFY_DEST_EXISTS: '$base' already exists; left untouched. Compare with '$src' manually."
    return 0
  fi
  install_executable "$src" "$base" "adapter"
}

wire_copy_adapter() {
  local harness=$1 dest_dir=$2 bin_dir=$3 src rendered
  src=$(adapter_source "$harness") || {
    diag "E_AGENT_NOTIFY_UNKNOWN_HARNESS: no copy-style adapter for '$harness'."
    return 1
  }
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would render $src into $dest_dir/ for $bin_dir/agent-notify (no-clobber)"
    return 0
  fi
  mkdir -p "$dest_dir"
  if ! rendered=$(mktemp "${TMPDIR:-/tmp}/agent-notify-adapter.XXXXXX"); then
    diag "E_AGENT_NOTIFY_TEMP_CREATE_FAILED: could not create temporary adapter for '$harness'."
    return 1
  fi
  if ! render_adapter "$harness" "$bin_dir" "$rendered"; then
    rm -f "$rendered"
    diag "E_AGENT_NOTIFY_ADAPTER_RENDER_FAILED: could not render '$harness' for '$bin_dir'."
    return 1
  fi
  if ! copy_adapter_file "$rendered" "$dest_dir" "$(basename "$src")"; then
    rm -f "$rendered"
    return 1
  fi
  rm -f "$rendered"
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
  rm -f "$ENV_DIR"/agent-notify.env.tmp.* 2> /dev/null || true
  {
    printf '# generated by Scripts/AgentNotify/install.sh\n'
    printf 'export AGENT_NOTIFY_URL=https://ntfy.sh\n'
    printf 'export AGENT_NOTIFY_TOPIC=%s\n' "$topic"
    printf 'export AGENT_NOTIFY_MACHINE_LABEL=%s\n' "$machine_label"
  } > "$ENV_FILE.tmp.$$"
  chmod 600 "$ENV_FILE.tmp.$$"
  mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
  status_line "env-file: created $ENV_FILE"
  status_line "TOPIC_NAME=$topic"
  status_line "next: subscribe your phone's ntfy app (https://ntfy.sh) to TOPIC_NAME above"
}

wire_claude() {
  local bin_dir=$1
  local settings="$HOME/.claude/settings.json"
  if is_true "$DRY_RUN"; then
    status_line "[dry-run] would merge $ADAPTER_CLAUDE hooks into $settings (non-destructive)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local rendered
  if ! rendered=$(mktemp "$settings.adapter.XXXXXX"); then
    diag "E_AGENT_NOTIFY_TEMP_CREATE_FAILED: could not create a temporary file beside '$settings'."
    return 1
  fi
  if ! render_adapter claude "$bin_dir" "$rendered"; then
    rm -f "$rendered"
    diag "E_AGENT_NOTIFY_ADAPTER_RENDER_FAILED: could not render Claude hooks for '$bin_dir'."
    return 1
  fi
  if [[ ! -f "$settings" ]]; then
    if ! chmod 600 "$rendered" || ! mv "$rendered" "$settings"; then
      rm -f "$rendered"
      diag "E_AGENT_NOTIFY_CLAUDE_WRITE_FAILED: could not atomically create '$settings'."
      return 1
    fi
    status_line "created: $settings with agent-notify hooks"
    return 0
  fi
  if ! jq -e 'type == "object"' "$settings" > /dev/null 2>&1; then
    rm -f "$rendered"
    diag "E_AGENT_NOTIFY_CLAUDE_SETTINGS_INVALID: $settings is not valid JSON object data; left untouched."
    return 1
  fi
  if jq -e '(.hooks // null) != null' "$settings" > /dev/null 2>&1; then
    rm -f "$rendered"
    diag "W_AGENT_NOTIFY_CLAUDE_HOOKS_PRESENT: $settings already defines a hooks section; left untouched. Merge $ADAPTER_CLAUDE manually if intended."
    return 0
  fi
  local merged backup
  if ! merged=$(mktemp "$settings.new.XXXXXX"); then
    rm -f "$rendered"
    diag "E_AGENT_NOTIFY_TEMP_CREATE_FAILED: could not create a temporary file beside '$settings'."
    return 1
  fi
  if ! jq -s '.[1] * {hooks: .[0].hooks}' \
    "$rendered" "$settings" > "$merged" 2> /dev/null; then
    rm -f "$rendered" "$merged"
    diag "E_AGENT_NOTIFY_CLAUDE_MERGE_FAILED: could not merge hooks into $settings; left untouched."
    return 1
  fi
  rm -f "$rendered"
  if ! backup=$(mktemp "$settings.bak.agent-notify.XXXXXX"); then
    rm -f "$merged"
    diag "E_AGENT_NOTIFY_TEMP_CREATE_FAILED: could not create a backup beside '$settings'."
    return 1
  fi
  if ! cp -p "$settings" "$backup" || ! chmod 600 "$merged" || ! mv "$merged" "$settings"; then
    rm -f "$merged"
    diag "E_AGENT_NOTIFY_CLAUDE_WRITE_FAILED: could not atomically replace '$settings'; original left in place (backup: $backup)."
    return 1
  fi
  status_line "merged: $settings (prior copy retained as $backup)"
}

install_core() {
  local bin_dir=$1
  if [[ ! -x "$SOURCE_BIN" ]]; then
    diag "E_AGENT_NOTIFY_SOURCE_MISSING: expected executable $SOURCE_BIN."
    return 1
  fi
  install_executable "$SOURCE_BIN" "$bin_dir/agent-notify" "core" "core" || return 1
  case ":$PATH:" in
    *":$bin_dir:"*) : ;;
    *) diag "W_AGENT_NOTIFY_PATH_HINT: '$bin_dir' is not on PATH; add it to your shell profile." ;;
  esac
}

wire_project() {
  local target_repo=$1 bin_dir=$2
  local failures=0
  if [[ ! -d "$target_repo" ]]; then
    diag "E_AGENT_NOTIFY_PROJECT_MISSING: --project directory '$target_repo' does not exist."
    return 1
  fi
  if should_wire codex; then
    wire_copy_adapter codex "$target_repo/.codex" "$bin_dir" || failures=$((failures + 1))
  fi
  if should_wire copilot; then
    wire_copy_adapter copilot "$target_repo/.copilot/hooks" "$bin_dir" || failures=$((failures + 1))
  fi
  if ((failures > 0)); then
    diag "E_AGENT_NOTIFY_PROJECT_PARTIAL: $failures project adapter(s) failed for '$target_repo'."
    return 1
  fi
  status_line "project wiring finished for $target_repo"
}

do_install() {
  local bin_dir="${INSTALL_BIN_DIR:-$DEFAULT_BIN_DIR}"
  local step_failures=0
  install_core "$bin_dir" || return 1
  ensure_env_file || return 1
  if should_wire nanocoder; then
    install_executable "$SOURCE_SHIM" "$bin_dir/notify-send" "nanocoder shim" "nanocoder-shim" ||
      step_failures=$((step_failures + 1))
  fi
  if should_wire claude; then
    wire_claude "$bin_dir" || step_failures=$((step_failures + 1))
  fi
  if should_wire codex; then
    wire_copy_adapter codex "$HOME/.codex" "$bin_dir" || step_failures=$((step_failures + 1))
  fi
  if should_wire copilot; then
    wire_copy_adapter copilot "$HOME/.copilot/hooks" "$bin_dir" || step_failures=$((step_failures + 1))
  fi
  if should_wire opencode; then
    wire_copy_adapter opencode "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins" "$bin_dir" ||
      step_failures=$((step_failures + 1))
  fi
  if [[ -n "$PROJECT_TARGET" ]]; then
    wire_project "$PROJECT_TARGET" "$bin_dir" || step_failures=$((step_failures + 1))
  fi
  if ((step_failures > 0)); then
    diag "E_AGENT_NOTIFY_INSTALL_PARTIAL: $step_failures wiring target(s) failed; see diagnostics above."
    return 1
  fi
}

do_uninstall() {
  local bin_dir="${INSTALL_BIN_DIR:-$DEFAULT_BIN_DIR}"
  local t owner
  for t in "$bin_dir/agent-notify" "$bin_dir/notify-send"; do
    if [[ "$t" == */agent-notify ]]; then
      owner=core
    else
      owner=nanocoder-shim
    fi
    if [[ -e "$t" || -L "$t" ]]; then
      if [[ -L "$t" ]] || ! grep -qF -- "# agent-notify-managed: $owner" "$t" 2> /dev/null; then
        diag "W_AGENT_NOTIFY_FOREIGN_EXECUTABLE: '$t' is not owned by agent-notify; left untouched."
        continue
      fi
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
    if [[ "$topic_value" =~ ^agent-alerts-[0-9a-f]{24}$ ]]; then
      status_line "audit ok: topic present with expected shape and entropy (${#topic_value} chars)"
    else
      diag "E_AGENT_NOTIFY_TOPIC_SHAPE: topic in $ENV_FILE does not look machine-generated (details withheld)."
      failures=$((failures + 1))
    fi
  fi
  if ! command -v git > /dev/null 2>&1; then
    diag "E_AGENT_NOTIFY_GIT_NOT_AVAILABLE: 'git' is required to prove the tracked tree contains no secrets."
    failures=$((failures + 1))
  else
    local hits git_status=0
    if hits=$(git -C "$REPO_ROOT" grep -l -E --cached -- \
      'agent-alerts-[0-9a-f]{24}|tk_[A-Za-z0-9]{16,}|ntfy\.sh/(agent-alerts-)?[A-Za-z0-9_-]{24,}' 2>&1); then
      git_status=0
    else
      git_status=$?
    fi
    if ((git_status == 1)); then
      status_line "audit ok: no tracked secrets in repository"
    elif ((git_status == 0)); then
      diag "E_AGENT_NOTIFY_SECRET_IN_TREE: potential secrets tracked in this repository:"
      local p
      while IFS= read -r p; do
        diag "  violation: $p"
      done <<< "$hits"
      failures=$((failures + 1))
    else
      diag "E_AGENT_NOTIFY_GIT_SCAN_FAILED: git could not scan the tracked index (exit $git_status): ${hits:-no details}."
      failures=$((failures + 1))
    fi
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

if [[ -n "$INSTALL_BIN_DIR" && "$INSTALL_BIN_DIR" != /* ]]; then
  diag "E_AGENT_NOTIFY_BIN_DIR_NOT_ABSOLUTE: --bin-dir must be an absolute path; received '$INSTALL_BIN_DIR'."
  exit 1
fi

if [[ "$MODE" == "uninstall" ]] &&
  { is_true "$WANT_ALL" || ((${#WANT_HARNESS[@]} > 0)) || [[ -n "$PROJECT_TARGET" ]]; }; then
  diag "E_AGENT_NOTIFY_UNINSTALL_TARGETS_UNSUPPORTED: --uninstall only removes owned executables; adapter targets and --project are intentionally retained and must be removed manually."
  exit 1
fi

case "$MODE" in
  status) do_status ;;
  install)
    require_cmd grep "executable ownership checks" || exit 1
    require_cmd jq "adapter wiring" || exit 1
    do_install
    ;;
  uninstall)
    require_cmd grep "executable ownership checks" || exit 1
    do_uninstall
    ;;
  audit) do_audit ;;
esac
