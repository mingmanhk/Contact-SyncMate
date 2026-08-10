//
//  ContactBackupManager.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  Comprehensive backup and versioning system for contacts with full rollback capability
//

import Foundation
import Contacts
import UniformTypeIdentifiers  // UTType.json for the backup export panel
import Combine
import AppKit

// MARK: - Data Models

/// Represents a single contact version snapshot
struct ContactVersion: Codable, Identifiable {
    let id: String // UUID
    let contactIdentifier: String // Google resourceName or Mac identifier
    let contactName: String
    let versionNumber: Int
    let timestamp: Date
    let syncSessionId: String // Link to sync session
    let source: ContactSource // Where it came from
    let data: ContactSnapshot // The actual contact data
    let changesSummary: [String] // Human-readable changes from previous version

    enum ContactSource: String, Codable {
        case google
        case mac
        case merged
    }
}

/// Lightweight snapshot of contact data for versioning
struct ContactSnapshot: Codable {
    let displayName: String
    let givenName: String?
    let familyName: String?
    let middleName: String?
    let phoneNumbers: [PhoneSnapshot]
    let emailAddresses: [EmailSnapshot]
    let postalAddresses: [AddressSnapshot]
    let organization: String?
    let jobTitle: String?
    let notes: String?
    let imageData: Data? // Optional photo
    let customFields: [String: String]

    // MARK: Fields added after the first release
    //
    // A snapshot is only as good as what it captured: these were missing, so a
    // restore pushed empty values for them — and because the Google update mask
    // includes urls, birthdays and nicknames, restoring actively *erased* those
    // fields from every contact it touched.
    //
    // All optional so backups written by earlier builds still decode: Swift's
    // synthesised Codable treats a missing key for an Optional as nil rather
    // than a decoding failure.
    let namePrefix: String?
    let nameSuffix: String?
    let nickname: String?
    let phoneticGivenName: String?
    let phoneticMiddleName: String?
    let phoneticFamilyName: String?
    let department: String?
    let urls: [URLSnapshot]?
    let birthday: DateComponents?

    /// Identifier on the *other* side, when the contact was linked at capture
    /// time. Lets a restore put a Mac contact back by its Mac identifier instead
    /// of guessing — see `snapshotToUnifiedContact`.
    let googleResourceName: String?
    let macContactIdentifier: String?

    struct URLSnapshot: Codable, Equatable {
        let label: String?
        let value: String
    }

    struct PhoneSnapshot: Codable, Equatable {
        let label: String?
        let value: String
    }

    struct EmailSnapshot: Codable, Equatable {
        let label: String?
        let value: String
    }

    struct AddressSnapshot: Codable, Equatable {
        let label: String?
        let street: String?
        let city: String?
        let state: String?
        let postalCode: String?
        let country: String?
    }
}

/// Complete backup session snapshot
struct BackupSession: Codable, Identifiable {
    let id: String // UUID
    let timestamp: Date
    let syncSessionId: String?
    let type: BackupType
    let googleContactsCount: Int
    let macContactsCount: Int
    var contactVersions: [ContactVersion]
    let metadata: BackupMetadata

    enum BackupType: String, Codable {
        case preSyncBackup // Before any sync operation
        case postSyncBackup // After successful sync
        case manualBackup // User-initiated backup
        case autoBackup // Automatic scheduled backup
    }
}

/// Metadata for backup session
struct BackupMetadata: Codable {
    let appVersion: String
    let syncDirection: String? // 2-way, Google→Mac, Mac→Google
    let syncMode: String? // manual, automatic
    let autoResolution: String?
    let customNotes: String?
}

// MARK: - Backup Manager

/// Manages contact backups and versions with full rollback capability
class ContactBackupManager: ObservableObject {
    static let shared = ContactBackupManager()

    @Published var lastBackupDate: Date?
    @Published var backupCount: Int = 0
    @Published var totalBackupSize: Int64 = 0

    private let fileManager = FileManager.default
    private let backupQueue = DispatchQueue(label: "ContactBackupManager.queue", attributes: .concurrent)
    private var backupSessions: [BackupSession] = []

    private let appVersion = "1.0.0" // Should match app version
    // Retention is driven by AppSettings.maxBackupCount (Settings → Backups →
    // "Keep at most"). The former `maxBackupSessions`/`maxVersionsPerContact`
    // constants disagreed with both that setting and each other, and neither was
    // ever read — three limits, none enforced.

