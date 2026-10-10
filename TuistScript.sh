#!/usr/bin/env bash
# TuistScript.sh — RuntimeViewer-Tuist.xcworkspace, the development-only Tuist workspace: the macOS
# app and its tests, built with the four local packages as source and every third-party dependency
# taken from Tuist's binary cache on this machine. Release builds, CI and every other script use the
# native projects and are unaffected. Documentations/Guides/TuistDevelopment.md explains the setup.
#
# Usage:
#   ./TuistScript.sh install                      # resolve the dependencies (tuist install)
#   ./TuistScript.sh generate [--configuration <c>]
#                                                 # generate RuntimeViewer-Tuist.xcworkspace against
#                                                 # the binary cache of one configuration
#                                                 # (default: Debug)
#   ./TuistScript.sh warm [--configuration <c>]   # build the third-party dependencies into the
#                                                 # binary cache of one configuration (default:
#                                                 # Debug), then generate for Debug
#   ./TuistScript.sh build [--configuration <c>] [--launch]
#                                                 # generate for that configuration, then build the
#                                                 # app the way RunScript.sh does (default: Debug)
#   ./TuistScript.sh check [--build]              # compare the Tuist description with the native
#                                                 # projects; --build also builds both and compares
#                                                 # the apps they produce
#   ./TuistScript.sh <command> --dry-run          # print what would run
#   ./TuistScript.sh --help
#
# The generated projects link the cached binaries of one configuration. `build` and `check` generate
# for the configuration they build and, when that is not Debug, generate for Debug again on the way
# out, failed or not, so the workspace Xcode has open stays a Debug one; `warm` ends with a Debug
# generation too. Only `generate --configuration` leaves another configuration in place.
#
# Every command uses the Xcode that DEVELOPER_DIR or xcode-select names. Resolve the dependencies
# with the Xcode the native lock files were resolved with: some packages pick their manifest by
# Swift version, so another Xcode resolves other packages.
#
# Tuist's dependency checkouts, its binary cache and the build products live under
# /Volumes/DerivedData/RuntimeViewer/Tuist when that volume is mounted, as RunScript.sh's DerivedData
# does, and inside the checkout otherwise. TUIST_SCRIPT_ROOT names another directory.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

WORKSPACE="RuntimeViewer-Tuist.xcworkspace"
SCHEME="RuntimeViewer macOS"
NATIVE_WORKSPACE="RuntimeViewer-Debug.xcworkspace"
NATIVE_PACKAGE_RESOLVED="$NATIVE_WORKSPACE/xcshareddata/swiftpm/Package.resolved"
TUIST_PACKAGE_RESOLVED="Tuist/Package.resolved"
LOCAL_PACKAGES=("RuntimeViewerCore" "RuntimeViewerPackages" "RuntimeViewerMCP" "RuntimeViewerCommandLine")
# The configuration the workspace Xcode opens is generated for.
RESTING_CONFIGURATION="Debug"

COMMAND=""
CONFIGURATION="Debug"
LAUNCH=false
CHECK_BUILD=false
DRY_RUN=false

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[TuistScript] $*"; }
warn() { echo "[TuistScript] warning: $*" >&2; }

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

# Runs a command with its output in a log under $LOG_DIR, echoing only its errors and the last
# lines. Returns the command's own exit code.
run_logged() {
    local log_name="$1"; shift
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; printf '> %q\n' "$LOG_DIR/$log_name.log"
        return 0
    fi
    mkdir -p "$LOG_DIR"
    local log_path="$LOG_DIR/$log_name.log"
    log "  log: $log_path"
    local status=0
    "$@" > "$log_path" 2>&1 || status=$?
    if [[ $status -ne 0 ]]; then
        grep -E 'error:|✖' "$log_path" | head -20 | sed 's/^/    /' >&2 || true
        tail -5 "$log_path" | sed 's/^/    /' >&2
    fi
    return $status
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|generate|warm|build|check)
            [[ -z "$COMMAND" ]] || fail "one command at a time: $COMMAND, $1"
            COMMAND="$1"; shift;;
        --configuration)
            [[ $# -ge 2 ]] || fail "--configuration needs a name (Debug, Debug-arm64e or Release)"
            CONFIGURATION="$2"; shift 2;;
        --launch) LAUNCH=true; shift;;
        --build) CHECK_BUILD=true; shift;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0;;
        *) fail "unknown argument: $1 (see --help)";;
    esac
done
[[ -n "$COMMAND" ]] || fail "no command given (see --help)"
case "$CONFIGURATION" in
    Debug|Debug-arm64e|Release) ;;
    *) fail "unknown configuration: $CONFIGURATION (expected Debug, Debug-arm64e or Release)";;
esac

# One directory per checkout: two worktrees must not share Tuist's dependency checkouts, which
# record where the local packages are. The binary cache is shared; it is keyed by content.
CHECKOUT_NAME="$(basename "$PROJECT_DIR")-$(printf '%s' "$PROJECT_DIR" | shasum | cut -c1-8)"
if [[ -n "${TUIST_SCRIPT_ROOT:-}" ]]; then
    STORAGE_ROOT="$TUIST_SCRIPT_ROOT"
elif [[ -d "/Volumes/DerivedData" ]]; then
    STORAGE_ROOT="/Volumes/DerivedData/RuntimeViewer/Tuist"
else
    STORAGE_ROOT=""
fi
if [[ -n "$STORAGE_ROOT" ]]; then
    export TUIST_XDG_CACHE_HOME="$STORAGE_ROOT/Cache"
    export SWIFTPM_BUILD_DIR="$STORAGE_ROOT/Dependencies/$CHECKOUT_NAME"
    export TUIST_CACHE_WARM_SCRATCH_DIRECTORY="$STORAGE_ROOT/WarmScratch/$CHECKOUT_NAME"
    DEPENDENCIES_DIRECTORY="$SWIFTPM_BUILD_DIR"
    WORK_ROOT="$STORAGE_ROOT/Work/$CHECKOUT_NAME"
