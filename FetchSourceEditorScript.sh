#!/usr/bin/env bash
# FetchSourceEditorScript.sh — Download the reconstructed SourceEditor frameworks that official
# builds of RuntimeViewer carry.
#
# The frameworks are a rebuild of Xcode 26.6's SourceEditor family, released as xcframeworks in the
# private repository Mx-Iris/SourceEditor. This script downloads the release pinned in
# RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt with `gh`, checks every zip
# against its pinned SHA-256, and puts the macOS slice of each framework in
# RuntimeViewerPrecompiledLibraries/SourceEditor/Frameworks/, which git ignores. The app links them
# from there, and its Embed SourceEditor Frameworks build phase copies them into the app.
#
# Without `gh`, a login, or read access to that repository nothing is downloaded, and the app
# builds without SourceEditor: it shows interfaces in the built-in text view. RunScript.sh runs
# this before every build and carries on either way; ArchiveScript.sh runs it and stops without
# the frameworks, because official builds must carry them.
#
# Usage:
#   ./FetchSourceEditorScript.sh            # download the pinned release unless it is already here
#   ./FetchSourceEditorScript.sh --check    # only report whether it is here; downloads nothing
#   ./FetchSourceEditorScript.sh --help
#
# Exit status: 0 when the pinned release is in place; 2 when it is not and could not be downloaded
# (no `gh`, no login, no access) or, with --check, is simply not there; 1 for anything else, such
# as a zip whose checksum is not the pinned one.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
SOURCE_EDITOR_DIRECTORY="$SCRIPT_DIRECTORY/RuntimeViewerPrecompiledLibraries/SourceEditor"
PIN_FILE="$SOURCE_EDITOR_DIRECTORY/PinnedRelease.txt"
FRAMEWORKS_DIRECTORY="$SOURCE_EDITOR_DIRECTORY/Frameworks"
# The pin the frameworks in FRAMEWORKS_DIRECTORY were downloaded for. The build phase embeds them
# only while it is identical to PIN_FILE, so a download for an older pin is never shipped.
FETCHED_PIN_FILE="$FRAMEWORKS_DIRECTORY/PinnedRelease.txt"
REPOSITORY="Mx-Iris/SourceEditor"

log()         { echo "[FetchSourceEditor] $*"; }
fail()        { echo "error: $*" >&2; exit 1; }
unavailable() { echo "warning: $*" >&2; exit 2; }

CHECK_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) fail "unknown argument: $1 (see --help)";;
    esac
done

[ -f "$PIN_FILE" ] || fail "missing $PIN_FILE"

version=""
framework_names=()
framework_checksums=()
while read -r key value; do
    case "$key" in
        ""|\#*) continue;;
        version) version="$value";;
        *) framework_names+=("$key"); framework_checksums+=("$value");;
    esac
done < "$PIN_FILE"
[ -n "$version" ] || fail "$PIN_FILE names no version"
[ ${#framework_names[@]} -gt 0 ] || fail "$PIN_FILE names no frameworks"

if cmp -s "$PIN_FILE" "$FETCHED_PIN_FILE"; then
    log "SourceEditor $version is in place: $FRAMEWORKS_DIRECTORY"
    exit 0
fi
if $CHECK_ONLY; then
    log "SourceEditor $version is not in place; run ./FetchSourceEditorScript.sh to download it"
    exit 2
fi

command -v gh >/dev/null 2>&1 \
    || unavailable "gh is not installed, so SourceEditor $version was not downloaded; the app will use the built-in text view"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || unavailable "gh is not logged in to github.com, so SourceEditor $version was not downloaded; the app will use the built-in text view"

# Beside the destination rather than in the system's temporary directory, so the final move is a
# rename on the same volume. Ignored by git, and removed on exit whatever happens.
work_directory="$(mktemp -d "$SOURCE_EDITOR_DIRECTORY/.Fetch.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

patterns=()
for name in "${framework_names[@]}"; do
    patterns+=(--pattern "$name.xcframework.zip")
done
log "Downloading SourceEditor $version from $REPOSITORY"
gh release download "$version" --repo "$REPOSITORY" --dir "$work_directory/Downloads" "${patterns[@]}" \
    || unavailable "could not download SourceEditor $version from $REPOSITORY (no read access?); the app will use the built-in text view"

mkdir -p "$work_directory/Frameworks"
for index in "${!framework_names[@]}"; do
    name="${framework_names[$index]}"
    expected_checksum="${framework_checksums[$index]}"
    archive="$work_directory/Downloads/$name.xcframework.zip"
    [ -f "$archive" ] || fail "the $version release has no $name.xcframework.zip"

    actual_checksum="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
    [ "$actual_checksum" = "$expected_checksum" ] \
        || fail "$name.xcframework.zip has SHA-256 $actual_checksum, but $PIN_FILE pins $expected_checksum"

    ditto -x -k "$archive" "$work_directory/Extracted"
    slices=("$work_directory/Extracted/$name.xcframework"/macos-*/"$name.framework")
    [ ${#slices[@]} -eq 1 ] && [ -d "${slices[0]}" ] \
        || fail "$name.xcframework does not hold exactly one macOS slice"
    ditto "${slices[0]}" "$work_directory/Frameworks/$name.framework"
done
cp "$PIN_FILE" "$work_directory/Frameworks/PinnedRelease.txt"

rm -rf "$FRAMEWORKS_DIRECTORY"
mv "$work_directory/Frameworks" "$FRAMEWORKS_DIRECTORY"
log "SourceEditor $version is in place: $FRAMEWORKS_DIRECTORY"
