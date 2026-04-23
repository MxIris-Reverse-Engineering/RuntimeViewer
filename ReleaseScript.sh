#!/usr/bin/env bash
# ReleaseScript.sh — Archive, notarize, sign, and (optionally) publish a
# RuntimeViewer release. Used by both local developers and CI.
#
# Usage:
#   ./ReleaseScript.sh --version-tag vX.Y.Z \
#                      [--release-notes Changelogs/vX.Y.Z.md] \
#                      [--update-appcast] [--upload-to-github] [--commit-push]
#   ./ReleaseScript.sh --help
#
# Run without --update-appcast / --upload-to-github / --commit-push for a
# local build that only produces the signed, notarized zip.
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
log()  { echo "[ReleaseScript] $*"; }

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

# Run a command with its stdout+stderr piped through pretty(). `set -o pipefail`
# ensures a failure in the leading command still propagates.
run_piped() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; printf '| pretty\n'
    else
        "$@" 2>&1 | pretty
    fi
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
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# *//'; exit 0;;
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
log "update_appcast=$UPDATE_APPCAST upload_to_github=$UPLOAD_TO_GITHUB commit_push=$COMMIT_PUSH"

BUILD_PATH="$PROJECT_DIR/Products/Archives"
EXPORT_PATH="$BUILD_PATH/Products/Export"
CATALYST_EXPORT_PATH="$PROJECT_DIR/RuntimeViewerUsingAppKit"
CATALYST_HELPER_ARCHIVE="$BUILD_PATH/RuntimeViewerCatalystHelper.xcarchive"
MAIN_ARCHIVE="$BUILD_PATH/RuntimeViewer.xcarchive"

mkdir -p "$BUILD_PATH"

log "Archiving Catalyst helper"
run_piped xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

run rm -rf "$CATALYST_EXPORT_PATH/RuntimeViewerCatalystHelper.app"
run xcodebuild -exportArchive \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$CATALYST_EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig-Catalyst.plist" \
    -quiet
run rm -f "$CATALYST_EXPORT_PATH/Packaging.log" \
        "$CATALYST_EXPORT_PATH/DistributionSummary.plist" \
        "$CATALYST_EXPORT_PATH/ExportOptions.plist"

log "Archiving main app"
run_piped xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$MAIN_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

run rm -rf "$EXPORT_PATH"
run xcodebuild -exportArchive \
    -archivePath "$MAIN_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig.plist" \
    -quiet

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
    run_piped xcodebuild build \
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
        --appcast-file "$APPCAST_PATH"
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
    if ! $DRY_RUN && git diff --quiet docs/appcast.xml; then
        log "docs/appcast.xml unchanged; nothing to commit"
    else
        run git add docs/appcast.xml
        run git commit -m "chore: update appcast for $VERSION_TAG"
        run git push origin HEAD
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
