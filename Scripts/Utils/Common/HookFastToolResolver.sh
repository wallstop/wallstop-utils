# shellcheck shell=bash
# Shared fast-path resolver for repo-managed hook tools.
#
# This file is sourced by git hook wrappers. Keep it Bash-only, dependency-light,
# and free of top-level side effects.

wallstop_fast_current_platform_key() {
  local os_name
  local arch_name

  case "$(uname -s 2> /dev/null || printf unknown)" in
    Darwin)
      os_name="darwin"
      ;;
    Linux)
      os_name="linux"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      os_name="windows"
      ;;
    *)
      return 1
      ;;
  esac

  case "$(uname -m 2> /dev/null || printf unknown)" in
    x86_64 | amd64)
      arch_name="x64"
      ;;
    arm64 | aarch64)
      arch_name="arm64"
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s-%s\n' "$os_name" "$arch_name"
}

wallstop_fast_is_windows_arm64_host() {
  local processor_text

  processor_text="${PROCESSOR_ARCHITECTURE:-} ${PROCESSOR_ARCHITEW6432:-} ${PROCESSOR_IDENTIFIER:-}"
  case "$processor_text" in
    *[Aa][Rr][Mm]64* | *[Aa][Aa][Rr][Cc][Hh]64*)
      return 0
      ;;
  esac

  return 1
}

wallstop_fast_append_unique_candidate_key() {
  local existing_keys="$1"
  local candidate_key="$2"

  [[ -n "$candidate_key" ]] || return 0

  case " ${existing_keys} " in
    *" ${candidate_key} "*)
      printf '%s\n' "$existing_keys"
      ;;
    *)
      if [[ -n "$existing_keys" ]]; then
        printf '%s %s\n' "$existing_keys" "$candidate_key"
      else
        printf '%s\n' "$candidate_key"
      fi
      ;;
  esac
}

wallstop_fast_candidate_keys() {
  local platform_key="$1"
  local candidate_keys=""

  case "$platform_key" in
    windows-*)
      if [[ "$platform_key" == "windows-arm64" ]] || wallstop_fast_is_windows_arm64_host; then
        candidate_keys="$(wallstop_fast_append_unique_candidate_key "$candidate_keys" "windows-arm64")"
        candidate_keys="$(wallstop_fast_append_unique_candidate_key "$candidate_keys" "windows-x64")"
      else
        candidate_keys="$(wallstop_fast_append_unique_candidate_key "$candidate_keys" "$platform_key")"
      fi
      ;;
    *)
      candidate_keys="$(wallstop_fast_append_unique_candidate_key "$candidate_keys" "$platform_key")"
      ;;
  esac

  printf '%s\n' "$candidate_keys"
}

wallstop_fast_read_json_string_property() {
  local json_path="$1"
  local property_name="$2"

  sed -n "s/.*\"${property_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$json_path" | head -n 1
}

wallstop_fast_read_manifest_version() {
  local manifest_path="$1"
  local tool_name="$2"

  awk -v tool_name="$tool_name" '
    $0 ~ "\"" tool_name "\"[[:space:]]*:" { in_tool = 1; next }
    in_tool && $0 ~ /"version"[[:space:]]*:/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$manifest_path"
}

wallstop_fast_read_manifest_asset_property() {
  local manifest_path="$1"
  local tool_name="$2"
  local asset_key="$3"
  local property_name="$4"

  awk -v tool_name="$tool_name" -v asset_key="$asset_key" -v property_name="$property_name" '
    function count_char(line, char, position, count) {
      count = 0
      for (position = 1; position <= length(line); position++) {
        if (substr(line, position, 1) == char) {
          count++
        }
      }
      return count
    }

    function extract_string(line) {
      sub(/^[^:]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      return line
    }

    function has_json_key(line, key) {
      return line ~ "\"" key "\"[[:space:]]*:"
    }

    {
      before_depth = depth
      after_depth = depth + count_char($0, "{") - count_char($0, "}")

      if (!in_tool && has_json_key($0, tool_name)) {
        in_tool = 1
        tool_depth = after_depth > before_depth ? after_depth : before_depth + 1
      }
      if (in_tool && !in_assets && has_json_key($0, "assets")) {
        in_assets = 1
        assets_depth = after_depth > before_depth ? after_depth : before_depth + 1
      }
      if (in_assets && !in_asset && has_json_key($0, asset_key)) {
        in_asset = 1
        asset_depth = after_depth > before_depth ? after_depth : before_depth + 1
      }
      if (in_asset && has_json_key($0, property_name)) {
        print extract_string($0)
        exit
      }

      depth = after_depth
      if (in_asset && depth < asset_depth) {
        in_asset = 0
      }
      if (in_assets && depth < assets_depth) {
        in_assets = 0
      }
      if (in_tool && depth < tool_depth) {
        in_tool = 0
      }
    }

  ' "$manifest_path"
}

wallstop_fast_read_file_size() {
  local tool_path="$1"

  wc -c < "$tool_path" | tr -d '[:space:]'
}

wallstop_fast_read_file_mtime() {
  local tool_path="$1"

  if stat -c '%Y' "$tool_path" > /dev/null 2>&1; then
    stat -c '%Y' "$tool_path"
    return 0
  fi

  if stat -f '%m' "$tool_path" > /dev/null 2>&1; then
    stat -f '%m' "$tool_path"
    return 0
  fi

  return 1
}

wallstop_fast_compute_stdin_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum | awk '{ print tolower($1) }'
    return 0
  fi

  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 | awk '{ print tolower($1) }'
    return 0
  fi

  if command -v openssl > /dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{ print tolower($1) }'
    return 0
  fi

  return 1
}