else
    DEPENDENCIES_DIRECTORY="$PROJECT_DIR/Tuist/.build"
    WORK_ROOT="$PROJECT_DIR/DerivedData/Tuist"
fi
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs/Tuist}"

# The manifests choose local checkouts or remote packages by this variable; the lock files and the
# Tuist description assume the remote ones.
if [[ -n "${USING_LOCAL_DEPENDENCIES:-}" ]]; then
    warn "ignoring USING_LOCAL_DEPENDENCIES=$USING_LOCAL_DEPENDENCIES: the Tuist workspace uses the remote packages"
    unset USING_LOCAL_DEPENDENCIES
fi

# The Tuist that mise.toml pins: through mise when it is installed, from PATH otherwise.
PINNED_TUIST_VERSION="$(sed -n 's/^tuist *= *"\(.*\)"$/\1/p' mise.toml)"
if command -v mise >/dev/null 2>&1; then
    TUIST=(mise exec -- tuist)
elif command -v tuist >/dev/null 2>&1; then
    TUIST=(tuist)
else
    fail "Tuist not found. Install mise (https://mise.jdx.dev) and run \`mise install\` here, or install Tuist $PINNED_TUIST_VERSION."
fi
if ! $DRY_RUN; then
    tuist_version="$("${TUIST[@]}" version 2>/dev/null | tail -1)" || fail "\`${TUIST[*]} version\` failed; run \`mise install\` here"
    [[ "$tuist_version" == "$PINNED_TUIST_VERSION" ]] \
        || fail "Tuist $tuist_version found, mise.toml pins $PINNED_TUIST_VERSION; run \`mise install\` here"
fi

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found (check compares the projects with it)"
log "command=$COMMAND configuration=$CONFIGURATION tuist=$PINNED_TUIST_VERSION"
log "xcode: $(xcodebuild -version | tr '\n' ' ')(${DEVELOPER_DIR:-$(xcode-select -p)})"
log "storage: ${STORAGE_ROOT:-inside the checkout} (dependencies: $DEPENDENCIES_DIRECTORY)"

# Compares the pins of Tuist/Package.resolved with those of the native Debug workspace. Prints the
# differences and returns 1 when there are any.
compare_lock_files() {
    python3 - "$TUIST_PACKAGE_RESOLVED" "$NATIVE_PACKAGE_RESOLVED" <<'PYTHON'
import json
import sys

def read_pins(path):
    with open(path) as handle:
        document = json.load(handle)
    pins = {}
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        pins[pin["identity"]] = state.get("version") or f"{state.get('branch')}@{state.get('revision', '')[:8]}"
    return pins

tuist_path, native_path = sys.argv[1:3]
try:
    tuist_pins, native_pins = read_pins(tuist_path), read_pins(native_path)
except OSError as error:
    print(f"    cannot compare the lock files: {error}")
    sys.exit(1)
differences = [
    f"    {identity}: Tuist {tuist_pins.get(identity, 'absent')}, native {native_pins.get(identity, 'absent')}"
    for identity in sorted(tuist_pins.keys() | native_pins.keys())
    if tuist_pins.get(identity) != native_pins.get(identity)
]
if differences:
    print("\n".join(differences))
    sys.exit(1)
PYTHON
}

LOCK_FILE_HINT="Some packages pick their manifest by Swift version, so an Xcode other than the one the native lock files were resolved with resolves other packages: run again with that Xcode (DEVELOPER_DIR), or run ./UpdatePackagesScript.sh, which updates both."

install_dependencies() {
    log "Resolving the dependencies (tuist install)"
    run_logged "install" "${TUIST[@]}" install || fail "tuist install failed"
    if ! $DRY_RUN; then
        if ! compare_lock_files; then
            warn "$TUIST_PACKAGE_RESOLVED now differs from $NATIVE_PACKAGE_RESOLVED (above). $LOCK_FILE_HINT"
        fi
    fi
}

ensure_dependencies() {
    if [[ ! -d "$DEPENDENCIES_DIRECTORY/checkouts" ]]; then
        install_dependencies
    fi
}

# Generates the workspace against the binary cache of one configuration ($1, $CONFIGURATION by
# default). Building another configuration with it mixes the two: Debug's binaries have no arm64e
# slice, for one, and a Debug-arm64e build against them fails to compile.
generate_workspace() {
    local configuration="${1:-$CONFIGURATION}"
    ensure_dependencies
    log "Generating $WORKSPACE ($configuration)"
    run_logged "generate-$configuration" "${TUIST[@]}" generate --no-open --configuration "$configuration" \
        || fail "tuist generate failed"
}

restore_resting_generation() {
    log "Generating $WORKSPACE for $RESTING_CONFIGURATION again"
    run_logged "generate-$RESTING_CONFIGURATION" "${TUIST[@]}" generate --no-open --configuration "$RESTING_CONFIGURATION" \
        || warn "generating $WORKSPACE for $RESTING_CONFIGURATION failed; run ./TuistScript.sh generate"
}

# For the commands that build: generate for $CONFIGURATION, and for Debug again when the script exits.
generate_for_this_command() {
    if [[ "$CONFIGURATION" != "$RESTING_CONFIGURATION" ]] && ! $DRY_RUN; then
        trap restore_resting_generation EXIT
    fi
    generate_workspace "$CONFIGURATION"
}

warm_cache() {
    ensure_dependencies
    if [[ -n "$STORAGE_ROOT" ]]; then
        # Tuist refuses to start with anything left in it from an earlier run, and never empties it.
        run rm -rf "$TUIST_CACHE_WARM_SCRATCH_DIRECTORY"
        run mkdir -p "$TUIST_CACHE_WARM_SCRATCH_DIRECTORY"
    fi
    log "Building the third-party dependencies into the binary cache ($CONFIGURATION)"
    # Without --cache-profile, `tuist cache warm` ignores the default profile in Tuist.swift and
    # caches every target it can, local ones included; the simulator payload then breaks its
    # device build.
    run_logged "warm-$CONFIGURATION" "${TUIST[@]}" cache warm --configuration "$CONFIGURATION" \
        --cache-profile development --no-upload \
        || fail "tuist cache warm failed"
    # A workspace generated before the warm-up still builds the dependencies from source.
    generate_workspace "$RESTING_CONFIGURATION"
}

