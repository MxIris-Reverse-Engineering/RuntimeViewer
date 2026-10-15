#!/usr/bin/env bash
# UpdatePackagesScript.sh — Update the Swift package pins of the three
# workspaces (RuntimeViewer, RuntimeViewer-Debug, RuntimeViewer-Distribution)
# to the newest versions their manifests allow.
#
# It does what Xcode's File > Packages > Update to Latest Package Versions
# should do. Under Xcode 27 that command often does nothing or fails: Xcode
# resolves from its local git mirrors of the packages without fetching them,
# so a release it has not seen does not exist for it. Here every mirror is
# fetched first, each workspace's Package.resolved is dropped together with
# the resolution state that would replay the old pins, and xcodebuild
# resolves afresh in a DerivedData of this script's own. Xcode may stay open:
# it resolves to the new Package.resolved from the mirrors fetched here.
#
# After the Debug workspace, it updates Tuist/Package.resolved, the lock file of
# the development-only Tuist workspace (TuistScript.sh): seeded from the Debug
# workspace's, resolved with `./TuistScript.sh install`, and compared with it.
#
# Usage:
#   ./UpdatePackagesScript.sh                        # all three workspaces
#   ./UpdatePackagesScript.sh --workspace Debug      # one workspace; repeatable
#                                                    # (RuntimeViewer, Debug, Distribution)
#   ./UpdatePackagesScript.sh --skip-fetch           # do not fetch the package mirrors first
#   ./UpdatePackagesScript.sh --clean                # resolve from empty checkouts (slow)
#   ./UpdatePackagesScript.sh --derived-data <dir>   # resolve under <dir>
#   ./UpdatePackagesScript.sh --dry-run              # print what would run
#   ./UpdatePackagesScript.sh --help
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

ALL_WORKSPACES=("RuntimeViewer" "RuntimeViewer-Debug" "RuntimeViewer-Distribution")

# Resolved with both schemes, helper first, the way RunScript.sh and
# ArchiveScript.sh refresh their pins.
RESOLVE_SCHEMES=("RuntimeViewerCatalystHelper" "RuntimeViewer macOS")

# A DerivedData of this script's own, so that resolving never touches the one
# an open Xcode is using. The three workspaces share its SourcePackages; each
# resolution starts by dropping the previous one's state, so what one leaves
# behind never decides another's pins. Same volume preference as RunScript.sh.
if [[ -d "/Volumes/DerivedData" ]]; then
    DERIVED_DATA_ROOT="/Volumes/DerivedData/RuntimeViewer/PackageUpdate"
    # RunScript.sh's and ArchiveScript.sh's DerivedData. Their mirrors are
    # fetched too, so that their next build finds the new pins locally.
    SCRIPT_DERIVED_DATA_DIRECTORIES=("/Volumes/DerivedData/RuntimeViewer/Debug-arm64e" "/Volumes/DerivedData/RuntimeViewer/Archive")
else
    DERIVED_DATA_ROOT="$PROJECT_DIR/DerivedData/PackageUpdate"
    SCRIPT_DERIVED_DATA_DIRECTORIES=("$PROJECT_DIR/DerivedData/Debug-arm64e" "$PROJECT_DIR/DerivedData")
fi

SWIFTPM_REPOSITORY_CACHE="$HOME/Library/Caches/org.swift.swiftpm/repositories"
FETCH_JOB_COUNT=8
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs/UpdatePackages}"

