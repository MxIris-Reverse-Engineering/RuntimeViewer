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

for framework in SourceEditor SourceModelSupport; do
    binary="$shared_frameworks/$framework.framework/Versions/A/$framework"
    [ -f "$binary" ] || { echo "missing $binary" >&2; exit 1; }

    output="$framework.framework/$framework.tbd"
    "$tapi" stubify "$binary" -o "$output"

    if [ "$keep_all" = false ] && [ -f "$framework.framework/UsedSymbols.txt" ]; then
        python3 Trim.py "$output" "$framework.framework/UsedSymbols.txt"
    fi

    printf "%-20s %s\n" "$framework" "$(du -h "$output" | cut -f1)"
done

echo "regenerated from $xcode_path"
