#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/agent-notify"
SHIM="$ROOT/adapters/nanocoder/notify-send"
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
export FAKE_CURL_LOG

cat > "$SB/bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_LOG:?}"
printf '%s' "200"
STUB
chmod +x "$SB/bin/curl"
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

for shfile in "$BIN" "$SHIM" "$0"; do
  if bash -n "$shfile" 2> /dev/null; then
    note_pass
  else
    note_fail "syntax error in $shfile"
  fi
done

if command -v shellcheck > /dev/null 2>&1; then
  shellcheck "$BIN" "$SHIM" "$0" 2> "$SB/shellcheck.out" ||
    printf '%s\n' "shellcheck notes (informational): $(head -c 300 "$SB/shellcheck.out")" >&2
fi

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

H=$(mktemp -d "$SB/home.XXXXXX")
HOME="$H" XDG_STATE_HOME='' AGENT_NOTIFY_TOPIC=test-topic \
  "$SHIM" -u critical "Action Required in my-project" "Nanocoder needs your approval" > /dev/null 2>&1
RC=$?
assert_eq "shim invocation completes cleanly" "$RC" "0"
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
