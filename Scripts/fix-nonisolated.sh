#!/bin/bash
# Mark the thread-safe members nonisolated and quiet the Contacts Sendable noise.
#
# Background: this project builds with default MainActor isolation, so members
# that are genuinely safe off the main actor still get inferred as isolated.
# SyncHistory synchronises with its own barrier queue and MacContactsConnector's
# diagnose/writeQueue touch no shared mutable state, so the isolation is wrong
# rather than protective — and it blocks logging from the Contacts write queue.
#
# CNMutableContact is not Sendable and never will be; @preconcurrency on the
# Contacts import is the sanctioned way to accept that for a type we hand to a
# serial queue and do not touch again.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Contact SyncMate"

perl -pi -e 's/^(\s*)public func (log|events|clear)\(/$1public nonisolated func $2(/' SyncHistory.swift
perl -pi -e 's/^(\s*)static func diagnose\(/$1nonisolated static func diagnose(/' MacContactsConnector.swift
perl -pi -e 's/nonisolated\(unsafe\) private static let writeQueue/private nonisolated static let writeQueue/' MacContactsConnector.swift

for file in SyncEngine.swift MacContactsConnector.swift; do
    perl -pi -e 's/^import Contacts$/\@preconcurrency import Contacts/' "$file"
done

echo "SyncHistory nonisolated members:"
grep -n 'nonisolated func' SyncHistory.swift || true
echo "preconcurrency imports:"
grep -ln 'preconcurrency import Contacts' *.swift || true
