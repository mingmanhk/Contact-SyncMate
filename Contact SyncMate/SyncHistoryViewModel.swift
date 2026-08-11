//
//  SyncHistoryViewModel.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  View model for managing sync history and backup operations
//

import Foundation
import Combine

class SyncHistoryViewModel: ObservableObject {
    @Published var syncEvents: [SyncEvent] = []
    @Published var groupedEvents: [Date: [SyncEvent]] = [:]
    @Published var isRestoring = false
    @Published var restoreError: Error?
    @Published var restoreSuccess = false

    private let backupManager = ContactBackupManager.shared
    private var refreshTimer: Timer?

    init() {
        loadHistory()
        // Set up periodic refresh with proper lifecycle management
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.loadHistory()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    func loadHistory() {
        let events = SyncHistory.shared.events()
        DispatchQueue.main.async {
            self.syncEvents = events

            // Group by date
            var grouped: [Date: [SyncEvent]] = [:]
            for event in events {
                let calendar = Calendar.current
                let dateComponents = calendar.dateComponents([.year, .month, .day], from: event.timestamp)
                let date = calendar.date(from: dateComponents) ?? event.timestamp

                if grouped[date] != nil {
                    grouped[date]?.append(event)
                } else {
                    grouped[date] = [event]
                }
            }

            self.groupedEvents = grouped
        }
    }

    func refresh() {
        loadHistory()
    }

    /// Roll both address books back to the state captured in `backup`.
    ///
    /// This used to log "restore_backup_initiated" and then set
    /// `restoreSuccess = true` without touching a single contact — so a user who
    /// had just lost data would be told the restore worked when nothing had
    /// happened. It now drives `SyncEngine.rollbackToBackup`, the real
    /// implementation, and reports what actually succeeded.
    func restoreBackup(_ backup: BackupSessionSummary,
                       extras: SyncEngine.ExtraContactPolicy = .keep) {
        isRestoring = true
        restoreError = nil
        restoreSuccess = false

        Task { @MainActor in
            defer { isRestoring = false }

            let engine = SyncEngine(
                googleConnector: GoogleContactsConnector(),
                macConnector: MacContactsConnector(),
                mappingStore: ContactMappingStore.shared
            )

            do {
                let result = try await engine.rollbackToBackup(backupId: backup.id,
                                                              extras: extras)

                // A partial restore is not a success. Saying so is the whole
                // point of a restore feature: the user needs to know which
                // contacts did not come back.
                SyncHistory.shared.log(
                    source: "SyncHistoryViewModel",
                    action: "restore.finished",
                    details: "restored \(result.restored), removed \(result.removed), failed \(result.failed.count)"
                )

                if result.failed.isEmpty {
                    restoreSuccess = true
                } else {
                    let names = result.failed.prefix(3).map(\.name).joined(separator: ", ")
                    let more = result.failed.count > 3 ? " and \(result.failed.count - 3) more" : ""
                    restoreError = RestoreError.partial(
                        restored: result.restored,
                        failed: result.failed.count,
                        detail: "\(names)\(more)"
                    )
                }
            } catch {
                restoreError = error
                SyncHistory.shared.log(source: "SyncHistoryViewModel",
                                       action: "restore.failed",
                                       details: error.localizedDescription)
            }

            loadHistory()
        }
    }

    enum RestoreError: LocalizedError {
        case partial(restored: Int, failed: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case let .partial(restored, failed, detail):
                return String(
                    format: NSLocalizedString(
                        "Restored %lld contacts, but %lld could not be restored: %@",
                        comment: "Partial backup restore result"
                    ),
                    restored, failed, detail
                )
            }
        }
    }

    func getVersionHistory(for contactIdentifier: String) -> [ContactVersion] {
        return backupManager.getVersionHistory(for: contactIdentifier)
    }

    func compareVersions(version1: ContactVersion, version2: ContactVersion) -> [VersionDifference] {
        var differences: [VersionDifference] = []

        // Compare names
        if version1.data.displayName != version2.data.displayName {
            differences.append(VersionDifference(
                field: "Display Name",
                oldValue: version1.data.displayName,
                newValue: version2.data.displayName
            ))
        }

        // Compare phone numbers
        if version1.data.phoneNumbers != version2.data.phoneNumbers {
            differences.append(VersionDifference(
                field: "Phone Numbers",
                oldValue: version1.data.phoneNumbers.count.description,
                newValue: version2.data.phoneNumbers.count.description
            ))
        }

        // Compare email addresses
        if version1.data.emailAddresses != version2.data.emailAddresses {
            differences.append(VersionDifference(
                field: "Email Addresses",
                oldValue: version1.data.emailAddresses.count.description,
                newValue: version2.data.emailAddresses.count.description
            ))
        }

        // Compare organization
        if version1.data.organization != version2.data.organization {
            differences.append(VersionDifference(
                field: "Organization",
                oldValue: version1.data.organization ?? "None",
                newValue: version2.data.organization ?? "None"
            ))
        }

        return differences
    }
}

// MARK: - Data Models

struct VersionDifference {
    let field: String
    let oldValue: String
    let newValue: String
}

// MARK: - Extension for ContactSnapshot comparison

extension Array where Element == ContactSnapshot.PhoneSnapshot {
    static func == (lhs: [ContactSnapshot.PhoneSnapshot], rhs: [ContactSnapshot.PhoneSnapshot]) -> Bool {
        return lhs.count == rhs.count &&
            zip(lhs, rhs).allSatisfy { $0.value == $1.value && $0.label == $1.label }
    }
}

extension Array where Element == ContactSnapshot.EmailSnapshot {
    static func == (lhs: [ContactSnapshot.EmailSnapshot], rhs: [ContactSnapshot.EmailSnapshot]) -> Bool {
        return lhs.count == rhs.count &&
            zip(lhs, rhs).allSatisfy { $0.value == $1.value && $0.label == $1.label }
    }
}
