#!/usr/bin/env bash
# UpdateSourceEditorScript.sh — Move official builds of RuntimeViewer to another release of the
# reconstructed SourceEditor frameworks.
#
# RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt pins the release official builds
# carry: its version and the SHA-256 of each framework's zip. This script takes the release asked
# for or, when none is named, the newest release of the private repository Mx-Iris/SourceEditor on
# the pinned release's line — the same major version, 26 or 27 — prereleases included, and reads
# the checksum of every pinned framework from the Package.swift at that release's tag. Without a
# version it never moves back, and never takes GitHub's own latest release, which leaves prereleases
# out: from a pin of 27.2.0-alpha.1 that release was 26.6.6. Moving to an older release, or to
# another line, takes its version. It writes the version and those checksums into the pin file,
# leaving its comments and the order of the frameworks as they are, then runs
# FetchSourceEditorScript.sh, which downloads the zips and checks each against its new checksum.
# When the download or a check fails, the pin file goes back to what it was. It ends with the
# Breaking section of every release it moved across: code that uses the frameworks may have to
# change before it builds again.
#
# Usage:
#   ./UpdateSourceEditorScript.sh              # move to the newest release on the pinned line
#   ./UpdateSourceEditorScript.sh 26.6.3       # move to that release, on any line, forward or back
#   ./UpdateSourceEditorScript.sh --dry-run    # print what would change in the pin file; change nothing
#   ./UpdateSourceEditorScript.sh --help
#
# It needs `gh`, logged in to github.com with read access to Mx-Iris/SourceEditor.
#
# Exit status: 0 when the release is pinned and in place; 2 when `gh` is missing, not logged in or
# cannot read the repository; 1 for anything else, such as a release that does not exist, a pin
# newer than every release on its line when no version is named, a Package.swift without one of the
# pinned frameworks, or a zip whose checksum is not the one its Package.swift gives.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PIN_FILE_RELATIVE_PATH="RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt"
PIN_FILE="$SCRIPT_DIRECTORY/$PIN_FILE_RELATIVE_PATH"
FETCH_SCRIPT="$SCRIPT_DIRECTORY/FetchSourceEditorScript.sh"
REPOSITORY="Mx-Iris/SourceEditor"

log()         { echo "[UpdateSourceEditor] $*"; }
fail()        { echo "error: $*" >&2; exit 1; }
unavailable() { echo "error: $*" >&2; exit 2; }

# Whether version $1 comes after version $2, a prerelease before the release it leads to
# (27.2.0-alpha.1 before 27.2.0), as semantic versioning orders them; `sort -V` alone puts it after.
version_is_after() {
    local first="$1" second="$2"
    [ "$first" != "$second" ] || return 1
    local first_core="${first%%-*}" second_core="${second%%-*}"
    if [ "$first_core" != "$second_core" ]; then
        [ "$(printf '%s\n%s\n' "$first_core" "$second_core" | sort -V | tail -n 1)" = "$first_core" ]
        return
    fi
    local first_suffix="${first#"$first_core"}" second_suffix="${second#"$second_core"}"
    [ -n "$first_suffix" ] || return 0
    [ -n "$second_suffix" ] || return 1
    [ "$(printf '%s\n%s\n' "$first_suffix" "$second_suffix" | sort -V | tail -n 1)" = "$first_suffix" ]
}

requested_version=""
DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        -*) fail "unknown argument: $1 (see --help)";;
        *)
            [ -z "$requested_version" ] || fail "more than one version given: $requested_version and $1"
            requested_version="$1"; shift;;
    esac
done

[ -f "$PIN_FILE" ] || fail "missing $PIN_FILE"

# The pinned version and frameworks, read the way FetchSourceEditorScript.sh reads them.
pinned_version=""
framework_names=()
while read -r key value; do
    case "$key" in
        ""|\#*) continue;;
        version) pinned_version="$value";;
        *) framework_names+=("$key");;
    esac
