#!/usr/bin/env bash
# LaunchWithXcodeSourceEditorScript.sh — Start a build of RuntimeViewer on Xcode 26.6's own
# SourceEditor frameworks instead of the reconstruction the app carries, to compare the two.
#
# The app links the reconstruction, a rebuild of Xcode 26.6's SourceEditor, SourceModel,
# SourceModelSupport and _CodeCompletionFoundation with the same install names
# (@rpath/<Name>.framework/Versions/A/<Name>). dyld looks for a framework on DYLD_FRAMEWORK_PATH
# before any rpath, so pointing that variable at links to Xcode 26.6's originals makes the same app
# load them instead of the copies in its Contents/Frameworks; nothing in the app changes. The
# links go in a directory of their own because Xcode's SharedFrameworks holds many other frameworks
# that the variable would substitute as well.
#
# Only where dyld takes the variable. RuntimeViewer's builds have the hardened runtime, and Apple
# documents that dyld then reads DYLD_ variables only for an app carrying the
# com.apple.security.cs.allow-dyld-environment-variables entitlement, which none of them does; on a
# Mac with System Integrity Protection off, as both development Macs are, dyld took it from a
# hardened build without that entitlement too (measured 2026-11-06). The script checks which
# frameworks the new instance mapped and quits it when they are not Xcode's. Only Xcode 26.6: the
# reconstruction rebuilds that version, and Xcode 27's frameworks lack symbols the bridge uses.
#
# The new instance runs beside any other: both read the same settings, and the one started last
# takes over the command-line tool's host and the MCP bridge. Settings › Developer shows which
# frameworks an instance runs on.
#
# Usage:
#   ./LaunchWithXcodeSourceEditorScript.sh                        # RunScript.sh's build, the installed Xcode 26.6
#   ./LaunchWithXcodeSourceEditorScript.sh --app <RuntimeViewer.app>
#   ./LaunchWithXcodeSourceEditorScript.sh --xcode /Applications/Xcode-26.6.0.app
#   ./LaunchWithXcodeSourceEditorScript.sh --dry-run              # check everything, launch nothing
#   ./LaunchWithXcodeSourceEditorScript.sh --help
#
# Exit status: 0 once the new instance is running on Xcode's frameworks; 1 otherwise.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_NAMES=(SourceEditor SourceModel SourceModelSupport _CodeCompletionFoundation)
BRIDGE_NAME="RuntimeViewerSourceEditorBridge"
SUPPORTED_XCODE_VERSION_PATTERN='^26\.6(\.[0-9]+)?$'
LAUNCH_TIMEOUT_SECONDS=20

# RunScript.sh's product, the default app.
if [[ -d "/Volumes/DerivedData" ]]; then
    RUN_SCRIPT_PRODUCTS_DIRECTORY="/Volumes/DerivedData/RuntimeViewer/Debug-arm64e/Build/Products/Debug-arm64e"
else
    RUN_SCRIPT_PRODUCTS_DIRECTORY="$SCRIPT_DIRECTORY/DerivedData/Debug-arm64e/Build/Products/Debug-arm64e"
fi

APP_PATH=""
XCODE_PATH=""
DRY_RUN=false

log()  { echo "[LaunchWithXcodeSourceEditor] $*"; }
fail() { echo "error: $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2;;
        --xcode) XCODE_PATH="$2"; shift 2;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

xcode_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true
}

is_supported_xcode() {
    [[ "$(xcode_version "$1")" =~ $SUPPORTED_XCODE_VERSION_PATTERN ]]
}

find_supported_xcode() {
    local candidate
    while IFS= read -r candidate; do
        [[ -d "$candidate" ]] || continue
        if is_supported_xcode "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done < <({ mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true; ls -d /Applications/Xcode*.app 2>/dev/null || true; } | sort -u)
    return 1
}

# The physical path, so that it can be compared with the paths lsof reports.
physical_path() {
    (cd "$1" && pwd -P)
}

