#!/usr/bin/env bash
# BuildJailbrokenIPAScript.sh — Build the jailbroken iOS variant and package it
# as an .ipa carrying the five entitlements it needs.
#
# Why not `xcodebuild -exportArchive`: no provisioning profile grants
# com.apple.private.security.no-sandbox or the two runningboard entitlements, so
# Xcode cannot produce this bundle signed at all. The target builds with
# CODE_SIGNING_ALLOWED = NO — set in the project, not here — and comes out
# unsigned; every Mach-O in it is pseudo-signed below, and that is the shape the
# device's AMFI is known to accept. `codesign --verify` rejects it by design: it
# rejects ldid's own output too. Do not "fix" that by re-signing with codesign.
#
# Either of two tools does that signing, picked by whichever is installed —
# `--signer` overrides. They are interchangeable here: `vphone-cli sign` is a
# wrapper that writes byte for byte what `ldid -S -M -K -I` writes, and `ldid`
# is that underlying tool. Which one a given machine has differs, so neither is
# assumed.
#
# Only the main executable carries entitlements. The frameworks get a plain
# signature — they need one to be loadable, none of the privileges.
#
# Install by handing the .ipa to something that honours the entitlements it
# already carries: vphoned preserves each binary's existing entitlements when it
# installs, and a jailbreak installer grants them outright. Installing through
# Xcode re-signs the bundle and loses all five, which is the whole reason this
# script exists.
#
# Usage:
#   ./BuildJailbrokenIPAScript.sh                           # build, sign, package
#   ./BuildJailbrokenIPAScript.sh --configuration Release
#   ./BuildJailbrokenIPAScript.sh --no-build                # package the last build
#   ./BuildJailbrokenIPAScript.sh --output /tmp/rv.ipa
#   ./BuildJailbrokenIPAScript.sh --signer ldid             # vphone-cli | ldid | auto
#   ./BuildJailbrokenIPAScript.sh --dry-run                 # print the commands

set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")" && pwd)

# Not RuntimeViewer.xcworkspace. The variant's app target and the payload are
# both arm64e (ARCHS = arm64e / arm64 arm64e), so the SwiftPM package products
# they link need an arm64e slice too — and that is a *workspace* setting,
# `iOSPackagesShouldBuildARM64e`, which only the Debug and Distribution
# workspaces carry. Built through the plain workspace the packages come out
# arm64-only and the payload dies at link time with "Undefined symbols for
# architecture arm64e" naming every type in RuntimeViewerCore. Measured.
WORKSPACE="$PROJECT_DIR/RuntimeViewer-Debug.xcworkspace"
SCHEME="RuntimeViewer iOS Jailbroken"
CONFIGURATION=Debug
PRODUCT_NAME=RuntimeViewerJailbroken
ENTITLEMENTS="$PROJECT_DIR/RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit-Jailbroken.entitlements"

# Injection needs arm64e: the payload is mapped into arm64e system processes and
# a pointer-authenticated process cannot run an arm64 payload. The target pins
# ARCHS = arm64e, so this only catches that pin being lost.
REQUIRED_ARCHITECTURE=arm64e

BUILD=true
DRY_RUN=false
REVEAL=true
OUTPUT_IPA=""
DERIVED_DATA=""

# `auto` resolves to whichever signer is installed, preferring vphone-cli
# because a machine that has it is a machine set up to install with vphoned.
SIGNER=auto

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[BuildJailbrokenIPA] $*"; }

# Pipe xcodebuild output through xcbeautify when it is installed, otherwise
# through cat, so a run never depends on the tool being there.
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2;;
        --scheme) SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --derived-data) DERIVED_DATA="$2"; shift 2;;
        --output) OUTPUT_IPA="$2"; shift 2;;
        --signer) SIGNER="$2"; shift 2;;
        --no-build) BUILD=false; shift;;
        --no-reveal) REVEAL=false; shift;;
        --dry-run) DRY_RUN=true; shift;;
        # The header comment is the help text. Bounded by the shebang and
        # `set -euo`, found rather than hardcoded — a line count goes stale the
        # first time the header is edited, and silently truncates the usage.
        -h|--help) sed -n "2,$(($(grep -n '^set -euo' "$0" | cut -d: -f1) - 1))p" "$0"; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

# Keep build products off the internal disk when the cache volume is mounted,
# the same way BuildSimulatorScript.sh does, and keep the path stable so the
# incremental build is worth something.
if [[ -z "$DERIVED_DATA" ]]; then
    if [[ -d /Volumes/DerivedData ]]; then
        DERIVED_DATA=/Volumes/DerivedData/RuntimeViewer/Jailbroken
    else
        DERIVED_DATA="$PROJECT_DIR/DerivedData"
    fi
