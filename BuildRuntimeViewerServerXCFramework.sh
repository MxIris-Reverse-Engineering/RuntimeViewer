#!/bin/bash

# ==========================================
# Build RuntimeViewerServer XCFramework
# Supports all Apple platforms:
#   - macOS (using RuntimeViewerServer)
#   - Mac Catalyst (using RuntimeViewerMobileServer)
#   - iOS (Device + Simulator) (using RuntimeViewerMobileServer)
#   - tvOS (Device + Simulator) (using RuntimeViewerMobileServer)
#   - watchOS (Device + Simulator) (using RuntimeViewerMobileServer)
#   - visionOS (Device + Simulator) (using RuntimeViewerMobileServer)
# ==========================================

set -e

# ==========================================
# Configuration
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_NAME="RuntimeViewer"
WORKSPACE_PATH="${SCRIPT_DIR}/${WORKSPACE_NAME}-Distribution.xcworkspace"
SCHEME_MACOS="RuntimeViewerServer"
SCHEME_MOBILE="RuntimeViewerMobileServer"
FRAMEWORK_NAME="RuntimeViewerServer"
OUTPUT_DIR="${SCRIPT_DIR}/Products"
ARCHIVE_PATH="${OUTPUT_DIR}/Archives"
XCFRAMEWORK_NAME="${FRAMEWORK_NAME}.xcframework"
CONFIGURATION="Distribution"

# Parse arguments
VERBOSE=false
CLEAN_BUILD=true
UPDATE_PACKAGES=true
USER_PLATFORMS=()
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

usage() {
    echo "Usage: $0 [options] [Platforms...]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose            Show detailed build output"
    echo "  --no-clean               Skip cleaning before build"
    echo "  --no-update-packages     Skip forcing a Swift package update"
    echo "                           (just resolve from existing Package.resolved)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Platforms (if none specified, builds all):"
    echo "  macOS, macCatalyst, iOS, tvOS, watchOS, visionOS"
    echo ""
    echo "Schemes:"
    echo "  macOS uses:  $SCHEME_MACOS"
    echo "  Others use:  $SCHEME_MOBILE (macCatalyst, iOS, tvOS, watchOS, visionOS)"
    echo ""
    echo "Examples:"
    echo "  $0                     # Build all platforms"
    echo "  $0 iOS macOS           # Build only iOS and macOS"
    echo "  $0 -v iOS              # Build iOS with verbose output"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --no-clean)
            CLEAN_BUILD=false
            shift
            ;;
        --no-update-packages)
            UPDATE_PACKAGES=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            USER_PLATFORMS+=("$1")
            shift
            ;;
    esac
done

# ==========================================
# Platform Configurations
# Format: "PlatformName|Scheme|DeviceDestination|SimulatorDestination"
# ==========================================
PLATFORM_CONFIGS=(
    "macOS|${SCHEME_MACOS}|generic/platform=macOS|"
    # "macCatalyst|${SCHEME_MOBILE}|generic/platform=macOS,variant=Mac Catalyst|"
    "iOS|${SCHEME_MOBILE}|generic/platform=iOS|generic/platform=iOS Simulator"
    "tvOS|${SCHEME_MOBILE}|generic/platform=tvOS|generic/platform=tvOS Simulator"
    "watchOS|${SCHEME_MOBILE}|generic/platform=watchOS|generic/platform=watchOS Simulator"
    "visionOS|${SCHEME_MOBILE}|generic/platform=visionOS|generic/platform=visionOS Simulator"
)

# Determine Target Platforms
TARGET_PLATFORMS=()