    /// UserDefaults key for custom backup directory
    private static let backupDirectoryKey = "customBackupDirectory"

    /// The user-configured backup directory path (persisted in UserDefaults)
    @Published var customBackupPath: String? {
        didSet {
            UserDefaults.standard.set(customBackupPath, forKey: Self.backupDirectoryKey)
        }
    }

    init() {
        customBackupPath = UserDefaults.standard.string(forKey: Self.backupDirectoryKey)
        loadBackupIndex()

        // Apply retention on launch as well as after each backup: a limit lowered
        // in Settings should take effect without waiting for the next sync, and
        // existing installs carry files earlier builds orphaned.
        pruneOldBackups()
        removeOrphanedBackupFiles()
    }

    // MARK: - Public API

    /// Create a pre-sync backup before any changes are made
    func createPreSyncBackup(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        syncSessionId: String,
        syncDirection: String,
        syncMode: String
    ) async throws -> BackupSession {
        let backupSession = BackupSession(
            id: UUID().uuidString,
            timestamp: Date(),
            syncSessionId: syncSessionId,
            type: .preSyncBackup,
            googleContactsCount: googleContacts.count,
            macContactsCount: macContacts.count,
            contactVersions: [],
            metadata: BackupMetadata(
                appVersion: appVersion,
                syncDirection: syncDirection,
                syncMode: syncMode,
                autoResolution: nil,
                customNotes: "Automatic backup before sync operation"
            )
        )

        let versions = await captureContactVersions(
            googleContacts: googleContacts,
            macContacts: macContacts,
            backupSessionId: backupSession.id,
            syncSessionId: syncSessionId
        )

        var sessionWithVersions = backupSession
        sessionWithVersions.contactVersions = versions

        // A pre-sync backup failure used to abort the whole sync: with a full
        // or read-only custom backup folder the user could never sync again,
        // and the error said nothing about why. Falling back to the container
        // directory keeps the safety net *and* the sync; only a failure of
        // both locations still throws.
        try saveBackupSession(sessionWithVersions, allowContainerFallback: true)

        return sessionWithVersions
    }

    /// Create a post-sync backup after changes were applied
    func createPostSyncBackup(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        syncSessionId: String,
        changesSummary: String
    ) async throws -> BackupSession {
        let backupSession = BackupSession(
            id: UUID().uuidString,
            timestamp: Date(),
            syncSessionId: syncSessionId,
            type: .postSyncBackup,
            googleContactsCount: googleContacts.count,
            macContactsCount: macContacts.count,
            contactVersions: [],
            metadata: BackupMetadata(
                appVersion: appVersion,
                syncDirection: nil,
                syncMode: nil,
                autoResolution: nil,
                customNotes: changesSummary
            )
        )

        let versions = await captureContactVersions(
            googleContacts: googleContacts,
            macContacts: macContacts,
            backupSessionId: backupSession.id,
            syncSessionId: syncSessionId
        )

        var sessionWithVersions = backupSession
        sessionWithVersions.contactVersions = versions

        try saveBackupSession(sessionWithVersions)

        return sessionWithVersions
    }

    /// Create a manual user-initiated backup
    func createManualBackup(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        customNotes: String? = nil
    ) async throws -> BackupSession {
        let backupSession = BackupSession(
            id: UUID().uuidString,
            timestamp: Date(),
            syncSessionId: nil,
            type: .manualBackup,
            googleContactsCount: googleContacts.count,
            macContactsCount: macContacts.count,
            contactVersions: [],
            metadata: BackupMetadata(
                appVersion: appVersion,
                syncDirection: nil,
                syncMode: nil,
                autoResolution: nil,
                customNotes: customNotes ?? "User-initiated manual backup"
            )
        )

        let versions = await captureContactVersions(
            googleContacts: googleContacts,
            macContacts: macContacts,
            backupSessionId: backupSession.id,
            syncSessionId: nil
        )

        var sessionWithVersions = backupSession
        sessionWithVersions.contactVersions = versions

        try saveBackupSession(sessionWithVersions)

        return sessionWithVersions
    }

    /// Get all backup sessions
    func getAllBackupSessions() -> [BackupSession] {
        var result: [BackupSession] = []
        backupQueue.sync {
            result = backupSessions.sorted { $0.timestamp > $1.timestamp }
        }
        return result
    }

    /// Get specific backup session by ID
    func getBackupSession(id: String) -> BackupSession? {
        var result: BackupSession?
        backupQueue.sync {
            result = backupSessions.first { $0.id == id }
        }
        return result
    }

