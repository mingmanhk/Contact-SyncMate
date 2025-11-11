//
//  AppState.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import Combine

/// Central app state observable object
class AppState: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncResult: SyncResult?
    @Published var syncProgress: SyncProgress?
    
    // Account connection states
    @Published var isGoogleConnected = false
    @Published var isMacContactsAuthorized = false
    
    // Current sync session
    @Published var currentSyncSession: SyncSession?
    
    init() {
        // Check authorization states on init
        checkAuthorizations()
    }
    
    private func checkAuthorizations() {
        // TODO: Check Mac Contacts authorization
        // TODO: Check Google OAuth status
    }
}

// MARK: - Supporting Types

struct SyncProgress {
    var currentStep: String
    var completedItems: Int
    var totalItems: Int
    var percentage: Double {
        guard totalItems > 0 else { return 0 }
        return Double(completedItems) / Double(totalItems)
    }
}

struct SyncResult {
    var mode: SyncMode
    var direction: SyncDirection
    var startTime: Date
    var endTime: Date
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    var added: Int
    var updated: Int
    var deleted: Int
    var merged: Int
    var skipped: Int
    var errors: [SyncError]
    
    var successful: Bool {
        errors.isEmpty
    }
    
    var summary: String {
        """
        Added: \(added), Updated: \(updated), Deleted: \(deleted), Merged: \(merged), Skipped: \(skipped)
        """
    }
}

struct SyncError: Identifiable {
    let id = UUID()
    let contactName: String?
    let message: String
    let timestamp: Date
}

struct SyncSession: Identifiable {
    let id = UUID()
    var mode: SyncMode
    var direction: SyncDirection
    var startTime: Date
    var contactChanges: [ContactChange]
}

struct ContactChange: Identifiable {
    let id = UUID()
    var contactName: String
    var action: SyncAction
    var direction: SyncDirection
    var changes: [String] // Human-readable change descriptions
    var userOverride: SyncAction? // User can override the planned action
}

enum SyncAction: String, CaseIterable {
    case add = "Add"
    case update = "Update"
    case delete = "Delete"
    case merge = "Merge"
    case skip = "Skip"
}
