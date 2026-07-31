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
#
# These reappear on their own: DerivedData keeps a `.stringsdata` per source
# file, an incremental build only regenerates the ones it recompiled, and
# `xcstringstool sync` reads all of them — so a string deleted from a file that
# was not rebuilt is re-added to the catalog from the stale sidecar. Deleting it
# from the catalog by hand does not stick; it has to be listed here.
STALE = [
    "Clear Log",
    # Renamed to "Reset Everything" — the qualifier implied it was for testing
    # only, when it is simply the full reset.
    "Reset Everything for Testing",
    "Reset Settings Only restores preferences. Reset Everything for Testing "
    "also clears contact mappings, the sync log and onboarding, so the next "
    "sync starts from scratch. Neither touches your contacts, your backups or "
    "your Google sign-in.",
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
