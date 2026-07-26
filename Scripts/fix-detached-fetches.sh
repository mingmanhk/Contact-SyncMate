#!/bin/bash
# Rewrite the Task.detached contact fetches to the nonisolated helper.
#
# Constructing MacContactsConnector inside Task.detached is main-actor work,
# which Swift 6 rejects. fetchAllContactsOffMain is nonisolated and uses the
# shared store, so the detached task needs neither an instance nor an actor hop.
#
# Applied mechanically because the same two-line pattern repeats at four call
# sites and hand-editing invites missing one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Contact SyncMate"

perl -0777 -pi -e '
    s/let connector = MacContactsConnector\(\)\n(\s*)let contacts = try connector\.fetchAllContacts\(\)/let contacts = try MacContactsConnector.fetchAllContactsOffMain()/g;
    s/let connector = MacContactsConnector\(\)\n(\s*)let contacts = try connector\.fetchAllContacts\(in: ([^)]*)\)/let contacts = try MacContactsConnector.fetchAllContactsOffMain(in: $2)/g;
' SettingsView.swift

echo "remaining detached connector constructions:"
grep -n 'MacContactsConnector()' SettingsView.swift || echo "  none"
