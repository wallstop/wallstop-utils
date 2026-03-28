#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
cd "$repo_root"

if ! command -v osacompile > /dev/null 2>&1; then
  echo "W_OSACOMPILE_UNAVAILABLE: osacompile is not available; skipping AppleScript checks."
  exit 0
fi

collect_files() {
  local pattern="$1"
  local output_path="$2"
  : > "$output_path"
  while IFS= read -r -d '' file; do
    printf '%s\0' "$file" >> "$output_path"
  done < <(find Scripts/Mac Config/Mac -type f -name "$pattern" -print0 2> /dev/null)
}

tmp_text_a="$(mktemp -t applescript-text-a.XXXXXX.lst)"
tmp_text_b="$(mktemp -t applescript-text-b.XXXXXX.lst)"
tmp_compiled="$(mktemp -t applescript-compiled.XXXXXX.lst)"
trap 'rm -f "$tmp_text_a" "$tmp_text_b" "$tmp_compiled"' EXIT

collect_files "*.applescript" "$tmp_text_a"
collect_files "*.osascript" "$tmp_text_b"
collect_files "*.scpt" "$tmp_compiled"

text_sources=()
while IFS= read -r -d '' source; do
  text_sources+=("$source")
done < "$tmp_text_a"
while IFS= read -r -d '' source; do
  text_sources+=("$source")
done < "$tmp_text_b"

compiled_sources=()
while IFS= read -r -d '' source; do
  compiled_sources+=("$source")
done < "$tmp_compiled"

validate_text_sources() {
  local failures=0
  for source in "$@"; do
    local tmp_scpt
    tmp_scpt="$(mktemp -t applescript-compile.XXXXXX.scpt)"
    if ! osacompile -o "$tmp_scpt" "$source" > /dev/null 2>&1; then
      echo "E_APPLESCRIPT_COMPILE_FAILED: failed to compile text source '$source'"
      failures=1
    fi
    rm -f "$tmp_scpt"
  done
  return $failures
}

validate_compiled_sources() {
  local failures=0
  if ! command -v osadecompile > /dev/null 2>&1; then
    echo "W_OSADECOMPILE_UNAVAILABLE: osadecompile is not available; cannot validate .scpt fallback artifacts."
    return 0
  fi

  for compiled in "$@"; do
    local tmp_text
    local tmp_scpt
    tmp_text="$(mktemp -t applescript-decompile.XXXXXX.applescript)"
    tmp_scpt="$(mktemp -t applescript-recompile.XXXXXX.scpt)"

    if ! osadecompile "$compiled" > "$tmp_text" 2> /dev/null; then
      echo "E_APPLESCRIPT_DECOMPILE_FAILED: failed to decompile '$compiled'"
      failures=1
      rm -f "$tmp_text" "$tmp_scpt"
      continue
    fi

    if ! osacompile -o "$tmp_scpt" "$tmp_text" > /dev/null 2>&1; then
      echo "E_APPLESCRIPT_RECOMPILE_FAILED: failed to recompile '$compiled' from decompiled source"
      failures=1
    fi

    rm -f "$tmp_text" "$tmp_scpt"
  done

  return $failures
}

if [[ ${#text_sources[@]} -gt 0 ]]; then
  echo "AppleScript checks: compiling ${#text_sources[@]} text source file(s)."
  validate_text_sources "${text_sources[@]}"
  exit $?
fi

echo "AppleScript checks: no text sources found; validating existing .scpt artifacts as migration fallback."
if [[ ${#compiled_sources[@]} -eq 0 ]]; then
  echo "AppleScript checks: no .scpt files found; nothing to validate."
  exit 0
fi

validate_compiled_sources "${compiled_sources[@]}"
exit $?
