#!/bin/bash
# Drop imports whose symbols the file never uses.
#
# Each was verified by grepping the file for any symbol the module provides —
# UTType for UniformTypeIdentifiers, and Combine's own types (AnyCancellable,
# PassthroughSubject, Publisher, Future, Just) for Combine. @Published and
# ObservableObject come through SwiftUI's re-export, so files importing SwiftUI
# do not need Combine for those alone.
#
# The build is the check: if a removal was wrong, compilation fails immediately.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Contact SyncMate"

drop() {
    local file="$1" import="$2"
    [ -f "$file" ] || { echo "  skip (missing): $file"; return; }
    perl -ni -e "print unless /^import \Q$import\E\s*(\/\/.*)?\$/" "$file"
    echo "  $file: dropped $import"
}

drop ContactBackupManager.swift UniformTypeIdentifiers
drop SyncHistoryView.swift Combine
drop SyncEngine.swift SwiftUI
drop MenuBarView.swift Combine
drop AppSettings.swift Combine