# --- The Xcode ---------------------------------------------------------------

if [[ -z "$XCODE_PATH" ]]; then
    XCODE_PATH=$(find_supported_xcode) || fail "no Xcode 26.6 is installed; pass one with --xcode"
fi
[[ -d "$XCODE_PATH" ]] || fail "no Xcode at $XCODE_PATH"
XCODE_PATH=$(physical_path "$XCODE_PATH")
XCODE_VERSION=$(xcode_version "$XCODE_PATH")
is_supported_xcode "$XCODE_PATH" \
    || fail "$XCODE_PATH is Xcode ${XCODE_VERSION:-of an unknown version}; only Xcode 26.6 matches the reconstruction"
SHARED_FRAMEWORKS_DIRECTORY="$XCODE_PATH/Contents/SharedFrameworks"
for framework_name in "${FRAMEWORK_NAMES[@]}"; do
    [[ -f "$SHARED_FRAMEWORKS_DIRECTORY/$framework_name.framework/Versions/A/$framework_name" ]] \
        || fail "$XCODE_PATH has no $framework_name.framework in Contents/SharedFrameworks"
done
log "Xcode $XCODE_VERSION: $XCODE_PATH"

# --- The app -----------------------------------------------------------------

if [[ -z "$APP_PATH" ]]; then
    if [[ -d "$RUN_SCRIPT_PRODUCTS_DIRECTORY" ]]; then
        APP_PATH=$(find "$RUN_SCRIPT_PRODUCTS_DIRECTORY" -maxdepth 1 -type d -name 'RuntimeViewer*.app' \
            -not -name 'RuntimeViewerCatalystHelper.app' | head -1)
    fi
    [[ -n "$APP_PATH" ]] \
        || fail "no build of RunScript.sh under $RUN_SCRIPT_PRODUCTS_DIRECTORY; build one (./RunScript.sh --no-launch) or pass --app"
fi
[[ -d "$APP_PATH" ]] || fail "no app at $APP_PATH"
APP_PATH=$(physical_path "$APP_PATH")
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
    || fail "$APP_PATH has no CFBundleExecutable in its Info.plist"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
log "App: $APP_PATH"

BRIDGE_BINARY="$APP_PATH/Contents/Frameworks/$BRIDGE_NAME.framework/Versions/A/$BRIDGE_NAME"
[[ -f "$BRIDGE_BINARY" ]] || fail "$APP_PATH carries no $BRIDGE_NAME.framework"
otool -arch arm64 -L "$BRIDGE_BINARY" 2>/dev/null | grep -q '/SourceEditor.framework/' \
    || fail "this build links no SourceEditor (built without the reconstruction, or not for arm64), so there is nothing to swap"

# Every symbol the bridge takes from the four frameworks has to be in Xcode's copies, or dyld stops
# the app at launch. Weak references may be missing.
check_symbols() {
    local exported_symbols_file imported_symbols_file missing_symbols framework_name
    exported_symbols_file=$(mktemp)
    imported_symbols_file=$(mktemp)
    for framework_name in "${FRAMEWORK_NAMES[@]}"; do
        nm -arch arm64 -gU "$SHARED_FRAMEWORKS_DIRECTORY/$framework_name.framework/Versions/A/$framework_name" | awk '{ print $NF }'
    done | sort -u > "$exported_symbols_file"
    nm -arch arm64 -um "$BRIDGE_BINARY" \
        | grep -E '\(from (SourceEditor|SourceModel|SourceModelSupport|_CodeCompletionFoundation)\)$' \
        | grep -v ' weak external ' \
        | awk '{ for (field = 1; field <= NF; field++) if ($field == "(from") print $(field - 1) }' \
        | sort -u > "$imported_symbols_file" || true
    missing_symbols=$(comm -23 "$imported_symbols_file" "$exported_symbols_file")
    local imported_count
    imported_count=$(wc -l < "$imported_symbols_file" | tr -d ' ')
    rm -f "$exported_symbols_file" "$imported_symbols_file"
    if [[ -n "$missing_symbols" ]]; then
        echo "$missing_symbols" | sed 's/^/  /' >&2
        fail "Xcode $XCODE_VERSION's frameworks lack the symbols above, which the bridge uses; dyld would stop the app at launch"
    fi
    log "Symbols: all $imported_count the bridge takes from the frameworks are in Xcode's copies"
}
check_symbols