    /// Get version history for a specific contact
    func getVersionHistory(for contactIdentifier: String) -> [ContactVersion] {
        var versions: [ContactVersion] = []
        backupQueue.sync {
            for session in backupSessions {
                versions.append(contentsOf: session.contactVersions.filter {
                    $0.contactIdentifier == contactIdentifier
                })
            }
        }
        return versions.sorted { $0.versionNumber < $1.versionNumber }
    }

    /// Every contact that appears in any backup, newest name first.
    ///
    /// Version history was captured from the very first release but there was no
    /// way to browse it: `getVersionHistory` needs an identifier, and nothing in
    /// the app ever offered a list to pick one from.
    func allVersionedContacts() -> [(identifier: String, name: String, versions: Int, latest: Date)] {
        var byIdentifier: [String: (name: String, versions: Int, latest: Date)] = [:]

        backupQueue.sync {
            for session in backupSessions {
                for version in session.contactVersions {
                    let existing = byIdentifier[version.contactIdentifier]
                    let isNewer = existing.map { version.timestamp > $0.latest } ?? true
                    byIdentifier[version.contactIdentifier] = (
                        // Keep the most recent name: a contact renamed since the
                        // first backup should be findable under what it is called
                        // now, not what it used to be.
                        name: isNewer ? version.contactName : (existing?.name ?? version.contactName),
                        versions: (existing?.versions ?? 0) + 1,
                        latest: max(existing?.latest ?? .distantPast, version.timestamp)
                    )
                }
            }
        }

        return byIdentifier
            .map { (identifier: $0.key, name: $0.value.name,
                    versions: $0.value.versions, latest: $0.value.latest) }
            .sorted { $0.latest > $1.latest }
    }

    /// Restore a specific contact version
    func restoreContactVersion(_ version: ContactVersion) -> UnifiedContact? {
        // Convert ContactSnapshot back to UnifiedContact
        return snapshotToUnifiedContact(version.data,
                                        identifier: version.contactIdentifier,
                                        source: version.source)
    }

    /// Restore entire backup session (returns all contacts as they were)
    func restoreBackupSession(id: String) -> (google: [UnifiedContact], mac: [UnifiedContact])? {
        guard let session = getBackupSession(id: id) else { return nil }

        var googleContacts: [UnifiedContact] = []
        var macContacts: [UnifiedContact] = []

        for version in session.contactVersions {
            if let unified = snapshotToUnifiedContact(version.data,
                                                      identifier: version.contactIdentifier,
                                                      source: version.source) {
                if version.source == .google {
                    googleContacts.append(unified)
                } else {
                    macContacts.append(unified)
                }
            }
        }

        return (googleContacts, macContacts)
    }