fi

BUILD_PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos"
SOURCE_APP="$BUILD_PRODUCTS_DIR/$PRODUCT_NAME.app"
STAGING_DIR="$PROJECT_DIR/Products/Jailbroken"
STAGED_APP="$STAGING_DIR/Payload/$PRODUCT_NAME.app"
[[ -n "$OUTPUT_IPA" ]] || OUTPUT_IPA="$STAGING_DIR/$PRODUCT_NAME.ipa"

[[ -d "$WORKSPACE" ]] || fail "workspace not found: $WORKSPACE"
[[ -f "$ENTITLEMENTS" ]] || fail "entitlements not found: $ENTITLEMENTS"

# Checked here rather than discovered at link time. Without this setting the
# whole graph builds for ten minutes and then fails linking the payload, with an
# error that names Swift symbols and says nothing about the workspace.
if ! grep -q iOSPackagesShouldBuildARM64e "$WORKSPACE/xcshareddata/WorkspaceSettings.xcsettings" 2>/dev/null; then
    fail "$(basename "$WORKSPACE") does not set iOSPackagesShouldBuildARM64e, so its SwiftPM packages build arm64-only and this arm64e variant cannot link against them. Use RuntimeViewer-Debug.xcworkspace or RuntimeViewer-Distribution.xcworkspace."
fi

# A signer is required rather than optional, even though *which* one is not.
# Without any, the .ipa would still build and install, and would then fail at
# runtime in a way that looks like a code bug: no entitlements means
# proc_listallpids returns EPERM and the process list comes back empty.
case "$SIGNER" in
    auto)
        for candidate in vphone-cli ldid; do
            if command -v "$candidate" >/dev/null 2>&1; then SIGNER=$candidate; break; fi
        done
        [[ "$SIGNER" != auto ]] \
            || fail "no signer found. Install either: 'brew install ldid', or vphone-cli if this machine installs with vphoned. Pick one explicitly with --signer."
        ;;
    vphone-cli|ldid)
        command -v "$SIGNER" >/dev/null 2>&1 \
            || fail "--signer $SIGNER was asked for, but $SIGNER is not on PATH."
        ;;
    *)
        fail "unknown signer: $SIGNER (expected vphone-cli, ldid, or auto)"
        ;;
esac

# A plain pseudo-signature, carrying no entitlements. The embedded frameworks
# need one to be loadable and none of the privileges.
sign_without_entitlements() {
    local mach_o=$1
    case "$SIGNER" in
        vphone-cli) vphone-cli sign "$mach_o";;
        ldid)       ldid -S "$mach_o";;
    esac
}

# The main executable: the only Mach-O that carries the five entitlements, and
# the only one whose signing identifier has to be the bundle's.
sign_with_entitlements() {
    local mach_o=$1
    local identifier=$2
    case "$SIGNER" in
        vphone-cli)
            vphone-cli sign "$mach_o" --entitlements "$ENTITLEMENTS" --identifier "$identifier"
            ;;
        ldid)
            # ldid attaches a flag's argument to the flag — `-Sfile`, not
            # `-S file`. Written apart, the path and the identifier are read as
            # two further input files to sign, and the executable comes out
            # pseudo-signed with no entitlements at all: a build that installs
            # and then lists no processes, which is the failure this script
            # exists to prevent.
            ldid -S"$ENTITLEMENTS" -I"$identifier" "$mach_o"
            ;;
    esac
}

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION"
log "derived_data=$DERIVED_DATA"
log "signer=$SIGNER"

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if $BUILD; then
    log "Building $SCHEME ($CONFIGURATION)"
    # `set -o pipefail` above is what makes this honest: xcbeautify exits 0 even
    # when the build failed, so without it the pipeline would always look green.
    if $DRY_RUN; then
        run xcodebuild build -workspace "$WORKSPACE" -scheme "$SCHEME" \
            -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
            -derivedDataPath "$DERIVED_DATA" -skipPackagePluginValidation -skipMacroValidation
    else
        xcodebuild build \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -configuration "$CONFIGURATION" \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "$DERIVED_DATA" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -jobs "$(sysctl -n hw.ncpu 2>/dev/null || echo 8)" \
            2>&1 | pretty
    fi
else
    log "Skipping the build; packaging whatever is at $SOURCE_APP"
fi

if $DRY_RUN; then
    log "Dry run: stopping before packaging, which needs a real build to read."
    exit 0
fi

[[ -d "$SOURCE_APP" ]] || fail "no built app at $SOURCE_APP"

