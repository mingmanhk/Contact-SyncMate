#!/bin/bash
# Point every ad-hoc CNContactStore() at the single shared instance.
#
# A CNContact belongs to the Core Data context of the store that fetched it, so
# mixing stores makes saves fail with 134092 "error during faulting". Leaving one
# stray CNContactStore() behind reintroduces the bug on whichever path uses it,
# so this is applied mechanically rather than by hand.
#
# MacContactsConnector.swift is excluded: it *declares* the shared instance.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Contact SyncMate"

for file in *.swift; do
    [ "$file" = "MacContactsConnector.swift" ] && continue
    grep -q 'CNContactStore()' "$file" || continue
    perl -pi -e 's/\bCNContactStore\(\)/MacContactsConnector.shared/g' "$file"
    echo "  rewrote $file"
done

echo "remaining ad-hoc stores:"
grep -rn 'CNContactStore()' *.swift | grep -v 'MacContactsConnector.swift' || echo "  none"
