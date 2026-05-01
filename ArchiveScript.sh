#!/usr/bin/env bash
# ArchiveScript.sh — Archive, notarize, sign, and (optionally) publish a
# RuntimeViewer release. Used by both local developers and CI.
#
# Usage:
#   ./ArchiveScript.sh --version-tag vX.Y.Z \
#                      [--configuration Release|Debug] \
#                      [--release-notes Changelogs/vX.Y.Z.md] \
#                      [--update-packages] \
#                      [--update-appcast] [--upload-to-github] [--commit-push]
#   ./ArchiveScript.sh --help
#
# Run without --update-appcast / --upload-to-github / --commit-push for a
# local build that only produces the signed, notarized zip. The default
# configuration is Release; pass --configuration Debug (or any other
# configuration name defined in the workspace) for local validation. Pass
# --update-packages to refresh SwiftPM pins before archiving.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Defaults
WORKSPACE="RuntimeViewer-Distribution.xcworkspace"
SCHEME="RuntimeViewer macOS"
CATALYST_SCHEME="RuntimeViewerCatalystHelper"
CONFIGURATION="Release"
BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"

VERSION_TAG=""
CHANNEL=""
RELEASE_NOTES=""
ED_KEY_FILE=""
UPDATE_PACKAGES=false
UPDATE_APPCAST=false
UPLOAD_TO_GITHUB=false
COMMIT_PUSH=false
INCLUDE_IOS_SIMULATOR=false
SKIP_NOTARIZATION=false
SKIP_OPEN_FINDER=false
KEEP_INTERMEDIATE=false
DRY_RUN=false

NOTARY_PROFILE="notarytool-password"
NOTARY_API_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER_ID=""

FEED_PAGES_URL="https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml"
DOWNLOAD_URL_PREFIX_BASE="https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/download"
RELEASE_NOTES_URL_PREFIX="https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/tag/"

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[ArchiveScript] $*"; }

# Pipe xcodebuild output through xcbeautify when it is installed; otherwise
# fall back to cat so that neither CI nor local runs depend on the tool.
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
# (un-pretty-printed) output is also tee'd to $LOG_DIR so CI/devs can
# recover the full xcodebuild log when xcbeautify drops error lines.
# `set -o pipefail` ensures a failure in the leading command still propagates.
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
        --version-tag) VERSION_TAG="$2"; shift 2;;
        --channel) CHANNEL="$2"; shift 2;;
        --release-notes) RELEASE_NOTES="$2"; shift 2;;
        --ed-key-file) ED_KEY_FILE="$2"; shift 2;;
        --update-packages) UPDATE_PACKAGES=true; shift;;
        --update-appcast) UPDATE_APPCAST=true; shift;;
        --upload-to-github) UPLOAD_TO_GITHUB=true; shift;;
        --commit-push) COMMIT_PUSH=true; shift;;
        --include-ios-simulator) INCLUDE_IOS_SIMULATOR=true; shift;;
        --skip-notarization) SKIP_NOTARIZATION=true; shift;;
        --skip-open-finder) SKIP_OPEN_FINDER=true; shift;;
        --keep-intermediate) KEEP_INTERMEDIATE=true; shift;;
        --dry-run) DRY_RUN=true; shift;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2;;
        --notary-api-key) NOTARY_API_KEY="$2"; shift 2;;
        --notary-key-id) NOTARY_KEY_ID="$2"; shift 2;;
        --notary-issuer-id) NOTARY_ISSUER_ID="$2"; shift 2;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# *//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

if $UPLOAD_TO_GITHUB || $UPDATE_APPCAST || $COMMIT_PUSH; then
    [[ -z "$VERSION_TAG" ]] && fail "--version-tag required when --upload-to-github / --update-appcast / --commit-push is set"
fi

if [[ -z "$CHANNEL" && -n "$VERSION_TAG" ]]; then
    case "$VERSION_TAG" in
        *-RC*|*-beta*|*-alpha*) CHANNEL="beta";;
        v[0-9]*) CHANNEL="stable";;
        *) fail "cannot infer channel from tag '$VERSION_TAG'; pass --channel explicitly";;
    esac
fi

