#!/usr/bin/env bash
# FetchSourceEditorScript.sh — Download the reconstructed SourceEditor frameworks that official
# builds of RuntimeViewer carry.
#
# The frameworks are a rebuild of Xcode 26.6's SourceEditor family, released as xcframeworks in the
# private repository Mx-Iris/SourceEditor. Each platform has a pin of its own beside this script's
# RuntimeViewerPrecompiledLibraries/SourceEditor/, because the UIKit build of the frameworks only
# exists on the 26.6 line while macOS follows the 27 line:
#
#   macos  PinnedRelease.txt      -> Frameworks/<Name>.framework                    (the macOS slice)
#   ios    PinnedRelease-iOS.txt  -> Frameworks-iOS/iphoneos/<Name>.framework        (the iOS slice)
#                                    Frameworks-iOS/iphonesimulator/<Name>.framework (the simulator slice)
#
# For each platform asked for, this downloads the pinned release with `gh`, checks every zip against
# its pinned SHA-256, and puts the slices in place; git ignores both directories. The bridge framework
# links them from there, and the apps' Embed SourceEditor Frameworks build phases copy them in.
#
# Without `gh`, a login, or read access to that repository nothing is downloaded, and the apps build
# without SourceEditor: they show interfaces in the built-in text views. RunScript.sh and
# TuistScript.sh run this for macOS before every build and carry on either way; ArchiveScript.sh runs
# it and stops without the frameworks, because official builds must carry them.
#
# Usage:
#   ./FetchSourceEditorScript.sh                     # every platform, unless already in place
#   ./FetchSourceEditorScript.sh --platform macos    # one platform: macos, ios or all (the default)
#   ./FetchSourceEditorScript.sh --check             # only report whether they are here
#   ./FetchSourceEditorScript.sh --help
#
# Exit status: 0 when every pinned release asked for is in place; 2 when one is not and could not be
# downloaded (no `gh`, no login, no access) or, with --check, is simply not there; 1 for anything
# else, such as a zip whose checksum is not the pinned one. One platform failing does not stop the
# others from being fetched; the status is the worst of them.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
SOURCE_EDITOR_DIRECTORY="$SCRIPT_DIRECTORY/RuntimeViewerPrecompiledLibraries/SourceEditor"
REPOSITORY="Mx-Iris/SourceEditor"

log()         { echo "[FetchSourceEditor] $*"; }
fail()        { echo "error: $*" >&2; exit 1; }
unavailable() { echo "warning: $*" >&2; exit 2; }

CHECK_ONLY=false
PLATFORM=all
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift;;
        --platform)
            [ $# -ge 2 ] || fail "--platform needs a value: macos, ios or all"
            PLATFORM="$2"; shift 2;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) fail "unknown argument: $1 (see --help)";;
    esac
done
case "$PLATFORM" in
    macos|ios|all) ;;
    *) fail "unknown platform: $PLATFORM (macos, ios or all)";;
esac

