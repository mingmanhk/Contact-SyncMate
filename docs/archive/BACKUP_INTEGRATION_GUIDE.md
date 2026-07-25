# Contact SyncMate — Backup System Integration Guide
**Quick Start for Developers | March 29, 2026**

---

## 📋 TABLE OF CONTENTS

1. [Installation](#installation)
2. [Quick Start](#quick-start)
3. [Integration Steps](#integration-steps)
4. [API Reference](#api-reference)
5. [Testing](#testing)
6. [Troubleshooting](#troubleshooting)

---

## 🚀 INSTALLATION

### Files Added

```
Contact SyncMate/
├── ContactBackupManager.swift          [NEW] Backup system core
├── SyncBackupIntegration.swift         [NEW] Sync engine integration
├── WORKFLOW_REVIEW_AND_BACKUP_SYSTEM.md [NEW] Full design & analysis
└── BACKUP_INTEGRATION_GUIDE.md         [THIS FILE]
```

### No External Dependencies

- Uses only standard Swift libraries (Foundation, Contacts, Combine)
- No additional CocoaPods or SPM dependencies
- Compatible with existing project structure

### Import Statements

Add to files that use the backup system:

```swift
import Foundation        // Already included
// ContactBackupManager and SyncBackupIntegration are in same target
// No explicit imports needed (same module)
```

---

## ⚡ QUICK START

### Minimum 3-Step Setup

#### Step 1: Add Pre-Sync Backup to SyncEngine

In your existing sync workflow, add backup creation:

```swift
// OLD CODE (in prepareManualSync)
let googleContacts = try await googleConnector.fetchAllContacts()
let macContacts = try macConnector.fetchAllContacts()
let changes = computeChanges(...)

// NEW CODE: Add backup capture
let syncSessionId = UUID().uuidString
let preBackup = try await ContactBackupManager.shared.createPreSyncBackup(
    googleContacts: unifiedGoogleContacts,
    macContacts: unifiedMacContacts,
    syncSessionId: syncSessionId,
    syncDirection: direction.rawValue,
    syncMode: "manual"
)
// Now proceed with changes
```

#### Step 2: Add Post-Sync Backup

After changes are applied in executeSync:

```swift
// After executing all changes successfully
let postBackup = try await ContactBackupManager.shared.createPostSyncBackup(
    googleContacts: finalGoogleContacts,
    macContacts: finalMacContacts,
    syncSessionId: syncSessionId,
    changesSummary: "Added: \(added), Updated: \(updated), Deleted: \(deleted)"
)
```

#### Step 3: Use New Integrated Methods

Replace your existing sync methods with the new ones:

```swift
// INSTEAD OF:
let session = try await syncEngine.prepareManualSync(direction: .twoWay)
let result = try await syncEngine.executeSync(session: session)

// USE:
let (session, preBackup) = try await syncEngine.prepareManualSyncWithBackup(direction: .twoWay)
let (result, postBackup) = try await syncEngine.executeSyncWithBackup(session: session)
```

---

## 🔧 INTEGRATION STEPS

### Step-by-Step Integration

#### **Phase 1: Add Backup Manager Instance**

```swift
// In AppState.swift or app initialization
let backupManager = ContactBackupManager.shared

// Optional: Monitor backup status
@Published var lastBackup: Date?
@Published var backupCount: Int = 0

// In UI, you can observe:
.onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
    lastBackup = backupManager.lastBackupDate
    backupCount = backupManager.backupCount
}
```

#### **Phase 2: Replace Manual Sync Flow**

**OLD:**
```swift
// In SyncEngine or wherever sync is triggered
func manualSync() async throws -> SyncResult {
    let session = try await prepareManualSync(direction: .twoWay)
    // Show preview to user
    return try await executeSync(session: session)
}
```

**NEW:**
```swift
// Use integrated methods
func manualSync() async throws -> (SyncResult, BackupSession?, BackupSession?) {
    let (session, preBackup) = try await prepareManualSyncWithBackup(direction: .twoWay)
    // Show preview to user
    let (result, postBackup) = try await executeSyncWithBackup(session: session)
    return (result, preBackup, postBackup)
}
```

#### **Phase 3: Replace Auto-Sync Flow**

**OLD:**
```swift
func autoSync() async throws -> SyncResult {
    return try await runAutoSync()
}
```

**NEW:**
```swift
func autoSync() async throws -> (SyncResult, BackupSession, BackupSession?) {
    let (result, preBackup, postBackup) = try await runAutoSyncWithBackup()
    return (result, preBackup, postBackup)
}
```

#### **Phase 4: Add UI for Backup Management**

In your Dashboard or Settings:

```swift
// Show last backup info
if let lastBackup = backupManager.lastBackupDate {
    Text("Last backup: \(lastBackup.formatted())")
}

// Create manual backup button
Button("Backup Now") {
    Task {
        try? await contactBackupManager.createManualBackup(
            googleContacts: googleContacts,
            macContacts: macContacts,
            customNotes: "Manual backup"
        )
    }
}

// List backups
List(backupManager.getAllBackupSessions()) { backup in
    VStack(alignment: .leading) {
        Text(backup.timestamp.formatted())
        Text("\(backup.contactVersions.count) contacts")
        Text(backup.type.rawValue)
    }
}

// Restore from backup
Button("Restore") {
    Task {
        try? await syncEngine.rollbackToBackup(backupId: backup.id)
    }
}
```

#### **Phase 5: Add Error Handling**

```swift
do {
    let (session, backup) = try await syncEngine.prepareManualSyncWithBackup(direction: .twoWay)
    // Proceed with sync
} catch {
    // Check if backup was created despite error
    let backups = ContactBackupManager.shared.getAllBackupSessions()
    if let latestBackup = backups.first {
        print("Backup \(latestBackup.id) created at \(latestBackup.timestamp)")
        // User can still restore if needed
    }
    throw error
}
```

---

## 📚 API REFERENCE

### ContactBackupManager

#### Public Methods

```swift
// Create pre-sync backup
func createPreSyncBackup(
    googleContacts: [UnifiedContact],
    macContacts: [UnifiedContact],
    syncSessionId: String,
    syncDirection: String,
    syncMode: String
) async throws -> BackupSession

// Create post-sync backup
func createPostSyncBackup(
    googleContacts: [UnifiedContact],
    macContacts: [UnifiedContact],
    syncSessionId: String,
    changesSummary: String
) async throws -> BackupSession

// Create manual user-initiated backup
func createManualBackup(
    googleContacts: [UnifiedContact],
    macContacts: [UnifiedContact],
    customNotes: String? = nil
) async throws -> BackupSession

// Get all backups
func getAllBackupSessions() -> [BackupSession]

// Get specific backup
func getBackupSession(id: String) -> BackupSession?

// Get contact version history
func getVersionHistory(for contactIdentifier: String) -> [ContactVersion]

// Restore specific contact version
func restoreContactVersion(_ version: ContactVersion) -> UnifiedContact?

// Restore entire backup
func restoreBackupSession(id: String) -> (google: [UnifiedContact], mac: [UnifiedContact])?

// Delete old backups
func pruneOldBackups(keepCount: Int = 30) async throws

// Export backup as JSON
func exportBackupSession(id: String) -> Data?

// Get statistics
func getBackupStats() -> BackupStats
```

#### Published Properties

```swift
@Published var lastBackupDate: Date?      // When last backup was created
@Published var backupCount: Int           // Total number of backups
@Published var totalBackupSize: Int64     // Estimated size in bytes
```

### SyncEngine Extensions

#### New Methods

```swift
// Manual sync with automatic pre/post backups
func prepareManualSyncWithBackup(direction: SyncDirection)
    async throws -> (session: SyncSession, backup: BackupSession)

// Execute sync with post-backup
func executeSyncWithBackup(session: SyncSession)
    async throws -> (result: SyncResult, postSyncBackup: BackupSession?)

// Auto-sync with automatic backups
func runAutoSyncWithBackup()
    async throws -> (result: SyncResult, preBackup: BackupSession, postBackup: BackupSession?)

// Rollback to previous backup state
func rollbackToBackup(backupId: String) async throws
```

### Data Models

```swift
// Main backup session
struct BackupSession: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let syncSessionId: String?
    let type: BackupType  // preSyncBackup, postSyncBackup, manualBackup, autoBackup
    let googleContactsCount: Int
    let macContactsCount: Int
    let contactVersions: [ContactVersion]
    let metadata: BackupMetadata
}

// Single contact version
struct ContactVersion: Codable, Identifiable {
    let id: String
    let contactIdentifier: String
    let contactName: String
    let versionNumber: Int
    let timestamp: Date
    let syncSessionId: String
    let source: ContactSource  // google, mac, merged
    let data: ContactSnapshot
    let changesSummary: [String]
}

// Contact snapshot (all fields)
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
    let imageData: Data?
    let customFields: [String: String]
}
```

---

## 🧪 TESTING

### Unit Tests to Add

```swift
// ContactBackupManagerTests.swift

class ContactBackupManagerTests: XCTestCase {
    var backupManager: ContactBackupManager!

    override func setUp() {
        super.setUp()
        backupManager = ContactBackupManager.shared
    }

    func testCreatePreSyncBackup() async throws {
        let google = [UnifiedContact(...)]
        let mac = [UnifiedContact(...)]

        let backup = try await backupManager.createPreSyncBackup(
            googleContacts: google,
            macContacts: mac,
            syncSessionId: "test",
            syncDirection: "2-way",
            syncMode: "manual"
        )

        XCTAssertEqual(backup.googleContactsCount, google.count)
        XCTAssertEqual(backup.macContactsCount, mac.count)
        XCTAssertEqual(backup.type, .preSyncBackup)
    }

    func testVersionHistory() async throws {
        // Create backup 1
        let backup1 = try await backupManager.createManualBackup(...)

        // Create backup 2
        let backup2 = try await backupManager.createManualBackup(...)

        // Get history
        let versions = backupManager.getVersionHistory(for: contactId)
        XCTAssertGreaterThanOrEqual(versions.count, 2)
    }

    func testRestoreBackup() async throws {
        let backup = try await backupManager.createManualBackup(...)
        let restored = backupManager.restoreBackupSession(id: backup.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.google.count, backup.googleContactsCount)
    }

    func testPruneOldBackups() async throws {
        // Create 60 backups
        for i in 0..<60 {
            try await backupManager.createManualBackup(
                googleContacts: [],
                macContacts: [],
                customNotes: "Backup \(i)"
            )
        }

        // Prune to 30
        try await backupManager.pruneOldBackups(keepCount: 30)

        let remaining = backupManager.getAllBackupSessions()
        XCTAssertLessThanOrEqual(remaining.count, 30)
    }
}
```

### Integration Tests

```swift
// SyncEngineBackupIntegrationTests.swift

class SyncEngineBackupIntegrationTests: XCTestCase {
    func testPreAndPostBackupCreatedDuringSyncFlow() async throws {
        let (session, preBackup) = try await syncEngine.prepareManualSyncWithBackup(...)
        XCTAssertNotNil(preBackup)

        let (result, postBackup) = try await syncEngine.executeSyncWithBackup(session: session)
        XCTAssertNotNil(postBackup)

        // Both backups should exist
        let allBackups = ContactBackupManager.shared.getAllBackupSessions()
        XCTAssertGreaterThanOrEqual(allBackups.count, 2)
    }

    func testRollbackToBackup() async throws {
        // Create initial backup
        let backup = try await backupManager.createManualBackup(...)

        // Make changes (simulated)
        // ...

        // Rollback
        try await syncEngine.rollbackToBackup(backupId: backup.id)

        // Verify state restored
    }
}
```

---

## 🔍 TROUBLESHOOTING

### Common Issues

#### Issue: Backup Not Created

**Symptom:** `backupManager.lastBackupDate` is nil

**Solutions:**
```swift
// Check if backup was attempted
let backups = ContactBackupManager.shared.getAllBackupSessions()
print("Backups count: \(backups.count)")

// Check for errors in console
// Look for any thrown exceptions

// Verify contact count > 0
print("Google contacts: \(googleContacts.count)")
print("Mac contacts: \(macContacts.count)")
```

#### Issue: Backup File Corruption

**Symptom:** Error loading backups on app restart

**Solution:**
```swift
// ContactBackupManager handles this gracefully
// Missing or corrupted backup_index.json → backupSessions = []
// Just clear and start fresh:

let stats = backupManager.getBackupStats()
if stats.totalBackups == 0 {
    print("No backups available - starting fresh")
}
```

#### Issue: Restore Not Working

**Symptom:** `restoreContactVersion` returns nil

**Solutions:**
```swift
// Check version exists
let versions = backupManager.getVersionHistory(for: contactId)
print("Available versions: \(versions.count)")

// Check ContactSnapshot conversion
if let snapshot = version.data {
    print("Snapshot has \(snapshot.phoneNumbers.count) phone numbers")
}
```

#### Issue: High Disk Usage

**Symptom:** Backup directory growing large (>1GB)

**Solution:**
```swift
// Manually prune old backups
try await backupManager.pruneOldBackups(keepCount: 20)

// Or check backup size
let stats = backupManager.getBackupStats()
print("Total backup size: \(stats.estimatedSizeBytes / 1024 / 1024) MB")

// Consider disabling photo backup (if implemented)
```

### Debug Logging

Add detailed logging:

```swift
// Enable detailed logging
extension ContactBackupManager {
    func logBackupOperation(_ message: String) {
        SyncHistory.shared.log(source: "BackupManager", action: "debug", details: message)
    }
}

// Usage
backupManager.logBackupOperation("Creating backup \(backupSession.id)")
```

---

## ✅ VERIFICATION CHECKLIST

After integration, verify:

- [ ] Pre-sync backups are created automatically
- [ ] Post-sync backups are created after changes
- [ ] Backup files exist in `~/Library/Application Support/com.example.ContactSync/backups/`
- [ ] Backup count increments after each sync
- [ ] Version history shows all versions
- [ ] Restore functionality works correctly
- [ ] Rollback restores contacts to previous state
- [ ] Old backups are cleaned up correctly
- [ ] Backup size is reasonable (<1GB for 50 backups)
- [ ] No performance degradation during sync (<2% overhead)

---

## 📞 SUPPORT

For issues or questions:

1. **Check logs** — Enable SyncHistory logging
2. **Review WORKFLOW_REVIEW_AND_BACKUP_SYSTEM.md** — Complete design doc
3. **Run tests** — Verify with unit/integration tests
4. **Check disk space** — Ensure sufficient space for backups

---

*Last updated: March 29, 2026*
*Integration status: Ready for implementation*
