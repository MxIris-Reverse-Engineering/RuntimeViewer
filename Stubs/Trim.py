#!/usr/bin/env python3
"""Shrinks a tapi-generated .tbd down to the symbols we actually link against.

`tapi stubify` emits every exported symbol, which for SourceEditor is close to a megabyte
of text. Everything past the handful the bridge references is noise in review and in diffs,
so keep only what is listed in the framework's UsedSymbols.txt.

Regenerate that list from the linked bridge binary:

    nm -u path/to/RuntimeViewerSourceEditorBridge | sed 's/^ *//' | sort -u > UsedSymbols.txt

Usage: Trim.py <tbd> <used-symbols-file>
"""

import json
import sys


def trim(tbd_path: str, used_symbols_path: str) -> None:
    with open(used_symbols_path, encoding="utf-8") as handle:
        wanted = {line.strip() for line in handle if line.strip()}

    with open(tbd_path, encoding="utf-8") as handle:
        document = json.load(handle)

    kept_total = 0
    dropped_total = 0
    for library_key in ("main_library", "libraries"):
        libraries = document.get(library_key)
        if libraries is None:
            continue
        for library in libraries if isinstance(libraries, list) else [libraries]:
            for section in library.get("exported_symbols", []):
                data = section.get("data")
                if not isinstance(data, dict):
                    continue
                for category, symbols in list(data.items()):
                    if not isinstance(symbols, list):
                        continue
                    kept = [symbol for symbol in symbols if symbol in wanted]
                    dropped_total += len(symbols) - len(kept)
                    kept_total += len(kept)
                    if kept:
                        data[category] = kept
                    else:
                        del data[category]

    missing = wanted - _all_symbols(document)
    if missing:
        print(f"  warning: {len(missing)} referenced symbols absent from the .tbd", file=sys.stderr)
        for symbol in sorted(missing)[:10]:
            print(f"    {symbol}", file=sys.stderr)

    with open(tbd_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, separators=(",", ":"))
        handle.write("\n")

    print(f"  kept {kept_total} symbols, dropped {dropped_total}")


def _all_symbols(document) -> set:
    found = set()
    for library_key in ("main_library", "libraries"):
        libraries = document.get(library_key)
        if libraries is None:
            continue
        for library in libraries if isinstance(libraries, list) else [libraries]:
            for section in library.get("exported_symbols", []):
                data = section.get("data")
                if isinstance(data, dict):
                    for symbols in data.values():
                        if isinstance(symbols, list):
                            found.update(symbols)
    return found


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    trim(sys.argv[1], sys.argv[2])
