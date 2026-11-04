#!/bin/sh
# Copies the reconstructed SourceEditor frameworks into the app's Frameworks directory and signs
# them, when FetchSourceEditorScript.sh has downloaded the release pinned in
# RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt. The bridge framework links them
# directly from that download (FRAMEWORK_SEARCH_PATHS); without it the bridge compiles without
# SourceEditor, nothing is linked, and the app shows interfaces in the built-in text view. Run as a
# build phase by both RuntimeViewerUsingAppKit.xcodeproj and the Tuist-generated RuntimeViewer-Tuist.xcodeproj.
#
# Usage: EmbedSourceEditorFrameworks.sh [destination directory]
#
# Without an argument the destination is the app's Frameworks folder. The bridge framework's own
# phase passes ${BUILT_PRODUCTS_DIR}: run from Xcode or under XCTest, dyld searches
# DYLD_FRAMEWORK_PATH before any rpath — the products directory first, and for tests Xcode's own
# SharedFrameworks after it, which holds Xcode's copies of these frameworks. A copy beside the bridge
# in the products directory is what makes tests and debug runs load the reconstruction.
set -eu

SOURCE_EDITOR_DIRECTORY="${SRCROOT}/../RuntimeViewerPrecompiledLibraries/SourceEditor"
PIN_FILE="${SOURCE_EDITOR_DIRECTORY}/PinnedRelease.txt"
FETCHED_DIRECTORY="${SOURCE_EDITOR_DIRECTORY}/Frameworks"
DESTINATION_DIRECTORY="${1:-${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}}"

# Every line of the pin but the version and the comments names one framework.
FRAMEWORK_NAMES="$(awk '!/^#/ && NF == 2 && $1 != "version" { print $1 }' "${PIN_FILE}")"
VERSION="$(awk '$1 == "version" { print $2 }' "${PIN_FILE}")"

remove_embedded_copies() {
    for name in ${FRAMEWORK_NAMES}; do
        rm -rf "${DESTINATION_DIRECTORY:?}/${name}.framework"
    done
}

# Nothing downloaded: the app compiled without SourceEditor, so there is nothing to embed — only a
# copy an earlier build may have left in the product, which would ship frameworks nothing uses.
if [ ! -d "${FETCHED_DIRECTORY}" ]; then
    remove_embedded_copies
    echo "note: SourceEditor ${VERSION} has not been downloaded, so this build shows interfaces in the built-in text view. Run ./FetchSourceEditorScript.sh to include it."
    exit 0
fi

# A download for another pin: the app has just been compiled and linked against it, and embedding it
# would ship a release the pin no longer names, so stop instead.
if ! cmp -s "${PIN_FILE}" "${FETCHED_DIRECTORY}/PinnedRelease.txt"; then
    echo "error: ${FETCHED_DIRECTORY} holds a SourceEditor download for another pin than ${VERSION}. Run ./FetchSourceEditorScript.sh, then build again."
    exit 1
fi

mkdir -p "${DESTINATION_DIRECTORY}"
remove_embedded_copies
for name in ${FRAMEWORK_NAMES}; do
    /usr/bin/ditto "${FETCHED_DIRECTORY}/${name}.framework" "${DESTINATION_DIRECTORY}/${name}.framework"
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --generate-entitlement-der "${DESTINATION_DIRECTORY}/${name}.framework"
    fi
done
echo "Embedded SourceEditor ${VERSION} in ${DESTINATION_DIRECTORY}"