# -----------------------------------------------------------------------------
# Stage
# -----------------------------------------------------------------------------

# Always work on a copy, so a re-run starts from the build output rather than
# from a bundle an earlier run already signed and stripped.
log "Staging to $STAGED_APP"
rm -rf "$STAGING_DIR/Payload" "$STAGING_DIR/Verify"
mkdir -p "$STAGING_DIR/Payload"
ditto "$SOURCE_APP" "$STAGED_APP"

# Xcode's debug scaffolding. The previews stub does nothing in an installed
# build; the .debug.dylib beside the executable is loaded only when Xcode itself
# launches the app, but it is left in place because the executable links it and
# the dynamic loader would refuse to start without it.
rm -f "$STAGED_APP/__preview.dylib"

BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$STAGED_APP/Info.plist")
# Read the identifier back out of the built Info.plist rather than hardcoding
# it: Debug and Release carry different ones (dev.JH… and com.JH…), and the
# signing identifier has to match whichever was built.
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Info.plist")
MAIN_EXECUTABLE="$STAGED_APP/$BUNDLE_EXECUTABLE"

[[ -f "$MAIN_EXECUTABLE" ]] || fail "Info.plist names an executable that is not there: $BUNDLE_EXECUTABLE"

ARCHITECTURES=$(lipo -archs "$MAIN_EXECUTABLE")
case " $ARCHITECTURES " in
    *" $REQUIRED_ARCHITECTURE "*) ;;
    *) fail "$BUNDLE_EXECUTABLE is $ARCHITECTURES, with no $REQUIRED_ARCHITECTURE slice; it could not inject into system processes";;
esac
log "identifier=$BUNDLE_IDENTIFIER architectures=$ARCHITECTURES"

# -----------------------------------------------------------------------------
# Sign
# -----------------------------------------------------------------------------

# Found rather than listed: the embedded frameworks change as the package graph
# does, and a hardcoded list goes stale silently — an unsigned framework is a
# launch failure on the device, nowhere near this script.
#
# Inner Mach-Os first. Signing the bundle before its contents would mean
# re-signing it afterwards anyway.
while IFS= read -r mach_o; do
    [[ "$mach_o" != "$MAIN_EXECUTABLE" ]] || continue
    file -b "$mach_o" | grep -q 'Mach-O' || continue
    log "signing ${mach_o#$STAGED_APP/}"
    sign_without_entitlements "$mach_o"
done < <(find "$STAGED_APP" -type f)

log "signing $BUNDLE_EXECUTABLE with the jailbroken entitlements"
sign_with_entitlements "$MAIN_EXECUTABLE" "$BUNDLE_IDENTIFIER"

# -----------------------------------------------------------------------------
# Package
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
(cd "$STAGING_DIR" && zip -qry "$OUTPUT_IPA" Payload)
rm -rf "$STAGING_DIR/Payload"

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

# Read the entitlements back off the packaged artifact, not off the staged
# bundle. The thing that gets installed is the .ipa, so it is the .ipa that has
# to be asked — and an earlier version of this check passed while silently
# matching only four of the five keys.
VERIFY_DIR="$STAGING_DIR/Verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
unzip -q "$OUTPUT_IPA" -d "$VERIFY_DIR"
EMBEDDED_ENTITLEMENTS=$(codesign -d --entitlements - \
    "$VERIFY_DIR/Payload/$PRODUCT_NAME.app/$BUNDLE_EXECUTABLE" 2>&1)
rm -rf "$VERIFY_DIR"

# Expected keys come from the entitlements file itself, so adding a sixth
# entitlement cannot escape this check by not being listed here.
MISSING_KEYS=""
while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    grep -Fq "$key" <<<"$EMBEDDED_ENTITLEMENTS" || MISSING_KEYS="$MISSING_KEYS $key"
done < <(/usr/libexec/PlistBuddy -c 'Print' "$ENTITLEMENTS" | sed -n 's/^    \([^ ][^ ]*\) = .*/\1/p')

if [[ -n "${MISSING_KEYS// /}" ]]; then
    fail "the packaged .ipa is missing these entitlements:$MISSING_KEYS"
fi

echo ''
log "entitlements verified on the packaged .ipa:"
/usr/libexec/PlistBuddy -c 'Print' "$ENTITLEMENTS" \
    | sed -n 's/^    \([^ ][^ ]*\) = .*/  \1/p'

echo ''
log "IPA: $OUTPUT_IPA"
ls -lh "$OUTPUT_IPA"

if $REVEAL; then
    open -R "$OUTPUT_IPA"
fi
