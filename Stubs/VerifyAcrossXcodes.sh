#!/bin/bash
# Loads one built bridge bundle against every installed Xcode, each in its own process.
#
#   ./VerifyAcrossXcodes.sh <RuntimeViewerSourceEditorBridge.bundle>
#   ./VerifyAcrossXcodes.sh <bundle> /Applications/Xcode-27.0.app   # just that one
#
# This is the red/green loop for the bridge's link model. The unit test in
# RuntimeViewerSourceEditorBridgeTests pins the shape of the built file — no load command naming
# Xcode's frameworks — but it cannot prove the bundle actually comes up against a *given* Xcode,
# because the frameworks are `dlopen`ed once per process and never unloaded. One version per
# process is the only way to cover more than one, and a test bundle is one process.
#
# What it catches: an install-name change like Xcode 27's `SharedFrameworks/` insertion, a symbol
# the bridge references that a version does not export, and a framework layout that moved.
#
# Read-only throughout: it opens files and loads libraries, and writes nothing.

set -euo pipefail

cd "$(dirname "$0")"

bundle_path="${1:-}"
if [ -z "$bundle_path" ]; then
    echo "usage: $0 <RuntimeViewerSourceEditorBridge.bundle> [Xcode.app …]" >&2
    exit 2
fi
if [ ! -d "$bundle_path" ]; then
    echo "no bundle at $bundle_path" >&2
    exit 1
fi
bundle_path="$(cd "$bundle_path" && pwd)"
shift

xcode_paths=("$@")
if [ ${#xcode_paths[@]} -eq 0 ]; then
    # Spotlight finds the copies a version manager keeps outside /Applications, which is the same
    # set the app's own picker offers. A machine with Spotlight off falls back to /Applications.
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            xcode_paths+=("$line")
        fi
    done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true)
    if [ ${#xcode_paths[@]} -eq 0 ]; then
        for candidate in /Applications/Xcode*.app; do
            if [ -d "$candidate/Contents/SharedFrameworks" ]; then
                xcode_paths+=("$candidate")
            fi
        done
    fi
fi
if [ ${#xcode_paths[@]} -eq 0 ]; then
    echo "found no installed Xcode" >&2
    exit 1
fi

failures=0
for xcode_path in "${xcode_paths[@]}"; do
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xcode_path/Contents/Info.plist" 2>/dev/null || echo "?")"
    printf '===== Xcode %s — %s\n' "$version" "$xcode_path"

    if [ ! -d "$xcode_path/Contents/SharedFrameworks/SourceEditor.framework" ]; then
        echo "SKIP no SourceEditor.framework"
        continue
    fi

    # `swift` rather than a compiled binary: the probe is 150 lines and runs three times, so the
    # ~10s of compiling it each time is cheaper than a build product to keep track of.
    if ! xcrun swift VerifyAcrossXcodes.swift "$xcode_path" "$bundle_path"; then
        failures=$((failures + 1))
    fi
done

if [ "$failures" -gt 0 ]; then
    printf '\n%d of %d Xcodes failed\n' "$failures" "${#xcode_paths[@]}" >&2
    exit 1
fi
printf '\nall %d Xcodes loaded the bridge\n' "${#xcode_paths[@]}"
