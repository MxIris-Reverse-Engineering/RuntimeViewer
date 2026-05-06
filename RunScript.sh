#!/usr/bin/env bash
# RunScript.sh — Build and launch RuntimeViewer with the Debug-arm64e
# configuration via xcodebuild. The Debug-arm64e configuration adds an
# arm64e slice only to the targets that need to inspect arm64e processes
# (RuntimeViewerServer.framework, dev.mxiris.runtimeviewer.service); the
# main app stays arm64-only just like Debug. The Xcode GUI fails to
# compile under iOSPackagesShouldBuildARM64e=true, so xcodebuild from the
# command line is the only working path.
#
# Usage:
#   ./RunScript.sh                          # build + launch
#   ./RunScript.sh --no-launch              # build only
#   ./RunScript.sh --update-packages        # refresh SPM pins first
#   ./RunScript.sh --dry-run                # print commands without running
#   ./RunScript.sh --help
#
# All distribution-related flags (notarize, appcast, GitHub upload, commit)
# are intentionally absent — see ArchiveScript.sh for those.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Defaults
WORKSPACE="RuntimeViewer-Debug.xcworkspace"
SCHEME="RuntimeViewer macOS"
CATALYST_SCHEME="RuntimeViewerCatalystHelper"
CONFIGURATION="Debug-arm64e"
BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"
DERIVED_DATA="$PROJECT_DIR/DerivedData/Debug-arm64e"

UPDATE_PACKAGES=false
LAUNCH=true
DRY_RUN=false

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[RunScript] $*"; }

# Pipe xcodebuild output through xcbeautify when it is installed; otherwise
# fall back to cat so that runs do not depend on the tool.
pretty() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

# Run a command with its stdout+stderr piped through pretty(). The raw
# output is also tee'd to $LOG_DIR so devs can recover the full xcodebuild
# log when xcbeautify drops error lines. `set -o pipefail` ensures a
# failure in the leading command still propagates.
run_piped() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; printf '| tee <log> | pretty\n'
        return 0
    fi
    mkdir -p "$LOG_DIR"
    XCODEBUILD_LOG_INDEX=$((XCODEBUILD_LOG_INDEX + 1))
    local slug="${XCODEBUILD_LOG_NAME:-step}"
    local log_path
    log_path="$LOG_DIR/$(printf '%02d' "$XCODEBUILD_LOG_INDEX")-${slug}.log"
    log "Raw xcodebuild log: $log_path"
    "$@" 2>&1 | tee "$log_path" | pretty
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2;;
        --scheme) SCHEME="$2"; shift 2;;
        --catalyst-helper-scheme) CATALYST_SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --build-number) BUILD_NUMBER="$2"; shift 2;;
        --derived-data) DERIVED_DATA="$2"; shift 2;;
        --update-packages) UPDATE_PACKAGES=true; shift;;
        --no-launch) LAUNCH=false; shift;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# *//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

[[ -d "$WORKSPACE" ]] || fail "workspace not found: $WORKSPACE"

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION build=$BUILD_NUMBER"
log "derived_data=$DERIVED_DATA update_packages=$UPDATE_PACKAGES launch=$LAUNCH"

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs}"
XCODEBUILD_LOG_INDEX=0

mkdir -p "$LOG_DIR"
log "xcodebuild logs: $LOG_DIR"

update_packages() {
    log "Updating Swift package dependencies"
    run swift package update --package-path "$PROJECT_DIR/RuntimeViewerCore"
    run swift package update --package-path "$PROJECT_DIR/RuntimeViewerPackages"

    local workspace_path="$WORKSPACE"
    if [[ "$workspace_path" != /* ]]; then
        workspace_path="$PROJECT_DIR/$workspace_path"
    fi

    local workspace_package_resolved="$workspace_path/xcshareddata/swiftpm/Package.resolved"
    log "Refreshing workspace package pins"
    run rm -f "$workspace_package_resolved"

    XCODEBUILD_LOG_NAME="resolve-catalyst-helper-packages" run_piped xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$CATALYST_SCHEME" \
        -skipPackagePluginValidation -skipMacroValidation

    XCODEBUILD_LOG_NAME="resolve-main-packages" run_piped xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -skipPackagePluginValidation -skipMacroValidation
}

if $UPDATE_PACKAGES; then
    update_packages
fi

log "Building Catalyst helper"
XCODEBUILD_LOG_NAME="build-catalyst-helper" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

log "Building main app"
XCODEBUILD_LOG_NAME="build-main" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_PATH=""
if [[ -d "$PRODUCTS_DIR" ]]; then
    APP_PATH=$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name 'RuntimeViewer*.app' \
        -not -name 'RuntimeViewerCatalystHelper.app' | head -1)
fi
if $DRY_RUN; then
    APP_PATH="${APP_PATH:-<app-path>}"
else
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "expected built *.app under $PRODUCTS_DIR"
fi

if $LAUNCH; then
    log "Launching $APP_PATH"
    run open "$APP_PATH"
else
    log "Launch skipped (--no-launch)"
fi

log "Done. Outputs:"
log "  app:                 $APP_PATH"
log "  derived_data:        $DERIVED_DATA"