# The xcframework slice directory of a platform's destination, such as `ios-arm64` for `iphoneos`.
# xcframework library identifiers end in `-simulator` or `-maccatalyst` for those variants, so the
# device slice is the `ios-` one with neither suffix.
slice_directory() {
    local xcframework="$1" destination="$2" candidate
    for candidate in "$xcframework"/*/; do
        candidate="${candidate%/}"
        case "$destination:$(basename "$candidate")" in
            macosx:macos-*) echo "$candidate";;
            iphonesimulator:ios-*-simulator) echo "$candidate";;
            iphoneos:ios-*-simulator|iphoneos:ios-*-maccatalyst) ;;
            iphoneos:ios-*) echo "$candidate";;
        esac
    done
}

# Puts one platform's pinned release in place. Runs in a subshell of its own, so that its `exit`
# ends only this platform and its scratch directory goes with it.
fetch_platform() {
    local platform="$1" pin_file frameworks_directory fetched_pin_file destinations
    case "$platform" in
        macos)
            pin_file="$SOURCE_EDITOR_DIRECTORY/PinnedRelease.txt"
            frameworks_directory="$SOURCE_EDITOR_DIRECTORY/Frameworks"
            fetched_pin_file="$frameworks_directory/PinnedRelease.txt"
            destinations=(macosx);;
        ios)
            pin_file="$SOURCE_EDITOR_DIRECTORY/PinnedRelease-iOS.txt"
            frameworks_directory="$SOURCE_EDITOR_DIRECTORY/Frameworks-iOS"
            fetched_pin_file="$frameworks_directory/PinnedRelease-iOS.txt"
            destinations=(iphoneos iphonesimulator);;
    esac
    # The pin the frameworks in frameworks_directory were downloaded for. The build phase embeds them
    # only while it is identical to pin_file, so a download for an older pin is never shipped.

    [ -f "$pin_file" ] || fail "missing $pin_file"

    local version="" key value
    local framework_names=() framework_checksums=()
    while read -r key value; do
        case "$key" in
            ""|\#*) continue;;
            version) version="$value";;
            *) framework_names+=("$key"); framework_checksums+=("$value");;
        esac
    done < "$pin_file"
    [ -n "$version" ] || fail "$pin_file names no version"
    [ ${#framework_names[@]} -gt 0 ] || fail "$pin_file names no frameworks"

    if cmp -s "$pin_file" "$fetched_pin_file"; then
        log "SourceEditor $version for $platform is in place: $frameworks_directory"
        exit 0
    fi
    if $CHECK_ONLY; then
        log "SourceEditor $version for $platform is not in place; run ./FetchSourceEditorScript.sh --platform $platform to download it"
        exit 2
    fi

    command -v gh >/dev/null 2>&1 \
        || unavailable "gh is not installed, so SourceEditor $version for $platform was not downloaded; the app will use the built-in text view"
    gh auth status --hostname github.com >/dev/null 2>&1 \
        || unavailable "gh is not logged in to github.com, so SourceEditor $version for $platform was not downloaded; the app will use the built-in text view"

    # Beside the destination rather than in the system's temporary directory, so the final move is a
    # rename on the same volume. Ignored by git, and removed on exit whatever happens. Not `local`:
    # the EXIT trap runs after the function has returned, when a local would be gone; the subshell
    # this runs in keeps it from leaking into the next platform.
    work_directory="$(mktemp -d "$SOURCE_EDITOR_DIRECTORY/.Fetch.XXXXXX")"
    trap 'rm -rf "$work_directory"' EXIT

    local patterns=() name
    for name in "${framework_names[@]}"; do
        patterns+=(--pattern "$name.xcframework.zip")
    done
    log "Downloading SourceEditor $version for $platform from $REPOSITORY"
    gh release download "$version" --repo "$REPOSITORY" --dir "$work_directory/Downloads" "${patterns[@]}" \
        || unavailable "could not download SourceEditor $version from $REPOSITORY (no read access?); the app will use the built-in text view"

    local index expected_checksum archive actual_checksum destination slices slice
    mkdir -p "$work_directory/Frameworks"
    for index in "${!framework_names[@]}"; do
        name="${framework_names[$index]}"
        expected_checksum="${framework_checksums[$index]}"
        archive="$work_directory/Downloads/$name.xcframework.zip"
        [ -f "$archive" ] || fail "the $version release has no $name.xcframework.zip"

        actual_checksum="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
        [ "$actual_checksum" = "$expected_checksum" ] \
            || fail "$name.xcframework.zip has SHA-256 $actual_checksum, but $pin_file pins $expected_checksum"

        ditto -x -k "$archive" "$work_directory/Extracted"
        for destination in "${destinations[@]}"; do
            slices=()
            while IFS= read -r slice; do
                slices+=("$slice/$name.framework")
            done < <(slice_directory "$work_directory/Extracted/$name.xcframework" "$destination")
            [ ${#slices[@]} -eq 1 ] && [ -d "${slices[0]}" ] \
                || fail "$name.xcframework does not hold exactly one $destination slice"
            if [ "$platform" = macos ]; then
                ditto "${slices[0]}" "$work_directory/Frameworks/$name.framework"
            else
                mkdir -p "$work_directory/Frameworks/$destination"
                ditto "${slices[0]}" "$work_directory/Frameworks/$destination/$name.framework"
            fi
        done
    done
    cp "$pin_file" "$work_directory/Frameworks/$(basename "$fetched_pin_file")"

    rm -rf "$frameworks_directory"
    mv "$work_directory/Frameworks" "$frameworks_directory"
    log "SourceEditor $version for $platform is in place: $frameworks_directory"
}

platforms=()
case "$PLATFORM" in
    all) platforms=(macos ios);;
    *) platforms=("$PLATFORM");;
esac

# Each platform in a subshell with errexit of its own: run as the left side of `||` instead, bash
# would switch errexit off inside it, and a failed `ditto` or `mv` would go unnoticed.
worst_status=0
for platform in "${platforms[@]}"; do
    set +e
    ( set -e; fetch_platform "$platform" )
    platform_status=$?
    set -e
    case "$platform_status" in
        0) ;;
        2) if [ "$worst_status" -eq 0 ]; then worst_status=2; fi;;
        *) worst_status=1;;
    esac
done
exit "$worst_status"
