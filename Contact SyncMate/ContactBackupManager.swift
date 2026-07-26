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
import Combine
import AppKit
import UniformTypeIdentifiers

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
    private let maxBackupSessions = 50 // Keep last 50 backup sessions
    private let maxVersionsPerContact = 100

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

        try saveBackupSession(sessionWithVersions)

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

    /// Restore a specific contact version
    func restoreContactVersion(_ version: ContactVersion) -> UnifiedContact? {
        // Convert ContactSnapshot back to UnifiedContact
        return snapshotToUnifiedContact(version.data, identifier: version.contactIdentifier)
    }

    /// Restore entire backup session (returns all contacts as they were)
    func restoreBackupSession(id: String) -> (google: [UnifiedContact], mac: [UnifiedContact])? {
        guard let session = getBackupSession(id: id) else { return nil }

        var googleContacts: [UnifiedContact] = []
        var macContacts: [UnifiedContact] = []

        for version in session.contactVersions {
            if let unified = snapshotToUnifiedContact(version.data, identifier: version.contactIdentifier) {
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
    func pruneOldBackups(keepCount: Int = 30) {
        backupQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if self.backupSessions.count > keepCount {
                let sorted = self.backupSessions.sorted { $0.timestamp > $1.timestamp }
                self.backupSessions = Array(sorted.prefix(keepCount))
                try? self.saveBackupIndex()
            }
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

    private func createSnapshot(from contact: UnifiedContact) -> ContactSnapshot? {
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
            customFields: [:]
        )
    }

    private func snapshotToUnifiedContact(_ snapshot: ContactSnapshot, identifier: String) -> UnifiedContact? {
        return UnifiedContact(
            id: UUID(),
            googleResourceName: identifier,
            macContactIdentifier: nil,
            givenName: snapshot.givenName,
            middleName: snapshot.middleName,
            familyName: snapshot.familyName,
            namePrefix: nil,
            nameSuffix: nil,
            nickname: nil,
            phoneticGivenName: nil,
            phoneticMiddleName: nil,
            phoneticFamilyName: nil,
            organizationName: snapshot.organization,
            department: nil,
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
            urls: [],
            birthday: nil,
            note: snapshot.notes,
            photoData: snapshot.imageData,
            lastModified: Date()
        )
    }

    private func getNextVersionNumber(for contactIdentifier: String) -> Int {
        let versions = getVersionHistory(for: contactIdentifier)
        return (versions.max { $0.versionNumber < $1.versionNumber }?.versionNumber ?? 0) + 1
    }

    private func calculateEstimatedSize() -> Int64 {
        let encoder = JSONEncoder()
        var totalSize: Int64 = 0

        for session in backupSessions {
            if let data = try? encoder.encode(session) {
                totalSize += Int64(data.count)
            }
        }

        return totalSize
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
        let dir = backupDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

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
    private func backupDirectoryURL() -> URL {
        let fm = FileManager.default

        // 1. User-chosen folder via bookmark
        if let url = SecurityScopedBookmark.resolve(.backupFolder) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }

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
        loadBackupIndex()
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

    private func saveBackupSession(_ session: BackupSession) throws {
        // Perform file I/O synchronously
        backupSessions.append(session)

        // Save individual session file
        let sessionFile = backupDirectoryURL().appendingPathComponent("\(session.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: sessionFile, options: [.atomic])

        // Update index
        try saveBackupIndex()

        // Update published properties on main thread
        let count = backupSessions.count
        let size = calculateEstimatedSize()
        let timestamp = session.timestamp
        DispatchQueue.main.async { [weak self] in
            self?.lastBackupDate = timestamp
            self?.backupCount = count
            self?.totalBackupSize = size
        }
    }

    private func saveBackupIndex() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let indexData = try encoder.encode(backupSessions)
        try indexData.write(to: backupIndexURL, options: [.atomic])
    }

    private func loadBackupIndex() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: backupIndexURL)
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
            // Initialize empty if load fails (first launch or corrupted index)
            print("ContactBackupManager: Could not load backup index: \(error.localizedDescription)")
            backupSessions = []
        }
    }
}