# The metadata RunScript.sh stamps into the app, worked out once per run: the two builds of
# `check --build` then carry the same values, even when the first one touches a tracked file.
BUILD_GIT_COMMIT=""
BUILD_GIT_BRANCH=""
BUILD_DATE=""
BUILD_NUMBER=""
stamp_build_metadata() {
    [[ -z "$BUILD_DATE" ]] || return 0
    BUILD_GIT_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    BUILD_GIT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo unknown)"
    BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"
    if [[ "$BUILD_GIT_COMMIT" != "unknown" ]] && [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
        BUILD_GIT_COMMIT="${BUILD_GIT_COMMIT}-dirty"
    fi
}

# Builds the app from $1 (a workspace) into the DerivedData $2, with the build metadata and the
# architecture setting of RunScript.sh; $3 names the log.
build_app_in() {
    local workspace="$1" derived_data="$2" log_name="$3"
    stamp_build_metadata
    run_logged "$log_name" xcodebuild build \
        -workspace "$workspace" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        -skipPackagePluginValidation -skipMacroValidation \
        "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
        "RUNTIME_VIEWER_BUILD_DATE=$BUILD_DATE" \
        "RUNTIME_VIEWER_GIT_BRANCH=$BUILD_GIT_BRANCH" \
        "RUNTIME_VIEWER_GIT_COMMIT=$BUILD_GIT_COMMIT" \
        "EXCLUDED_ARCHS=x86_64" \
        || return 1
}

built_app_path() {
    local products_directory="$1/Build/Products/$CONFIGURATION"
    find "$products_directory" -maxdepth 1 -type d -name 'RuntimeViewer*.app' -not -name 'RuntimeViewerCatalystHelper.app' 2>/dev/null | head -1
}

build_command() {
    generate_for_this_command
    local derived_data="$WORK_ROOT/DerivedData/$CONFIGURATION"
    log "Building $SCHEME ($CONFIGURATION)"
    build_app_in "$WORKSPACE" "$derived_data" "build-$CONFIGURATION" || fail "the build failed"
    $DRY_RUN && return 0
    local app_path
    app_path="$(built_app_path "$derived_data")"
    [[ -n "$app_path" ]] || fail "no app under $derived_data/Build/Products/$CONFIGURATION"
    log "app: $app_path"
    if $LAUNCH; then
        run open "$app_path"
    fi
}

