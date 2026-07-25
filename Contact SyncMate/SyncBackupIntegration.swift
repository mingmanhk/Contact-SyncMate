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

    /// Result of a rollback operation.
    struct RollbackResult {
        let restored: Int
        let failed: [(name: String, error: String)]
        var successful: Bool { failed.isEmpty }
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
    /// **Limitation:** This does NOT delete contacts that were *added*
    ///  after the backup was taken (it cannot tell new vs. moved). To do a
    ///  full delete-on-rollback you would diff the current snapshot against
    ///  the backup snapshot and issue deletes for the difference; that is
    ///  intentionally not done here to avoid destructive surprises.
    func rollbackToBackup(backupId: String) async throws -> RollbackResult {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }

        guard let restored = ContactBackupManager.shared.restoreBackupSession(id: backupId) else {
            throw SyncEngineError.backupNotFound
        }

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
                let macContact = ContactMapper.toMac(from: unified)
                if unified.macContactIdentifier != nil {
                    // CNMutableContact preserves the identifier when present;
                    // updateContact will throw if the identifier is no longer
                    // valid, in which case we save as new.
                    do {
                        try macConnector.updateContact(macContact)
                    } catch {
                        try macConnector.saveContact(macContact)
                    }
                } else {
                    try macConnector.saveContact(macContact)
                }
                restoredCount += 1
            } catch {
                failed.append((unified.displayName, error.localizedDescription))
            }
        }

        // Log outcome
        SyncHistory.shared.log(
            source: "SyncEngine",
            action: failed.isEmpty ? "rollback.success" : "rollback.partial",
            details: "Backup \(backupId): restored \(restoredCount), failed \(failed.count)"
        )

        return RollbackResult(restored: restoredCount, failed: failed)
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