    /// Delete old backup sessions (keeps specified count)
    /// Drop the oldest backups beyond the user's retention limit.
    ///
    /// Three things were wrong before, and together they meant backups grew
    /// without bound despite Settings promising "Older backups are pruned
    /// automatically once this limit is reached":
    ///
    ///  1. Nothing ever called this.
    ///  2. It trimmed the in-memory index but never deleted the `<id>.json`
    ///     files, so disk use kept climbing while the app reported fewer
    ///     backups — and `calculateEstimatedSize()` stopped counting the
    ///     orphans, making the size shown in Settings wrong too.
    ///  3. It used a hardcoded 30, ignoring `AppSettings.maxBackupCount`.
    ///
    /// Runs on the barrier queue and is safe to call after every backup.
    func pruneOldBackups(keepCount: Int? = nil) {
        let limit = max(1, keepCount ?? AppSettings.shared.maxBackupCount)

        backupQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.backupSessions.count > limit else { return }

            let sorted = self.backupSessions.sorted { $0.timestamp > $1.timestamp }
            let keep = Array(sorted.prefix(limit))
            let drop = Array(sorted.dropFirst(limit))

            self.backupSessions = keep
            try? self.saveBackupIndex()

            // Delete the files too, inside the sandbox grant.
            self.withBackupDirectory { dir in
                for session in drop {
                    let file = dir.appendingPathComponent("\(session.id).json")
                    try? FileManager.default.removeItem(at: file)
                }
            }

            SyncHistory.shared.log(
                source: "BackupManager",
                action: "backups.pruned",
                details: "removed \(drop.count), kept \(keep.count) (limit \(limit))"
            )

            let size = self.calculateEstimatedSize()
            let count = self.backupSessions.count
            DispatchQueue.main.async { [weak self] in
                self?.backupCount = count
                self?.totalBackupSize = size
            }
        }
    }

    /// Delete every backup: the index, the version history, and the files.
    ///
    /// Irreversible, and the one operation here with no undo — a backup *is* the
    /// undo for everything else. Only reachable from Reset Everything, behind a
    /// confirmation that says so.
    ///
    /// Asynchronous, like every other mutation on this queue.
    ///
    /// The first version used `sync(flags: .barrier)` so the deletion would
    /// finish before the caller reset the rest of the app. That deadlocked: this
    /// type is main-actor isolated under the project's default isolation, so a
    /// blocking barrier from here parks the main thread behind whatever the
    /// concurrent queue is already running — including the prune and orphan
    /// sweep that `init` fires. The test run hung on it.
    ///
    /// Ordering was never the real concern anyway: the rest of the reset touches
    /// settings, mappings and history, none of which this queue owns.
    ///
    /// The published counters are set here, on the main actor, rather than from
    /// inside the barrier — they drive the UI.
    func deleteAllBackups() {
        backupCount = 0
        totalBackupSize = 0
        lastBackupDate = nil

        backupQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let removed = self.backupSessions.count

            self.withBackupDirectory { dir in
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "json" {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            // Per-contact version history lives inside each session's
            // `contactVersions`, so clearing the sessions clears it too — there
            // is no second store to forget about.
            self.backupSessions = []
            try? self.saveBackupIndex()

            SyncHistory.shared.log(source: "BackupManager", action: "backups.deletedAll",
                                   details: "removed \(removed) session(s)")
        }
    }

    /// Delete backup files with no entry in the index.
    ///
    /// Earlier builds trimmed the index without removing files, so existing
    /// installs carry orphans that nothing will ever read. Run at launch.
    func removeOrphanedBackupFiles() {
        backupQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let known = Set(self.backupSessions.map { "\($0.id).json" })

            let removed = self.withBackupDirectory { dir -> Int in
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { return 0 }

                var count = 0
                for file in files where file.pathExtension == "json"
                    && file.lastPathComponent != "backup_index.json"
                    && !known.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                    count += 1
                }
                return count
            }

            guard removed > 0 else { return }
            SyncHistory.shared.log(source: "BackupManager", action: "backups.orphansRemoved",
                                   details: "\(removed) file(s) with no index entry")

            let size = self.calculateEstimatedSize()
            DispatchQueue.main.async { [weak self] in self?.totalBackupSize = size }
        }
    }

    /// Export backup session as JSON (for user download/sharing)
    func exportBackupSession(id: String) -> Data? {
        guard let session = getBackupSession(id: id) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        return try? encoder.encode(session)
    }

    /// Get backup statistics
    func getBackupStats() -> BackupStats {
        var stats = BackupStats()
        backupQueue.sync {
            stats.totalBackups = backupSessions.count
            stats.oldestBackup = backupSessions.min { $0.timestamp < $1.timestamp }?.timestamp
            stats.newestBackup = backupSessions.max { $0.timestamp < $1.timestamp }?.timestamp
            stats.totalContactVersions = backupSessions.reduce(0) { $0 + $1.contactVersions.count }
            stats.estimatedSizeBytes = calculateEstimatedSize()
        }
        return stats
    }

    struct BackupStats {
        var totalBackups: Int = 0
        var oldestBackup: Date?
        var newestBackup: Date?
        var totalContactVersions: Int = 0
        var estimatedSizeBytes: Int64 = 0
    }

    // MARK: - Private Helpers

    private func captureContactVersions(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        backupSessionId: String,
        syncSessionId: String?
    ) async -> [ContactVersion] {
        var versions: [ContactVersion] = []

        // Capture Google contacts
        for contact in googleContacts {
            if let snapshot = createSnapshot(from: contact) {
                let version = ContactVersion(
                    id: UUID().uuidString,
                    contactIdentifier: contact.googleResourceName ?? "unknown",
                    contactName: contact.displayName,
                    versionNumber: getNextVersionNumber(for: contact.googleResourceName ?? ""),
                    timestamp: Date(),
                    syncSessionId: syncSessionId ?? backupSessionId,
                    source: .google,
                    data: snapshot,
                    changesSummary: []
                )
                versions.append(version)
            }
        }

        // Capture Mac contacts
        for contact in macContacts {
            if let snapshot = createSnapshot(from: contact) {
                let version = ContactVersion(
                    id: UUID().uuidString,
                    contactIdentifier: contact.macContactIdentifier ?? "unknown",
                    contactName: contact.displayName,
                    versionNumber: getNextVersionNumber(for: contact.macContactIdentifier ?? ""),
                    timestamp: Date(),
                    syncSessionId: syncSessionId ?? backupSessionId,
                    source: .mac,
                    data: snapshot,
                    changesSummary: []
                )
                versions.append(version)
            }
        }

        return versions
    }

    func createSnapshot(from contact: UnifiedContact) -> ContactSnapshot? { // internal for testing
        return ContactSnapshot(
            displayName: contact.displayName,
            givenName: contact.givenName,
            familyName: contact.familyName,
            middleName: contact.middleName,
            phoneNumbers: contact.phoneNumbers.map { num in
                ContactSnapshot.PhoneSnapshot(label: num.label, value: num.value)
            },
            emailAddresses: contact.emailAddresses.map { email in
                ContactSnapshot.EmailSnapshot(label: email.label, value: email.value)
            },
            postalAddresses: contact.postalAddresses.map { addr in
                ContactSnapshot.AddressSnapshot(
                    label: addr.label,
                    street: addr.street,
                    city: addr.city,
                    state: addr.state,
                    postalCode: addr.postalCode,
                    country: addr.country
                )
            },
            organization: contact.organizationName,
            jobTitle: contact.jobTitle,
            notes: contact.note,
            imageData: contact.photoData,
            customFields: [:],
            namePrefix: contact.namePrefix,
            nameSuffix: contact.nameSuffix,
            nickname: contact.nickname,
            phoneticGivenName: contact.phoneticGivenName,
            phoneticMiddleName: contact.phoneticMiddleName,
            phoneticFamilyName: contact.phoneticFamilyName,
            department: contact.department,
            urls: contact.urls.map { ContactSnapshot.URLSnapshot(label: $0.label, value: $0.value) },
            birthday: contact.birthday,
            // Both identifiers are captured so a restore can target the exact
            // record on each side rather than creating a new one.
            googleResourceName: contact.googleResourceName,
            macContactIdentifier: contact.macContactIdentifier
        )
    }

    /// Rebuild a contact from a snapshot, targeting the record it came from.
    ///
    /// `source` matters: this used to hardcode `googleResourceName: identifier,
    /// macContactIdentifier: nil` for *both* sources, so a restored Mac contact
    /// arrived with no Mac identifier. The rollback then took the "no existing
    /// record" branch and created a new one — turning a restore into a full
    /// duplication of the address book.
    ///
    /// Prefers the identifiers captured in the snapshot and falls back to
    /// `identifier` + `source` for backups written before those were stored.
    func snapshotToUnifiedContact( // internal for testing
        _ snapshot: ContactSnapshot,
        identifier: String,
        source: ContactVersion.ContactSource
    ) -> UnifiedContact? {
        let googleID = snapshot.googleResourceName
            ?? (source == .mac ? nil : identifier)
        let macID = snapshot.macContactIdentifier
            ?? (source == .mac ? identifier : nil)

        return UnifiedContact(
            id: UUID(),
            googleResourceName: googleID,
            macContactIdentifier: macID,
            givenName: snapshot.givenName,
            middleName: snapshot.middleName,
            familyName: snapshot.familyName,
            namePrefix: snapshot.namePrefix,
            nameSuffix: snapshot.nameSuffix,
            nickname: snapshot.nickname,
            phoneticGivenName: snapshot.phoneticGivenName,
            phoneticMiddleName: snapshot.phoneticMiddleName,
            phoneticFamilyName: snapshot.phoneticFamilyName,
            organizationName: snapshot.organization,
            department: snapshot.department,
            jobTitle: snapshot.jobTitle,
            phoneNumbers: snapshot.phoneNumbers.map { UnifiedContact.PhoneNumber(value: $0.value, label: $0.label) },
            emailAddresses: snapshot.emailAddresses.map { UnifiedContact.EmailAddress(value: $0.value, label: $0.label) },
            postalAddresses: snapshot.postalAddresses.map { UnifiedContact.PostalAddress(
                street: $0.street,
                city: $0.city,
                state: $0.state,
                postalCode: $0.postalCode,
                country: $0.country,
                countryCode: nil,
                label: $0.label
            )},
            urls: (snapshot.urls ?? []).map { UnifiedContact.Url(value: $0.value, label: $0.label) },
            birthday: snapshot.birthday,
            note: snapshot.notes,
            photoData: snapshot.imageData,
            lastModified: Date()
        )
    }

    private func getNextVersionNumber(for contactIdentifier: String) -> Int {
        let versions = getVersionHistory(for: contactIdentifier)
        return (versions.max { $0.versionNumber < $1.versionNumber }?.versionNumber ?? 0) + 1
    }

    /// Total size of the backup files on disk.
    ///
    /// Reads the file sizes. The previous implementation re-encoded every
    /// session to JSON — every contact of both address books, including the
    /// full photo bytes — and threw the result away except for its length. With
    /// 30 retained backups of a normal address book that is hundreds of
    /// megabytes serialised to produce one number for a Settings label, and it
    /// ran after every backup, on every prune, and whenever the statistics view
    /// appeared.
    ///
    /// Asking the filesystem is also more accurate: it measures what is
    /// actually stored rather than what a fresh encode would produce.
    private func calculateEstimatedSize() -> Int64 {
        withBackupDirectory { dir -> Int64 in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(into: Int64(0)) { total, file in
                guard file.pathExtension == "json" else { return }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                total += Int64(size ?? 0)
            }
        }
    }

    // MARK: - Disk Persistence

    /// Public accessor so the UI can show/open the backup folder
    var backupDirectory: URL { backupDirectoryURL() }

    /// Formatted path for display (replaces /Users/<name> with ~)
    var backupDirectoryDisplayPath: String {
        let path = backupDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// List all backup JSON files on disk, newest first
    func listBackupFiles() -> [(name: String, url: URL, size: Int64, date: Date)] {
        let files = withBackupDirectory { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        guard !files.isEmpty else { return [] }

        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "backup_index.json" }
            .compactMap { url in
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return (
                    name: url.lastPathComponent,
                    url: url,
                    size: Int64(attrs?.fileSize ?? 0),
                    date: attrs?.creationDate ?? Date.distantPast
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Export a backup session to a user-chosen location via NSSavePanel
    @MainActor
    func exportBackupToFile(id: String) {
        guard let jsonData = exportBackupSession(id: id) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Backup"
        panel.nameFieldStringValue = "ContactSyncMate_Backup_\(id.prefix(8)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? jsonData.write(to: url, options: .atomic)
        }
    }

    /// Bring a backup file created by `exportBackupToFile` back into the app.
    ///
    /// Export existed with no counterpart, so an exported backup was a file the
    /// app could produce and never read — useless for the case backups exist for:
    /// a reinstall, a lost index, or moving to another Mac. This closes the loop.
    ///
    /// The picked file carries its own sandbox grant from `NSOpenPanel`, so no
    /// bookmark is involved.
    @MainActor
    @discardableResult
    func importBackupFromFile() -> Result<BackupSession, Error>? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Backup")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(BackupSession.self, from: data)

            // Re-importing the same file must not create a second entry — the id
            // is the session's identity, and a duplicate would show as two
            // restore targets holding identical data.
            if getBackupSession(id: session.id) != nil {
                SyncHistory.shared.log(source: "BackupManager", action: "import.alreadyPresent",
                                       details: session.id)
                return .success(session)
            }

            // No queue wrapper here: saveBackupSession serialises internally
            // with a sync barrier on this same queue, so wrapping the call in
            // another sync barrier re-entered the lock we would already be
            // holding — a guaranteed deadlock on every import.
            try saveBackupSession(session)

            SyncHistory.shared.log(
                source: "BackupManager",
                action: "import.succeeded",
                details: "\(session.id) — \(session.contactVersions.count) contacts from \(session.timestamp)"
            )
            return .success(session)

        } catch {
            SyncHistory.shared.log(source: "BackupManager", action: "import.failed",
                                   details: error.localizedDescription)
            return .failure(error)
        }
    }

    /// Resolve the folder backups are written to.
    ///
    /// Sandbox-aware resolution order:
    ///   1. A user-chosen folder, reached through a *security-scoped bookmark*
    ///      (the only way a sandboxed app keeps folder access across launches —
    ///      a bare path string is revoked when the process exits).
    ///   2. The app's own Documents directory. Under the sandbox this is
    ///      `~/Library/Containers/<bundle-id>/Data/Documents`, which is always
    ///      writable without any entitlement.
    ///   3. Temp directory as a last resort.
    /// Run `body` with the backup folder, holding sandbox access open for its
    /// whole duration.
    ///
    /// `backupDirectoryURL()` opened the security scope and then closed it in a
    /// `defer` *before returning* — so every caller received a URL whose access
    /// had already been released, and every read or write to a user-chosen folder
    /// was denied by the sandbox. Because those writes all used `try?`, backups
    /// to a custom folder failed silently.
    ///
    /// Access must span the file operation, not the lookup, which is exactly what
    /// `SecurityScopedBookmark.withAccess` provides.
    @discardableResult
    private func withBackupDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let fm = FileManager.default

        if let result = try SecurityScopedBookmark.withAccess(to: .backupFolder, { url -> T in
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return try body(url)
        }) {
            return result
        }

        // No bookmark, or it no longer resolves — fall back to the container.
        return try body(containerBackupDirectory())
    }

    private func backupDirectoryURL() -> URL {
        // Retained for callers that only need the path for display. File I/O must
        // go through `withBackupDirectory` so the sandbox grant is held.
        if let url = SecurityScopedBookmark.resolve(.backupFolder) {
            return url
        }
        return containerBackupDirectory()
    }

    private func containerBackupDirectory() -> URL {
        let fm = FileManager.default

        // 2. Container Documents (sandbox-safe default)
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let backupDir = docs.appendingPathComponent("Contact SyncMate Backups", isDirectory: true)
            if !fm.fileExists(atPath: backupDir.path) {
                try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            }
            return backupDir
        }

        return fm.temporaryDirectory
    }

    /// Whether the user has chosen a custom backup folder (vs. the default
    /// container location). Drives the "Reset to Default" button in Settings.
    var hasCustomBackupFolder: Bool {
        SecurityScopedBookmark.exists(.backupFolder)
    }

    /// Let the user pick a new backup folder.
    ///
    /// The chosen URL is persisted as a security-scoped bookmark so access
    /// survives relaunch under the App Sandbox.
    @MainActor
    func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.message = "Contact SyncMate will store backup snapshots in this folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Persist the grant BEFORE doing anything else with the URL.
        guard SecurityScopedBookmark.save(url, forKey: .backupFolder) else {
            SyncHistory.shared.log(
                source: "BackupManager",
                action: "chooseBackupDirectory.failed",
                details: "Could not persist access to \(url.lastPathComponent)"
            )
            return
        }

        customBackupPath = url.path   // display only
        SyncHistory.shared.log(
            source: "BackupManager",
            action: "backupFolder.changed",
            details: url.lastPathComponent
        )

        // Backups are plaintext JSON holding both address books in full. A
        // folder that a cloud service mirrors silently uploads all of that
        // off-device, so the choice is honoured but never silent: it goes in
        // the history log and in front of the user, like every other
        // confirmation of a consequence in this app.
        if Self.isCloudSyncedLocation(url) {
            SyncHistory.shared.log(
                source: "BackupManager",
                action: "backupFolder.cloudSyncWarning",
                details: "\"\(url.lastPathComponent)\" is inside a cloud-synced location — "
                    + "backup files are unencrypted and will be uploaded by the sync service"
            )
            let alert = NSAlert()
            alert.messageText = "This Folder Syncs to the Cloud"
            alert.informativeText = """
                The folder you chose appears to be synced by a cloud service \
                (such as iCloud Drive, Dropbox, Google Drive, or OneDrive).

                Backups are not encrypted: they contain your contacts' names, \
                phone numbers, email addresses, photos, and notes in plain text, \
                and the sync service will upload them to its servers.

                Backups will still be saved here. Choose a different folder if \
                you do not want them leaving this Mac.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        loadBackupIndex()
    }

    /// Whether `url` lies inside a folder a cloud service mirrors off-device.
    ///
    /// Covers iCloud Drive (`~/Library/Mobile Documents/…`, including
    /// `com~apple~CloudDocs`), the modern File Provider mount point every
    /// current cloud client uses (`~/Library/CloudStorage/<Provider>-…`), and
    /// the legacy direct-in-home folders older Dropbox / Google Drive /
    /// OneDrive installs left behind. Component-based on purpose: the panel
    /// hands back real user paths, not container-relative ones, so matching a
    /// sandboxed "home" prefix would miss all of them.
    static func isCloudSyncedLocation(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents

        if components.contains("Mobile Documents")
            || components.contains("com~apple~CloudDocs")
            || components.contains("CloudStorage") {
            return true
        }

        // Legacy sync folders sit directly in the home directory:
        // /Users/<name>/Dropbox, /Users/<name>/Google Drive, /Users/<name>/OneDrive.
        if components.count >= 4, components[1] == "Users" {
            return ["Dropbox", "Google Drive", "OneDrive"].contains(components[3])
        }

        return false
    }

    /// Return to the default (container) backup folder and drop the bookmark.
    @MainActor
    func resetBackupDirectoryToDefault() {
        SecurityScopedBookmark.clear(.backupFolder)
        customBackupPath = nil
        loadBackupIndex()
    }

    private var backupIndexURL: URL {
        backupDirectoryURL().appendingPathComponent("backup_index.json")
    }

    /// Write a backup session and the updated index to disk.
    ///
    /// With `allowContainerFallback`, a failed write to a user-chosen custom
    /// folder (full disk, revoked permissions, read-only volume) is retried in
    /// the default container directory instead of thrown. Both files — the
    /// session JSON and the index — go to the same directory either way, so a
    /// restore that loads the index always finds the session file next to it.
    private func saveBackupSession(_ session: BackupSession,
                                   allowContainerFallback: Bool = false) throws {
        // Appending on the caller's thread was a data race.
        //
        // Every other access to `backupSessions` is serialised on `backupQueue`
        // — reads under `sync`, writes under `async(flags: .barrier)`. This one
        // appended from the main actor while `pruneOldBackups` (which this
        // method itself schedules, below) barrier-assigns the whole array.
        // Concurrent append and whole-array assignment on a Swift Array is
        // undefined behaviour, in the component whose entire job is to be the
        // undo for everything else.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        // One barrier block: append, snapshot the index, and take the count —
        // a second blocking `sync` just to read the count doubled the
        // main-thread wait for no benefit.
        let (indexData, count) = try backupQueue.sync(flags: .barrier) { () throws -> (Data, Int) in
            backupSessions.append(session)
            return (try encoder.encode(backupSessions), backupSessions.count)
        }

        func write(to dir: URL) throws {
            try data.write(to: dir.appendingPathComponent("\(session.id).json"),
                           options: [.atomic])
            try indexData.write(to: dir.appendingPathComponent("backup_index.json"),
                                options: [.atomic])
        }

        do {
            try withBackupDirectory { dir in try write(to: dir) }
        } catch {
            // Only fall back when a custom folder is in play: without one,
            // `withBackupDirectory` already targeted the container, and
            // retrying the same location would just fail the same way.
            guard allowContainerFallback, hasCustomBackupFolder else { throw error }

            try write(to: containerBackupDirectory())
            SyncHistory.shared.log(
                source: "BackupManager",
                action: "backup.savedToFallback",
                details: "Custom backup folder was not writable (\(error.localizedDescription)) — "
                    + "backup \(session.id) was written to the default folder instead"
            )
        }

        // Update published properties on main thread
        let size = calculateEstimatedSize()
        let timestamp = session.timestamp
        DispatchQueue.main.async { [weak self] in
            self?.lastBackupDate = timestamp
            self?.backupCount = count
            self?.totalBackupSize = size
        }

        // Enforce the retention limit now that a new backup exists. Async on the
        // barrier queue, so it runs after this write completes rather than
        // re-entering the lock we are already holding.
        pruneOldBackups()
    }

    private func saveBackupIndex() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let indexData = try encoder.encode(backupSessions)
        try withBackupDirectory { dir in
            try indexData.write(to: dir.appendingPathComponent("backup_index.json"),
                                options: [.atomic])
        }
    }

    private func loadBackupIndex() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try withBackupDirectory { dir in
                try Data(contentsOf: dir.appendingPathComponent("backup_index.json"))
            }
            let loaded = try decoder.decode([BackupSession].self, from: data)
            backupQueue.async(flags: .barrier) { [weak self] in
                self?.backupSessions = loaded
                DispatchQueue.main.async {
                    self?.backupCount = loaded.count
                    self?.lastBackupDate = loaded.max { $0.timestamp < $1.timestamp }?.timestamp
                    self?.totalBackupSize = self?.calculateEstimatedSize() ?? 0
                }
            }
        } catch {
            // Initialize empty if load fails (first launch or corrupted index).
            // Through the barrier queue like every other write: this path also
            // runs when the user re-points the backup folder at runtime, where
            // a direct assignment can race an in-flight pruneOldBackups
            // barrier block mutating the same array.
            print("ContactBackupManager: Could not load backup index: \(error.localizedDescription)")
            backupQueue.async(flags: .barrier) { [weak self] in
                self?.backupSessions = []
            }
        }
    }
}
