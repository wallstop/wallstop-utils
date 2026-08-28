#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/agent-notify"
SHIM="$ROOT/adapters/nanocoder/notify-send"
INSTALLER="$ROOT/install.sh"
FIXDIR="$ROOT/tests/fixtures"

PASS=0
FAIL=0
declare -a FAILURES=()

note_pass() { PASS=$((PASS + 1)); }
note_fail() {
  FAILURES+=("$1")
  FAIL=$((FAIL + 1))
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then
    note_pass
  else
    note_fail "$1: expected [$3] got [$2]"
  fi
}

assert_match() {
  if [[ "$2" =~ $3 ]]; then
    note_pass
  else
    note_fail "$1: [$2] !~ [$3]"
  fi
}

assert_not_match() {
  if [[ ! "$2" =~ $3 ]]; then
    note_pass
  else
    note_fail "$1: [$2] unexpectedly ~ [$3]"
  fi
}

assert_absent_path() {
  if [[ ! -e "$2" ]]; then
    note_pass
  else
    note_fail "$1: path unexpectedly exists: $2"
  fi
}

log_field() {
  local dir=$1 expr=$2
  local f="$dir/.local/state/agent-notify/log.jsonl"
  local out=""
  local i
  for ((i = 0; i < 40; i++)); do
    if [[ -s "$f" ]]; then
      out=$(tail -n 1 "$f" | jq -r "$expr" 2> /dev/null)
      [[ -n "$out" && "$out" != "null" ]] && break
    fi
    sleep 0.05
  done
  printf '%s' "${out:-}"
}

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
FAKE_CURL_LOG="$SB/curl-calls.log"
FAKE_CURL_BODY_LOG="$SB/curl-body.log"
FAKE_NOTIFY_SEND_LOG="$SB/notify-send-args.json"
export FAKE_CURL_LOG FAKE_CURL_BODY_LOG FAKE_NOTIFY_SEND_LOG

cat > "$SB/bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_LOG:?}"
cat >"${FAKE_CURL_BODY_LOG:?}"
printf '%s' "200"
STUB
chmod +x "$SB/bin/curl"
mkdir -p "$SB/realbin"
cat > "$SB/realbin/notify-send" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]' >"${FAKE_NOTIFY_SEND_LOG:?}"
STUB
chmod +x "$SB/realbin/notify-send"
export PATH="$SB/bin:$PATH"

unset AGENT_NOTIFY_URL AGENT_NOTIFY_TOPIC AGENT_NOTIFY_TOKEN \
  AGENT_NOTIFY_COOLDOWN_SECS AGENT_NOTIFY_SNIPPET_MAX CODESPACE_NAME
mkdir -p "$SB/config"
export XDG_CONFIG_HOME="$SB/config"

export AGENT_NOTIFY_MACHINE_LABEL=testbox

curl_calls() {
  if [[ -f "$FAKE_CURL_LOG" ]]; then
    wc -l < "$FAKE_CURL_LOG"
  else
    printf 0
  fi
}

for shfile in "$BIN" "$SHIM" "$INSTALLER" "$0"; do
  if bash -n "$shfile" 2> /dev/null; then
    note_pass
  else
    note_fail "syntax error in $shfile"
  fi
done

if command -v shellcheck > /dev/null 2>&1; then
  if shellcheck "$BIN" "$SHIM" "$INSTALLER" "$0" 2> "$SB/shellcheck.out"; then
    note_pass
  else
    note_fail "shellcheck failed: $(head -c 300 "$SB/shellcheck.out")"
  fi
fi

# Installer coverage is hermetic: every HOME/bin/config/repository lives under SB,
# entropy is local, and no adapter or notification command is executed.
IH=$(mktemp -d "$SB/install-home.XXXXXX")
IB="$IH/custom bin [managed]"
HOME="$IH" XDG_CONFIG_HOME="$IH/config" \
  "$INSTALLER" --install --all --bin-dir "$IB" > "$IH/install.out" 2> "$IH/install.err"
RC=$?
assert_eq "installer all-target custom-bin exit code" "$RC" "0"
for json_file in "$IH/.claude/settings.json" "$IH/.codex/hooks.json" \
  "$IH/.copilot/hooks/agent-notify.json"; do
  if jq -e . "$json_file" > /dev/null 2>&1; then
    note_pass
  else
    note_fail "installer emitted invalid JSON: $json_file"
  fi
done
printf -v EXPECTED_BIN_COMMAND '%q' "$IB/agent-notify"
printf -v DEFAULT_BIN_REFERENCE '\176/.local/bin/agent-notify'
for command_file in "$IH/.claude/settings.json" "$IH/.codex/hooks.json" \
  "$IH/.copilot/hooks/agent-notify.json"; do
  if jq -e --arg expected "$EXPECTED_BIN_COMMAND" \
    '[.. | strings | select(startswith($expected))] | length > 0' "$command_file" > /dev/null 2>&1; then
    note_pass
  else
    note_fail "custom --bin-dir missing from adapter: $command_file"
  fi
  if grep -qF -- "$DEFAULT_BIN_REFERENCE" "$command_file"; then
    note_fail "default bin path leaked into custom adapter: $command_file"
  else
    note_pass
  fi
done
OPENCODE_FILE="$IH/config/opencode/plugins/agent-notify.js"
if grep -qF -- "const script = \"$IB/agent-notify\"" "$OPENCODE_FILE"; then
  note_pass
else
  note_fail "custom --bin-dir missing from OpenCode adapter"
fi
printf -v OPENCODE_DEFAULT_BIN_REFERENCE '\044{home}/.local/bin/agent-notify'
if grep -qF -- "$OPENCODE_DEFAULT_BIN_REFERENCE" "$OPENCODE_FILE"; then
  note_fail "default bin path leaked into custom OpenCode adapter"
else
  note_pass
fi

