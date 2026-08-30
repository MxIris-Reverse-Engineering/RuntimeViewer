#!/bin/bash
# Regenerates the .tbd link stubs from an installed Xcode.
#
#   ./Generate.sh                                # active Xcode, via xcode-select
#   ./Generate.sh /Applications/Xcode-beta.app   # a specific one
#
# Only the symbols the bridge actually references are kept, so the checked-in stub stays
# small and reviewable. Pass --full to keep every exported symbol instead, which is what
# you want while adding new API to the .swiftinterface and the link is still failing.

set -euo pipefail

cd "$(dirname "$0")"

keep_all=false
xcode_path=""
for argument in "$@"; do
    case "$argument" in
        --full) keep_all=true ;;
        *) xcode_path="$argument" ;;
    esac
done

if [ -z "$xcode_path" ]; then
    xcode_path="$(xcode-select -p)"
    xcode_path="${xcode_path%/Contents/Developer}"
fi

shared_frameworks="$xcode_path/Contents/SharedFrameworks"
[ -d "$shared_frameworks" ] || { echo "no SharedFrameworks under $xcode_path" >&2; exit 1; }

tapi="$(xcrun -f tapi)"

for framework in SourceEditor SourceModelSupport SourceModel; do
    binary="$shared_frameworks/$framework.framework/Versions/A/$framework"
    [ -f "$binary" ] || { echo "missing $binary" >&2; exit 1; }

    output="$framework.framework/$framework.tbd"
    "$tapi" stubify "$binary" -o "$output"

    if [ "$keep_all" = false ] && [ -f "$framework.framework/UsedSymbols.txt" ]; then
        python3 Trim.py "$output" "$framework.framework/UsedSymbols.txt"
    fi

    # The stub has to describe every architecture we build the bridge for, not just the
    # ones this Xcode's binary happens to carry. See AddArchitectures.py for why that is
    # sound, and why an x86_64 build fails without it.
    python3 AddArchitectures.py "$output" x86_64-macos

    # Same reasoning one level up: a module the compiler cannot resolve for x86_64 stops
    # the build before the linker is ever reached. The interfaces are hand-written, so the
    # x86_64 one is derived from the arm64 one here rather than maintained beside it —
    # two copies of a hand-written file drift, and the only difference is the target flag.
    interface_directory="$framework.framework/Modules/$framework.swiftmodule"
    if [ -f "$interface_directory/arm64-apple-macos.swiftinterface" ]; then
        sed 's/-target arm64-apple-macos/-target x86_64-apple-macos/' \
            "$interface_directory/arm64-apple-macos.swiftinterface" \
            > "$interface_directory/x86_64-apple-macos.swiftinterface"
    fi

    printf "%-20s %s\n" "$framework" "$(du -h "$output" | cut -f1)"
done

echo "regenerated from $xcode_path"
