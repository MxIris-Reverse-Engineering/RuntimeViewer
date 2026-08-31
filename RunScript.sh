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
#   ./RunScript.sh --local-deps             # build against local dependency checkouts
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
MOBILE_SERVER_SCHEME="RuntimeViewerMobileServer"
CONFIGURATION="Debug-arm64e"
BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"

# Where the app's "Embed RuntimeViewerMobileServer Framework" copy phase expects
# the iOS Simulator payload. A fixed path inside the project rather than one
# under DerivedData, because the phase is a plain file reference — the same
# arrangement that carries the Catalyst helper, and the reason neither needs a
# shell script.
MOBILE_SERVER_STAGED_PATH="$PROJECT_DIR/RuntimeViewerUsingAppKit/RuntimeViewerMobileServer.framework"

# DerivedData prefers the dedicated /Volumes/DerivedData cache volume so the
# SwiftPM checkouts under DerivedData/SourcePackages stay OUT of the project
# tree (otherwise git clients like Fork index them). Falls back to a
# project-relative path when the volume is absent (e.g. CI). Override with
# --derived-data.
if [[ -d "/Volumes/DerivedData" ]]; then
    DERIVED_DATA="/Volumes/DerivedData/RuntimeViewer/Debug-arm64e"
else
    DERIVED_DATA="$PROJECT_DIR/DerivedData/Debug-arm64e"
fi

UPDATE_PACKAGES=false
LAUNCH=true
DRY_RUN=false
LOCAL_DEPENDENCIES=false

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
        --mobile-server-scheme) MOBILE_SERVER_SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --build-number) BUILD_NUMBER="$2"; shift 2;;
        --derived-data) DERIVED_DATA="$2"; shift 2;;
        --update-packages) UPDATE_PACKAGES=true; shift;;
        --no-launch) LAUNCH=false; shift;;
        --dry-run) DRY_RUN=true; shift;;
        --local-deps) LOCAL_DEPENDENCIES=true; shift;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# *//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

[[ -d "$WORKSPACE" ]] || fail "workspace not found: $WORKSPACE"

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION build=$BUILD_NUMBER"
log "derived_data=$DERIVED_DATA update_packages=$UPDATE_PACKAGES launch=$LAUNCH"

# Build against the local sibling checkouts of the dependency repos rather
# than the pinned remote versions. Needed whenever a change under test lives
# in one of those repos and has not been tagged yet — MachInjector reached
# through swift-helper-service is the usual case. Without it the build
# silently uses the remote pin, and the symptom is "I changed it and nothing
# happened", which is hard to self-diagnose.
if $LOCAL_DEPENDENCIES; then
    export USING_LOCAL_DEPENDENCIES=1
    log "Using local dependency checkouts (USING_LOCAL_DEPENDENCIES=1)"
fi

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs}"
XCODEBUILD_LOG_INDEX=0

mkdir -p "$LOG_DIR"
log "xcodebuild logs: $LOG_DIR"

# Update package pins through the workspace ONLY. Do not run
# `swift package update` on RuntimeViewerCore / RuntimeViewerPackages
# individually: the workspace unifies swift-syntax via the local
# RuntimeViewerPrecompiledLibraries/swift-syntax checkout, so resolving each
# package standalone picks incompatible upstream constraints (e.g. SwiftMCP
# wants 602.x while RxSwiftPlus wants 601.x) and writes per-package
# Package.resolved files that the workspace build never reads.
#
# Deleting the workspace's Package.resolved before -resolvePackageDependencies
# is what turns "resolve" into a real update: SPM then picks the newest
# versions matching the workspace constraints instead of replaying the old
# pins. BuildRuntimeViewerServerXCFramework.sh does the same thing.
update_packages() {
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
        -derivedDataPath "$DERIVED_DATA" \
        -skipPackagePluginValidation -skipMacroValidation

    XCODEBUILD_LOG_NAME="resolve-main-packages" run_piped xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" \
        -skipPackagePluginValidation -skipMacroValidation
}