SELECTED_WORKSPACES=()
FETCH_MIRRORS=true
CLEAN=false
DRY_RUN=false

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[UpdatePackagesScript] $*"; }
warn() { echo "[UpdatePackagesScript] warning: $*" >&2; }

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            [[ $# -ge 2 ]] || fail "--workspace needs a name"
            workspace_argument="${2%/}"
            case "$(printf '%s' "${workspace_argument%.xcworkspace}" | tr '[:upper:]' '[:lower:]')" in
                runtimeviewer) SELECTED_WORKSPACES+=("RuntimeViewer");;
                debug|runtimeviewer-debug) SELECTED_WORKSPACES+=("RuntimeViewer-Debug");;
                distribution|runtimeviewer-distribution) SELECTED_WORKSPACES+=("RuntimeViewer-Distribution");;
                *) fail "unknown workspace: $2 (expected RuntimeViewer, Debug or Distribution)";;
            esac
            shift 2;;
        --skip-fetch) FETCH_MIRRORS=false; shift;;
        --clean) CLEAN=true; shift;;
        --derived-data)
            [[ $# -ge 2 ]] || fail "--derived-data needs a directory"
            DERIVED_DATA_ROOT="$2"; shift 2;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

if [[ ${#SELECTED_WORKSPACES[@]} -eq 0 ]]; then
    SELECTED_WORKSPACES=("${ALL_WORKSPACES[@]}")
fi
SOURCE_PACKAGES="$DERIVED_DATA_ROOT/SourcePackages"

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found (it compares the old and new pins)"
for workspace_name in "${SELECTED_WORKSPACES[@]}"; do
    [[ -d "$PROJECT_DIR/$workspace_name.xcworkspace" ]] || fail "workspace not found: $workspace_name.xcworkspace"
done

# Package.resolved records remote pins. With local checkouts switched on, the
# manifests hand SwiftPM those checkouts instead and their pins drop out.
if [[ -n "${USING_LOCAL_DEPENDENCIES:-}" ]]; then
    warn "ignoring USING_LOCAL_DEPENDENCIES=$USING_LOCAL_DEPENDENCIES: Package.resolved records the remote pins"
    unset USING_LOCAL_DEPENDENCIES
fi

log "xcodebuild: $(xcodebuild -version | tr '\n' ' ')(${DEVELOPER_DIR:-$(xcode-select -p)})"
log "workspaces: ${SELECTED_WORKSPACES[*]}"
log "derived_data=$DERIVED_DATA_ROOT fetch=$FETCH_MIRRORS clean=$CLEAN"

# Backups of the Package.resolved files being replaced, and the workspace
# whose resolution is under way: an interrupted or failed resolution puts its
# previous Package.resolved back instead of leaving the workspace without one.
WORK_DIRECTORY="$(mktemp -d -t UpdatePackagesScript)"
WORKSPACE_IN_PROGRESS=""

package_resolved_path() { echo "$PROJECT_DIR/$1.xcworkspace/xcshareddata/swiftpm/Package.resolved"; }
backup_path() { echo "$WORK_DIRECTORY/$1.Package.resolved"; }

restore_package_resolved() {
    local workspace_name="$1"
    local backup
    backup="$(backup_path "$workspace_name")"
    if [[ -f "$backup" ]]; then
        cp "$backup" "$(package_resolved_path "$workspace_name")"
        log "$workspace_name: put the previous Package.resolved back"
    fi
}

cleanup() {
    if [[ -n "$WORKSPACE_IN_PROGRESS" ]]; then
        restore_package_resolved "$WORKSPACE_IN_PROGRESS"
    fi
    rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# DerivedData folders Xcode created for this checkout's workspaces, found by
# the workspace path Xcode records in each folder's info.plist.
xcode_derived_data_directories() {
    local derived_data_root info_plist workspace_path workspace_name
    derived_data_root="$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)"
    derived_data_root="${derived_data_root:-$HOME/Library/Developer/Xcode/DerivedData}"
    for info_plist in "${derived_data_root%/}"/*/info.plist; do
        [[ -f "$info_plist" ]] || continue
        workspace_path="$(plutil -extract WorkspacePath raw -o - "$info_plist" 2>/dev/null)" || continue
        for workspace_name in "${ALL_WORKSPACES[@]}"; do
            if [[ "$workspace_path" == "$PROJECT_DIR/$workspace_name.xcworkspace" ]]; then
                dirname "$info_plist"
            fi
        done
    done
}

# Every git mirror a resolution of these workspaces reads from, NUL-separated.
# SwiftPM keeps one per package in its global cache, which a new SourcePackages
# starts as a copy of, and one in every SourcePackages.
collect_mirror_directories() {
    local repositories_directories=("$SWIFTPM_REPOSITORY_CACHE" "$SOURCE_PACKAGES/repositories")
    local derived_data_directory repositories_directory mirror_directory
    for derived_data_directory in "${SCRIPT_DERIVED_DATA_DIRECTORIES[@]}"; do
        repositories_directories+=("$derived_data_directory/SourcePackages/repositories")
    done
    while IFS= read -r derived_data_directory; do
        repositories_directories+=("$derived_data_directory/SourcePackages/repositories")
    done < <(xcode_derived_data_directories)

    for repositories_directory in "${repositories_directories[@]}"; do
        [[ -d "$repositories_directory" ]] || continue
        for mirror_directory in "$repositories_directory"/*/; do
            if [[ -f "${mirror_directory}HEAD" ]]; then
                printf '%s\0' "${mirror_directory%/}"
            fi
        done
    done
}

fetch_mirrors() {
    local mirror_list="$WORK_DIRECTORY/mirrors"
    local failure_list="$WORK_DIRECTORY/mirror-failures"
    local mirror_count
    # Deduplicated: two fetches into one mirror at once fail on its ref locks.
    collect_mirror_directories | sort -zu > "$mirror_list"
    mirror_count="$(tr -cd '\000' < "$mirror_list" | wc -c | tr -d ' ')"
    if $DRY_RUN; then
        log "would fetch $mirror_count package mirrors"
        return 0
    fi
    if [[ "$mirror_count" -eq 0 ]]; then
        log "no package mirrors to fetch yet"
        return 0
    fi
    log "Fetching $mirror_count package mirrors, $FETCH_JOB_COUNT at a time"
    # GIT_TERMINAL_PROMPT=0: a mirror whose remote asks for credentials fails
    # at once instead of waiting for input that never comes.
    GIT_TERMINAL_PROMPT=0 xargs -0 -n 1 -P "$FETCH_JOB_COUNT" \
        sh -c 'git -C "$1" fetch --quiet --prune --tags >/dev/null 2>&1 || printf "%s\n" "$1"' fetch-mirror \
        < "$mirror_list" > "$failure_list"
    if [[ -s "$failure_list" ]]; then
        warn "could not fetch $(wc -l < "$failure_list" | tr -d ' ') mirrors; the resolution may miss their newest versions:"
        sed 's/^/    /' "$failure_list" >&2
    fi
}

resolve_with_scheme() {
    local workspace_name="$1" scheme="$2" log_path="$3"
    local command=(xcodebuild -resolvePackageDependencies
        -workspace "$PROJECT_DIR/$workspace_name.xcworkspace"
        -scheme "$scheme"
        -derivedDataPath "$DERIVED_DATA_ROOT/$workspace_name"
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
        -skipPackagePluginValidation -skipMacroValidation)
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "${command[@]}"; printf '> %q\n' "$log_path"
        return 0
    fi
    log "  resolving with scheme \"$scheme\" (log: $log_path)"
    # The raw output goes to the log; only the per-package progress lines and
    # errors are echoed. The verdict is xcodebuild's own exit code.
    "${command[@]}" 2>&1 | tee "$log_path" \
        | grep --line-buffered -E '^(Fetching|Cloning|Checking out|Creating working copy)|error:' \
        | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
}

explain_failure() {
    local log_path="$1"
    warn "resolution failed; full log: $log_path"
    grep -E 'error:' "$log_path" | head -5 | sed 's/^/    /' >&2 || true
    if grep -q 'does not match previously recorded value' "$log_path"; then
        warn "a package moved one of its tags to another commit, and SwiftPM refuses the move. If you trust it, delete that package's record under ~/Library/org.swift.swiftpm/security/fingerprints and run again."
    elif grep -qE "is not declared by package|cannot be accessed|doesn't exist in file system" "$log_path"; then
        warn "leftover checkouts may be out of step with the manifests; run again with --clean."
    fi
}

report_pin_changes() {
    local workspace_name="$1" old_file="$2" new_file="$3"
    if [[ ! -f "$new_file" ]]; then
        warn "$workspace_name: xcodebuild succeeded but wrote no Package.resolved"
        return 0
    fi
    python3 - "$workspace_name" "$old_file" "$new_file" <<'PYTHON'
import json
import sys

def read_pins(path):
    try:
        with open(path) as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return {}
    pins = document.get("pins") or document.get("object", {}).get("pins", [])
    described = {}
    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "").lower()
        state = pin.get("state", {})
        revision = state.get("revision", "")[:8]
        if state.get("version"):
            described[identity] = state["version"]
        elif state.get("branch"):
            described[identity] = f"{state['branch']}@{revision}"
        else:
            described[identity] = revision
    return described

workspace_name, old_path, new_path = sys.argv[1:4]
old_pins, new_pins = read_pins(old_path), read_pins(new_path)
changed = [
    (identity, old_pins[identity], new_pins[identity])
    for identity in sorted(old_pins.keys() & new_pins.keys())
    if old_pins[identity] != new_pins[identity]
]
added = sorted(new_pins.keys() - old_pins.keys())
removed = sorted(old_pins.keys() - new_pins.keys())
print(f"[UpdatePackagesScript] {workspace_name}: {len(new_pins)} pins; "
      f"{len(changed)} changed, {len(added)} added, {len(removed)} removed")
for identity, old_version, new_version in changed:
    print(f"    {identity}: {old_version} -> {new_version}")
for identity in added:
    print(f"    + {identity} {new_pins[identity]}")
for identity in removed:
    print(f"    - {identity} (was {old_pins[identity]})")
PYTHON
}

update_workspace() {
    local workspace_name="$1"
    local package_resolved backup scheme log_path
    package_resolved="$(package_resolved_path "$workspace_name")"
    backup="$(backup_path "$workspace_name")"

    log "$workspace_name.xcworkspace"
    if ! $DRY_RUN; then
        if [[ -f "$package_resolved" ]]; then
            cp "$package_resolved" "$backup"
        fi
        mkdir -p "$LOG_DIR"
        WORKSPACE_IN_PROGRESS="$workspace_name"
    fi
    # Without its Package.resolved SwiftPM still replays the pins recorded in
    # workspace-state.json, so both have to go for the resolution to update.
    run rm -f "$package_resolved" "$SOURCE_PACKAGES/workspace-state.json"

    for scheme in "${RESOLVE_SCHEMES[@]}"; do
        log_path="$LOG_DIR/$workspace_name-$(printf '%s' "$scheme" | tr ' ' '-').log"
        if ! resolve_with_scheme "$workspace_name" "$scheme" "$log_path"; then
            WORKSPACE_IN_PROGRESS=""
            restore_package_resolved "$workspace_name"
            explain_failure "$log_path"
            return 1
        fi
    done
    WORKSPACE_IN_PROGRESS=""
    if ! $DRY_RUN; then
        report_pin_changes "$workspace_name" "$backup" "$package_resolved"
    fi
}

if $CLEAN; then
    log "Removing $SOURCE_PACKAGES (--clean)"
    run rm -rf "$SOURCE_PACKAGES"
fi

if $FETCH_MIRRORS; then
    fetch_mirrors
else
    log "Skipping the mirror fetch (--skip-fetch)"
fi

failed_workspaces=()
for workspace_name in "${SELECTED_WORKSPACES[@]}"; do
    if ! update_workspace "$workspace_name"; then
        failed_workspaces+=("$workspace_name")
    fi
done

# Tuist/Package.resolved has to pin what the native lock files pin. It starts as
# a copy of the Debug workspace's, so the pins are right even when Tuist cannot
# run here (Xcode's command plugin may not see mise); `tuist install` then
# checks that Tuist resolves the same, with this script's Xcode, and records the
# hash of Tuist/Package.swift.
update_tuist_lock_file() {
    local debug_package_resolved
    debug_package_resolved="$(package_resolved_path "RuntimeViewer-Debug")"
    log "Tuist/Package.resolved"
    run cp "$debug_package_resolved" "$PROJECT_DIR/Tuist/Package.resolved"
    if $DRY_RUN; then
        run "$PROJECT_DIR/TuistScript.sh" install
        return 0
    fi
    if ! "$PROJECT_DIR/TuistScript.sh" install 2>&1 | sed 's/^/    /'; then
        warn "\`./TuistScript.sh install\` failed; Tuist/Package.resolved holds the Debug workspace's pins. Run it again where Tuist is installed."
    fi
}

tuist_lock_file_updated=false
for workspace_name in "${SELECTED_WORKSPACES[@]}"; do
    if [[ "$workspace_name" == "RuntimeViewer-Debug" ]] && [[ -f "$PROJECT_DIR/Tuist/Package.swift" ]]; then
        if [[ " ${failed_workspaces[*]:-} " == *" RuntimeViewer-Debug "* ]]; then
            warn "Tuist/Package.resolved not updated: the Debug workspace's resolution failed"
        else
            update_tuist_lock_file
            tuist_lock_file_updated=true
        fi
    fi
done

if ! $DRY_RUN && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    changed_tracked_files=()
    candidate_paths=()
    for workspace_name in "${SELECTED_WORKSPACES[@]}"; do
        candidate_paths+=("$workspace_name.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    done
    if $tuist_lock_file_updated; then
        candidate_paths+=("Tuist/Package.resolved")
    fi
    for relative_path in "${candidate_paths[@]}"; do
        if git ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 \
            && ! git diff --quiet -- "$relative_path"; then
            changed_tracked_files+=("$relative_path")
        fi
    done
    if [[ ${#changed_tracked_files[@]} -gt 0 ]]; then
        log "Changed Package.resolved files under version control; review and commit them:"
        printf '    %s\n' "${changed_tracked_files[@]}"
    fi
fi

if [[ ${#failed_workspaces[@]} -gt 0 ]]; then
    fail "resolution failed for ${failed_workspaces[*]}; their previous Package.resolved is back in place"
fi
log "Done. If Xcode keeps showing the old versions, close the workspace and open it again."
