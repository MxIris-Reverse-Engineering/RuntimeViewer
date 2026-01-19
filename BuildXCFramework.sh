#!/bin/bash

# ==========================================
# Script Initialization & Argument Parsing
# ==========================================

SCHEME_NAME=""
BUILD_FOR_DISTRIBUTION="NO"
CONTAINER_ARGS="" # Stores -workspace or -project arguments
USER_PLATFORMS=()

# Function to print usage
usage() {
    echo "Usage: $0 <SchemeName> [options] [Platforms...]"
    echo ""
    echo "Options:"
    echo "  -w, --workspace <path>   Specify the workspace (.xcworkspace)"
    echo "  -p, --project <path>     Specify the project (.xcodeproj)"
    echo "  --dist                   Enable BUILD_LIBRARY_FOR_DISTRIBUTION (for ABI stability)"
    echo ""
    echo "Platforms:"
    echo "  iOS, macOS, Catalyst, tvOS, watchOS, visionOS"
    echo ""
    echo "Example:"
    echo "  $0 MyScheme -w My.xcworkspace --dist iOS macOS"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dist)
            BUILD_FOR_DISTRIBUTION="YES"
            shift # Remove --dist
            ;;
        -w|--workspace)
            if [ -z "$2" ]; then echo "❌ Error: Missing workspace path."; usage; fi
            CONTAINER_ARGS="-workspace $2"
            shift 2 # Remove flag and value
            ;;
        -p|--project)
            if [ -z "$2" ]; then echo "❌ Error: Missing project path."; usage; fi
            CONTAINER_ARGS="-project $2"
            shift 2 # Remove flag and value
            ;;
        -h|--help)
            usage
            ;;
        *)
            # The first non-flag argument is treated as the Scheme Name
            if [ -z "$SCHEME_NAME" ]; then
                SCHEME_NAME="$1"
            else
                # Subsequent non-flag arguments are treated as Platforms
                USER_PLATFORMS+=("$1")
            fi
            shift
            ;;
    esac
done

# Validate Scheme Name
if [ -z "$SCHEME_NAME" ]; then
    echo "❌ Error: Scheme Name is required."
    usage
fi

# ==========================================
# Configuration
# ==========================================
OUTPUT_DIR="./Products"
ARCHIVE_PATH="${OUTPUT_DIR}/Archives"
XCFRAMEWORK_NAME="${SCHEME_NAME}.xcframework"

# Platform Configurations
# Format: "PlatformName|DeviceDestination|SimulatorDestination"
# Note: Catalyst does not need a separate simulator slice (it runs on Mac).
PLATFORM_CONFIGS=(
    "iOS|generic/platform=iOS|generic/platform=iOS Simulator"
    "macOS|generic/platform=macOS|"
    "Catalyst|generic/platform=macOS,variant=Mac Catalyst|"
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
    # Filter user-specified platforms
    for arg in "${USER_PLATFORMS[@]}"; do
        found=false
        for config in "${PLATFORM_CONFIGS[@]}"; do
            p_name="${config%%|*}"
            # Case-insensitive comparison
            if echo "$p_name" | grep -iq "^$arg$"; then
                TARGET_PLATFORMS+=("$p_name")
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            echo "⚠️ Warning: Unknown platform '$arg', skipping."
        fi
    done
fi

if [ ${#TARGET_PLATFORMS[@]} -eq 0 ]; then
    echo "❌ Error: No valid platforms to build."
    exit 1
fi

echo "🚀 Scheme: $SCHEME_NAME"
if [ -n "$CONTAINER_ARGS" ]; then
    echo "📂 Container: $CONTAINER_ARGS"
fi
echo "⚙️  Build for Distribution: $BUILD_FOR_DISTRIBUTION"
echo "🎯 Target Platforms: ${TARGET_PLATFORMS[*]}"

# Clean up old builds
rm -rf "$OUTPUT_DIR"
mkdir -p "$ARCHIVE_PATH"

# ==========================================
# Function: Build Archive
# ==========================================
build_archive() {
    local destination=$1
    local archive_name=$2
    
    echo "🛠  [$(date +%T)] Building: $archive_name ..."

    # Note: We use $CONTAINER_ARGS (workspace/project) here
    xcodebuild archive \
        -scheme "$SCHEME_NAME" \
        $CONTAINER_ARGS \
        -destination "$destination" \
        -archivePath "$ARCHIVE_PATH/$archive_name.xcarchive" \
        BUILD_LIBRARY_FOR_DISTRIBUTION="$BUILD_FOR_DISTRIBUTION" \
        SKIP_INSTALL=NO \
        > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "❌ Build Failed: $archive_name"
        echo "   (Try running without '> /dev/null' to see the error log)"
        exit 1
    else
        echo "✅ Build Success: $archive_name"
    fi
}

# ==========================================
# Main Loop: Generate Archives
# ==========================================
FRAMEWORK_ARGS=""

for platform in "${TARGET_PLATFORMS[@]}"; do
    for config in "${PLATFORM_CONFIGS[@]}"; do
        if [[ "$config" == "$platform|"* ]]; then
            IFS='|' read -r p_name dest_device dest_sim <<< "$config"
            
            # 1. Build Device Slice
            if [ -n "$dest_device" ]; then
                build_archive "$dest_device" "${p_name}_Device"
                FRAMEWORK_ARGS+="-framework $ARCHIVE_PATH/${p_name}_Device.xcarchive/Products/Library/Frameworks/${SCHEME_NAME}.framework "
            fi
            
            # 2. Build Simulator Slice (if applicable)
            if [ -n "$dest_sim" ]; then
                build_archive "$dest_sim" "${p_name}_Simulator"
                FRAMEWORK_ARGS+="-framework $ARCHIVE_PATH/${p_name}_Simulator.xcarchive/Products/Library/Frameworks/${SCHEME_NAME}.framework "
            fi
        fi
    done
done

# ==========================================
# Create XCFramework
# ==========================================
echo "📦 Packaging XCFramework..."

xcodebuild -create-xcframework \
    $FRAMEWORK_ARGS \
    -output "$OUTPUT_DIR/$XCFRAMEWORK_NAME"

if [ -d "$OUTPUT_DIR/$XCFRAMEWORK_NAME" ]; then
    echo "🎉 Success! XCFramework generated at:"
    echo "   $OUTPUT_DIR/$XCFRAMEWORK_NAME"
    
    if [ "$BUILD_FOR_DISTRIBUTION" == "YES" ]; then
        echo "ℹ️  Library Distribution Enabled (ABI Stable)"
    fi
    
    open "$OUTPUT_DIR"
else
    echo "❌ Failed to create XCFramework."
    exit