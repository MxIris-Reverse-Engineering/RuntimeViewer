#!/bin/zsh
#
# Builds the probe and assembles it the way RuntimeViewer would ship it:
#
#   ProbeHost.app                              macOS
#   └── Contents/XPCServices/ProbeService.xpc  Mac Catalyst
#       └── Contents/PlugIns/ProbePlugin.bundle  macOS
#
# project.yml spells Catalyst the way RuntimeViewerCatalystHelper did at the
# time (SDKROOT = iphoneos, SUPPORTS_MACCATALYST = YES), which turns into
# Catalyst only under a Mac Catalyst destination. So the service is built on its
# own and copied in, as RunScript.sh then did for the helper.
# project-single-build.yml does without this; see README.md.
#
# Usage: ./build.sh   (then run the path it prints last)
#        CATALYST_XPC_SERVICE_PROBE_DERIVED_DATA_PATH=<directory> ./build.sh

set -euo pipefail

probeDirectory=${0:A:h}
derivedDataPath=${CATALYST_XPC_SERVICE_PROBE_DERIVED_DATA_PATH:-/Volumes/DerivedData/Agents.noindex/claude/DerivedData/CatalystXPCServiceProbe}
productsPath=$derivedDataPath/Build/Products
assembledHostPath=$derivedDataPath/Assembled/ProbeHost.app
servicePath=$assembledHostPath/Contents/XPCServices/ProbeService.xpc
pluginPath=$servicePath/Contents/PlugIns/ProbePlugin.bundle

cd "$probeDirectory"
xcodegen generate --spec project.yml --quiet

buildScheme() {
    local scheme=$1 destination=$2
    echo "== Building $scheme ($destination)"
    queued-build xcodebuild build \
        -project CatalystXPCServiceProbe.xcodeproj \
        -scheme "$scheme" \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derivedDataPath" 2>&1 | xcsift --quiet
    local buildStatus=${pipestatus[1]}
    if (( buildStatus != 0 )); then
        echo "xcodebuild failed for $scheme (exit $buildStatus)"
        exit $buildStatus
    fi
}

buildScheme ProbeService 'generic/platform=macOS,variant=Mac Catalyst'
buildScheme ProbePlugin 'platform=macOS,arch=arm64'
buildScheme ProbeHost 'platform=macOS,arch=arm64'

echo "== Assembling $assembledHostPath"
rm -rf "$assembledHostPath"
mkdir -p "${assembledHostPath:h}"
ditto "$productsPath/Debug/ProbeHost.app" "$assembledHostPath"
mkdir -p "${servicePath:h}"
ditto "$productsPath/Debug-maccatalyst/ProbeService.xpc" "$servicePath"
mkdir -p "${pluginPath:h}"
ditto "$productsPath/Debug/ProbePlugin.bundle" "$pluginPath"

# Copying nested code in breaks every enclosing signature; re-sign inside out.
codesign --force --sign - "$pluginPath"
codesign --force --sign - "$servicePath"
codesign --force --sign - "$assembledHostPath"
codesign --verify --deep --strict "$assembledHostPath"

echo "== Platform of each executable"
for executablePath in \
    "$assembledHostPath/Contents/MacOS/ProbeHost" \
    "$servicePath/Contents/MacOS/ProbeService" \
    "$pluginPath/Contents/MacOS/ProbePlugin"; do
    echo "${executablePath#$derivedDataPath/Assembled/}: $(vtool -show-build "$executablePath" | awk '/platform/ { print $2 }' | sort -u | xargs)"
done

echo "== Run with"
echo "$assembledHostPath/Contents/MacOS/ProbeHost"
