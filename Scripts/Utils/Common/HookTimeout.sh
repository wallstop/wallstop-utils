#!/usr/bin/env bash
# Shared timeout helpers for git hooks and bootstrap scripts.
# shellcheck disable=SC2034 # Reason: WALLSTOP_TIMEOUT_COMMAND_* globals are read by sourced callers.

wallstop_timeout_emit_warning() {
  local message="$*"

  if [[ -n "${WALLSTOP_TIMEOUT_WARNING_PREFIX:-}" ]]; then
    echo "${WALLSTOP_TIMEOUT_WARNING_PREFIX}${message}" >&2
    return 0
  fi

  echo "$message"
}

wallstop_resolve_timeout_command() {
  if command -v timeout > /dev/null 2>&1; then
    printf '%s\n' "timeout"
    return 0
  fi

  if command -v gtimeout > /dev/null 2>&1; then
    printf '%s\n' "gtimeout"
    return 0
  fi

  return 1
}

wallstop_can_start_session_with_setsid() {
  command -v setsid > /dev/null 2>&1 && setsid sh -c 'kill -0 -- "-$$"' > /dev/null 2>&1
}

wallstop_can_start_session_with_python3() {
  command -v python3 > /dev/null 2>&1 && python3 -c 'import os, signal; os.setsid(); os.kill(-os.getpid(), 0)' > /dev/null 2>&1
}

wallstop_can_start_session_with_perl() {
  command -v perl > /dev/null 2>&1 && perl -MPOSIX=setsid -e 'setsid() or exit 1; kill 0, -$$ or exit 1' > /dev/null 2>&1
}

wallstop_start_timeout_command() {
  local label="$1"
  shift

  if wallstop_can_start_session_with_setsid; then
    setsid "$@" &
    WALLSTOP_TIMEOUT_COMMAND_PID=$!
    WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE="isolated"
    return 0
  fi

  if wallstop_can_start_session_with_python3; then
    python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
    WALLSTOP_TIMEOUT_COMMAND_PID=$!
    WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE="isolated"
    return 0
  fi

  if wallstop_can_start_session_with_perl; then
    perl -MPOSIX=setsid -e 'setsid() or die "setsid failed: $!"; exec @ARGV; die "exec failed: $!"' -- "$@" &
    WALLSTOP_TIMEOUT_COMMAND_PID=$!
    WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE="isolated"
    return 0
  fi

  wallstop_timeout_emit_warning "W_HOOK_PROCESS_GROUP_UNAVAILABLE: setsid/python3/perl not found; shell watchdog can only signal the direct child for '${label}'."
  "$@" &
  WALLSTOP_TIMEOUT_COMMAND_PID=$!
  WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE="direct"
}

wallstop_is_timeout_command_alive() {
  local command_pid="$1"
  local process_group_mode="$2"

  if [[ "$process_group_mode" == "isolated" ]]; then
    kill -0 -- "-${command_pid}" > /dev/null 2>&1
    return $?
  fi

  kill -0 "$command_pid" > /dev/null 2>&1
}

wallstop_signal_direct_timeout_process_tree() {
  local command_pid="$1"
  local signal_name="$2"

  if command -v pgrep > /dev/null 2>&1; then
    local child_pid
    for child_pid in $(pgrep -P "$command_pid" 2> /dev/null || true); do
      wallstop_signal_direct_timeout_process_tree "$child_pid" "$signal_name"
    done
  fi

  kill "-${signal_name}" "$command_pid" > /dev/null 2>&1 || true
}

wallstop_signal_timeout_command() {
  local command_pid="$1"
  local process_group_mode="$2"
  local signal_name="$3"

  if [[ "$process_group_mode" == "isolated" ]]; then
    kill "-${signal_name}" -- "-${command_pid}" > /dev/null 2>&1 || kill "-${signal_name}" "$command_pid" > /dev/null 2>&1 || true
    return 0
  fi

  wallstop_signal_direct_timeout_process_tree "$command_pid" "$signal_name"
}

wallstop_terminate_timeout_command() {
  local command_pid="$1"
  local process_group_mode="$2"

  wallstop_signal_timeout_command "$command_pid" "$process_group_mode" "TERM"
  sleep 2
  if wallstop_is_timeout_command_alive "$command_pid" "$process_group_mode"; then
    wallstop_signal_timeout_command "$command_pid" "$process_group_mode" "KILL"
  fi
}

wallstop_cleanup_timeout_command_processes() {
  local command_pid="$1"
  local process_group_mode="$2"
  local label="$3"

  if [[ "$process_group_mode" != "isolated" ]]; then
    return 0
  fi

  if wallstop_is_timeout_command_alive "$command_pid" "$process_group_mode"; then
    wallstop_timeout_emit_warning "W_HOOK_PROCESS_GROUP_CLEANUP: ${label} left child processes running after exit; terminating process group ${command_pid}."
    wallstop_terminate_timeout_command "$command_pid" "$process_group_mode"
  fi
}
