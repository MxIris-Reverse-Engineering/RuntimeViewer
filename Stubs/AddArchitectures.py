#!/usr/bin/env python3
"""Declares the stub for architectures the local Xcode's binary does not carry.

`tapi stubify` records only the slices present in the framework it read, and the Xcode
installed here ships SourceEditor and friends as arm64 alone. Linking the bridge for
x86_64 against such a stub fails at the module-resolution step, long before any symbol
is looked up — so a Mac Catalyst-era Intel machine could not build the bridge at all,
even though the *user's* Xcode may well carry an x86_64 slice for it to dlopen at run
time. Which slices the bridge can load is a property of the machine it runs on, not of
the machine it was built on, so the stub has to describe every architecture we are
willing to build for.

This is sound because the stub is a link-time contract only. Swift mangled names do not
encode the architecture, none of these .tbd files qualifies a symbol section per target,
and nothing is dlopened until run time — where a slice that is genuinely missing simply
fails to load and the app falls back to its own text view.

Usage: AddArchitectures.py <tbd> <arch-macos> [<arch-macos> ...]
"""

import json
import sys


def add_architectures(tbd_path: str, wanted_targets: list) -> None:
    with open(tbd_path, encoding="utf-8") as handle:
        document = json.load(handle)

    library = document.get("main_library")
    if library is None:
        libraries = document.get("libraries") or []
        library = libraries[0] if libraries else None
    if library is None:
        raise SystemExit(f"{tbd_path}: no library section")

    target_info = library["target_info"]
    present = {entry["target"] for entry in target_info}
    # Every entry carries the same deployment target; reuse it rather than inventing one.
    minimum_deployment = target_info[0]["min_deployment"]

    added = []
    for target in wanted_targets:
        if target in present:
            continue
        target_info.append({"min_deployment": minimum_deployment, "target": target})
        added.append(target)

    if not added:
        return

    with open(tbd_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, separators=(",", ":"))
        handle.write("\n")

    print(f"  added {', '.join(added)}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    add_architectures(sys.argv[1], sys.argv[2:])
