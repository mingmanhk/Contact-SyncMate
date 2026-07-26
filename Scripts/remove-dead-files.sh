#!/bin/bash
# Delete files an audit verified as entirely unreferenced.
#
# Each was checked for references across the app target AND the test target; the
# only hits were inside the file itself or its own #Preview. Removing them is
# behaviour-preserving.
#
# NOT removed, deliberately:
#   SyncBackupIntegration.swift — also unreferenced, but it holds
#   SyncEngine.rollbackToBackup, the only working restore implementation in the
#   codebase. The Restore button is currently wired to a log-only stub. Deleting
#   this would destroy the code that needs to be wired up instead.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Contact SyncMate"

DEAD=(
    # 313 lines: a long comment plus fileprivate examples nothing calls.
    "DeduplicationScoringReference.swift"
    # 364 lines: header says "Example integration". Its merge helpers also
    # delete duplicates without merging their fields — a data-loss path one call
    # site away from being live.
    "SyncEngineDeduplicationIntegration.swift"
    # 271 lines: view never instantiated; owns 6 dead dedup.* UserDefaults keys
    # that duplicate the live AI-matching settings.
    "DeduplicationSettingsView.swift"
    # 364 lines: view never instantiated.
    "BackupComparisonView.swift"
    # 72 lines: referenced only by its own #Preview.
    "Components/SyncProgressView.swift"
    # 25 lines: People API rejects API keys outright, so this was never usable.
    "GoogleAPIConfig.swift"
)

for file in "${DEAD[@]}"; do
    if [ -f "$file" ]; then
        rm "$file"
        echo "  removed $file"
    else
        echo "  already gone: $file"
    fi
done