wallstop_fast_fingerprint_version() {
  printf '%s\n' "sampled-sha256-v1-65536"
}

wallstop_fast_emit_fingerprint_segment() {
  local tool_path="$1"
  local offset="$2"
  local length="$3"
  local sample_bytes="$4"

  printf 'segment=%s:%s\n' "$offset" "$length"
  if [[ "$length" -le 0 ]]; then
    return 0
  fi

  if [[ "$offset" -eq 0 && "$length" -eq "$sample_bytes" ]]; then
    dd if="$tool_path" bs="$sample_bytes" count=1 2> /dev/null
    printf '\n'
    return 0
  fi

  if [[ "$offset" -gt 0 && "$length" -eq "$sample_bytes" && $((offset % sample_bytes)) -eq 0 ]]; then
    dd if="$tool_path" bs="$sample_bytes" skip="$((offset / sample_bytes))" count=1 2> /dev/null
    printf '\n'
    return 0
  fi

  tail -c "$length" "$tool_path"
  printf '\n'
}

wallstop_fast_compute_tool_fingerprint() {
  local tool_path="$1"
  local tool_size="$2"
  local sample_bytes=65536
  local middle_offset
  local end_offset

  {
    printf 'wallstop-fast-fingerprint-v1\n'
    printf 'size=%s\n' "$tool_size"
    printf 'sampleBytes=%s\n' "$sample_bytes"

    if [[ "$tool_size" -le $((sample_bytes * 3)) ]]; then
      printf 'segment=0:%s\n' "$tool_size"
      cat "$tool_path"
      printf '\n'
    else
      middle_offset=$(((((tool_size - sample_bytes) / 2) / sample_bytes) * sample_bytes))
      end_offset=$((tool_size - sample_bytes))
      wallstop_fast_emit_fingerprint_segment "$tool_path" 0 "$sample_bytes" "$sample_bytes"
      wallstop_fast_emit_fingerprint_segment "$tool_path" "$middle_offset" "$sample_bytes" "$sample_bytes"
      wallstop_fast_emit_fingerprint_segment "$tool_path" "$end_offset" "$sample_bytes" "$sample_bytes"
    fi
  } | wallstop_fast_compute_stdin_sha256
}

