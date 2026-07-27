//
//  SyncBackupIntegration.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  Integration layer between SyncEngine and BackupManager for automatic backup workflows
//
//  NOTE: The core backup calls (pre-sync and post-sync) are integrated directly into
//  SyncEngine.prepareManualSync() and SyncEngine.executeSync(). This file provides
//  additional backup utilities: rollback support and the BackupManagementViewModel.
//

import Foundation
@preconcurrency import Contacts
import Combine

// MARK: - Enhanced Sync Session with Backup Reference

extension SyncSession {
    /// Reference to backup sessions created during this sync
    struct BackupReferences {
        let preSyncBackupId: String? // Backup before any changes
        let postSyncBackupId: String? // Backup after changes applied
        let syncSessionId: String // Reference to this sync session
    }
}

// MARK: - Rollback Support

extension SyncEngine {

    /// Restore one contact to an earlier version, on the side it came from.
    ///
    /// `ContactBackupManager.restoreContactVersion` only decoded the snapshot back
    /// into a `UnifiedContact` — it wrote nothing anywhere, so per-contact history
    /// was captured on every sync and could never be acted on. This applies it.
    ///
    /// Scoped to a single contact on purpose: reverting one person's details is a
    /// far smaller decision than rolling both address books back, and it should
    /// not require the latter.
    @discardableResult
    func restoreContactVersion(_ version: ContactVersion) async throws -> String {
        guard let unified = ContactBackupManager.shared.restoreContactVersion(version) else {
            throw SyncEngineError.missingContactData(version.contactName)
        }

        switch version.source {
        case .google, .merged:
            guard let gID = unified.googleResourceName?.nonBlank else {
                throw SyncEngineError.missingContactData(version.contactName)
            }
            var google = GoogleContact(id: gID)
            ContactMapper.applyToGoogle(from: unified, to: &google)
            google.etag = googleConnector.knownETag(for: gID)
            _ = try await googleConnector.updateContact(google)

        case .mac:
            guard let mID = unified.macContactIdentifier?.nonBlank else {
                throw SyncEngineError.missingContactData(version.contactName)
            }
            let connector = macConnector
            try await MacContactsConnector.performWriteOffMain {
                guard let existing = try connector.fetchContactSync(withIdentifier: mID) else {
                    // Deleted since the backup — recreate rather than fail, which
                    // is the case where restoring a version matters most.
                    let fresh = ContactMapper.toMac(from: unified)
                    try connector.saveContactSync(fresh, to: nil)
                    return
                }
                let mutable = existing.mutableCopy() as! CNMutableContact
                ContactMapper.applyToMac(from: unified, to: mutable)
                try connector.updateContactSync(mutable)
            }
        }

        SyncHistory.shared.log(
            source: "SyncEngine",
            action: "contactVersion.restored",
            details: "\(version.contactName) → version \(version.versionNumber) (\(version.source.rawValue))"
        )

        return unified.displayName
    }

    /// Result of a rollback operation.
    struct RollbackResult {
        let restored: Int
        /// Contacts deleted because they did not exist in the backup.
        let removed: Int
        let failed: [(name: String, error: String)]
        var successful: Bool { failed.isEmpty }
    }

    /// What a rollback does about contacts added since the backup was taken.
    enum ExtraContactPolicy {
        /// Leave them. Safe, but the result is a *merge* of the backup and the
        /// current state, not the state the backup captured.
        case keep
        /// Delete them, so both address books end up exactly as the snapshot
        /// recorded. This is what "revert to this backup" normally means, and it
        /// is the only option that undoes contacts a bad sync created.
        case remove
    }

    /// Rollback to a previous backup state.
    ///
    /// Performs a best-effort restore by upserting every contact in the
    /// backup snapshot back to its original side:
    ///
    ///   • For each Google contact in the backup, attempt to update the
    ///     contact (matched by `googleResourceName`). If the contact no
    ///     longer exists, recreate it.
    ///   • For each Mac contact in the backup, look up by
    ///     `macContactIdentifier`; update if present, create otherwise.
    ///
    /// With `extras == .remove`, contacts absent from the backup are deleted, so
    /// both sides end up exactly as the snapshot recorded. Without it, a rollback
    /// cannot undo contacts a bad sync created — which is the main reason anyone
    /// reaches for a backup in the first place.
    ///
    /// A fresh safety backup is taken before anything is written, so the rollback
    /// itself can be rolled back.
    func rollbackToBackup(
        backupId: String,
        extras: ExtraContactPolicy = .keep
    ) async throws -> RollbackResult {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }

        guard let restored = ContactBackupManager.shared.restoreBackupSession(id: backupId) else {
            throw SyncEngineError.backupNotFound
        }

        // Snapshot the current state first. Restoring is destructive — especially
        // with `.remove` — and the user must be able to get back to where they
        // were if the backup turns out to be the wrong one.
        let liveGoogle = try await googleConnector.fetchAllContacts()
        let liveMac = try await macConnector.fetchAllContactsOffMainActor()
        let liveGoogleUnified = liveGoogle.map { ContactMapper.toUnified(from: $0) }
        let liveMacUnified = liveMac.map { ContactMapper.toUnified(from: $0) }

        _ = try? await ContactBackupManager.shared.createManualBackup(
            googleContacts: liveGoogleUnified,
            macContacts: liveMacUnified,
            customNotes: "Safety snapshot taken before restoring backup \(backupId)"
        )

        await MainActor.run {
            isRunning = true
            progress = SyncProgress(
                currentStep: "Restoring contacts from backup…",
                completedItems: 0,
                totalItems: restored.google.count + restored.mac.count
            )
        }

        defer {
            Task { @MainActor in
                isRunning = false
                progress = nil
            }
        }

