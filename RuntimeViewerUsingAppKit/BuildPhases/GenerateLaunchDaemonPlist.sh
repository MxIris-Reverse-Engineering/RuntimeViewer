#!/bin/sh
# Writes the launchd plist of the privileged helper daemon into the app bundle, under the name of
# the daemon of the configuration being built (RUNTIME_VIEWER_SERVICE_NAME, from
# Configurations/ServiceName). Run as a build phase of the app by both RuntimeViewerUsingAppKit.xcodeproj
# and the Tuist-generated RuntimeViewer-Tuist.xcodeproj.
set -e
LAUNCHD_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchDaemons"
PLIST="${LAUNCHD_DIR}/${RUNTIME_VIEWER_SERVICE_NAME}.plist"
mkdir -p "${LAUNCHD_DIR}"
rm -f "${PLIST}"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "${PLIST}"
PB=/usr/libexec/PlistBuddy
"${PB}" -c "Add :Label string ${RUNTIME_VIEWER_SERVICE_NAME}" "${PLIST}"
"${PB}" -c "Add :BundleProgram string Contents/Library/LaunchServices/${RUNTIME_VIEWER_SERVICE_NAME}" "${PLIST}"
"${PB}" -c "Add :KeepAlive bool true" "${PLIST}"
"${PB}" -c "Add :MachServices dict" "${PLIST}"
"${PB}" -c "Add :MachServices:${RUNTIME_VIEWER_SERVICE_NAME} bool true" "${PLIST}"
echo "Generated LaunchDaemon plist: ${PLIST}"