done < "$PIN_FILE"
[ -n "$pinned_version" ] || fail "$PIN_FILE names no version"
[ ${#framework_names[@]} -gt 0 ] || fail "$PIN_FILE names no frameworks"

command -v gh >/dev/null 2>&1 || unavailable "gh is not installed"
gh auth status --hostname github.com >/dev/null 2>&1 || unavailable "gh is not logged in to github.com"
gh repo view "$REPOSITORY" --json name >/dev/null 2>&1 || unavailable "gh cannot read $REPOSITORY (no read access?)"

if [ -n "$requested_version" ]; then
    gh release view "$requested_version" --repo "$REPOSITORY" --json tagName >/dev/null 2>&1 \
        || fail "$REPOSITORY has no release $requested_version"
    target_version="$requested_version"
else
    # The newest release on the pinned release's line, prereleases included — not GitHub's latest
    # release, which leaves prereleases out and so moved a pin of 27.2.0-alpha.1 back to 26.6.6.
    pinned_line="${pinned_version%%.*}"
    release_tags="$(gh release list --repo "$REPOSITORY" --limit 100 --json tagName,isDraft \
        --jq '.[] | select(.isDraft | not) | .tagName')" \
        || fail "could not list the releases of $REPOSITORY"
    target_version=""
    for tag in $release_tags; do
        [ "${tag%%.*}" = "$pinned_line" ] || continue
        if [ -z "$target_version" ] || version_is_after "$tag" "$target_version"; then
            target_version="$tag"
        fi
    done
    [ -n "$target_version" ] \
        || fail "$REPOSITORY has no release on the $pinned_line line of the pinned $pinned_version; name the version to move to"
    if version_is_after "$pinned_version" "$target_version"; then
        fail "the pinned $pinned_version is newer than $target_version, the newest release on its line; name the version to move to"
    fi
fi

# Every binary target the release's Package.swift declares, as "name checksum" lines.
manifest="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPOSITORY/contents/Package.swift?ref=$target_version")" \
    || fail "could not read the Package.swift of $target_version"
binary_targets="$(printf '%s\n' "$manifest" | tr '\n' ' ' \
    | grep -oE '\.binaryTarget\([^)]*\)' \
    | sed -nE 's/.*name: *"([^"]+)".*checksum: *"([0-9a-f]{64})".*/\1 \2/p' || true)"

new_checksums=()
for name in "${framework_names[@]}"; do
    checksum="$(printf '%s\n' "$binary_targets" | awk -v name="$name" '$1 == name { print $2; exit }')"
    [ -n "$checksum" ] || fail "the Package.swift of $target_version has no binary target $name with a checksum"
    new_checksums+=("$checksum")
done

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/UpdateSourceEditor.XXXXXX")"
new_pin_file="$work_directory/PinnedRelease.txt"
previous_pin_file="$work_directory/PreviousPinnedRelease.txt"

# Set while the pin file names a release that is not in place yet. Leaving then — a failed download
# or check, or an interruption — puts the previous pin back.
pin_file_replaced=false
finish() {
    if $pin_file_replaced; then
        cat "$previous_pin_file" > "$PIN_FILE"
        echo "error: SourceEditor $target_version could not be put in place, so $PIN_FILE_RELATIVE_PATH pins $pinned_version again" >&2
    fi
    rm -rf "$work_directory"
}
trap finish EXIT

# The version line and each framework's line rewritten; every other line as it was.
awk -v version="$target_version" -v names="${framework_names[*]}" -v checksums="${new_checksums[*]}" '
    BEGIN {
        count = split(names, name_list, " ")
        split(checksums, checksum_list, " ")
        for (position = 1; position <= count; position++) checksum_by_name[name_list[position]] = checksum_list[position]
    }
    $1 == "version" { print "version " version; next }
    $1 in checksum_by_name { print $1 " " checksum_by_name[$1]; next }
    { print }
' "$PIN_FILE" > "$new_pin_file"

# The Breaking section of the notes of every release after the pinned one, up to the target.
breaking_changes() {
    local tag notes
    while read -r tag; do
        [ -n "$tag" ] || continue
        version_is_after "$tag" "$pinned_version" || continue
        if version_is_after "$tag" "$target_version"; then continue; fi
        notes="$(gh release view "$tag" --repo "$REPOSITORY" --json body --jq .body 2>/dev/null | tr -d '\r' \
            | awk '/^## / { inside = ($0 ~ /^## Breaking/); next } inside && NF' || true)"
        [ -z "$notes" ] || printf 'Breaking changes in %s:\n%s\n' "$tag" "$notes"
    done < <(gh release list --repo "$REPOSITORY" --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null | sort -V || true)
}

report_breaking_changes() {
    local changes
    changes="$(breaking_changes || true)"
    if [ -n "$changes" ]; then
        printf '%s\n' "$changes"
    elif version_is_after "$target_version" "$pinned_version"; then
        log "No release after $pinned_version up to $target_version lists breaking changes"
    fi
}

if cmp -s "$PIN_FILE" "$new_pin_file"; then
    log "SourceEditor $target_version is already pinned"
    $DRY_RUN && exit 0
    "$FETCH_SCRIPT"
    exit 0
fi

if version_is_after "$pinned_version" "$target_version"; then
    log "$target_version is older than the pinned $pinned_version: moving back"
fi

if $DRY_RUN; then
    log "Would move SourceEditor $pinned_version to $target_version:"
    diff -u --label "$PIN_FILE_RELATIVE_PATH" --label "$PIN_FILE_RELATIVE_PATH (new)" "$PIN_FILE" "$new_pin_file" || true
    report_breaking_changes
    exit 0
fi

# Rewritten in place rather than replaced, so the file keeps its permissions. When the download
# fails, set -e leaves with its exit status, and finish puts the previous pin back.
cp "$PIN_FILE" "$previous_pin_file"
cat "$new_pin_file" > "$PIN_FILE"
pin_file_replaced=true
log "Pinned SourceEditor $target_version (was $pinned_version); downloading it"
"$FETCH_SCRIPT"
pin_file_replaced=false

release_url="$(gh release view "$target_version" --repo "$REPOSITORY" --json url --jq .url 2>/dev/null || true)"
log "SourceEditor $pinned_version -> $target_version${release_url:+: $release_url}"
report_breaking_changes
log "Next: build and run RuntimeViewerSourceEditorBridgeTests against it, then commit $PIN_FILE_RELATIVE_PATH"
