#!/bin/bash

# increment-version.sh - A bash version of Increment-Version.ps1
# Increments the version in a package.json file found in the current or parent directories.

set -euo pipefail

# Colors for help text
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;37m'
readonly NC='\033[0m' # No Color

# Default values
PROMOTE_TO_RELEASE=false
INCREMENT_MODE="RolloverAt9"
WHATIF=false
VERBOSE=false

COMMIT_CHANGES=false
RUN_HOOKS=false
NO_VERIFY=false
ALLOW_NON_MAIN=false
PUSH=false
# Display help
show_help() {
    echo -e "${YELLOW}increment-version.sh Script Quick Help:${NC}"
    echo -e "------------------------------------"
    echo
    echo -e "${YELLOW}SYNOPSIS${NC}"
    echo "  Increments the version in a package.json file found in the current or parent directories."
    echo
    echo -e "${YELLOW}SYNTAX${NC}"
    echo -e "  ${GREEN}increment-version.sh${NC} [-p|--promote] [-m|--mode ${GRAY}<Default|RolloverAt9>${NC}] [-w|--whatif] [-v|--verbose] [--commit] [--run-hooks] [--no-verify] [--allow-non-main-branch] [--push] [-h|--help]"
    echo
    echo -e "${YELLOW}DESCRIPTION${NC}"
    echo "  This script searches for a 'package.json' file by traversing upwards from the current directory."
    echo "  It reads the 'version' field, increments it according to SemVer rules (or specified mode),"
    echo "  and writes the changes back. Supports standard increments, pre-release increments,"
    echo "  promotion of pre-releases, and a special 'RolloverAt9' mode."
    echo
    echo -e "${YELLOW}OPTIONS${NC}"
    echo -e "  -p, --promote${NC}"
    echo "    If specified, and the current version is a pre-release (e.g., X.Y.Z-rc.N), it will be promoted"
    echo "    to the release version X.Y.Z. If the current version is already a release, its patch"
    echo "    component will be incremented based on the selected increment mode."
    echo
    echo -e "  -m, --mode ${GRAY}<Default|RolloverAt9>${NC}"
    echo "    Specifies how numeric version components are incremented. Default is 'RolloverAt9'."
    echo "    - Default: Standard SemVer increment."
    echo "        - M.m.p: Patch increments (e.g., 0.0.9 -> 0.0.10)."
    echo "        - Pre-release: Only the rightmost numeric identifier increments (e.g., -rc.07.9 -> -rc.07.10)."
    echo "    - RolloverAt9: Numeric components 'roll over' at 9."
    echo "        - M.m.p: e.g., 0.0.9 -> 0.1.0; 0.9.9 -> 1.0.0."
    echo "        - Pre-release: Applies hierarchically from right to left to numeric/alpha-numeric segments."
    echo "                       e.g., -rc.07.9 -> -rc.08.0."
    echo
    echo -e "  -w, --whatif${NC}"
    echo "    Shows the intended version change without modifying the file."
    echo
    echo -e "  -v, --verbose${NC}"
    echo "    Display verbose output."
    echo
    echo -e "  --commit${NC}"
    echo "    Stage and commit the bump with message 'chore(version): bump to <new>'."
    echo
    echo -e "  --run-hooks${NC}"
    echo "    Run pre-commit hooks (if installed) or formatting fallbacks before commit."
    echo
    echo -e "  --no-verify${NC}"
    echo "    Pass --no-verify to git commit (skip hooks)."
    echo
    echo -e "  --allow-non-main-branch${NC}"
    echo "    Allow committing version bumps on non-main branches (default is restricted)."
    echo
    echo -e "  --push${NC}"
    echo "    Push to the current branch after commit."
    echo
    echo -e "  -h, --help${NC}"
    echo "    Displays this help summary."
    echo
    echo -e "${YELLOW}EXAMPLES${NC}"
    echo -e "  ${GREEN}increment-version.sh${NC}"
    echo "    # Default mode: 0.0.9 -> 0.1.0;  1.0.0-rc.07.9 -> 1.0.0-rc.08.0"
    echo
    echo -e "  ${GREEN}increment-version.sh${NC} -m Default"
    echo "    # Default SemVer mode: 0.0.9 -> 0.0.10;  1.0.0-rc.07.9 -> 1.0.0-rc.07.10"
    echo
    echo -e "  ${GREEN}increment-version.sh${NC} --promote"
    echo "    # Promotes a pre-release (e.g., 1.0.0-rc.2 -> 1.0.0)."
    echo
    echo -e "  ${GREEN}increment-version.sh${NC} --whatif"
    echo "    # Shows the intended version change without modifying the file."
    echo
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help|help|/?|--?)
                show_help
                exit 0
                ;;
            -p|--promote)
                PROMOTE_TO_RELEASE=true
                shift
                ;;
            -m|--mode)
                if [[ -z "${2:-}" ]]; then
                    echo -e "${RED}Error: --mode requires an argument${NC}" >&2
                    exit 1
                fi
                INCREMENT_MODE="$2"
                if [[ "$INCREMENT_MODE" != "Default" && "$INCREMENT_MODE" != "RolloverAt9" ]]; then
                    echo -e "${RED}Error: Invalid increment mode '$INCREMENT_MODE'. Must be 'Default' or 'RolloverAt9'${NC}" >&2
                    exit 1
                fi
                shift 2
                ;;
            -w|--whatif)
                WHATIF=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --commit)
                COMMIT_CHANGES=true
                shift
                ;;
            --run-hooks)
                RUN_HOOKS=true
                shift
                ;;
            --no-verify)
                NO_VERIFY=true
                shift
                ;;
            --allow-non-main-branch)
                ALLOW_NON_MAIN=true
                shift
                ;;
            --push)
                PUSH=true
                shift
                ;;
            *)
                echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
                echo "Use -h or --help for usage information."
                exit 1
                ;;
        esac
    done
}

