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

    func restoreBackup(_ backup: BackupSession) {
        isRestoring = true
        restoreError = nil
        restoreSuccess = false

        Task {
            // This would integrate with your SyncEngine
            // For now, we just log the action
            SyncHistory.shared.log(
                source: "SyncHistoryViewModel",
                action: "restore_backup_initiated",
                details: "Backup \(backup.id) - \(backup.contactVersions.count) contacts"
            )

            await MainActor.run {
                self.isRestoring = false
                self.restoreSuccess = true
            }

            // Refresh after restore
            loadHistory()
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
