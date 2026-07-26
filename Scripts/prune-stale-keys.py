#!/usr/bin/env python3
"""Remove catalog keys that no longer exist in source.

`xcstringstool sync` marks vanished keys stale rather than deleting them, and
entries this project created with extractionState "manual" are never pruned at
all. A leftover key is normally harmless, but two keys whose generated symbols
collide ("Clear Log" vs "Clear Log…" both become `clearLog`) fail the build, so
stale manual entries have to be cleared out deliberately.
"""

import json
import pathlib
import sys

CATALOG = pathlib.Path("Contact SyncMate/Localizable.xcstrings")

# Keys removed from source; listed explicitly so pruning is never guesswork.
STALE = [
    "Clear Log",
]


def main() -> int:
    if not CATALOG.exists():
        print(f"error: {CATALOG} not found — run from the repo root", file=sys.stderr)
        return 1

    catalog = json.loads(CATALOG.read_text())
    removed = [key for key in STALE if catalog["strings"].pop(key, None) is not None]

    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"pruned: {removed if removed else 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