RH=$(mktemp -d "$SB/relative-bin-home.XXXXXX")
(
  cd "$RH" || exit 1
  HOME="$RH" XDG_CONFIG_HOME="$RH/config" \
    "$INSTALLER" --install --bin-dir 'relative-bin' > "$RH/install.out" 2> "$RH/install.err"
)
RC=$?
assert_eq "relative --bin-dir is rejected" "$RC" "1"
assert_match "relative --bin-dir failure is actionable" "$(cat "$RH/install.err")" \
  "E_AGENT_NOTIFY_BIN_DIR_NOT_ABSOLUTE"
assert_absent_path "relative --bin-dir performs no install" "$RH/relative-bin/agent-notify"

HOME="$IH" XDG_CONFIG_HOME="$IH/config" \
  "$INSTALLER" --uninstall --claude --bin-dir "$IB" > "$IH/target-uninstall.out" 2> "$IH/target-uninstall.err"
RC=$?
assert_eq "targeted uninstall is rejected" "$RC" "1"
assert_match "targeted uninstall explains retained adapters" "$(cat "$IH/target-uninstall.err")" \
  "E_AGENT_NOTIFY_UNINSTALL_TARGETS_UNSUPPORTED"
if [[ -f "$IB/agent-notify" && -f "$IB/notify-send" ]]; then
  note_pass
else
  note_fail "rejected targeted uninstall mutated managed executables"
fi

HOME="$IH" XDG_CONFIG_HOME="$IH/config" \
  "$INSTALLER" --uninstall --bin-dir "$IB" > "$IH/uninstall.out" 2> "$IH/uninstall.err"
RC=$?
assert_eq "owned executable uninstall exit code" "$RC" "0"
assert_absent_path "owned core removed on uninstall" "$IB/agent-notify"
assert_absent_path "owned shim removed on uninstall" "$IB/notify-send"

FH=$(mktemp -d "$SB/foreign-core-home.XXXXXX")
FB="$FH/bin"
mkdir -p "$FB"
printf '%s\n' 'foreign core sentinel' > "$FB/agent-notify"
chmod 755 "$FB/agent-notify"
HOME="$FH" XDG_CONFIG_HOME="$FH/config" \
  "$INSTALLER" --install --bin-dir "$FB" > "$FH/install.out" 2> "$FH/install.err"
RC=$?
assert_eq "foreign core blocks install" "$RC" "1"
assert_eq "foreign core is not clobbered" "$(cat "$FB/agent-notify")" "foreign core sentinel"
assert_match "foreign core failure is actionable" "$(cat "$FH/install.err")" \
  "E_AGENT_NOTIFY_DEST_EXISTS"
HOME="$FH" XDG_CONFIG_HOME="$FH/config" \
  "$INSTALLER" --install --dry-run --bin-dir "$FB" > "$FH/dry-run.out" 2> "$FH/dry-run.err"
RC=$?
assert_eq "foreign core blocks dry-run plan" "$RC" "1"
assert_match "foreign core dry-run failure is actionable" "$(cat "$FH/dry-run.err")" \
  "E_AGENT_NOTIFY_DEST_EXISTS"
assert_not_match "foreign core dry-run does not claim installation" "$(cat "$FH/dry-run.out")" \
  "would install"

FSH=$(mktemp -d "$SB/foreign-shim-home.XXXXXX")
FSB="$FSH/bin"
mkdir -p "$FSB"
cp "$BIN" "$FSB/agent-notify"
chmod 755 "$FSB/agent-notify"
printf '%s\n' 'foreign shim sentinel' > "$FSB/notify-send"
chmod 755 "$FSB/notify-send"
HOME="$FSH" XDG_CONFIG_HOME="$FSH/config" \
  "$INSTALLER" --install --nanocoder --bin-dir "$FSB" > "$FSH/install.out" 2> "$FSH/install.err"
RC=$?
assert_eq "foreign notify-send blocks shim install" "$RC" "1"
assert_eq "foreign notify-send is not clobbered" "$(cat "$FSB/notify-send")" \
  "foreign shim sentinel"

FUH=$(mktemp -d "$SB/foreign-uninstall-home.XXXXXX")
FUB="$FUH/bin"
mkdir -p "$FUB"
printf '%s\n' 'foreign core uninstall sentinel' > "$FUB/agent-notify"
printf '%s\n' 'foreign shim uninstall sentinel' > "$FUB/notify-send"
HOME="$FUH" XDG_CONFIG_HOME="$FUH/config" \
  "$INSTALLER" --uninstall --bin-dir "$FUB" > "$FUH/uninstall.out" 2> "$FUH/uninstall.err"
RC=$?
assert_eq "foreign executable uninstall remains successful" "$RC" "0"
assert_eq "foreign core is not deleted" "$(cat "$FUB/agent-notify")" \
  "foreign core uninstall sentinel"
assert_eq "foreign shim is not deleted" "$(cat "$FUB/notify-send")" \
  "foreign shim uninstall sentinel"
assert_match "foreign uninstall warning is actionable" "$(cat "$FUH/uninstall.err")" \
  "W_AGENT_NOTIFY_FOREIGN_EXECUTABLE"

