#!/bin/bash
# Answers the question that decides how a class must be declared: is it rooted at NSObject?
#
#   NSObject-rooted -> `@objc public class X : ObjectiveC.NSObject { @objc override dynamic public init() … }`
#   native root     -> `public class X { … }`
#
# Getting this wrong is the worst of the three reconstruction rules to debug, because nothing
# fails until the object is *deallocated*: Swift emits native release for a class it believes
# is its own root, while the real object needs the Objective-C dealloc chain. A mis-declared
# class constructs fine, answers every call fine, and then crashes on release — and an instance
# kept alive for the lifetime of the process hides the bug completely, which is exactly how it
# survived a passing spike.
#
# Do NOT try to read this off `@objc deinit`. On Darwin every Swift class exposes its deinit as
# `dealloc`, so real .swiftinterface files carry `@objc deinit` on classes that inherit nothing;
# it carries no information. Measured: adding `@objc deinit` to a wrongly-rooted class does not
# stop the crash, only fixing the superclass does.
#
#   printf '%s\n' SourceEditor.SourceEditorGutter | ./AuditClasses.sh
#   ./AuditClasses.sh /Applications/Xcode-beta.app < classes.txt
#
# Input is one fully-qualified type per line, module name included.

set -euo pipefail

xcode_path="${1:-}"
if [ -z "$xcode_path" ]; then
    xcode_path="$(xcode-select -p)"
    xcode_path="${xcode_path%/Contents/Developer}"
fi
shared_frameworks="$xcode_path/Contents/SharedFrameworks"

cache_directory="$(mktemp -d)"
trap 'rm -rf "$cache_directory"' EXIT

while read -r qualified_name; do
    [ -z "$qualified_name" ] && continue
    module="${qualified_name%%.*}"
    class_name="${qualified_name#*.}"

    cache="$cache_directory/$module"
    if [ ! -f "$cache" ]; then
        binary="$shared_frameworks/$module.framework/Versions/A/$module"
        if [ ! -f "$binary" ]; then
            printf "%-40s <no such module>\n" "$class_name"
            continue
        fi
        nm -gU "$binary" > "$cache"
    fi

    # Swift mangles the Objective-C class symbol as
    # _OBJC_CLASS_$__TtC<module length><module><name length><name>.
    if grep -qE "_OBJC_CLASS_\\\$__TtC${#module}$module[0-9]+$class_name\$" "$cache"; then
        printf "%-40s OBJC     @objc class : NSObject, @objc deinit\n" "$class_name"
    else
        printf "%-40s native   plain Swift class, plain deinit\n" "$class_name"
    fi
done
