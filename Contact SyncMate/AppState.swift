//
//  AppState.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import Combine
import Contacts

/// Central app state observable object
class AppState: ObservableObject {
    @Published var isSyncing = false

    /// When the last sync finished — persisted, not just remembered.
    ///
    /// This drives the "Never synced" / "Last synced …" line everywhere. It used
    /// to live only in memory, so it reset on every launch: the app would report
    /// Never synced while the history window listed hundreds of events from that
    /// same afternoon. The sync log is on disk; the one fact summarising it was
    /// not.
    /// `Self` is not usable in a stored-property initialiser on a non-final
    /// class, so the key is spelled out here and named once below.
    @Published var lastSyncDate: Date? = UserDefaults.standard
        .object(forKey: "lastSyncDate") as? Date {
        didSet { UserDefaults.standard.set(lastSyncDate, forKey: Self.lastSyncDateKey) }
    }
    static let lastSyncDateKey = "lastSyncDate"

    /// Not persisted, on purpose. A `SyncResult` describes one run in detail and
    /// is only meaningful next to the progress UI that produced it; the history
    /// window is where past runs are read. Only the date outlives the session.
    @Published var lastSyncResult: SyncResult?
    @Published var syncProgress: SyncProgress?

    // Account connection states
    @Published var isGoogleConnected = false
    @Published var isMacContactsAuthorized = false

    // Current sync session
    @Published var currentSyncSession: SyncSession?

    // Auto-sync scheduling
    @Published var nextScheduledSync: Date?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Seed initial values
        isMacContactsAuthorized = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        isGoogleConnected = GoogleOAuthManager.shared.isAuthenticated

        // Keep isGoogleConnected in sync with the OAuth manager for the lifetime of
        // the app — sign-in, token refresh, and sign-out all update this automatically.
        GoogleOAuthManager.shared.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .assign(to: \.isGoogleConnected, on: self)
            .store(in: &cancellables)

        // Re-check Contacts authorisation whenever the app becomes active
        // (user may have changed it in System Settings while the app was running).
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isMacContactsAuthorized =
                    CNContactStore.authorizationStatus(for: .contacts) == .authorized
            }
            .store(in: &cancellables)
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

    /// Deletions held back because the run was not user-reviewed and
    /// "Ask before deleting contacts" is on. Counted inside `skipped` as well;
    /// this names *why* they were skipped so the UI can offer a review.
    var deferredDeletions: Int = 0

    var successful: Bool {
        errors.isEmpty
    }

    var summary: String {
        var text = """
        Added: \(added), Updated: \(updated), Deleted: \(deleted), Merged: \(merged), Skipped: \(skipped)
        """
        if deferredDeletions > 0 {
            text += "\nHeld back for review: \(deferredDeletions) deletion"
                 + (deferredDeletions == 1 ? "" : "s")
        }
        return text
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
    var syncSessionId: String?  // Reference for backup linkage
    var mode: SyncMode
    var direction: SyncDirection
    var startTime: Date
    var contactChanges: [ContactChange]

    /// True once the user has seen these changes and pressed Apply.
    ///
    /// Read by `SyncEngine` for the "Ask before deleting contacts" setting: an
    /// unreviewed run records what it would delete and leaves it, rather than
    /// deleting on a schedule with nobody watching. Additions and updates are
    /// recoverable from a backup; deletions across two address books are the
    /// change users actually get hurt by.
    var userReviewed: Bool = false
}

struct ContactChange: Identifiable {
    let id = UUID()
    var contactName: String
    var action: SyncAction
    var direction: SyncDirection
    var changes: [String]          // Human-readable change descriptions
    var userOverride: SyncAction?  // User can override the planned action

    // Full contact references — populated during diff, used during apply
    var sourceContact: UnifiedContact?   // The contact to read from
    var targetContact: UnifiedContact?   // The contact to update (for updates/deletes)
}

enum SyncAction: String, CaseIterable {
    case add = "Add"
    case update = "Update"
    case delete = "Delete"
    case merge = "Merge"
    case skip = "Skip"
}
