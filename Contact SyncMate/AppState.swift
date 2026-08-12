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
///
/// `@MainActor` is explicit rather than inherited from the project's
/// default-isolation setting: every `@Published` property here feeds SwiftUI,
/// so main-actor confinement is part of this type's contract and must not
/// silently change when the build default does (e.g. a Swift 6 migration).
@MainActor
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

    /// Merges held back because the run was not user-reviewed and the match
    /// was never confirmed (`userOverride == nil`). Counted inside `skipped`;
    /// named so the UI can send the user to the sync preview to decide.
    var deferredMerges: Int = 0

    /// Contacts skipped because they have failed repeatedly. Counted inside
    /// `skipped`; named separately so the UI can point at the list rather than
    /// letting them vanish into an anonymous skip count.
    var setAside: Int = 0

    var successful: Bool {
        errors.isEmpty
    }

    /// What this run did, in one line.
    ///
    /// See `SyncOutcomeText` for why there is only one of these now.
    var summary: String {
        SyncOutcomeText.phrase(
            added: added, updated: updated, deleted: deleted, merged: merged,
            skipped: skipped, failed: errors.count, setAside: setAside,
            deletionsHeld: deferredDeletions, mergesHeld: deferredMerges)
    }
}

/// The single place sync counts become words.
///
/// There were three of these, and they disagreed. `SyncResult.summary` was
/// multi-line ("Added: 0, Updated: 21…\nFailed: 21"), `SyncResult.compactSummary`
/// was one line, and `SyncPhaseResult.summary` used diff notation (`+3, ~21,
/// -1`). Which one you saw depended on which object the view happened to hold —
/// and since `SyncPhaseResult` is what the dashboard banner gets, the notation
/// version is the one that shipped to the place people look when a sync fails.
/// A user asked what "sync error -21" meant. It meant twenty-one contacts were
/// updated.
///
/// Three formatters is how that happens: each was written for one call site,
/// none knew about the others, and no single one was ever wrong on its own
/// terms. So there is now one, every caller goes through it, and adding a new
/// counter means adding it here once.
///
/// Zero counts are omitted rather than printed. "Added: 0, Updated: 0,
/// Deleted: 0, Merged: 0, Skipped: 0" is five facts to read before learning
/// that nothing happened.
nonisolated enum SyncOutcomeText {
    static func phrase(added: Int = 0,
                       updated: Int = 0,
                       deleted: Int = 0,
                       merged: Int = 0,
                       skipped: Int = 0,
                       failed: Int = 0,
                       setAside: Int = 0,
                       deletionsHeld: Int = 0,
                       mergesHeld: Int = 0) -> String {
        // `String(localized:)` per fragment: this line shows in the dashboard
        // banner, the menu bar and the history log, and raw literals would pin
        // all three to English.
        var parts: [String] = []
        if added    > 0 { parts.append(String(localized: "\(added) added")) }
        if updated  > 0 { parts.append(String(localized: "\(updated) updated")) }
        if deleted  > 0 { parts.append(String(localized: "\(deleted) deleted")) }
        if merged   > 0 { parts.append(String(localized: "\(merged) merged")) }
        if skipped  > 0 { parts.append(String(localized: "\(skipped) skipped")) }
        if failed   > 0 { parts.append(String(localized: "\(failed) failed")) }
        if setAside > 0 { parts.append(String(localized: "\(setAside) set aside")) }
        if deletionsHeld > 0 {
            parts.append(String(localized: "\(deletionsHeld) deletions held for review"))
        }
        // The unconfirmed-merge gate is the safety feature most worth seeing
        // in a one-line record — omitting it hid exactly the deferrals the
        // engine went out of its way to make.
        if mergesHeld > 0 {
            parts.append(String(localized: "\(mergesHeld) merges awaiting decision"))
        }
        return parts.isEmpty ? String(localized: "No changes")
                             : parts.joined(separator: " · ")
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