wallstop_fast_validate_tool_candidate() {
  local tool_name="$1"
  local expected_version="$2"
  local candidate_key="$3"
  local tool_path="$4"
  local expected_asset_name="$5"
  local expected_asset_sha256="$6"
  local marker_path
  local marker_tool
  local marker_version
  local marker_asset_key
  local marker_asset_name
  local marker_asset_sha256
  local marker_executable_sha256
  local marker_executable_size
  local marker_executable_mtime
  local marker_fast_fingerprint_version
  local marker_fast_fingerprint
  local actual_executable_size
  local actual_executable_mtime
  local actual_fast_fingerprint

  marker_path="${tool_path%/bin/*}/asset.json"
  expected_asset_sha256="$(printf '%s' "$expected_asset_sha256" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$expected_version" || -z "$expected_asset_name" || ! "$expected_asset_sha256" =~ ^[A-Fa-f0-9]{64}$ || ! -f "$marker_path" ]]; then
    return 1
  fi

  marker_tool="$(wallstop_fast_read_json_string_property "$marker_path" "tool")"
  marker_version="$(wallstop_fast_read_json_string_property "$marker_path" "version")"
  marker_asset_key="$(wallstop_fast_read_json_string_property "$marker_path" "assetKey")"
  marker_asset_name="$(wallstop_fast_read_json_string_property "$marker_path" "assetName")"
  marker_asset_sha256="$(wallstop_fast_read_json_string_property "$marker_path" "sha256" | tr '[:upper:]' '[:lower:]')"
  marker_executable_sha256="$(wallstop_fast_read_json_string_property "$marker_path" "executableSha256")"
  marker_executable_size="$(wallstop_fast_read_json_string_property "$marker_path" "executableSize")"
  marker_executable_mtime="$(wallstop_fast_read_json_string_property "$marker_path" "executableMtime")"
  marker_fast_fingerprint_version="$(wallstop_fast_read_json_string_property "$marker_path" "executableFastFingerprintVersion")"
  marker_fast_fingerprint="$(wallstop_fast_read_json_string_property "$marker_path" "executableFastFingerprint")"

  if [[ "$marker_tool" != "$tool_name" || "$marker_version" != "$expected_version" || "$marker_asset_key" != "$candidate_key" || "$marker_asset_name" != "$expected_asset_name" || "$marker_asset_sha256" != "$expected_asset_sha256" ]]; then
    return 1
  fi

  if [[ ! "$marker_executable_sha256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    return 1
  fi

  if [[ "$marker_fast_fingerprint_version" != "$(wallstop_fast_fingerprint_version)" || ! "$marker_fast_fingerprint" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    return 1
  fi

  actual_executable_size="$(wallstop_fast_read_file_size "$tool_path" || true)"
  actual_executable_mtime="$(wallstop_fast_read_file_mtime "$tool_path" || true)"
  if [[ -z "$marker_executable_size" || -z "$marker_executable_mtime" || "$actual_executable_size" != "$marker_executable_size" || "$actual_executable_mtime" != "$marker_executable_mtime" ]]; then
    return 1
  fi

  if ! actual_fast_fingerprint="$(wallstop_fast_compute_tool_fingerprint "$tool_path" "$actual_executable_size")"; then
    return 1
  fi

  if [[ "$actual_fast_fingerprint" != "$(printf '%s' "$marker_fast_fingerprint" | tr '[:upper:]' '[:lower:]')" ]]; then
    return 1
  fi

  return 0
}

wallstop_resolve_managed_fast_tool() {
  local repo_root="$1"
  local suite_root="$2"
  local tool_name="$3"
  local platform_key
  local manifest_path
  local expected_version
  local candidate=""
  local candidate_keys
  local candidate_key
  local expected_asset_name
  local expected_asset_sha256
  local executable_suffix
  local tool_path
  local preferred_candidate_failed=0

  if ! platform_key="$(wallstop_fast_current_platform_key)"; then
    return 1
  fi

  case "$suite_root" in
    ".tools/native-quality")
      manifest_path="${repo_root}/Scripts/Utils/Quality/native-quality-tools.json"
      ;;
    ".tools/shell-quality")
      manifest_path="${repo_root}/Scripts/Utils/Quality/shell-quality-tools.json"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ ! -f "$manifest_path" ]]; then
    return 1
  fi

  expected_version="$(wallstop_fast_read_manifest_version "$manifest_path" "$tool_name")"
  if [[ -z "$expected_version" ]]; then
    return 1
  fi

  candidate_keys="$(wallstop_fast_candidate_keys "$platform_key")"
  for candidate_key in $candidate_keys; do
    expected_asset_name="$(wallstop_fast_read_manifest_asset_property "$manifest_path" "$tool_name" "$candidate_key" "assetName")"
    expected_asset_sha256="$(wallstop_fast_read_manifest_asset_property "$manifest_path" "$tool_name" "$candidate_key" "sha256")"
    if [[ -z "$expected_asset_name" || -z "$expected_asset_sha256" ]]; then
      continue
    fi

    executable_suffix=""
    case "$candidate_key" in
      windows-*)
        executable_suffix=".exe"
        ;;
    esac

    tool_path="${repo_root}/${suite_root}/${tool_name}/${expected_version}/${candidate_key}/bin/${tool_name}${executable_suffix}"
    if [[ -f "$tool_path" ]] && wallstop_fast_validate_tool_candidate "$tool_name" "$expected_version" "$candidate_key" "$tool_path" "$expected_asset_name" "$expected_asset_sha256"; then
      candidate="$tool_path"
    elif [[ "$candidate_key" == "windows-arm64" ]]; then
      preferred_candidate_failed=1
    fi
    if [[ -n "$candidate" ]]; then
      break
    fi
    if [[ "$preferred_candidate_failed" -eq 1 ]]; then
      break
    fi
  done

  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}