AH=$(mktemp -d "$SB/atomic-claude-home.XXXXXX")
AB="$AH/bin"
mkdir -p "$AH/.claude" "$AH/fake-bin"
printf '%s\n' '{"theme":"dark"}' > "$AH/.claude/settings.json"
REAL_MV=$(command -v mv)
export REAL_MV
cat > "$AH/fake-bin/mv" << 'STUB'
#!/usr/bin/env bash
target=${!#}
if [[ "$target" == "${FAIL_MOVE_DEST:?}" ]]; then
  exit 73
fi
exec "${REAL_MV:?}" "$@"
STUB
chmod 755 "$AH/fake-bin/mv"
PATH="$AH/fake-bin:$PATH" FAIL_MOVE_DEST="$AH/.claude/settings.json" \
  HOME="$AH" XDG_CONFIG_HOME="$AH/config" \
  "$INSTALLER" --install --claude --bin-dir "$AB" > "$AH/install.out" 2> "$AH/install.err"
RC=$?
assert_eq "failed Claude atomic replacement fails install" "$RC" "1"
assert_eq "failed Claude replacement preserves live settings" \
  "$(cat "$AH/.claude/settings.json")" '{"theme":"dark"}'
if jq -e '.theme == "dark" and has("hooks") == false' "$AH/.claude/settings.json" > /dev/null 2>&1; then
  note_pass
else
  note_fail "Claude settings invalid or partially replaced after failed atomic move"
fi
assert_match "failed Claude replacement is actionable" "$(cat "$AH/install.err")" \
  "E_AGENT_NOTIFY_CLAUDE_WRITE_FAILED"

IJH=$(mktemp -d "$SB/invalid-json-claude-home.XXXXXX")
IJB="$IJH/bin"
mkdir -p "$IJH/.claude"
printf '%s\n' '{invalid-json' > "$IJH/.claude/settings.json"
HOME="$IJH" XDG_CONFIG_HOME="$IJH/config" \
  "$INSTALLER" --install --claude --bin-dir "$IJB" > "$IJH/install.out" 2> "$IJH/install.err"
RC=$?
assert_eq "invalid Claude JSON fails install" "$RC" "1"
assert_eq "invalid Claude JSON is preserved" \
  "$(cat "$IJH/.claude/settings.json")" '{invalid-json'
assert_match "invalid Claude JSON failure is actionable" "$(cat "$IJH/install.err")" \
  "E_AGENT_NOTIFY_CLAUDE_SETTINGS_INVALID"

AR="$SB/audit-repo"
mkdir -p "$AR/Scripts/AgentNotify"
cp "$INSTALLER" "$AR/Scripts/AgentNotify/install.sh"
git -C "$AR" init -q
git -C "$AR" config user.email agent-notify-tests@example.invalid
git -C "$AR" config user.name agent-notify-tests
git -C "$AR" add -- 'Scripts/AgentNotify/install.sh'
git -C "$AR" commit -q -m 'audit fixture baseline'
SECRET_TOPIC="agent-alerts-$(printf '%s' '0123456789abcdef01234567')"
printf 'AGENT_NOTIFY_TOPIC=%s\n' "$SECRET_TOPIC" > "$AR/--leak.md"
git -C "$AR" add -- '--leak.md'
AUDIT_HOME=$(mktemp -d "$SB/audit-home.XXXXXX")
mkdir -p "$AUDIT_HOME/config/agent-notify"
printf 'export AGENT_NOTIFY_TOPIC=%s\n' "$SECRET_TOPIC" \
  > "$AUDIT_HOME/config/agent-notify/agent-notify.env"
chmod 600 "$AUDIT_HOME/config/agent-notify/agent-notify.env"
HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  "$AR/Scripts/AgentNotify/install.sh" --audit > "$AUDIT_HOME/audit.out" 2> "$AUDIT_HOME/audit.err"
RC=$?
assert_eq "audit rejects tracked unexported Markdown secret" "$RC" "1"
assert_match "audit reports option-like Markdown operand" "$(cat "$AUDIT_HOME/audit.err")" \
  "violation: --leak.md"
printf 'AGENT_NOTIFY_TOPIC="%s"\n' "$SECRET_TOPIC" > "$AR/--leak.md"
git -C "$AR" add -- '--leak.md'
HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  "$AR/Scripts/AgentNotify/install.sh" --audit > "$AUDIT_HOME/quoted.out" 2> "$AUDIT_HOME/quoted.err"
RC=$?
assert_eq "audit rejects tracked quoted topic" "$RC" "1"
assert_match "quoted topic audit reports tracked file" "$(cat "$AUDIT_HOME/quoted.err")" \
  "violation: --leak.md"
printf 'example private topic: %s\n' "$SECRET_TOPIC" > "$AR/--leak.md"
git -C "$AR" add -- '--leak.md'
HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  "$AR/Scripts/AgentNotify/install.sh" --audit > "$AUDIT_HOME/standalone.out" 2> "$AUDIT_HOME/standalone.err"
RC=$?
assert_eq "audit rejects tracked standalone topic" "$RC" "1"
assert_match "standalone topic audit reports tracked file" "$(cat "$AUDIT_HOME/standalone.err")" \
  "violation: --leak.md"
git -C "$AR" rm --cached -q -- '--leak.md'
assert_eq "removed audit fixture is absent from index" \
  "$(git -C "$AR" ls-files -- '--leak.md')" ""
HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  "$AR/Scripts/AgentNotify/install.sh" --audit > "$AUDIT_HOME/clean.out" 2> "$AUDIT_HOME/clean.err"
RC=$?
KERNEL_NAME=$(uname -s 2> /dev/null || printf 'unknown')
if ((RC == 0)); then
  note_pass
  assert_match "clean audit proves tracked scan" "$(cat "$AUDIT_HOME/clean.out")" \
    "audit ok: no tracked secrets in repository"
elif [[ "$KERNEL_NAME" == MINGW* || "$KERNEL_NAME" == MSYS* || "$KERNEL_NAME" == CYGWIN* ]] &&
  grep -qF -- 'E_AGENT_NOTIFY_ENV_PERMS' "$AUDIT_HOME/clean.err"; then
  # Git Bash on NTFS cannot always prove chmod 600 through POSIX mode bits. The audit must
  # remain fail-closed there, while still proving that the tracked-index scan itself ran.
  note_pass
  assert_match "Windows clean audit still proves tracked scan" "$(cat "$AUDIT_HOME/clean.out")" \
    "audit ok: no tracked secrets in repository"
else
  note_fail "audit passes for a clean tracked index: exit=$RC stderr=[$(head -c 300 "$AUDIT_HOME/clean.err")]"
  assert_match "clean audit proves tracked scan" "$(cat "$AUDIT_HOME/clean.out")" \
    "audit ok: no tracked secrets in repository"
fi
INVALID_TOPIC_SHORT="agent-alerts-$(printf '%s' '12345678')"
INVALID_TOPIC_NONHEX="agent-alerts-$(printf '%s' '0123456789abcdef0123456g')"
for invalid_topic in "$INVALID_TOPIC_SHORT" "$INVALID_TOPIC_NONHEX"; do
  printf 'export AGENT_NOTIFY_TOPIC=%s\n' "$invalid_topic" \
    > "$AUDIT_HOME/config/agent-notify/agent-notify.env"
  HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
    "$AR/Scripts/AgentNotify/install.sh" --audit \
    > "$AUDIT_HOME/weak-topic.out" 2> "$AUDIT_HOME/weak-topic.err"
  RC=$?
  assert_eq "audit rejects non-minted topic shape ($invalid_topic)" "$RC" "1"
  assert_match "invalid topic shape is actionable ($invalid_topic)" \
    "$(cat "$AUDIT_HOME/weak-topic.err")" "E_AGENT_NOTIFY_TOPIC_SHAPE"
done
printf 'export AGENT_NOTIFY_TOPIC=%s\n' "$SECRET_TOPIC" \
  > "$AUDIT_HOME/config/agent-notify/agent-notify.env"

FAIL_GIT_BIN="$SB/failing-git-bin"
mkdir -p "$FAIL_GIT_BIN"
cat > "$FAIL_GIT_BIN/git" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' 'synthetic git scan failure' >&2
exit 42
STUB
chmod 755 "$FAIL_GIT_BIN/git"
PATH="$FAIL_GIT_BIN:$PATH" HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  "$AR/Scripts/AgentNotify/install.sh" --audit > "$AUDIT_HOME/git-fail.out" 2> "$AUDIT_HOME/git-fail.err"
RC=$?
assert_eq "audit fails closed when git scan fails" "$RC" "1"
assert_match "git scan failure is actionable" "$(cat "$AUDIT_HOME/git-fail.err")" \
  "E_AGENT_NOTIFY_GIT_SCAN_FAILED.*exit 42"

NO_GIT_BIN="$SB/no-git-bin"
mkdir -p "$NO_GIT_BIN"
for required_tool in dirname stat grep tail cut; do
  required_tool_path=$(command -v "$required_tool")
  {
    printf '#!/usr/bin/bash\n'
    printf 'exec %q "$@"\n' "$required_tool_path"
  } > "$NO_GIT_BIN/$required_tool"
  chmod 755 "$NO_GIT_BIN/$required_tool"
done
PATH="$NO_GIT_BIN" HOME="$AUDIT_HOME" XDG_CONFIG_HOME="$AUDIT_HOME/config" \
  /usr/bin/bash "$AR/Scripts/AgentNotify/install.sh" --audit \
  > "$AUDIT_HOME/no-git.out" 2> "$AUDIT_HOME/no-git.err"
RC=$?
assert_eq "audit fails closed when git is missing" "$RC" "1"
assert_match "missing git is actionable" "$(cat "$AUDIT_HOME/no-git.err")" \
  "E_AGENT_NOTIFY_GIT_NOT_AVAILABLE"

for f in "$FIXDIR"/*.json; do
  fname=$(basename "$f")
  H=$(mktemp -d "$SB/home.XXXXXX")
  HARNESS=$(jq -r '.x_expect.harness // ""' "$f")

  if [[ -z "$HARNESS" ]]; then
    note_fail "$fname: missing x_expect.harness"
    rm -rf "$H"
    continue
  fi

  OUT=$(HOME="$H" XDG_STATE_HOME='' "$BIN" --print "$HARNESS" < "$f" 2> "$H/stderr")
  RC=$?

  assert_eq "$fname exit code" "$RC" "0"

  WANT_SKIP=$(jq -r '.x_expect.skip // false' "$f")
  if [[ "$WANT_SKIP" == "true" ]]; then
    assert_eq "$fname skip -> no output" "$OUT" ""
    assert_eq "$fname skip -> logged as skipped" \
      "$(log_field "$H" '.result')" "skipped"
    rm -rf "$H"
    continue
  fi

  if ! jq -e 'has("title") and has("body") and has("machine")' <<< "$OUT" > /dev/null 2>&1; then
    note_fail "$fname: --print did not emit a valid request JSON: [$OUT]"
    rm -rf "$H"
    continue
  fi

  STATE=$(jq -r '.state' <<< "$OUT")
  PRIO=$(jq -r '.priority' <<< "$OUT")
  TITLE=$(jq -r '.title' <<< "$OUT")
  BODY=$(jq -r '.body' <<< "$OUT")
  TAGS=$(jq -r '.tags' <<< "$OUT")

  assert_eq "$fname state" "$STATE" "$(jq -r '.x_expect.state' "$f")"
  assert_eq "$fname priority" "$PRIO" "$(jq -r '.x_expect.priority' "$f")"

  TRE=$(jq -r '.x_expect.title_re // ""' "$f")
  if [[ -n "$TRE" ]]; then
    assert_match "$fname title" "$TITLE" "$TRE"
  fi

  BRE=$(jq -r '.x_expect.body_re // ""' "$f")
  if [[ -n "$BRE" ]]; then
    assert_match "$fname body" "$BODY" "$BRE"
  fi

  TRUNC=$(jq -r '.x_expect.truncated // false' "$f")
  if [[ "$TRUNC" == "true" ]]; then
    if [[ "$BODY" == *… ]]; then
      note_pass
    else
      note_fail "$fname expected truncated body, got: $BODY"
    fi
  fi

  TAGP=$(jq -r '.x_expect.tag_present // ""' "$f")
  if [[ -n "$TAGP" ]]; then
    if grep -qx -- "$TAGP" < <(tr ',' '\n' <<< "$TAGS"); then
      note_pass
    else
      note_fail "$fname tags [$TAGS] missing required tag [$TAGP]"
    fi
  fi
  rm -rf "$H"
done

H=$(mktemp -d "$SB/home.XXXXXX")
BEFORE=$(curl_calls)
OUT=$(HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=no-send-expected "$BIN" --print claude < /dev/null 2> /dev/null)
RC=$?
assert_eq "empty stdin exits 0" "$RC" "0"
assert_eq "empty stdin emits nothing" "$OUT" ""
assert_eq "empty stdin sends nothing" "$(curl_calls)" "$BEFORE"
rm -rf "$H"

OUT=$(printf 'not-json{{{' | HOME="$SB/h-mal" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=no-send-expected "$BIN" --print claude 2> /dev/null)
RC=$?
assert_eq "malformed stdin exits 0" "$RC" "0"
assert_eq "malformed stdin emits nothing" "$OUT" ""
rm -rf "$SB/h-mal"

CLAUDE_STOP_FIXTURE="$FIXDIR/claude-stop-truncated.json"

H=$(mktemp -d "$SB/home.XXXXXX")
N0=$(curl_calls)
SEND_STDOUT=$(HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic AGENT_NOTIFY_TOKEN=tk_unit_123 \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" 2> /dev/null)
N1=$(curl_calls)
RC=$?
assert_eq "send mode exits 0" "$RC" "0"
assert_eq "send mode stdout stays pure" "$SEND_STDOUT" ""
assert_eq "send mode invokes curl once" "$((N1 - N0))" "1"
assert_eq "first send logged sent+not-deduped" "$(log_field "$H" '.result')" "sent"
assert_eq "first send deduped flag" "$(log_field "$H" '.deduped')" "false"
COOLDOWN_FILE="$H/.local/state/agent-notify/cooldown/testbox_claude_done.ts"
if [[ -e "$COOLDOWN_FILE" ]]; then
  note_pass "cooldown stamped after successful publish"
else
  note_fail "cooldown not armed after successful publish"
fi

HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic AGENT_NOTIFY_TOKEN=tk_unit_123 \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
N2=$(curl_calls)
assert_eq "cooldown suppresses second publish" "$N2" "$N1"
assert_eq "second send logged deduped" "$(log_field "$H" '.result')" "deduped"
assert_eq "second send deduped flag" "$(log_field "$H" '.deduped')" "true"

CURLLINE=$(tail -n 1 "$FAKE_CURL_LOG")
assert_match "publish targets configured topic url" "$CURLLINE" "https://ntfy.sh/test-topic"
assert_match "publish carries title header" "$CURLLINE" "Title: \[testbox\] Claude: DONE"
assert_match "publish carries tags incl machine" "$CURLLINE" "Tags: heavy_check_mark,testbox"
assert_match "publish body passed via --data-binary" "$CURLLINE" "--data-binary"
assert_match "publish includes bearer token when configured" "$CURLLINE" "Authorization: Bearer tk_unit_123"
rm -rf "$H"

mkdir -p "$SB/slowbin"
cat > "$SB/slowbin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
cat > /dev/null
sleep "${FAKE_CURL_SLEEP_SECONDS:-0.4}"
printf '%s' "200"
STUB
chmod 755 "$SB/slowbin/curl"
H=$(mktemp -d "$SB/home.XXXXXX")
N_CONCURRENT=$(curl_calls)
PATH="$SB/slowbin:$PATH" HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1 &
PID_ONE=$!
PATH="$SB/slowbin:$PATH" HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1 &
PID_TWO=$!
wait "$PID_ONE"
RC_ONE=$?
wait "$PID_TWO"
RC_TWO=$?
assert_eq "first concurrent notifier exits 0" "$RC_ONE" "0"
assert_eq "second concurrent notifier exits 0" "$RC_TWO" "0"
assert_eq "cooldown lock permits one concurrent publish" \
  "$(($(curl_calls) - N_CONCURRENT))" "1"
CONCURRENT_LOG="$H/.local/state/agent-notify/log.jsonl"
assert_eq "concurrent cooldown logs one sent result" \
  "$(jq -s '[.[] | select(.result == "sent")] | length' "$CONCURRENT_LOG")" "1"
assert_eq "concurrent cooldown logs one deduped result" \
  "$(jq -s '[.[] | select(.result == "deduped")] | length' "$CONCURRENT_LOG")" "1"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
N_DISTINCT=$(curl_calls)
declare -a DISTINCT_PIDS=()
for machine_label in concurrent-a concurrent-b concurrent-c; do
  PATH="$SB/slowbin:$PATH" HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
    AGENT_NOTIFY_MACHINE_LABEL="$machine_label" FAKE_CURL_SLEEP_SECONDS=4 \
    "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1 &
  DISTINCT_PIDS+=("$!")
done
for distinct_pid in "${DISTINCT_PIDS[@]}"; do
  wait "$distinct_pid"
  assert_eq "distinct-key concurrent notifier exits 0 ($distinct_pid)" "$?" "0"
done
assert_eq "per-key locks preserve all distinct concurrent publishes" \
  "$(($(curl_calls) - N_DISTINCT))" "3"
DISTINCT_LOG="$H/.local/state/agent-notify/log.jsonl"
assert_eq "distinct-key concurrency has no lock timeout" \
  "$(jq -s '[.[] | select(.result == "cooldown-lock-timeout")] | length' "$DISTINCT_LOG")" "0"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
printf '%s' '{"summary":"@owner","body":"review needed"}' |
  HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic AGENT_NOTIFY_COOLDOWN_SECS=0 \
    "$BIN" desktop > /dev/null 2>&1
assert_eq "leading-at body is streamed literally to curl" \
  "$(cat "$FAKE_CURL_BODY_LOG")" "@owner - review needed"
assert_match "publish reads the body from stdin" \
  "$(tail -n 1 "$FAKE_CURL_LOG")" "--data-binary @-"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
N3=$(curl_calls)
HOME="$H" XDG_STATE_HOME='' "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
RC=$?
assert_eq "missing topic exits 0" "$RC" "0"
assert_eq "missing topic sends nothing" "$(curl_calls)" "$N3"
assert_eq "missing topic logged as no-topic" "$(log_field "$H" '.result')" "no-topic"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
N4=$(curl_calls)
printf 'broken{' | HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=t "$BIN" claude > /dev/null 2>&1
RC=$?
assert_eq "malformed payload exits 0 in send mode" "$RC" "0"
assert_eq "malformed payload sends nothing" "$(curl_calls)" "$N4"
assert_eq "malformed payload logged skipped" "$(log_field "$H" '.result')" "skipped"
rm -rf "$H"

mkdir -p "$SB/failbin"
cat > "$SB/failbin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_LOG:?}"
exit 7
STUB
chmod +x "$SB/failbin/curl"

H=$(mktemp -d "$SB/home.XXXXXX")
N5=$(curl_calls)
PATH="$SB/failbin:$PATH" HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
RC=$?
assert_eq "failing curl still exits 0" "$RC" "0"
assert_eq "failing curl attempt is observable" "$(($(curl_calls) - N5))" "1"
RESULT_F=$(log_field "$H" '.result')
assert_match "failure recorded in log" "$RESULT_F" "^failed"
assert_absent_path "cooldown released on failed publish" \
  "$H/.local/state/agent-notify/cooldown/testbox_claude_done.ts"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
mkdir -p "$SB/config/agent-notify"
cat > "$SB/config/agent-notify/agent-notify.env" << 'ENVEOF'
export AGENT_NOTIFY_TOPIC=from-envfile
export AGENT_NOTIFY_MACHINE_LABEL=envbox
ENVEOF
chmod 600 "$SB/config/agent-notify/agent-notify.env"
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_MACHINE_LABEL=testbox \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
ENVLINE=$(tail -n 1 "$FAKE_CURL_LOG")
assert_match "env-file topic picked up automatically" "$ENVLINE" "https://ntfy.sh/from-envfile"
assert_match "env-file machine label wins over ambient env" "$ENVLINE" "Title: \[envbox\] Claude: DONE"
assert_eq "env-file flow completes successfully" "$(log_field "$H" '.result')" "sent"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
printf 'export AGENT_NOTIFY_TOPIC=crlf-topic\r\nexport AGENT_NOTIFY_MACHINE_LABEL=crbox\r\n' \
  > "$SB/config/agent-notify/agent-notify.env"
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_MACHINE_LABEL=testbox \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
CRLFLINE=$(tail -n 1 "$FAKE_CURL_LOG")
assert_match "CRLF env-file values are carriage-return free" "$CRLFLINE" "https://ntfy.sh/crlf-topic( |$)"
assert_match "CRLF machine label sanitized in title" "$CRLFLINE" "Title: \[crbox\] Claude: DONE"
assert_eq "CRLF env-file flow succeeds" "$(log_field "$H" '.result')" "sent"
rm -rf "$SB/config/agent-notify/agent-notify.env"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
N7=$(curl_calls)
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS='90 sec' AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
RC=$?
assert_eq "non-numeric cooldown exits 0" "$RC" "0"
assert_eq "non-numeric cooldown falls back to default and sends once" "$(($(curl_calls) - N7))" "1"
assert_eq "non-numeric cooldown still logs sent" "$(log_field "$H" '.result')" "sent"
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS='90 sec' AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
assert_eq "fallback cooldown window suppresses repeat" "$(curl_calls)" "$((N7 + 1))"
rm -rf "$H"

OUT=$(HOME="$SB/h-snip" XDG_STATE_HOME='' AGENT_NOTIFY_SNIPPET_MAX='1m60' \
  "$BIN" --print claude < "$FIXDIR/claude-stop-truncated.json" 2> /dev/null)
SNIPBODY=$(jq -r '.body' <<< "$OUT")
if [[ "$SNIPBODY" == *… ]]; then
  note_pass "non-numeric snippet max falls back to clamping"
else
  note_fail "non-numeric snippet max disabled truncation: [$SNIPBODY]"
fi
rm -rf "$SB/h-snip"

H=$(mktemp -d "$SB/home.XXXXXX")
N8=$(curl_calls)
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC='../evil-x y' \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
RC=$?
assert_eq "invalid topic exits 0" "$RC" "0"
assert_eq "invalid topic sends nothing" "$(curl_calls)" "$N8"
assert_eq "invalid topic logged as bad-topic" "$(log_field "$H" '.result')" "bad-topic"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=08 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=08 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
N9=$(curl_calls)
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=08 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
assert_eq "leading-zero cooldown normalizes instead of disabling dedup" "$(curl_calls)" "$N9"
rm -rf "$H"

OUT=$(HOME="$SB/h-huge" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=99999999999999999999999 \
  AGENT_NOTIFY_TOPIC=test-topic "$BIN" --print claude < "$CLAUDE_STOP_FIXTURE" 2> /dev/null)
if jq -e '.url' <<< "$OUT" > /dev/null 2>&1; then
  note_pass "overflowing cooldown clamps without crashing"
else
  note_fail "overflowing cooldown broke print mode"
fi
rm -rf "$SB/h-huge"

H=$(mktemp -d "$SB/home.XXXXXX")
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=9223372036854775808 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=9223372036854775808 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
N10=$(curl_calls)
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_COOLDOWN_SECS=9223372036854775808 AGENT_NOTIFY_TOPIC=test-topic \
  "$BIN" claude < "$CLAUDE_STOP_FIXTURE" > /dev/null 2>&1
assert_eq "int64-wrapband cooldown cannot disable dedup" "$(curl_calls)" "$N10"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
mkdir -p "$SB/config/agent-notify"
printf 'export AGENT_NOTIFY_DEBUG=1\n' > "$SB/config/agent-notify/agent-notify.env"
DBG_OUT=$(HOME="$H" XDG_STATE_HOME='' "$BIN" --print desktop 2>&1 > /dev/null < /dev/null)
if [[ "$DBG_OUT" == *"agent-notify: "* ]]; then
  note_pass "env-file can enable debug output"
else
  note_fail "env-file AGENT_NOTIFY_DEBUG ignored: [$DBG_OUT]"
fi
rm -f "$SB/config/agent-notify/agent-notify.env"
rm -rf "$H"

SHIM_LAYOUT_ROOT=$(mktemp -d "$SB/shim-layout.XXXXXX")
SHIM_LAYOUT_ROOT=$(cd -P -- "$SHIM_LAYOUT_ROOT" && pwd)
SHIM_TOOL_DIR="$SHIM_LAYOUT_ROOT/tools"
SHIM_CORE_STUB="$SHIM_LAYOUT_ROOT/core-stub"
SHIM_TARGET_LOG="$SHIM_LAYOUT_ROOT/selected-target.log"
mkdir -p "$SHIM_TOOL_DIR"
if ! SHIM_HOST_BASH=$(command -v bash); then
  note_fail "shim layout harness requires bash"
  SHIM_HOST_BASH=/usr/bin/bash
fi
for tool in bash cat dirname grep jq; do
  if ! SHIM_HOST_TOOL=$(command -v "$tool"); then
    note_fail "shim layout harness requires $tool"
    continue
  fi
  {
    printf '#!%s\n' "$SHIM_HOST_BASH"
    printf 'exec %q "$@"\n' "$SHIM_HOST_TOOL"
  } > "$SHIM_TOOL_DIR/$tool"
  chmod 755 "$SHIM_TOOL_DIR/$tool"
done
cat > "$SHIM_CORE_STUB" << 'STUB'
#!/usr/bin/env bash
# agent-notify-managed: core
cat > /dev/null
printf '%s\n' "$0" >> "${AGENT_NOTIFY_SHIM_TARGET_LOG:?}"
STUB
chmod 755 "$SHIM_CORE_STUB"

SHIM_INSTALL_DIR="$SHIM_LAYOUT_ROOT/default-home/.local/bin"
SHIM_STALE_DIR="$SHIM_LAYOUT_ROOT/default-home/bin"
mkdir -p "$SHIM_INSTALL_DIR" "$SHIM_STALE_DIR"
cp "$SHIM" "$SHIM_INSTALL_DIR/notify-send"
cp "$SHIM_CORE_STUB" "$SHIM_INSTALL_DIR/agent-notify"
cp "$SHIM_CORE_STUB" "$SHIM_STALE_DIR/agent-notify"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  PATH="$SHIM_TOOL_DIR" HOME="$SHIM_LAYOUT_ROOT/default-home" XDG_STATE_HOME='' \
  "$SHIM_INSTALL_DIR/notify-send" "Installed layout" "Uses sibling core" > /dev/null 2>&1
for ((i = 0; i < 40; i++)); do
  [[ -s "$SHIM_TARGET_LOG" ]] && break
  sleep 0.05
done
assert_eq "installed shim prefers its managed sibling core" \
  "$(cat "$SHIM_TARGET_LOG" 2> /dev/null || printf 'missing')" "$SHIM_INSTALL_DIR/agent-notify"

rm -f "$SHIM_TARGET_LOG" "$SHIM_INSTALL_DIR/agent-notify"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  PATH="$SHIM_TOOL_DIR" HOME="$SHIM_LAYOUT_ROOT/default-home" XDG_STATE_HOME='' \
  "$SHIM_INSTALL_DIR/notify-send" "Installed layout" "Ignores stale parent core" > /dev/null 2>&1
assert_absent_path "installed shim does not infer a core from ~/bin" "$SHIM_TARGET_LOG"

SHIM_SOURCE_ROOT="$SHIM_LAYOUT_ROOT/source/AgentNotify"
SHIM_SOURCE_DIR="$SHIM_SOURCE_ROOT/adapters/nanocoder"
mkdir -p "$SHIM_SOURCE_DIR" "$SHIM_SOURCE_ROOT/bin"
cp "$SHIM" "$SHIM_SOURCE_DIR/notify-send"
cp "$SHIM_CORE_STUB" "$SHIM_SOURCE_DIR/agent-notify"
cp "$SHIM_CORE_STUB" "$SHIM_SOURCE_ROOT/bin/agent-notify"
printf '%s\n' "readonly SOURCE_SHIM=\"\$SCRIPT_DIR/adapters/nanocoder/notify-send\"" \
  > "$SHIM_SOURCE_ROOT/install.sh"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  PATH="$SHIM_TOOL_DIR" HOME="$SHIM_LAYOUT_ROOT/source-home" XDG_STATE_HOME='' \
  "$SHIM_SOURCE_DIR/notify-send" "Source layout" "Uses repository core" > /dev/null 2>&1
assert_eq "source shim prefers the repository core over a foreign sibling" \
  "$(cat "$SHIM_TARGET_LOG" 2> /dev/null || printf 'missing')" \
  "$SHIM_SOURCE_DIR/../../bin/agent-notify"

rm -f "$SHIM_TARGET_LOG" "$SHIM_SOURCE_ROOT/bin/agent-notify"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  PATH="$SHIM_TOOL_DIR" HOME="$SHIM_LAYOUT_ROOT/source-home" XDG_STATE_HOME='' \
  "$SHIM_SOURCE_DIR/notify-send" "Partial source layout" "Falls back to sibling" > /dev/null 2>&1
assert_eq "partial source layout falls back to its managed sibling" \
  "$(cat "$SHIM_TARGET_LOG" 2> /dev/null || printf 'missing')" "$SHIM_SOURCE_DIR/agent-notify"

rm -f "$SHIM_TARGET_LOG"
SHIM_CUSTOM_DIR="$SHIM_LAYOUT_ROOT/custom/bin"
SHIM_FALLBACK_DIR="$SHIM_LAYOUT_ROOT/fallback-home/.local/bin"
mkdir -p "$SHIM_CUSTOM_DIR/agent-notify" "$SHIM_FALLBACK_DIR"
cp "$SHIM" "$SHIM_CUSTOM_DIR/notify-send"
cp "$SHIM_CORE_STUB" "$SHIM_FALLBACK_DIR/agent-notify"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  PATH="$SHIM_TOOL_DIR" HOME="$SHIM_LAYOUT_ROOT/fallback-home" XDG_STATE_HOME='' \
  "$SHIM_CUSTOM_DIR/notify-send" "Installed layout" "Skips directory candidate" > /dev/null 2>&1
assert_eq "shim skips executable directories when resolving the core" \
  "$(cat "$SHIM_TARGET_LOG" 2> /dev/null || printf 'missing')" "$SHIM_FALLBACK_DIR/agent-notify"

rm -f "$SHIM_TARGET_LOG"
SHIM_ALIAS_DIR="$SHIM_LAYOUT_ROOT/alias-bin"
SHIM_REALPATH_DIR="$SHIM_LAYOUT_ROOT/no-realpath-bin"
SHIM_REALPATH_LOG="$SHIM_LAYOUT_ROOT/realpath-called.log"
mkdir -p "$SHIM_ALIAS_DIR" "$SHIM_REALPATH_DIR"
if ! ln "$SHIM_INSTALL_DIR/notify-send" "$SHIM_ALIAS_DIR/notify-send"; then
  note_fail "shim identity harness could not create a same-filesystem hard link"
fi
cat > "$SHIM_REALPATH_DIR/realpath" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' called >> "${AGENT_NOTIFY_REALPATH_LOG:?}"
exit 127
STUB
chmod 755 "$SHIM_REALPATH_DIR/realpath"
cp "$SHIM_CORE_STUB" "$SHIM_INSTALL_DIR/agent-notify"
AGENT_NOTIFY_SHIM_TARGET_LOG="$SHIM_TARGET_LOG" \
  AGENT_NOTIFY_REALPATH_LOG="$SHIM_REALPATH_LOG" \
  PATH="$SHIM_ALIAS_DIR:$SHIM_REALPATH_DIR:$SB/realbin:$SHIM_TOOL_DIR" \
  HOME="$SHIM_LAYOUT_ROOT/default-home" XDG_STATE_HOME='' \
  "$SHIM_INSTALL_DIR/notify-send" "Alias identity" "Forwards once" > /dev/null 2>&1
for ((i = 0; i < 40; i++)); do
  [[ -s "$SHIM_TARGET_LOG" ]] && break
  sleep 0.05
done
assert_eq "shim recognizes its aliased path and invokes the core once" \
  "$(cat "$SHIM_TARGET_LOG" 2> /dev/null || printf 'missing')" "$SHIM_INSTALL_DIR/agent-notify"
assert_absent_path "shim path identity does not depend on realpath" "$SHIM_REALPATH_LOG"

H=$(mktemp -d "$SB/home.XXXXXX")
PATH="$SB/bin:$SB/realbin:$PATH" HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$SHIM" -u critical "Action Required in my-project" "Nanocoder needs your approval" > /dev/null 2>&1
RC=$?
assert_eq "shim invocation completes cleanly" "$RC" "0"
FORWARDED_ARGS=$(jq -c '.' "$FAKE_NOTIFY_SEND_LOG" 2> /dev/null || printf 'missing')
assert_eq "shim preserves original desktop notification arguments" "$FORWARDED_ARGS" \
  '["-u","critical","Action Required in my-project","Nanocoder needs your approval"]'
LASTLOG=$(log_field "$H" '.result')
assert_eq "shim forwarded notification logged sent-or-no-topic" "$LASTLOG" "sent"
STATE_LOGGED=$(log_field "$H" '.state')
assert_eq "shim approval text mapped to waiting" "$STATE_LOGGED" "waiting"
DETAIL_LOGGED=$(log_field "$H" '.detail')
assert_match "summary intact after long-option strip" "$DETAIL_LOGGED" "^Action Required in my-project"
assert_not_match "urgency value must not replace summary" "$DETAIL_LOGGED" "^critical"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$SHIM" -i "/sp ace/icon.png" "Question from nanocoder" "Which database driver should I use?" > /dev/null 2>&1
STATE_LOGGED_Q=$(log_field "$H" '.state')
assert_eq "space-bearing icon option consumed cleanly" "$STATE_LOGGED_Q" "waiting"
DETAIL_LOGGED_Q=$(log_field "$H" '.detail')
assert_match "question summary intact after option strip" "$DETAIL_LOGGED_Q" "^Question from nanocoder"
rm -rf "$H"

H=$(mktemp -d "$SB/home.XXXXXX")
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$SHIM" --expire-time=5000 "Response ready in helper-project" "" > /dev/null 2>&1
STATE_LOGGED2=$(log_field "$H" '.state')
assert_eq "shim completion text mapped to done" "$STATE_LOGGED2" "done"
rm -rf "$H"

echo
echo "==========================================="
echo " PASS: $PASS   FAIL: $FAIL"
echo "==========================================="
if ((FAIL > 0)); then
  printf '%s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