if ! $SKIP_NOTARIZATION; then
    if [[ -n "$NOTARY_API_KEY" ]]; then
        [[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] \
            || fail "--notary-api-key requires --notary-key-id and --notary-issuer-id"
    fi
fi

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION build=$BUILD_NUMBER"
log "version_tag=${VERSION_TAG:-<none>} channel=${CHANNEL:-<none>}"
log "update_packages=$UPDATE_PACKAGES update_appcast=$UPDATE_APPCAST upload_to_github=$UPLOAD_TO_GITHUB commit_push=$COMMIT_PUSH"

BUILD_PATH="$PROJECT_DIR/Products/Archives"
EXPORT_PATH="$BUILD_PATH/Products/Export"
CATALYST_EXPORT_PATH="$PROJECT_DIR/RuntimeViewerUsingAppKit"
CATALYST_HELPER_ARCHIVE="$BUILD_PATH/RuntimeViewerCatalystHelper.xcarchive"
MAIN_ARCHIVE="$BUILD_PATH/RuntimeViewer.xcarchive"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs}"
XCODEBUILD_LOG_INDEX=0

mkdir -p "$BUILD_PATH" "$LOG_DIR"

# Snapshot any xcdistributionlogs bundles (from exportArchive) into $LOG_DIR
# on exit so CI can upload them as artifacts when a run fails.
collect_xcdistributionlogs() {
    local tmp="${TMPDIR:-/tmp}"
    local dest="$LOG_DIR/xcdistributionlogs"
    local any=0
    while IFS= read -r -d '' bundle; do
        any=1
        mkdir -p "$dest"
        cp -R "$bundle" "$dest/" 2>/dev/null || true
    done < <(find "$tmp" -maxdepth 2 -type d -name '*.xcdistributionlogs' -print0 2>/dev/null)
    if [[ $any -eq 1 ]]; then
        log "Collected xcdistributionlogs into $dest"
    fi
}
trap collect_xcdistributionlogs EXIT

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

log "Archiving Catalyst helper"
XCODEBUILD_LOG_NAME="archive-catalyst-helper" run_piped xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

run rm -rf "$CATALYST_EXPORT_PATH/RuntimeViewerCatalystHelper.app"
XCODEBUILD_LOG_NAME="export-catalyst-helper" run_piped xcodebuild -exportArchive \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$CATALYST_EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig-Catalyst.plist"
run rm -f "$CATALYST_EXPORT_PATH/Packaging.log" \
        "$CATALYST_EXPORT_PATH/DistributionSummary.plist" \
        "$CATALYST_EXPORT_PATH/ExportOptions.plist"

log "Archiving main app"
XCODEBUILD_LOG_NAME="archive-main" run_piped xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$MAIN_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

run rm -rf "$EXPORT_PATH"
XCODEBUILD_LOG_NAME="export-main" run_piped xcodebuild -exportArchive \
    -archivePath "$MAIN_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig.plist"

APP_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -type d -name '*.app' | head -1)
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "expected exported *.app under $EXPORT_PATH"

if ! $SKIP_NOTARIZATION; then
    log "Notarizing"
    NOTARIZE_ZIP="$EXPORT_PATH/RuntimeViewer-notarize.zip"
    run /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    if [[ -n "$NOTARY_API_KEY" ]]; then
        run xcrun notarytool submit "$NOTARIZE_ZIP" \
            --key "$NOTARY_API_KEY" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait
    else
        run xcrun notarytool submit "$NOTARIZE_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" --wait
    fi
    run xcrun stapler staple "$APP_PATH"
    run rm -f "$NOTARIZE_ZIP"
fi

IOS_SIM_ZIP=""
if $INCLUDE_IOS_SIMULATOR; then
    log "Building iOS Simulator app"
    DERIVED="$PROJECT_DIR/DerivedData"
    XCODEBUILD_LOG_NAME="build-ios-simulator" run_piped xcodebuild build \
        -workspace "$WORKSPACE" \
        -scheme "RuntimeViewer iOS" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation -skipMacroValidation \
        CODE_SIGNING_ALLOWED=NO

    IOS_APP="$DERIVED/Build/Products/${CONFIGURATION}-iphonesimulator/RuntimeViewer.app"
    IOS_SIM_ZIP="$PROJECT_DIR/RuntimeViewer-iOS-Simulator.zip"
    [[ -d "$IOS_APP" ]] || fail "iOS Simulator app missing at $IOS_APP"
    ( cd "$(dirname "$IOS_APP")" && /usr/bin/ditto -c -k --keepParent "RuntimeViewer.app" "$IOS_SIM_ZIP" )
fi

log "Packaging macOS zip"
MAC_ZIP="$PROJECT_DIR/RuntimeViewer-macOS.zip"
run rm -f "$MAC_ZIP"
run /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$MAC_ZIP"