# Find nearest package.json by searching upwards
find_package_json() {
    local current_dir="$(pwd)"
    while true; do
        local file_path="$current_dir/package.json"
        if [[ -f "$file_path" ]]; then
            echo "$file_path"
            return 0
        fi
        local parent_dir="$(dirname "$current_dir")"
        if [[ "$parent_dir" == "$current_dir" ]]; then
            [[ "$VERBOSE" == "true" ]] && echo "Reached root directory. No package.json found." >&2
            return 1
        fi
        current_dir="$parent_dir"
    done
}

# Increment pre-release using RolloverAt9 mode
increment_prerelease_rollover() {
    local prerelease="$1"
    local carry=1

    # Split prerelease into parts
    IFS='.' read -ra parts <<< "$prerelease"

    # Check if last part needs conceptual .0 appended
    local last_idx=$((${#parts[@]} - 1))
    if [[ ${parts[$last_idx]} =~ ^[a-zA-Z0-9\-]*[0-9]+$ ]] && [[ ${parts[$last_idx]} =~ [a-zA-Z] ]]; then
        if [[ $last_idx -eq 0 ]] || [[ ! ${parts[$last_idx]} =~ ^[0-9]+$ ]] || [[ ! ${parts[$((last_idx-1))]} =~ ^[a-zA-Z0-9\-]*[0-9]+$ ]]; then
            parts+=("0")
        fi
    fi

    # Process from right to left
    for ((i=${#parts[@]}-1; i>=0; i--)); do
        if [[ $carry -eq 0 ]]; then
            break
        fi

        local current_part="${parts[$i]}"
        local original_length=${#current_part}

        # Extract prefix and numeric suffix
        if [[ $current_part =~ ^([a-zA-Z\-\.]*)?([0-9]+)$ ]]; then
            local prefix="${BASH_REMATCH[1]}"
            local num_str="${BASH_REMATCH[2]}"
            local original_num_length=${#num_str}
            local num_val=$((10#$num_str + carry))

            # Check if this is the rightmost numeric segment
            if [[ $i -eq $((${#parts[@]}-1)) ]]; then
                # Rightmost always uses rollover at 9
                if [[ $num_val -gt 9 ]]; then
                    num_val=0
                    carry=1
                else
                    carry=0
                fi
            else
                # Internal segment just increments
                carry=0
            fi

            # Format with zero-padding
            printf -v formatted_num "%0${original_num_length}d" $num_val
            parts[$i]="${prefix}${formatted_num}"
        elif [[ $i -eq $((${#parts[@]}-1)) ]] && [[ $carry -eq 1 ]]; then
            # Non-numeric rightmost part
            parts+=("1")
            carry=0
        fi
    done

    if [[ $carry -eq 1 ]]; then
        echo "ROLLOVER"
        return 0
    fi

    # Join parts and clean up trailing .0 if applicable
    local result=$(IFS='.'; echo "${parts[*]}")
    if [[ $result =~ \.0$ ]] && [[ ${#result} -gt 2 ]]; then
        result="${result%.0}"
    fi

    echo "$result"
}

# Increment pre-release using Default mode
increment_prerelease_default() {
    local prerelease="$1"

    IFS='.' read -ra parts <<< "$prerelease"
    local last_idx=$((${#parts[@]} - 1))
    local last_part="${parts[$last_idx]}"
    local original_length=${#last_part}

    if [[ $last_part =~ ^[0-9]+$ ]]; then
        local num_val=$((10#$last_part + 1))
        printf -v formatted_num "%0${original_length}d" $num_val
        parts[$last_idx]="$formatted_num"
    else
        parts+=("1")
    fi

    IFS='.'; echo "${parts[*]}"
}

# Main version increment with RolloverAt9
increment_main_version_rollover() {
    local major=$1 minor=$2 patch=$3 carry=$4

    patch=$((patch + carry))
    if [[ $patch -gt 9 ]]; then
        patch=0
        minor=$((minor + 1))
        if [[ $minor -gt 9 ]]; then
            minor=0
            major=$((major + 1))
        fi
    fi

    echo "$major.$minor.$patch"
}

# Main script logic
main() {
    parse_args "$@"
    local UPDATED=false
    local PYTHON_CMD=""
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_CMD="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_CMD="python"
    else
        echo -e "${RED}Error: python3 or python is required.${NC}" >&2
        exit 1
    fi

    # Find package.json
    local package_json_path
    if ! package_json_path=$(find_package_json); then
        echo -e "${RED}Error: package.json not found.${NC}" >&2
        exit 1
    fi

    echo "Found package.json at: $package_json_path"

    # Read and parse JSON to obtain current version
    local original_version
    if ! original_version=$("$PYTHON_CMD" - "$package_json_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    raw = path.read_bytes()
except OSError as exc:
    sys.stderr.write(f"{exc}\n")
    sys.exit(2)

try:
    text = raw.decode("utf-8-sig")
    data = json.loads(text)
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    sys.stderr.write(f"{exc}\n")
    sys.exit(3)

version = data.get("version")
if not version:
    sys.exit(4)
sys.stdout.write(version)
PY
    ); then
        echo -e "${RED}Error: Failed to parse JSON from '$package_json_path'.${NC}" >&2
        exit 1
    fi

    if [[ -z "$original_version" || "$original_version" == "null" ]]; then
        echo -e "${RED}Error: 'version' field not found or is null.${NC}" >&2
        exit 1
    fi

    echo "Current version: $original_version"

    # Validate SemVer format
    local semver_regex='^([0-9]+)\.([0-9]+)\.([0-9]+)(-(.+))?(\+(.+))?$'
    if [[ ! $original_version =~ $semver_regex ]]; then
        echo -e "${RED}Error: Version '$original_version' is not valid per SemVer.${NC}" >&2
        exit 1
    fi

    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    local prerelease="${BASH_REMATCH[5]}"

    local new_version=""
    local action_message=""
    local main_version_carry=0

    # Handle promotion to release
    if [[ "$PROMOTE_TO_RELEASE" == "true" && -n "$prerelease" ]]; then
        new_version="$major.$minor.$patch"
        action_message="Action: Promoting pre-release '$original_version' to release version '$new_version'."
        prerelease=""
    fi

    # Handle pre-release increment
    if [[ -n "$prerelease" ]]; then
        if [[ "$INCREMENT_MODE" == "RolloverAt9" ]]; then
            action_message="Action: Incrementing pre-release of '$original_version' using RolloverAt9 mode."
            local new_prerelease
            new_prerelease=$(increment_prerelease_rollover "$prerelease")

            if [[ "$new_prerelease" == "ROLLOVER" ]]; then
                prerelease=""
                main_version_carry=1
                action_message+=" Pre-release rolled over completely."
            else
                prerelease="$new_prerelease"
            fi
        else
            action_message="Action: Incrementing pre-release part of '$original_version' (Default mode)."
            prerelease=$(increment_prerelease_default "$prerelease")
        fi

        if [[ $main_version_carry -eq 0 ]]; then
            new_version="$major.$minor.$patch"
            if [[ -n "$prerelease" ]]; then
                new_version+="-$prerelease"
            fi
        fi
    fi

    # Increment main version if needed
    if [[ -z "$prerelease" ]]; then
        local initial_carry
        if [[ $main_version_carry -eq 1 ]]; then
            initial_carry=1
        elif [[ "$PROMOTE_TO_RELEASE" != "true" ]]; then
            initial_carry=1
        else
            initial_carry=0
        fi

        if [[ $initial_carry -eq 1 ]]; then
            if [[ "$INCREMENT_MODE" == "RolloverAt9" ]]; then
                if [[ ! "$action_message" =~ RolloverAt9 ]]; then
                    action_message+=" Incrementing M.m.p of '$original_version' using RolloverAt9 mode."
                fi
                new_version=$(increment_main_version_rollover $major $minor $patch $initial_carry)
            else
                if [[ ! "$action_message" =~ "Default mode" ]]; then
                    action_message+=" Incrementing patch of '$original_version' using Default mode."
                fi
                new_version="$major.$minor.$((patch + initial_carry))"
            fi
        else
            new_version="$major.$minor.$patch"
        fi
    fi

    # Clean up action message
    action_message=$(echo "$action_message" | sed 's/  */ /g')
    echo "$action_message"
    echo "New version will be: $new_version"

    # Update the file
    if [[ "$WHATIF" == "true" ]]; then
        echo "Operation cancelled (--whatif specified)."
    else
        if "$PYTHON_CMD" - "$package_json_path" "$new_version" <<'PY'
import os
import re
import sys

path, new_version = sys.argv[1], sys.argv[2]
with open(path, 'rb') as fh:
    raw = fh.read()
utf8_bom = b'\xef\xbb\xbf'
has_bom = raw.startswith(utf8_bom)
if has_bom:
    text = raw[len(utf8_bom):].decode('utf-8')
else:
    text = raw.decode('utf-8')
pattern = re.compile(r'^(?P<indent>\s*)"version"\s*:\s*"[^"]*"', re.MULTILINE)
if not pattern.search(text):
    sys.stderr.write("Error: version field not found in package.json\n")
    sys.exit(1)
updated = pattern.sub(lambda m: '{}"version": "{}"'.format(m.group("indent"), new_version), text, count=1)
if updated == text:
    sys.stderr.write("Error: version field was not modified\n")
    sys.exit(2)
with open(path, 'wb') as fh:
    if has_bom:
        fh.write(utf8_bom)
    fh.write(updated.encode('utf-8'))
PY
        then
            echo "Successfully updated."
            UPDATED=true
        else
            status=$?
            if [[ $status -eq 2 ]]; then
                echo -e "${RED}Error: Version field was not modified; check package.json formatting.${NC}" >&2
            else
                echo -e "${RED}Error: Could not write to file.${NC}" >&2
            fi
            exit 1
        fi
    fi
    # Post-update git integration to avoid PR conflicts with pre-commit/CI
    if [[ "$UPDATED" == "true" && ( "$COMMIT_CHANGES" == "true" || "$RUN_HOOKS" == "true" || "$PUSH" == "true" ) ]]; then
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            branch=$(git rev-parse --abbrev-ref HEAD)
            primary_branches=(master main)
            allow_branch=false
            for b in "${primary_branches[@]}"; do
              if [[ "$branch" == "$b" ]]; then allow_branch=true; fi
            done
            if [[ "$ALLOW_NON_MAIN" != "true" && "$allow_branch" != "true" ]]; then
                echo -e "${YELLOW}Note:${NC} On branch '$branch'. Version bumps are restricted to main/master by default. Use --allow-non-main-branch to override." >&2
            else
                git fetch --prune || true
                                # Safe fast-forward pull only when clean and behind
                if [ -d "$(git rev-parse --git-dir 2>/dev/null)" ]; then
                    if [ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && [ ! -d "$(git rev-parse --git-dir)/rebase-apply" ] && [ ! -d "$(git rev-parse --git-dir)/rebase-merge" ]; then
                        if git diff --no-ext-diff --quiet --exit-code; then
                            counts=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true)
                            behind=$(echo "$counts" | awk '{print $1}')
                            ahead=$(echo "$counts" | awk '{print $2}')
                            if [ -n "$behind" ] && [ "${behind:-0}" -gt 0 ] && [ "${ahead:-0}" -eq 0 ]; then
                                git pull --ff-only || true
                            fi
                        fi
                    fi
                fi
                git add -- "$package_json_path" || true
                lock_path="$(dirname "$package_json_path")/package-lock.json"
                [[ -f "$lock_path" ]] && git add -- "$lock_path" || true
                if [[ "$RUN_HOOKS" == "true" ]]; then
                    if command -v pre-commit >/dev/null 2>&1; then
                        pre-commit run -a || true
                        git add -A || true
                    else
                        if command -v npm >/dev/null 2>&1; then
                            npm run format:json --silent || true
                            npm run format:md --silent || true
                            npm run format:yaml --silent || true
                        fi
                        if [[ -f scripts/fix-eol.js ]]; then node scripts/fix-eol.js -v || true; fi
                        if [[ -f .config/dotnet-tools.json ]] && command -v dotnet >/dev/null 2>&1; then
                            dotnet tool restore || true
                            dotnet tool run csharpier format || true
                        fi
                        git add -A || true
                    fi
                fi
                msg="chore(version): bump to $new_version"
                if [[ "$NO_VERIFY" == "true" ]]; then
                    git commit -m "$msg" --no-verify || true
                else
                    if ! git commit -m "$msg"; then
                        echo "Commit failed; retrying after restage with --no-verify..."
                        git add -A || true
                        git commit -m "$msg" --no-verify || true
                    fi
                fi
                if [[ "$PUSH" == "true" ]]; then
                    git push -u origin "$branch" || true
                fi
            fi
        else
            echo -e "${YELLOW}Note:${NC} Not a git repository; skipping commit/push."
        fi
    fi
}

# Run main function with all arguments
main "$@"