# --- Launch ------------------------------------------------------------------

LINK_DIRECTORY="${TMPDIR:-/tmp}"
LINK_DIRECTORY="${LINK_DIRECTORY%/}/RuntimeViewer-XcodeSourceEditor/$(basename "$XCODE_PATH" .app)"
run rm -rf "$LINK_DIRECTORY"
run mkdir -p "$LINK_DIRECTORY"
for framework_name in "${FRAMEWORK_NAMES[@]}"; do
    run ln -s "$SHARED_FRAMEWORKS_DIRECTORY/$framework_name.framework" "$LINK_DIRECTORY/$framework_name.framework"
done

instance_process_identifiers() {
    ps -axo pid=,command= | awk -v executable="$EXECUTABLE_PATH" 'index($0, executable) { print $1 }' | sort
}

if $DRY_RUN; then
    run open -n --env "DYLD_FRAMEWORK_PATH=$LINK_DIRECTORY" "$APP_PATH"
    log "Dry run: nothing launched"
    exit 0
fi

existing_process_identifiers=$(instance_process_identifiers)
open -n --env "DYLD_FRAMEWORK_PATH=$LINK_DIRECTORY" "$APP_PATH"

# The new instance, and the four frameworks it mapped. dyld maps them before main, so once
# SourceEditor shows up the instance runs on whichever copies it lists.
mapped_framework_binaries() {
    lsof -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' \
        | grep -E '/(SourceEditor|SourceModel|SourceModelSupport|_CodeCompletionFoundation)\.framework/Versions/A/' || true
}

process_identifier=""
mapped_binaries=""
for (( attempt = 0; attempt < LAUNCH_TIMEOUT_SECONDS * 2; attempt++ )); do
    if [[ -z "$process_identifier" ]]; then
        process_identifier=$(comm -13 <(echo "$existing_process_identifiers") <(instance_process_identifiers) | head -1)
    fi
    if [[ -n "$process_identifier" ]]; then
        mapped_binaries=$(mapped_framework_binaries "$process_identifier")
        [[ "$mapped_binaries" == *"/SourceEditor.framework/Versions/A/SourceEditor"* ]] && break
    fi
    sleep 0.5
done
[[ -n "$process_identifier" ]] || fail "the new instance did not show up within $LAUNCH_TIMEOUT_SECONDS seconds"
[[ "$mapped_binaries" == *"/SourceEditor.framework/Versions/A/SourceEditor"* ]] \
    || fail "instance $process_identifier mapped no SourceEditor within $LAUNCH_TIMEOUT_SECONDS seconds; it is still running"

reconstruction_binaries=$(echo "$mapped_binaries" | grep -v "^$SHARED_FRAMEWORKS_DIRECTORY/" || true)
if [[ -n "$reconstruction_binaries" ]]; then
    kill "$process_identifier" 2>/dev/null || true
    echo "$reconstruction_binaries" | sed 's/^/  /' >&2
    fail "instance $process_identifier mapped the copies above, not Xcode's, so it was quit: dyld did not take DYLD_FRAMEWORK_PATH. With System Integrity Protection on, a hardened app takes it only with the com.apple.security.cs.allow-dyld-environment-variables entitlement"
fi
log "Running: instance $process_identifier on Xcode $XCODE_VERSION's frameworks:"
echo "$mapped_binaries" | sed 's/^/  /'