if [ ${#USER_PLATFORMS[@]} -eq 0 ]; then
    echo "🌍 No platforms specified. Building for ALL supported platforms..."
    for config in "${PLATFORM_CONFIGS[@]}"; do
        TARGET_PLATFORMS+=("${config%%|*}")
    done
else
    for arg in "${USER_PLATFORMS[@]}"; do
        found=false
        for config in "${PLATFORM_CONFIGS[@]}"; do
            p_name="${config%%|*}"
            if echo "$p_name" | grep -iq "^$arg$"; then
                TARGET_PLATFORMS+=("$p_name")
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            echo "⚠️  Warning: Unknown platform '$arg', skipping."
        fi
    done
fi

if [ ${#TARGET_PLATFORMS[@]} -eq 0 ]; then
    echo "❌ Error: No valid platforms to build."
    exit 1
fi

# ==========================================
# Print Build Configuration
# ==========================================
echo "============================================"
echo "🚀 Building RuntimeViewerServer XCFramework"
echo "============================================"
echo "📂 Project: $WORKSPACE_PATH"
echo "📋 Schemes:"
echo "   - macOS:  $SCHEME_MACOS"
echo "   - Mobile: $SCHEME_MOBILE (macCatalyst, iOS, tvOS, watchOS, visionOS)"
echo "⚙️  Configuration: $CONFIGURATION"
echo "📦 Build for Distribution: $BUILD_FOR_DISTRIBUTION"
echo "🔧 Parallel compile tasks: $CPU_CORES"
echo "🎯 Target Platforms: ${TARGET_PLATFORMS[*]}"
echo "============================================"
echo ""

# ==========================================
# Clean up old builds
# ==========================================
if [ "$CLEAN_BUILD" = true ]; then
    echo "🧹 Cleaning previous build artifacts..."
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$ARCHIVE_PATH"
mkdir -p "$OUTPUT_DIR/DerivedData"

# ==========================================
# Update / Resolve Workspace Package Dependencies
# ==========================================
# Note: Do NOT run `swift package update` on individual packages —
# the workspace unifies swift-syntax via a local checkout
# (RuntimeViewerPrecompiledLibraries/swift-syntax). Resolving each
# package standalone would pick incompatible upstream constraints
# (e.g. SwiftMCP wants 602.x while RxSwiftPlus wants 601.x).
#
# To force a real update (latest versions matching workspace
# constraints) we:
#   1. delete the workspace's Package.resolved
#   2. point -resolvePackageDependencies at our clean
#      $OUTPUT_DIR/DerivedData so SPM cannot reuse a stale
#      SourcePackages/checkouts directory from the default
#      ~/Library/Developer/Xcode/DerivedData location.
# Without (2), SPM happily keeps an older transitive version
# (e.g. swift-dyld-private 1.1.0) even though a newer matching
# version (1.2.0) is available in the repository cache.
# Both Package.resolved and DerivedData are gitignored / disposable.
WORKSPACE_RESOLVED="$WORKSPACE_PATH/xcshareddata/swiftpm/Package.resolved"
RESOLVE_DERIVED_DATA="$OUTPUT_DIR/DerivedData"

if [ "$UPDATE_PACKAGES" = true ] && [ -f "$WORKSPACE_RESOLVED" ]; then
    echo "🔄 Removing workspace Package.resolved to force update..."
    rm -f "$WORKSPACE_RESOLVED"
fi

echo "📦 Resolving workspace package dependencies..."
if [ "$VERBOSE" = true ]; then
    if ! xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$SCHEME_MACOS" \
        -derivedDataPath "$RESOLVE_DERIVED_DATA"; then
        echo "❌ Failed to resolve workspace package dependencies"
        exit 1
    fi
else
    if ! xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$SCHEME_MACOS" \
        -derivedDataPath "$RESOLVE_DERIVED_DATA" > /dev/null 2>&1; then
        echo "❌ Failed to resolve workspace package dependencies (re-run with -v to see details)"
        exit 1
    fi
fi
echo ""

# ==========================================
# Function: Build Archive
# ==========================================
build_archive() {
    local scheme=$1
    local destination=$2
    local archive_name=$3
    shift 3
    local extra_build_settings=("$@")
    local derived_data_path="$OUTPUT_DIR/DerivedData"

    echo "🛠  [$(date +%T)] Building: $archive_name (scheme: $scheme) ..."

    local redirect="/dev/null"
    if [ "$VERBOSE" = true ]; then
        redirect="/dev/stdout"
    fi

    local job_args=("-jobs" "$CPU_CORES")

    if ! xcodebuild archive \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$scheme" \
        -destination "$destination" \
        -archivePath "$ARCHIVE_PATH/$archive_name.xcarchive" \
        -derivedDataPath "$derived_data_path" \
        -configuration "$CONFIGURATION" \
        "${job_args[@]}" \
        "${extra_build_settings[@]}" \
        > "$redirect" 2>&1; then
        echo "❌ Build Failed: $archive_name"
        echo "   Run with -v flag to see detailed error log"
        exit 1
    fi

    # Verify framework exists
    local framework_path="$ARCHIVE_PATH/$archive_name.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework"
    if [ ! -d "$framework_path" ]; then
        echo "❌ Error: Framework not found at expected path:"
        echo "   $framework_path"
        exit 1
    fi

    echo "✅ Build Success: $archive_name"
}


# ==========================================
# Main Loop: Generate Archives (Sequential)
# ==========================================
echo "📦 Starting archive builds..."
echo ""

FRAMEWORK_PATHS=()
DSYM_PATHS=()

for platform in "${TARGET_PLATFORMS[@]}"; do
    for config in "${PLATFORM_CONFIGS[@]}"; do
        if [[ "$config" == "$platform|"* ]]; then
            IFS='|' read -r p_name p_scheme dest_device dest_sim <<< "$config"

            # Build Device Slice
            if [ -n "$dest_device" ]; then
                build_archive "$p_scheme" "$dest_device" "${p_name}_Device"
                FRAMEWORK_PATHS+=("$ARCHIVE_PATH/${p_name}_Device.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")
                DSYM_PATHS+=("$ARCHIVE_PATH/${p_name}_Device.xcarchive/dSYMs/${FRAMEWORK_NAME}.framework.dSYM")
            fi

            # Build Simulator Slice (if applicable)
            if [ -n "$dest_sim" ]; then
                build_archive "$p_scheme" "$dest_sim" "${p_name}_Simulator"
                FRAMEWORK_PATHS+=("$ARCHIVE_PATH/${p_name}_Simulator.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")
                DSYM_PATHS+=("$ARCHIVE_PATH/${p_name}_Simulator.xcarchive/dSYMs/${FRAMEWORK_NAME}.framework.dSYM")
            fi
        fi
    done
done

FRAMEWORK_ARGS=()
for i in "${!FRAMEWORK_PATHS[@]}"; do
    FRAMEWORK_ARGS+=("-framework" "${FRAMEWORK_PATHS[$i]}")
    if [ -d "${DSYM_PATHS[$i]}" ]; then
        FRAMEWORK_ARGS+=("-debug-symbols" "${DSYM_PATHS[$i]}")
    fi
done

# ==========================================
# Create XCFramework
# ==========================================
echo ""
echo "📦 Creating XCFramework..."

# Remove existing xcframework if present
rm -rf "$OUTPUT_DIR/$XCFRAMEWORK_NAME"

if ! xcodebuild -create-xcframework \
    "${FRAMEWORK_ARGS[@]}" \
    -output "$OUTPUT_DIR/$XCFRAMEWORK_NAME"; then
    echo "❌ Failed to create XCFramework."
    exit 1
fi

if [ -d "$OUTPUT_DIR/$XCFRAMEWORK_NAME" ]; then
    echo ""
    echo "============================================"
    echo "🎉 Success! XCFramework created at:"
    echo "   $OUTPUT_DIR/$XCFRAMEWORK_NAME"
    echo "============================================"
    echo ""

    # Print framework info
    echo "📋 XCFramework Contents:"
    ls -la "$OUTPUT_DIR/$XCFRAMEWORK_NAME/"
    echo ""

    # Print supported platforms from Info.plist
    echo "🎯 Supported Platforms:"
    plutil -p "$OUTPUT_DIR/$XCFRAMEWORK_NAME/Info.plist" | grep -E "LibraryIdentifier|SupportedPlatform|SupportedArchitectures" | head -30
    echo ""

    # Open output directory
    open "$OUTPUT_DIR"
else
    echo "❌ Failed to create XCFramework."
    exit 1
fi