# Everything `check` compares is read from evaluated manifests and generated project files, never
# from the Swift sources of the manifests.
check_command() {
    local work_directory="$WORK_ROOT/Check"
    local findings=0
    generate_for_this_command
    $DRY_RUN && { log "would compare the projects, the target lists, the lock files and the trait settings"; return 0; }
    rm -rf "$work_directory"
    mkdir -p "$work_directory/Manifests" "$work_directory/Dependencies"

    log "Reading the manifests"
    "${TUIST[@]}" dump config > "$work_directory/Manifests/TuistConfig.json" 2>/dev/null || fail "tuist dump config failed"
    "${TUIST[@]}" dump package --path Tuist > "$work_directory/Manifests/PackageSettings.json" 2>/dev/null || fail "tuist dump package failed"
    "${TUIST[@]}" dump workspace > "$work_directory/Manifests/Workspace.json" 2>/dev/null || fail "tuist dump workspace failed"
    local package_directory
    for package_directory in "${LOCAL_PACKAGES[@]}" Tuist; do
        swift package --package-path "$package_directory" --scratch-path "$work_directory/Scratch/$package_directory" \
            dump-package > "$work_directory/Manifests/$package_directory.json" 2> "$work_directory/Manifests/$package_directory.err" \
            || fail "swift package dump-package failed in $package_directory (see $work_directory/Manifests/$package_directory.err)"
    done
    # Every dependency's manifest, as the selected Xcode's SwiftPM reads it.
    find "$DEPENDENCIES_DIRECTORY/checkouts" -mindepth 1 -maxdepth 1 -type d -print0 \
        | DUMP_DIRECTORY="$work_directory/Dependencies" xargs -0 -P 8 -n 1 sh -c \
            'swift package --package-path "$1" --scratch-path "$DUMP_DIRECTORY/Scratch/${1##*/}" dump-package > "$DUMP_DIRECTORY/${1##*/}.json" 2>/dev/null || echo "$1" >> "$DUMP_DIRECTORY/failures"' dump
    if [[ -s "$work_directory/Dependencies/failures" ]]; then
        warn "could not read these dependencies' manifests; their trait settings are not checked:"
        sed 's/^/    /' "$work_directory/Dependencies/failures" >&2
    fi

    log "Comparing the projects, the target lists and the trait settings"
    python3 - "$PROJECT_DIR" "$work_directory" <<'PYTHON' || findings=1
import glob
import json
import os
import re
import subprocess
import sys

project_directory, work_directory = sys.argv[1:3]
manifests = os.path.join(work_directory, "Manifests")
findings = []

def finding(message):
    findings.append(message)

def load_json(path):
    with open(path) as handle:
        return json.load(handle)

# MARK: - Project files

class ProjectFile:
    """A project.pbxproj, its targets and their configurations, with base xcconfig files as paths
    relative to the repository."""

    def __init__(self, relative_path):
        self.relative_path = relative_path
        self.directory = os.path.dirname(os.path.join(project_directory, relative_path))
        output = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", os.path.join(project_directory, relative_path, "project.pbxproj")])
        document = json.loads(output)
        self.objects = document["objects"]
        self.root = self.objects[document["rootObject"]]
        self.parents = {}
        for identifier, item in self.objects.items():
            for child in item.get("children", []):
                self.parents[child] = identifier

    def element_path(self, identifier):
        item = self.objects[identifier]
        path = item.get("path", "")
        source_tree = item.get("sourceTree", "<group>")
        if source_tree == "<absolute>":
            return path
        if source_tree == "SOURCE_ROOT":
            return os.path.normpath(os.path.join(self.directory, path))
        parent = self.parents.get(identifier)
        base = self.element_path(parent) if parent else self.directory
        return os.path.normpath(os.path.join(base, path))

    def configurations(self, configuration_list):
        result = {}
        for identifier in self.objects[configuration_list]["buildConfigurations"]:
            configuration = self.objects[identifier]
            base = None
            if "baseConfigurationReference" in configuration:
                base = self.element_path(configuration["baseConfigurationReference"])
            elif "baseConfigurationReferenceAnchor" in configuration:
                anchor = self.element_path(configuration["baseConfigurationReferenceAnchor"])
                base = os.path.normpath(os.path.join(anchor, configuration["baseConfigurationReferenceRelativePath"]))
            if base:
                base = os.path.relpath(base, project_directory)
            result[configuration["name"]] = (base, configuration["buildSettings"])
        return result

    def project_configurations(self):
        return self.configurations(self.root["buildConfigurationList"])

    def targets(self):
        return {self.objects[identifier]["name"]: self.configurations(self.objects[identifier]["buildConfigurationList"])
                for identifier in self.root["targets"]}

native_projects = {
    "RuntimeViewerUsingAppKit": ProjectFile("RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj"),
    "RuntimeViewerServer": ProjectFile("RuntimeViewerServer/RuntimeViewerServer.xcodeproj"),
}
tuist_project = ProjectFile("RuntimeViewerUsingAppKit/RuntimeViewer-Tuist.xcodeproj")

# Native targets the Tuist workspace leaves out on purpose.
NOT_MIRRORED = {
    "com.JH.RuntimeViewerService": "the old privileged helper, no longer embedded",
    "RuntimeViewerMobileServer": "the iOS-family payload for the iOS apps and the XCFramework",
}
TUIST_CONFIGURATIONS = ["Debug", "Debug-arm64e", "Release"]

native_targets = {}
for project_name, project in native_projects.items():
    for target_name, configurations in project.targets().items():
        if target_name not in NOT_MIRRORED:
            native_targets[target_name] = (project_name, configurations)

# The native targets set nothing in their project files: every setting is in their xcconfig, which
# the Tuist targets share.
for target_name, (project_name, configurations) in sorted(native_targets.items()):
    for configuration_name, (base, settings) in configurations.items():
        if settings:
            finding(f"{project_name}.xcodeproj: target {target_name} ({configuration_name}) sets {', '.join(sorted(settings))} "
                    f"in the project file. Move it to {base or 'an xcconfig under Configurations/'}, which the Tuist project shares.")
        if not base or not base.startswith("Configurations/"):
            finding(f"{project_name}.xcodeproj: target {target_name} ({configuration_name}) has no base xcconfig under Configurations/.")

appkit_project_configurations = native_projects["RuntimeViewerUsingAppKit"].project_configurations()
for configuration_name, (base, settings) in appkit_project_configurations.items():
    if settings:
        finding(f"RuntimeViewerUsingAppKit.xcodeproj sets {', '.join(sorted(settings))} at the project level ({configuration_name}). "
                f"Move it to {base}, which the Tuist project shares.")

# The Tuist project uses the same files, configuration by configuration.
tuist_project_configurations = tuist_project.project_configurations()
for configuration_name in TUIST_CONFIGURATIONS:
    native_base = appkit_project_configurations.get(configuration_name, (None, {}))[0]
    tuist_base, tuist_settings = tuist_project_configurations.get(configuration_name, (None, {}))
    if tuist_base != native_base:
        finding(f"Project level, {configuration_name}: the Tuist project uses {tuist_base}, the native one {native_base}.")
    if tuist_settings:
        finding(f"Project level, {configuration_name}: the Tuist project sets {', '.join(sorted(tuist_settings))} itself.")

def read_xcconfig(relative_path, values=None, optional=False):
    """The assignments of an xcconfig and the files it includes, as written (not expanded)."""
    values = {} if values is None else values
    path = os.path.join(project_directory, relative_path)
    if not os.path.exists(path):
        if not optional:
            finding(f"{relative_path} does not exist.")
        return values
    with open(path) as handle:
        for line in handle:
            include = re.match(r'\s*#include(\?)?\s+"([^"]+)"', line)
            if include:
                read_xcconfig(os.path.normpath(os.path.join(os.path.dirname(relative_path), include.group(2))), values, bool(include.group(1)))
                continue
            line = line.split("//")[0].strip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = " ".join(value.split())
    return values

def normalized(value):
    return " ".join(value) if isinstance(value, list) else " ".join(str(value).split())

# Settings the Tuist targets may set themselves, and how.
HANDED_BACK = {"SDKROOT", "TARGETED_DEVICE_FAMILY", "SUPPORTS_MACCATALYST", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD"}
TUIST_ONLY = {
    "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
    "SWIFT_INSTALL_MODULE": "NO",
    "SWIFT_INSTALL_OBJC_HEADER": "NO",
    "ONLY_ACTIVE_ARCH": "YES",
}
# Tuist's own linking settings. Wherever the xcconfig files also set one, Tuist's value has to add
# to theirs ($(inherited) first) rather than replace it.
APPENDED = {"FRAMEWORK_SEARCH_PATHS", "HEADER_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS", "OTHER_SWIFT_FLAGS",
            "OTHER_CFLAGS", "OTHER_LDFLAGS", "LD_RUNPATH_SEARCH_PATHS", "EXCLUDED_SOURCE_FILE_NAMES", "SWIFT_LOAD_BINARY_MACROS",
            "GCC_PREPROCESSOR_DEFINITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS"}

def configured_values(target_base, configuration_name):
    """What the xcconfig files of a target configuration and of its project level assign."""
    project_base = tuist_project_configurations.get(configuration_name, (None, {}))[0]
    values = dict(read_xcconfig(project_base)) if project_base else {}
    if target_base:
        values.update(read_xcconfig(target_base))
    return values

def first_element(value):
    if isinstance(value, list):
        return value[0] if value else ""
    return value.split()[0] if value.split() else ""

tuist_targets = tuist_project.targets()
for target_name in sorted(set(native_targets) - set(tuist_targets)):
    finding(f"Target {target_name} of {native_targets[target_name][0]}.xcodeproj has no counterpart in RuntimeViewerUsingAppKit/Project.swift.")
for target_name in sorted(set(tuist_targets) - set(native_targets)):
    finding(f"Target {target_name} of RuntimeViewerUsingAppKit/Project.swift has no counterpart in the native projects.")
for target_name in sorted(set(native_targets) & set(tuist_targets)):
    native_configurations = native_targets[target_name][1]
    for configuration_name in TUIST_CONFIGURATIONS:
        native_base = native_configurations.get(configuration_name, (None, {}))[0]
        tuist_base, settings = tuist_targets[target_name].get(configuration_name, (None, {}))
        if tuist_base != native_base:
            finding(f"Target {target_name} ({configuration_name}): the Tuist project uses {tuist_base}, the native one {native_base}.")
        for key, value in sorted(settings.items()):
            name = key.split("[")[0]
            if name in HANDED_BACK or (name == "PRODUCT_NAME" and value == "${inherited}"):
                if value != "${inherited}":
                    finding(f"Target {target_name} ({configuration_name}): the Tuist project sets {key} = {value}; expected ${{inherited}}.")
            elif name == "PRODUCT_NAME":
                if "$(" in value:
                    finding(f"Target {target_name} ({configuration_name}): PRODUCT_NAME = {value}.")
            elif name == "PRODUCT_BUNDLE_IDENTIFIER":
                if value != "$(inherited)":
                    finding(f"Target {target_name} ({configuration_name}): PRODUCT_BUNDLE_IDENTIFIER = {value}; expected $(inherited).")
            elif name in TUIST_ONLY:
                if value != TUIST_ONLY[name]:
                    finding(f"Target {target_name} ({configuration_name}): {key} = {value}; expected {TUIST_ONLY[name]}.")
            elif name in APPENDED:
                if first_element(value) != "$(inherited)" and key in configured_values(tuist_base, configuration_name):
                    finding(f"Target {target_name} ({configuration_name}): the Tuist project's {key} replaces the xcconfig's value instead of adding to it.")
            else:
                finding(f"Target {target_name} ({configuration_name}): the Tuist project sets {key} = {value}, which the native target does not.")

# Tuist links the packages as static libraries; without -ObjC the linker leaves out code the runtime
# looks up by name (packageLinkingSettings in RuntimeViewerUsingAppKit/Project.swift).
def linker_flags(value):
    return value if isinstance(value, list) else str(value).split()

for target_name, configurations in sorted(tuist_targets.items()):
    for configuration_name in TUIST_CONFIGURATIONS:
        settings = configurations.get(configuration_name, (None, {}))[1]
        if "-ObjC" not in linker_flags(settings.get("OTHER_LDFLAGS", [])):
            finding(f"Target {target_name} ({configuration_name}): OTHER_LDFLAGS lacks -ObjC; see packageLinkingSettings in RuntimeViewerUsingAppKit/Project.swift.")

# MARK: - The two project levels

# The Tuist project builds the two payloads under RuntimeViewerUsingAppKit's project level; the
# native one under RuntimeViewerServer's. Whatever the two levels set differently, the payloads'
# own xcconfig has to settle.
SETTLED_ELSEWHERE = {
    ("RuntimeViewerSimulatorServer", "MACOSX_DEPLOYMENT_TARGET"): "an iOS Simulator product does not use it",
}
server_project_configurations = native_projects["RuntimeViewerServer"].project_configurations()
for configuration_name in TUIST_CONFIGURATIONS:
    server_base, server_settings = server_project_configurations[configuration_name]
    server_level = read_xcconfig(server_base) if server_base else {}
    server_level.update({key: normalized(value) for key, value in server_settings.items()})
    appkit_level = read_xcconfig(appkit_project_configurations[configuration_name][0])
    differing = {key for key in server_level.keys() | appkit_level.keys() if server_level.get(key) != appkit_level.get(key)}
    for target_name in ("RuntimeViewerServer", "RuntimeViewerSimulatorServer"):
        target_base = native_targets[target_name][1][configuration_name][0]
        target_level = read_xcconfig(target_base)
        for key in sorted(differing - set(target_level)):
            if (target_name, key) in SETTLED_ELSEWHERE:
                continue
            finding(f"{key} ({configuration_name}) is {server_level.get(key, 'unset')} at RuntimeViewerServer.xcodeproj's project level and "
                    f"{appkit_level.get(key, 'unset')} at RuntimeViewerUsingAppKit.xcodeproj's, and {target_base} does not settle it; "
                    f"the Tuist project builds {target_name} under the latter.")

# MARK: - Target lists

def package_manifest(name):
    return load_json(os.path.join(manifests, f"{name}.json"))

local_packages = {name: package_manifest(name) for name in ("RuntimeViewerCore", "RuntimeViewerPackages", "RuntimeViewerMCP", "RuntimeViewerCommandLine")}
expected_source_targets, expected_bundles, expected_tests, expected_macos_products = set(), set(), set(), set()
for directory, manifest in local_packages.items():
    for target in manifest["targets"]:
        if target["type"] == "regular":
            expected_source_targets.add(target["name"])
            if target.get("resources"):
                expected_bundles.add(f"{manifest['name']}_{target['name']}")
        elif target["type"] == "test":
            expected_tests.add(target["name"])
    if directory != "RuntimeViewerCore":
        for product in manifest["products"]:
            if "library" in product["type"]:
                expected_macos_products.add(product["name"])

def compare(description, actual, expected):
    for name in sorted(expected - actual):
        finding(f"{description}: {name} is missing.")
    for name in sorted(actual - expected):
        finding(f"{description}: {name} is not a target of the local packages any more.")

configuration = load_json(os.path.join(manifests, "TuistConfig.json"))
profiles = configuration["project"]["tuist"]["cacheOptions"]["profiles"]["profileByName"]
cache_exceptions = {query["named"] for query in profiles["development"]["exceptTargetQueries"] if "named" in query}
compare("Tuist.swift, localPackageTargetNames", cache_exceptions, expected_source_targets | expected_bundles)

package_settings = load_json(os.path.join(manifests, "PackageSettings.json"))
warning_targets = {name for name, settings in package_settings["targetSettings"].items()
                   if settings.get("base", {}).get("SWIFT_SUPPRESS_WARNINGS")}
compare("LocalPackages.sourceTargetNames (Tuist/ProjectDescriptionHelpers)", warning_targets, expected_source_targets)
compare("LocalPackages.macOSOnlyProductNames (Tuist/ProjectDescriptionHelpers)", set(package_settings["productDestinations"]), expected_macos_products)

workspace = load_json(os.path.join(manifests, "Workspace.json"))
tested = set()
for scheme in workspace["schemes"]:
    for testable in (scheme.get("testAction") or {}).get("targets", []):
        tested.add(testable["target"]["targetName"])
compare("Workspace.swift, the test scheme", tested, expected_tests | {"RuntimeViewerSourceEditorBridgeTests"})

# SwiftPM builds test targets for at least macOS 14.0 (what XCTest and Swift Testing require);
# Tuist keeps the package's own minimum, so a package declaring less needs its tests raised.
def version_tuple(version):
    return tuple(int(part) for part in str(version).split(".") if part.isdigit())

for directory, manifest in local_packages.items():
    declared = next((platform["version"] for platform in manifest.get("platforms") or [] if platform["platformName"] == "macos"), "10.13")
    if version_tuple(declared) >= (14, 0):
        continue
    for target in manifest["targets"]:
        if target["type"] != "test":
            continue
        value = (package_settings["targetSettings"].get(target["name"], {}).get("base", {}).get("MACOSX_DEPLOYMENT_TARGET") or {})
        raised = (value.get("string") or {}).get("_0")
        if not raised or version_tuple(raised) < (14, 0):
            finding(f"{target['name']} ({directory} declares macOS {declared}) needs MACOSX_DEPLOYMENT_TARGET 14.0 in Tuist/Package.swift's targetSettings, as SwiftPM gives it.")

for target_name in sorted(expected_tests):
    value = package_settings["targetSettings"].get(target_name, {}).get("base", {}).get("OTHER_LDFLAGS") or {}
    flags = (value.get("array") or {}).get("_0") or ((value.get("string") or {}).get("_0") or "").split()
    if "-ObjC" not in flags:
        finding(f"{target_name}: OTHER_LDFLAGS lacks -ObjC in Tuist/Package.swift's targetSettings; see localTestTargetSettings.")

# MARK: - Settings the packages condition on traits alone

# Tuist drops every package setting whose only condition is a trait. Work out which traits are
# enabled, the way SwiftPM does, from Tuist/Package.swift down; every such setting of an enabled
# trait has to be restated in PackageSettings.targetSettings.
dependency_manifests = {}
for path in glob.glob(os.path.join(work_directory, "Dependencies", "*.json")):
    try:
        manifest = load_json(path)
    except (OSError, ValueError):
        continue
    dependency_manifests[os.path.basename(path)[:-5].lower()] = manifest
for directory, manifest in local_packages.items():
    dependency_manifests[directory.lower()] = manifest
root_manifest = package_manifest("Tuist")

def expand(manifest, traits):
    """A package's enabled traits, with "default" and the traits each one enables."""
    definitions = {trait["name"]: trait.get("enabledTraits", []) for trait in manifest.get("traits") or []}
    pending, enabled = list(traits), set()
    while pending:
        trait = pending.pop()
        if trait in enabled:
            continue
        enabled.add(trait)
        pending.extend(definitions.get(trait, []))
    return enabled

def requested_traits(dependency, enabled):
    traits = dependency.get("traits")
    if traits is None:
        return {"default"}
    requested = set()
    for trait in traits:
        condition = (trait.get("condition") or {}).get("traits")
        if not condition or enabled & set(condition):
            requested.add(trait["name"])
    return requested

def dependencies_of(manifest):
    for dependency in manifest.get("dependencies", []):
        for entries in dependency.values():
            for entry in entries:
                if isinstance(entry, dict) and entry.get("identity"):
                    yield entry

enabled_traits = {}
pending = [(entry["identity"], requested_traits(entry, set())) for entry in dependencies_of(root_manifest)]
while pending:
    identity, traits = pending.pop()
    manifest = dependency_manifests.get(identity)
    if manifest is None:
        continue
    enabled = expand(manifest, traits)
    if enabled <= enabled_traits.get(identity, set()):
        continue
    enabled_traits[identity] = enabled_traits.get(identity, set()) | enabled
    for entry in dependencies_of(manifest):
        pending.append((entry["identity"], requested_traits(entry, enabled_traits[identity])))

restated = package_settings["targetSettings"]
def restated_values(target_name, key):
    value = (restated.get(target_name, {}).get("base", {}).get(key) or {})
    if "array" in value:
        return value["array"]["_0"]
    if "string" in value:
        return value["string"]["_0"].split()
    return []

for identity, manifest in sorted(dependency_manifests.items()):
    for target in manifest.get("targets", []):
        if target["type"] == "test":
            continue
        for setting in target.get("settings") or []:
            condition = setting.get("condition") or {}
            traits = set(condition.get("traits") or [])
            if not traits or condition.get("platformNames") or condition.get("config"):
                continue
            if not traits & enabled_traits.get(identity, set()):
                continue
            kind = setting.get("kind", {})
            definition = (kind.get("define") or {}).get("_0")
            if definition is None:
                finding(f"{manifest['name']}, target {target['name']}: a {setting.get('tool')} setting conditioned on the enabled "
                        f"trait(s) {', '.join(sorted(traits))} ({json.dumps(kind)}) is dropped by Tuist; restate it in Tuist/Package.swift.")
                continue
            name = definition.split("=")[0]
            key = "SWIFT_ACTIVE_COMPILATION_CONDITIONS" if setting.get("tool") == "swift" else "GCC_PREPROCESSOR_DEFINITIONS"
            values = restated_values(target["name"], key)
            if not any(value == definition or value.split("=")[0] == name for value in values):
                finding(f"{manifest['name']}, target {target['name']}: {name} ({setting.get('tool')}), defined when the enabled trait(s) "
                        f"{', '.join(sorted(traits))} are on, is missing from Tuist/Package.swift's targetSettings[\"{target['name']}\"] {key}.")

if findings:
    print("\n".join(f"    {message}" for message in findings))
    sys.exit(1)
print("    the projects, the target lists and the trait settings agree")
PYTHON

    log "Comparing the lock files"
    if compare_lock_files; then
        echo "    $TUIST_PACKAGE_RESOLVED agrees with $NATIVE_PACKAGE_RESOLVED"
    else
        echo "    $LOCK_FILE_HINT"
        findings=1
    fi

    if $CHECK_BUILD; then
        check_builds || findings=1
    fi

    if [[ $findings -ne 0 ]]; then
        fail "the Tuist description and the native projects disagree (above)"
    fi
    log "Done: the Tuist description agrees with the native projects."
}

# Builds the app with both workspaces and compares what they produce: the files in the bundle, the
# Info.plist of every bundle in it, and the platform and architectures of every executable.
check_builds() {
    local native_derived_data="$WORK_ROOT/DerivedData/Check-Native-$CONFIGURATION"
    local tuist_derived_data="$WORK_ROOT/DerivedData/Check-Tuist-$CONFIGURATION"
    log "Building $SCHEME ($CONFIGURATION) with $NATIVE_WORKSPACE"
    build_app_in "$NATIVE_WORKSPACE" "$native_derived_data" "check-native-$CONFIGURATION" || { warn "the native build failed"; return 1; }
    log "Building $SCHEME ($CONFIGURATION) with $WORKSPACE"
    build_app_in "$WORKSPACE" "$tuist_derived_data" "check-tuist-$CONFIGURATION" || { warn "the Tuist build failed"; return 1; }
    log "Comparing the two apps"
    python3 - "$(built_app_path "$native_derived_data")" "$(built_app_path "$tuist_derived_data")" <<'PYTHON'
import os
import plistlib
import subprocess
import sys

native_app, tuist_app = sys.argv[1:3]
findings = []

# Known differences, each compared some other way or not at all:
# - the Catalyst helper's plugin is a framework in the Tuist project (Tuist does not link static
#   packages into a bundle), so it has a versioned layout instead of a flat one;
# - RxSwift also declares a dynamic product, and Tuist builds it as a dynamic framework where
#   SwiftPM links it statically, so its privacy manifest moves from a resource bundle into it;
# - third-party frameworks are built by SwiftPM in one and by Tuist in the other: their slices
#   and identifiers differ, so only their presence is compared;
# - Tuist writes the Info.plist of the packages' resource bundles itself;
# - SwiftPM's Bundle.module accessor defines a <package>_<target>_SWIFTPM_MODULE_BUNDLER_FINDER class,
#   which Tuist's own resource accessors do without.
PLUGIN = "Contents/Applications/RuntimeViewerCatalystHelper.app/Contents/PlugIns/RuntimeViewerCatalystHelperPlugin.bundle/"
ONLY_NATIVE = ("Contents/Resources/RxSwift_RxSwift.bundle/",)
ONLY_TUIST = ("Contents/Frameworks/RxSwift.framework/",)
THIRD_PARTY_FRAMEWORKS = "Contents/Frameworks/"
RESOURCE_BUNDLE_KEYS = {"CFBundleIdentifier", "CFBundleShortVersionString", "NSHumanReadableCopyright"}

def is_package_resource_bundle(relative):
    parts = relative.split("/")
    return len(parts) > 2 and parts[1] == "Resources" and parts[2].endswith(".bundle") and "_" in parts[2]

def files(app):
    result = set()
    for directory, directories, names in os.walk(app):
        for name in names + [d for d in directories if os.path.islink(os.path.join(directory, d))]:
            relative = os.path.relpath(os.path.join(directory, name), app)
            if relative.startswith(PLUGIN) or "/_CodeSignature/" in f"/{relative}" or relative.endswith(".DS_Store"):
                continue
            result.add(relative)
    return result

native_files, tuist_files = files(native_app), files(tuist_app)
for relative in sorted(native_files - tuist_files):
    if not relative.startswith(ONLY_NATIVE):
        findings.append(f"only the native app has {relative}")
for relative in sorted(tuist_files - native_files):
    if not relative.startswith(ONLY_TUIST):
        findings.append(f"only the Tuist app has {relative}")

IGNORED_KEYS = {"CFBundleVersion", "BuildMachineOSBuild", "RuntimeViewerBuildDate"}
for relative in sorted(native_files & tuist_files):
    if relative.startswith(THIRD_PARTY_FRAMEWORKS):
        continue
    if relative.endswith("Info.plist") or relative.endswith(".plist"):
        try:
            with open(os.path.join(native_app, relative), "rb") as handle:
                native_plist = plistlib.load(handle)
            with open(os.path.join(tuist_app, relative), "rb") as handle:
                tuist_plist = plistlib.load(handle)
        except Exception:
            continue
        if isinstance(native_plist, dict) and isinstance(tuist_plist, dict):
            ignored = IGNORED_KEYS | (RESOURCE_BUNDLE_KEYS if is_package_resource_bundle(relative) else set())
            for key in sorted((native_plist.keys() | tuist_plist.keys()) - ignored):
                if native_plist.get(key) != tuist_plist.get(key):
                    findings.append(f"{relative}: {key} is {native_plist.get(key)!r} in the native app and {tuist_plist.get(key)!r} in the Tuist app")

def objective_c_classes(path):
    """The Objective-C classes a Mach-O file defines, read from its first architecture."""
    try:
        architecture = subprocess.check_output(["lipo", "-archs", path], stderr=subprocess.DEVNULL, text=True).split()[0]
    except (subprocess.CalledProcessError, IndexError):
        return set()
    output = subprocess.run(["nm", "-m", "-arch", architecture, path], capture_output=True, text=True).stdout
    return {line.split("_OBJC_CLASS_$_", 1)[1] for line in output.splitlines()
            if "_OBJC_CLASS_$_" in line and "(undefined)" not in line}

def framework_binary(framework_path):
    name = os.path.basename(framework_path.rstrip("/"))[:-len(".framework")]
    for candidate in (os.path.join(framework_path, "Versions/A", name), os.path.join(framework_path, name)):
        if os.path.isfile(candidate) and not os.path.islink(candidate):
            return candidate
    return None

# The classes of the frameworks only the Tuist build embeds (RxSwift's) moved there, so they are not
# missing from the binaries that linked them statically before.
classes_in_tuist_only_frameworks = set()
for prefix in ONLY_TUIST:
    binary = framework_binary(os.path.join(tuist_app, prefix))
    if binary:
        classes_in_tuist_only_frameworks |= objective_c_classes(binary)

# Code the runtime looks up by name is what a static link can leave out without failing the link.
def compare_objective_c_classes(relative, native_path, tuist_path):
    missing = sorted(name for name in objective_c_classes(native_path) - objective_c_classes(tuist_path) - classes_in_tuist_only_frameworks
                     if not name.endswith("_SWIFTPM_MODULE_BUNDLER_FINDER"))
    if missing:
        findings.append(f"{relative}: the Tuist build leaves out {len(missing)} Objective-C class(es) the native one links, "
                        f"such as {', '.join(missing[:8])}")

def describe_binary(path):
    """Architectures, platforms, signing identifier and entitlements of a Mach-O file."""
    try:
        architectures = subprocess.check_output(["lipo", "-archs", path], stderr=subprocess.DEVNULL, text=True).split()
        platforms = subprocess.check_output(["vtool", "-show-build", path], stderr=subprocess.DEVNULL, text=True)
    except subprocess.CalledProcessError:
        return None
    signature = subprocess.run(["codesign", "-dv", path], capture_output=True, text=True).stderr
    identifier = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("Identifier=")), None)
    entitlements_output = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True).stdout
    try:
        entitlements = plistlib.loads(entitlements_output) if entitlements_output.strip() else {}
    except Exception:
        entitlements = {"unreadable": True}
    return (sorted(architectures), sorted({line.split()[-1] for line in platforms.splitlines() if line.strip().startswith("platform")}),
            identifier, entitlements)

