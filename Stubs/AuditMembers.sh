#!/bin/bash
# Answers the one question the .swiftinterface cannot be written without: does the
# framework export this member as a dispatch thunk (declare it plainly) or only as a
# direct symbol (it must be declared `final`)?
#
# Guessing wrong shows up as `Undefined symbols: dispatch thunk of …` at link time, so ask
# first instead of discovering it one member at a time.
#
#   printf '%s\n' SourceEditor.SourceEditorView.dataSource | ./AuditMembers.sh
#   ./AuditMembers.sh /Applications/Xcode-beta.app < members.txt
#
# Input is one fully-qualified member per line, module name included.

set -euo pipefail

xcode_path="${1:-}"
if [ -z "$xcode_path" ]; then
    xcode_path="$(xcode-select -p)"
    xcode_path="${xcode_path%/Contents/Developer}"
fi
shared_frameworks="$xcode_path/Contents/SharedFrameworks"

symbols_of_module() {
    local module="$1"
    local binary="$shared_frameworks/$module.framework/Versions/A/$module"
    [ -f "$binary" ] || return 1
    nm -gU "$binary" | awk '{print $NF}' | xcrun swift-demangle --compact
}

cache_directory="$(mktemp -d)"
trap 'rm -rf "$cache_directory"' EXIT

while read -r member; do
    [ -z "$member" ] && continue
    module="${member%%.*}"
    cache="$cache_directory/$module"
    if [ ! -f "$cache" ]; then
        symbols_of_module "$module" > "$cache" || { printf "%-64s <no such module>\n" "$member"; continue; }
    fi

    # Anchor on a real member boundary, otherwise `contentView` also matches
    # `contentViewOffset` and `contentViewDidFinishLayout`.
    boundary="($member\.(getter|setter|modify)|$member\(| $member :)"
    thunk=$(grep -cE "dispatch thunk of $boundary" "$cache" || true)
    direct=$(grep -E "$boundary" "$cache" \
             | grep -vE 'dispatch thunk of|method descriptor for|property descriptor for|key path' \
             | grep -c . || true)

    if [ "$thunk" -gt 0 ]; then
        verdict="plain      public var / public func"
    elif [ "$direct" -gt 0 ]; then
        verdict="FINAL      public final var / public final func"
    else
        verdict="MISSING    not exported under this name"
    fi
    printf "%-62s thunk=%-3s direct=%-3s  %s\n" "${member#*.}" "$thunk" "$direct" "$verdict"
done