if $UPDATE_APPCAST; then
    STAGING="$PROJECT_DIR/.release-staging"
    run rm -rf "$STAGING"
    run mkdir -p "$STAGING"
    run cp "$MAC_ZIP" "$STAGING/"

    APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"
    [[ -f "$APPCAST_PATH" ]] || fail "docs/appcast.xml missing; run Task 9 first"

    DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX_BASE}/${VERSION_TAG}/"

    GENERATE_APPCAST_ARGS=(
        "$STAGING"
        -o "$APPCAST_PATH"
        --download-url-prefix "$DOWNLOAD_URL_PREFIX"
        --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX"
    )
    if [[ -n "$ED_KEY_FILE" ]]; then
        GENERATE_APPCAST_ARGS+=(--ed-key-file "$ED_KEY_FILE")
    fi
    if [[ "$CHANNEL" == "beta" ]]; then
        GENERATE_APPCAST_ARGS+=(--channel beta)
    fi

    log "Running generate_appcast"
    run generate_appcast "${GENERATE_APPCAST_ARGS[@]}"

    if ! $KEEP_INTERMEDIATE; then
        run rm -rf "$STAGING"
    fi
fi

if $UPLOAD_TO_GITHUB; then
    log "Uploading GitHub Release"
    GH_ARGS=(release create "$VERSION_TAG" \
        --title "RuntimeViewer $VERSION_TAG")
    [[ "$CHANNEL" == "beta" ]] && GH_ARGS+=(--prerelease)
    if [[ -n "$RELEASE_NOTES" && -f "$RELEASE_NOTES" ]]; then
        GH_ARGS+=(--notes-file "$RELEASE_NOTES")
    else
        GH_ARGS+=(--generate-notes)
    fi
    GH_ARGS+=("$MAC_ZIP")
    [[ -n "$IOS_SIM_ZIP" ]] && GH_ARGS+=("$IOS_SIM_ZIP")

    if ! $DRY_RUN && gh release view "$VERSION_TAG" >/dev/null 2>&1; then
        log "Release $VERSION_TAG exists; uploading assets with --clobber"
        ASSETS=("$MAC_ZIP")
        [[ -n "$IOS_SIM_ZIP" ]] && ASSETS+=("$IOS_SIM_ZIP")
        run gh release upload "$VERSION_TAG" --clobber "${ASSETS[@]}"
    else
        run gh "${GH_ARGS[@]}"
    fi
fi

if $COMMIT_PUSH; then
    log "Committing docs/appcast.xml"
    if $DRY_RUN; then
        run git add docs/appcast.xml
        run git commit -m "chore: update appcast for $VERSION_TAG"
        run git push origin HEAD
    elif git diff --quiet docs/appcast.xml; then
        log "docs/appcast.xml unchanged; nothing to commit"
    elif git symbolic-ref -q HEAD >/dev/null 2>&1; then
        # On a real branch (local dev, or CI checked out a branch ref).
        run git add docs/appcast.xml
        run git commit -m "chore: update appcast for $VERSION_TAG"
        run git push origin HEAD
    else
        # Detached HEAD (tag-triggered CI). Apply the freshly generated
        # appcast.xml as a standalone commit on top of origin/main, so we
        # don't try to push a nameless HEAD and don't sweep unrelated
        # feature-branch commits along for the ride.
        log "Detached HEAD; applying appcast update on top of origin/main"
        tmp_appcast=$(mktemp)
        cp docs/appcast.xml "$tmp_appcast"
        run git fetch origin main
        run git checkout -B "appcast-for-$VERSION_TAG" origin/main
        cp "$tmp_appcast" docs/appcast.xml
        rm -f "$tmp_appcast"
        if git diff --quiet docs/appcast.xml; then
            log "docs/appcast.xml on main already matches; nothing to push"
        else
            run git add docs/appcast.xml
            run git commit -m "chore: update appcast for $VERSION_TAG"
            run git push origin "HEAD:refs/heads/main"
        fi
    fi
fi

if ! $SKIP_OPEN_FINDER; then
    run open "$EXPORT_PATH"
fi

log "Done. Outputs:"
log "  macOS zip:           $MAC_ZIP"
if [[ -n "$IOS_SIM_ZIP" ]]; then
    log "  iOS Simulator zip:   $IOS_SIM_ZIP"
fi
if $UPDATE_APPCAST; then
    log "  appcast:             $PROJECT_DIR/docs/appcast.xml"
fi