for relative in sorted(native_files & tuist_files):
    native_path = os.path.join(native_app, relative)
    if relative.startswith(THIRD_PARTY_FRAMEWORKS):
        continue
    if os.path.islink(native_path) or not os.access(native_path, os.X_OK) or os.path.isdir(native_path):
        continue
    native_description = describe_binary(native_path)
    if native_description is None:
        continue
    tuist_description = describe_binary(os.path.join(tuist_app, relative))
    if native_description != tuist_description:
        findings.append(f"{relative}: {native_description} in the native app, {tuist_description} in the Tuist app")
    compare_objective_c_classes(relative, native_path, os.path.join(tuist_app, relative))

# The plugin, whose layout differs: its executable and the Info.plist keys the helper relies on.
def plugin_parts(app, executable, info_plist):
    executable_path, info_plist_path = os.path.join(app, PLUGIN, executable), os.path.join(app, PLUGIN, info_plist)
    if not os.path.exists(executable_path) or not os.path.exists(info_plist_path):
        return None, None
    with open(info_plist_path, "rb") as handle:
        plist = plistlib.load(handle)
    return describe_binary(executable_path), {key: plist.get(key) for key in ("CFBundleIdentifier", "CFBundleExecutable", "NSPrincipalClass", "CFBundleShortVersionString")}

