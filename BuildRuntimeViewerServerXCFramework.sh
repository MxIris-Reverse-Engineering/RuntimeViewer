#!/bin/bash

# ==========================================
# Build RuntimeViewerServer XCFramework
# Supports all Apple platforms:
#   - macOS
#   - Mac Catalyst
#   - iOS (Device + Simulator)
#   - tvOS (Device + Simulator)
#   - watchOS (Device + Simulator)
#   - visionOS (Device + Simulator)
# ==========================================

set -e

# ==========================================
# Configuration
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_NAME="RuntimeViewer"
WORKSPACE_PATH="${SCRIPT_DIR}/${WORKSPACE_NAME}.xcworkspace"
SCHEME_NAME="RuntimeViewerServer"
FRAMEWORK_NAME="RuntimeViewerServer"
OUTPUT_DIR="${SCRIPT_DIR}/Products"
ARCHIVE_PATH="${OUTPUT_DIR}/Archives"
XCFRAMEWORK_NAME="${FRAMEWORK_NAME}.xcframework"
CONFIGURATION="Release"
BUILD_FOR_DISTRIBUTION="NO"

# Parse arguments
VERBOSE=false
CLEAN_BUILD=true
USER_PLATFORMS=()

usage() {
    echo "Usage: $0 [options] [Platforms...]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose      Show detailed build output"
    echo "  --no-clean         Skip cleaning before build"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Platforms (if none specified, builds all):"
    echo "  macOS, Catalyst, iOS, tvOS, watchOS, visionOS"
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
# Format: "PlatformName|DeviceDestination|SimulatorDestination"
# ==========================================
PLATFORM_CONFIGS=(
    "macOS|generic/platform=macOS|"
    "Catalyst|generic/platform=macOS,variant=Mac Catalyst|"
    "iOS|generic/platform=iOS|generic/platform=iOS Simulator"
    "tvOS|generic/platform=tvOS|generic/platform=tvOS Simulator"
    "watchOS|generic/platform=watchOS|generic/platform=watchOS Simulator"
    "visionOS|generic/platform=visionOS|generic/platform=visionOS Simulator"
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
echo "📋 Scheme: $SCHEME_NAME"
echo "⚙️  Configuration: $CONFIGURATION"
echo "📦 Build for Distribution: $BUILD_FOR_DISTRIBUTION"
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

# ==========================================
# Function: Build Archive
# ==========================================
build_archive() {
    local destination=$1
    local archive_name=$2

    echo "🛠  [$(date +%T)] Building: $archive_name ..."

    local redirect="/dev/null"
    if [ "$VERBOSE" = true ]; then
        redirect="/dev/stdout"
    fi

    xcodebuild archive \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$SCHEME_NAME" \
        -destination "$destination" \
        -archivePath "$ARCHIVE_PATH/$archive_name.xcarchive" \
        -configuration "$CONFIGURATION" \
        BUILD_LIBRARY_FOR_DISTRIBUTION="$BUILD_FOR_DISTRIBUTION" \
        SKIP_INSTALL=NO \
        > "$redirect" 2>&1

    if [ $? -ne 0 ]; then
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
# Main Loop: Generate Archives
# ==========================================
echo "📦 Starting archive builds..."
echo ""

FRAMEWORK_ARGS=()
DEBUG_SYMBOL_ARGS=()

for platform in "${TARGET_PLATFORMS[@]}"; do
    for config in "${PLATFORM_CONFIGS[@]}"; do
        if [[ "$config" == "$platform|"* ]]; then
            IFS='|' read -r p_name dest_device dest_sim <<< "$config"

            # Build Device Slice
            if [ -n "$dest_device" ]; then
                build_archive "$dest_device" "${p_name}_Device"
                FRAMEWORK_ARGS+=("-framework" "$ARCHIVE_PATH/${p_name}_Device.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")

                # Add debug symbols if available
                local dsym_path="$ARCHIVE_PATH/${p_name}_Device.xcarchive/dSYMs/${FRAMEWORK_NAME}.framework.dSYM"
                if [ -d "$dsym_path" ]; then
                    DEBUG_SYMBOL_ARGS+=("-debug-symbols" "$dsym_path")
                fi
            fi

            # Build Simulator Slice (if applicable)
            if [ -n "$dest_sim" ]; then
                build_archive "$dest_sim" "${p_name}_Simulator"
                FRAMEWORK_ARGS+=("-framework" "$ARCHIVE_PATH/${p_name}_Simulator.xcarchive/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework")

                # Add debug symbols if available
                local dsym_path="$ARCHIVE_PATH/${p_name}_Simulator.xcarchive/dSYMs/${FRAMEWORK_NAME}.framework.dSYM"
                if [ -d "$dsym_path" ]; then
                    DEBUG_SYMBOL_ARGS+=("-debug-symbols" "$dsym_path")
                fi
            fi
        fi
    done
done

# ==========================================
# Create XCFramework
# ==========================================
echo ""
echo "📦 Creating XCFramework..."

# Remove existing xcframework if present
rm -rf "$OUTPUT_DIR/$XCFRAMEWORK_NAME"

xcodebuild -create-xcframework \
    "${FRAMEWORK_ARGS[@]}" \
    -output "$OUTPUT_DIR/$XCFRAMEWORK_NAME"

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