if $UPDATE_PACKAGES; then
    update_packages
fi

GIT_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
GIT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || true)"
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
[[ -n "$GIT_COMMIT" ]] || GIT_COMMIT="unknown"
[[ -n "$GIT_BRANCH" ]] || GIT_BRANCH="unknown"
if [[ "$GIT_COMMIT" != "unknown" ]] && [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    GIT_COMMIT="${GIT_COMMIT}-dirty"
fi

COMMON_XCODEBUILD_SETTINGS=(
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
    "RUNTIME_VIEWER_BUILD_DATE=$BUILD_DATE"
    "RUNTIME_VIEWER_GIT_BRANCH=$GIT_BRANCH"
    "RUNTIME_VIEWER_GIT_COMMIT=$GIT_COMMIT"

    # Debug-arm64e exists to debug on this machine and to inspect arm64e
    # processes, so the Intel slice is dead weight here. It is also broken
    # weight: AppKitPlus ships as a prebuilt XCFramework whose macOS slice
    # covers arm64 and arm64e only, so compiling the x86_64 variant of any
    # package that imports it dies in AppKitPlus-Swift.h with "unsupported
    # Swift architecture".
    #
    # This must be a command-line setting rather than a line in
    # Configurations/RuntimeViewerUsingAppKit/Debug-arm64e.xcconfig: that
    # xcconfig is the base configuration of the app target alone, and the
    # targets that fail are the SwiftPM ones. Command-line settings reach
    # every target.
    #
    # EXCLUDED_ARCHS subtracts a slice instead of dictating the list, which
    # leaves both sources of arm64e untouched — iOSPackagesShouldBuildARM64e
    # in RuntimeViewer-Debug.xcworkspace for the SwiftPM targets, and the
    # service target's own settings for the daemon. Overwriting ARCHS here
    # would drop arm64e on the floor, and so would narrowing -destination
    # away from 'generic/platform=macOS'.
    "EXCLUDED_ARCHS=x86_64"
)

log "build_metadata commit=$GIT_COMMIT branch=$GIT_BRANCH date=$BUILD_DATE"

log "Building Catalyst helper"
XCODEBUILD_LOG_NAME="build-catalyst-helper" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "${COMMON_XCODEBUILD_SETTINGS[@]}"

# The iOS Simulator injection payload, built before the app and staged at
# $MOBILE_SERVER_STAGED_PATH — the fixed path referenced by the app's "Embed
# RuntimeViewerMobileServer Framework" copy phase, the same arrangement the
# Catalyst helper uses. It is
# deliberately not a target dependency: Xcode rejects iOS-family embedded
# content from a macOS app target, which is what keeps the helper out too.
#
# A failure here is not fatal: the app builds and runs, and only injecting into
# simulator processes is unavailable.
log "Building iOS Simulator injection payload"
SIMULATOR_PAYLOAD_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/RuntimeViewerServer.framework"
if XCODEBUILD_LOG_NAME="build-simulator-payload" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$MOBILE_SERVER_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "${COMMON_XCODEBUILD_SETTINGS[@]}"; then
    run rm -rf "$MOBILE_SERVER_STAGED_PATH"
    run ditto "$SIMULATOR_PAYLOAD_PATH" "$MOBILE_SERVER_STAGED_PATH"
else
    log "warning: iOS Simulator payload failed to build; simulator injection will be unavailable in this build"
    # Clear the staged copy rather than leaving the last good one there. The
    # copy phase has no way to tell a current payload from a stale one, so
    # without this the app would embed — and inject — a build that this run
    # just failed to produce, with only the warning above to say otherwise.
    run rm -rf "$MOBILE_SERVER_STAGED_PATH"
fi

log "Building main app"
XCODEBUILD_LOG_NAME="build-main" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation -skipMacroValidation \
    "${COMMON_XCODEBUILD_SETTINGS[@]}"

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