native_plugin = plugin_parts(native_app, "Contents/MacOS/RuntimeViewerCatalystHelperPlugin", "Contents/Info.plist")
tuist_plugin = plugin_parts(tuist_app, "Versions/A/RuntimeViewerCatalystHelperPlugin", "Versions/A/Resources/Info.plist")
if native_plugin[0] is None or tuist_plugin[0] is None:
    findings.append(f"the Catalyst helper's plugin is missing (native: {native_plugin[0] is not None}, Tuist: {tuist_plugin[0] is not None})")
else:
    if native_plugin != tuist_plugin:
        findings.append(f"the Catalyst helper's plugin: {native_plugin} in the native app, {tuist_plugin} in the Tuist app")
    compare_objective_c_classes("the Catalyst helper's plugin",
                                os.path.join(native_app, PLUGIN, "Contents/MacOS/RuntimeViewerCatalystHelperPlugin"),
                                os.path.join(tuist_app, PLUGIN, "Versions/A/RuntimeViewerCatalystHelperPlugin"))

if findings:
    print("\n".join(f"    {message}" for message in findings))
    sys.exit(1)
print("    the two apps agree")
PYTHON
}

case "$COMMAND" in
    install) install_dependencies;;
    generate) generate_workspace; log "Open $WORKSPACE";;
    warm) warm_cache;;
    build) build_command;;
    check) check_command;;
esac