        var restoredCount = 0
        var failed: [(name: String, error: String)] = []

        // ── Google side ────────────────────────────────────────────────
        for unified in restored.google {
            await MainActor.run {
                progress = SyncProgress(
                    currentStep: "Restoring \(unified.displayName)…",
                    completedItems: restoredCount,
                    totalItems: restored.google.count + restored.mac.count
                )
            }
            do {
                let googleContact = ContactMapper.toGoogle(from: unified)
                if unified.googleResourceName != nil {
                    // Try to update; if Google returns 404 (gone) recreate.
                    do {
                        _ = try await googleConnector.updateContact(googleContact)
                    } catch {
                        let nsErr = error as NSError
                        if nsErr.domain == "com.google.HTTPStatus" && nsErr.code == 404 {
                            _ = try await googleConnector.createContact(googleContact)
                        } else {
                            throw error
                        }
                    }
                } else {
                    _ = try await googleConnector.createContact(googleContact)
                }
                restoredCount += 1
            } catch {
                failed.append((unified.displayName, error.localizedDescription))
            }
        }

        // ── Mac side ───────────────────────────────────────────────────
        for unified in restored.mac {
            await MainActor.run {
                progress = SyncProgress(
                    currentStep: "Restoring \(unified.displayName)…",
                    completedItems: restoredCount,
                    totalItems: restored.google.count + restored.mac.count
                )
            }
            do {
                // Fetch the live record and mutate *that*, rather than mapping the
                // snapshot into a fresh CNMutableContact.
                //
                // The previous code assumed "CNMutableContact preserves the
                // identifier when present" — it does not. `ContactMapper.toMac`
                // allocates a new `CNMutableContact()`, which has a new identifier,
                // so `updateContact` could never match an existing record and every
                // contact fell through to `saveContact`. Combined with the snapshot
                // bug that left `macContactIdentifier` nil, a restore duplicated the
                // entire address book instead of reverting it.
                let connector = macConnector
                let existing = try unified.macContactIdentifier.flatMap {
                    try macConnector.fetchContact(withIdentifier: $0)
                }

                if let existing {
                    let mutable = existing.mutableCopy() as! CNMutableContact
                    ContactMapper.applyToMac(from: unified, to: mutable)
                    try await MacContactsConnector.performWriteOffMain {
                        try connector.updateContactSync(mutable)
                    }
                } else {
                    // The contact was deleted since the backup — recreate it.
                    let macContact = ContactMapper.toMac(from: unified)
                    try await MacContactsConnector.performWriteOffMain {
                        try connector.saveContactSync(macContact, to: nil)
                    }
                }
                restoredCount += 1
            } catch {
                failed.append((unified.displayName, error.localizedDescription))
            }
        }

        // ── Remove contacts the backup does not contain ────────────────
        //
        // Without this a "restore" is really a merge: everything a bad sync added
        // survives it. Matching is by identifier — the same one the backup stored
        // — so a contact is only deleted when it demonstrably was not part of the
        // snapshot.
        var removedCount = 0

        if case .remove = extras {
            let backupGoogleIDs = Set(restored.google.compactMap(\.googleResourceName))
            let backupMacIDs = Set(restored.mac.compactMap(\.macContactIdentifier))

            for contact in liveGoogleUnified {
                guard let gID = contact.googleResourceName,
                      !backupGoogleIDs.contains(gID) else { continue }
                do {
                    try await googleConnector.deleteContact(resourceName: gID)
                    mappingStore.deleteMapping(googleResourceName: gID)
                    removedCount += 1
                } catch {
                    failed.append((contact.displayName, error.localizedDescription))
                }
            }

            let connector = macConnector
            for contact in liveMacUnified {
                guard let mID = contact.macContactIdentifier,
                      !backupMacIDs.contains(mID) else { continue }
                do {
                    try await MacContactsConnector.performWriteOffMain {
                        try connector.deleteContactSync(withIdentifier: mID)
                    }
                    removedCount += 1
                } catch {
                    failed.append((contact.displayName, error.localizedDescription))
                }
            }
        }

        // Log outcome
        SyncHistory.shared.log(
            source: "SyncEngine",
            action: failed.isEmpty ? "rollback.success" : "rollback.partial",
            details: "Backup \(backupId): restored \(restoredCount), removed \(removedCount), failed \(failed.count)"
        )

        return RollbackResult(restored: restoredCount, removed: removedCount, failed: failed)
    }
}

// MARK: - Backup Recovery View Support

/// View model for backup management UI
class BackupManagementViewModel: ObservableObject {
    @Published var backupSessions: [BackupSession] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let backupManager = ContactBackupManager.shared

    func loadBackups() {
        backupSessions = backupManager.getAllBackupSessions()
    }

    func deleteBackup(id: String) {
        // Filter out the backup
        backupSessions.removeAll { $0.id == id }
    }

    func exportBackup(id: String) -> Data? {
        return backupManager.exportBackupSession(id: id)
    }

    func getStats() -> ContactBackupManager.BackupStats {
        return backupManager.getBackupStats()
    }

    func restoreBackup(id: String) async -> SyncEngine.RollbackResult? {
        isLoading = true
        defer { isLoading = false }

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore()
        )
        do {
            let result = try await engine.rollbackToBackup(backupId: id)
            SyncHistory.shared.log(
                source: "BackupManagement",
                action: result.successful ? "restore.success" : "restore.partial",
                details: "Backup \(id): \(result.restored) restored, \(result.failed.count) failed"
            )
            return result
        } catch {
            self.error = error
            SyncHistory.shared.log(
                source: "BackupManagement",
                action: "restore.failed",
                details: error.localizedDescription
            )
            return nil
        }
    }
}
