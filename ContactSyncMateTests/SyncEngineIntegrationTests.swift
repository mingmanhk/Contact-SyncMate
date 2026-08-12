// SyncEngineIntegrationTests.swift
// executeSync / applyGoogleBatches driven end to end through the connector
// protocol seam (issue #94), the legacy-restore fixture through the real
// restore entry point (issue #93), and the shared settings pin helper every
// settings-mutating test class uses (issue #107).

import XCTest
import Contacts
@testable import Contact_SyncMate

// MARK: - Issue #107: one shared settings pin-and-restore helper

/// Base class for every test class that mutates `AppSettings`.
///
/// The suite shares the app's UserDefaults domain, so an unpinned setting means
/// the test's behaviour depends on what the user last chose in the running app
/// — and an unrestored one leaks test values into the user's real settings.
/// `pin` records the original value and `tearDown` restores everything in
/// reverse order, so later pins of the same key unwind correctly.
class SettingsPinnedTestCase: XCTestCase {

    private var restorers: [() -> Void] = []

    /// Pin one setting for the duration of the test method.
    func pin<T>(_ keyPath: ReferenceWritableKeyPath<AppSettings, T>, to value: T) {
        let settings = AppSettings.shared
        let original = settings[keyPath: keyPath]
        restorers.append { settings[keyPath: keyPath] = original }
        settings[keyPath: keyPath] = value
    }

    /// The settings `computeChanges` reads, pinned to the values the diff
    /// tests were written against. Classes that need a different value pin
    /// again after calling this — restores still unwind correctly.
    func pinDiffDefaults() {
        pin(\.defaultConflictResolution, to: .alwaysAsk)
        pin(\.forceUpdateAll, to: false)
        pin(\.syncPostalCountryCodes, to: true)
        pin(\.filterByGroups, to: false)
        pin(\.syncDeletedContacts, to: false)
        pin(\.historyRetentionDays, to: 30)
    }

    override func tearDown() {
        for restore in restorers.reversed() { restore() }
        restorers.removeAll()
        super.tearDown()
    }
}

// MARK: - Recording connector fakes (issue #94)

/// Records every Google-side call the engine makes; performs no I/O.
@MainActor
final class RecordingGoogleConnector: GoogleContactsProviding {

    private(set) var calls: [String] = []
    /// Thrown by every batch endpoint when set — the chunk-failure scenario.
    var batchError: Error?

    /// The calls that would have written to Google.
    var writeCalls: [String] {
        calls.filter { !$0.hasPrefix("fetch") && $0 != "cacheETags" }
    }

    func fetchAllContacts() async throws -> [GoogleContact] {
        calls.append("fetchAllContacts")
        return []
    }

    func fetchContact(resourceName: String) async throws -> GoogleContact {
        calls.append("fetchContact(\(resourceName))")
        return GoogleContact(id: resourceName)
    }

    func createContact(_ contact: GoogleContact) async throws -> GoogleContact {
        calls.append("createContact")
        return contact.resourceName.isEmpty
            ? GoogleContact(id: "people/created-\(calls.count)")
            : contact
    }

    func updateContact(_ contact: GoogleContact) async throws -> GoogleContact {
        calls.append("updateContact(\(contact.resourceName))")
        return contact
    }

    func deleteContact(resourceName: String) async throws {
        calls.append("deleteContact(\(resourceName))")
    }

    func batchCreateContacts(_ contacts: [GoogleContact]) async throws -> [GoogleContact?] {
        calls.append("batchCreateContacts")
        if let batchError { throw batchError }
        return contacts.enumerated().map { index, contact in
            contact.resourceName.isEmpty
                ? GoogleContact(id: "people/batch-created-\(index)")
                : contact
        }
    }

    func batchUpdateContacts(_ contacts: [GoogleContact]) async throws -> [String: GoogleContact] {
        calls.append("batchUpdateContacts")
        if let batchError { throw batchError }
        return Dictionary(uniqueKeysWithValues: contacts.map { ($0.resourceName, $0) })
    }

    func batchDeleteContacts(resourceNames: [String]) async throws {
        calls.append("batchDeleteContacts")
        if let batchError { throw batchError }
    }

    func cacheETags(from contacts: [GoogleContact]) {
        calls.append("cacheETags")
    }

    func knownETag(for resourceName: String) -> String? { nil }
}

/// Records every Mac-side call; hands back seeded contacts instead of talking
/// to contactsd. `@unchecked Sendable` because the protocol's requirements run
/// on the Contacts write queue — the lock is what makes that safe.
final class RecordingMacConnector: MacContactsProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _seeded: [String: CNContact] = [:]
    private var _updated: [CNMutableContact] = []
    private var _saved: [CNMutableContact] = []

    var calls: [String] { lock.withLock { _calls } }
    var updatedContacts: [CNMutableContact] { lock.withLock { _updated } }
    var savedContacts: [CNMutableContact] { lock.withLock { _saved } }

    /// The calls that would have written to the Mac address book.
    var writeCalls: [String] {
        calls.filter { !$0.hasPrefix("fetch") }
    }

    func seed(_ contact: CNContact, forIdentifier identifier: String) {
        lock.withLock { _seeded[identifier] = contact }
    }

    func fetchAllContactsOffMainActor() async throws -> [CNContact] {
        lock.withLock { _calls.append("fetchAllContactsOffMainActor") }
        return []
    }

    func fetchContactSync(withIdentifier identifier: String) throws -> CNContact? {
        lock.withLock {
            _calls.append("fetchContactSync(\(identifier))")
            return _seeded[identifier]
        }
    }

    func updateContactSync(_ contact: CNMutableContact) throws {
        lock.withLock {
            _calls.append("updateContactSync")
            _updated.append(contact)
        }
    }

    func saveContactSync(_ contact: CNMutableContact, to container: CNContainer?) throws {
        lock.withLock {
            _calls.append("saveContactSync")
            _saved.append(contact)
        }
    }

    func deleteContactSync(withIdentifier identifier: String) throws {
        lock.withLock { _calls.append("deleteContactSync(\(identifier))") }
    }
}

// MARK: - Issue #94: executeSync integration through the seam

/// The hold-back gates (#1 unconfirmed merges, #24 set-aside, #53/#102 strike
/// accounting) tested at their *call sites* in `executeSync` — not as pure
/// functions. Un-wiring any gate now fails a test instead of staying green.
@MainActor
final class SyncEngineExecuteIntegrationTests: SettingsPinnedTestCase {

    override func setUp() {
        super.setUp()
        pin(\.dryRunMode, to: false)
        pin(\.batchGoogleUpdates, to: true)
        pin(\.confirmPendingDeletions, to: true)
        pin(\.autoBackupEnabled, to: false)
        pin(\.syncPhotos, to: false)
        pin(\.historyRetentionDays, to: 30)
    }

    private func makeEngine() -> (SyncEngine, RecordingGoogleConnector, RecordingMacConnector) {
        let google = RecordingGoogleConnector()
        let mac = RecordingMacConnector()
        let engine = SyncEngine(googleConnector: google,
                                macConnector: mac,
                                mappingStore: ContactMappingStore.testStore())
        return (engine, google, mac)
    }

    private func session(direction: SyncDirection,
                         reviewed: Bool,
                         changes: [ContactChange]) -> SyncSession {
        var s = SyncSession(mode: .manual, direction: direction,
                            startTime: Date(), contactChanges: changes)
        s.userReviewed = reviewed
        return s
    }

    // (1) An unreviewed, nil-override merge performs no connector calls and
    // is counted as deferred.
    func test_unconfirmedMerge_performsNoConnectorCalls_andCountsDeferred() async throws {
        let (engine, google, mac) = makeEngine()
        let merge = ContactChange(
            contactName: "David Chan", action: .merge, direction: .twoWay,
            changes: ["Possible match: same name only"],
            sourceContact: .diffMake(givenName: "David",
                                     googleResourceName: "people/it-merge"),
            targetContact: .diffMake(givenName: "David",
                                     macContactIdentifier: "mac/it-merge"))

        let result = try await engine.executeSync(
            session: session(direction: .twoWay, reviewed: false, changes: [merge]))

        XCTAssertEqual(result.deferredMerges, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.merged, 0)
        XCTAssertTrue(google.calls.isEmpty,
                      "an unconfirmed merge must never reach Google: \(google.calls)")
        XCTAssertTrue(mac.calls.isEmpty,
                      "an unconfirmed merge must never reach the Mac store: \(mac.calls)")
    }

    // Positive control for (1): the same merge with an explicit decision
    // writes to both sides. Proves the gate — not a broken engine — is what
    // kept the connectors silent above.
    func test_confirmedMerge_writesBothSides() async throws {
        let (engine, google, mac) = makeEngine()
        let existing = CNMutableContact()
        existing.givenName = "David"
        mac.seed(existing, forIdentifier: "mac/it-confirmed")

        var merge = ContactChange(
            contactName: "David Chan", action: .merge, direction: .twoWay,
            changes: ["Matched on a shared email address"],
            sourceContact: .diffMake(givenName: "David",
                                     googleResourceName: "people/it-confirmed"),
            targetContact: .diffMake(givenName: "David",
                                     macContactIdentifier: "mac/it-confirmed"))
        merge.userOverride = .merge

        let result = try await engine.executeSync(
            session: session(direction: .twoWay, reviewed: false, changes: [merge]))

        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(result.deferredMerges, 0)
        XCTAssertTrue(google.calls.contains { $0.hasPrefix("updateContact(people/it-confirmed") },
                      "the confirmed merge writes the union to Google")
        XCTAssertTrue(mac.calls.contains("updateContactSync"),
                      "the confirmed merge writes the union to the Mac store")
        XCTAssertNotNil(engine.mappingStore.getMapping(googleResourceName: "people/it-confirmed"),
                        "the applied merge links the pair")
    }

    // (2) A set-aside contact reaches no connector — not even the batch
    // pre-pass (issue #24's gate, at its call site).
    func test_setAsideContact_reachesNoConnector() async throws {
        let key = "mac:it-setaside-\(UUID().uuidString)"
        let macID = String(key.dropFirst("mac:".count))
        defer { SyncFailureStore.shared.clearFailure(key: key) }
        for _ in 1...SyncFailureStore.attemptsBeforeSkipping {
            SyncFailureStore.shared.recordFailure(key: key, name: "Stuck", reason: "134092")
        }

        let (engine, google, mac) = makeEngine()
        let update = ContactChange(
            contactName: "Stuck", action: .update, direction: .macToGoogle,
            changes: ["Name changed"],
            sourceContact: .diffMake(givenName: "Stuck", macContactIdentifier: macID),
            targetContact: .diffMake(givenName: "Stuck",
                                     googleResourceName: "people/it-setaside"))

        let result = try await engine.executeSync(
            session: session(direction: .macToGoogle, reviewed: true, changes: [update]))

        XCTAssertEqual(result.setAside, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertTrue(google.calls.isEmpty,
                      "set aside means set aside — nothing may reach Google: \(google.calls)")
        XCTAssertTrue(mac.calls.isEmpty, "…nor the Mac store: \(mac.calls)")
    }

    // (3) A chunk-level batch failure reports errors but advances no strike
    // counts (issues #53/#102, at the call site that wraps and rethrows).
    func test_chunkLevelBatchFailure_addsErrors_butAdvancesNoStrikes() async throws {
        let macIDs = ["it-chunk-a-\(UUID().uuidString)", "it-chunk-b-\(UUID().uuidString)"]
        let keys = macIDs.map { "mac:\($0)" }
        defer { for key in keys { SyncFailureStore.shared.clearFailure(key: key) } }

        let (engine, google, mac) = makeEngine()
        google.batchError = GoogleContactsError.apiError(statusCode: 400,
                                                         message: "stale etag")

        let changes = macIDs.enumerated().map { index, macID in
            ContactChange(
                contactName: "Chunk \(index)", action: .update, direction: .macToGoogle,
                changes: ["Name changed"],
                sourceContact: .diffMake(givenName: "Chunk\(index)",
                                         macContactIdentifier: macID),
                targetContact: .diffMake(givenName: "Chunk\(index)",
                                         googleResourceName: "people/it-chunk-\(index)"))
        }

        let result = try await engine.executeSync(
            session: session(direction: .macToGoogle, reviewed: true, changes: changes))

        XCTAssertEqual(result.errors.count, 2,
                       "both members of the failed chunk report their failure")
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(google.calls, ["batchUpdateContacts"],
                       "the chunk failed as one HTTP call; no per-contact retries follow")
        XCTAssertTrue(mac.calls.isEmpty)
        for key in keys {
            XCTAssertFalse(SyncFailureStore.shared.shouldSkip(key: key))
            XCTAssertFalse(SyncFailureStore.shared.allFailures().contains { $0.id == key },
                           "a chunk-level failure says nothing about \(key) and must not strike it")
        }
    }

    // Companion gate at its call site: an unreviewed deletion is recorded,
    // not performed.
    func test_unreviewedDeletion_isHeldBack_andReachesNoConnector() async throws {
        let (engine, google, mac) = makeEngine()
        let deletion = ContactChange(
            contactName: "Going Away", action: .delete, direction: .macToGoogle,
            changes: ["Deleted on Mac"],
            sourceContact: .diffMake(givenName: "Going",
                                     googleResourceName: "people/it-delete"))

        let result = try await engine.executeSync(
            session: session(direction: .macToGoogle, reviewed: false, changes: [deletion]))

        XCTAssertEqual(result.deferredDeletions, 1)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(google.calls.isEmpty,
                      "an unreviewed deletion must not reach Google: \(google.calls)")
        XCTAssertTrue(mac.calls.isEmpty)
    }
}

// MARK: - Issue #93: v1 snapshot fixture through the real restore path

/// A genuine first-release backup snapshot decoded and driven through
/// `SyncEngine.restoreContactVersion` — the entry point that contains the
/// legacy-detection predicate (`version.data.urls == nil`). If that predicate
/// regresses, these tests fail; the mask-only unit test could not see it.
@MainActor
final class LegacySnapshotRestoreTests: SettingsPinnedTestCase {

    /// Byte-genuine v1 shape: exactly the keys the first release encoded.
    /// No `urls`, no `birthday`, no nickname/prefix/suffix/phonetics/
    /// department, no captured identifiers.
    private static let v1SnapshotJSON = """
    {
      "displayName": "Legacy Person",
      "givenName": "Legacy",
      "familyName": "Person",
      "phoneNumbers": [{"value": "+1 555 000 1234", "label": "mobile"}],
      "emailAddresses": [{"value": "legacy@example.com", "label": "work"}],
      "postalAddresses": [],
      "organization": "Acme Corp",
      "customFields": {}
    }
    """

    /// A live Mac contact carrying every field v1 never captured.
    private func seededMacContact() -> CNMutableContact {
        let live = CNMutableContact()
        live.givenName = "Old"
        live.familyName = "Name"
        live.nickname = "Vic"
        live.namePrefix = "Dr."
        live.departmentName = "R&D"
        live.birthday = DateComponents(year: 1990, month: 1, day: 2)
        live.urlAddresses = [CNLabeledValue(
            label: CNLabelURLAddressHomePage,
            value: "https://example.com" as NSString)]
        return live
    }

    private func version(from snapshot: ContactSnapshot,
                         identifier: String) -> ContactVersion {
        ContactVersion(
            id: UUID().uuidString,
            contactIdentifier: identifier,
            contactName: snapshot.displayName,
            versionNumber: 1,
            timestamp: Date(),
            syncSessionId: "restore-test",
            source: .mac,
            data: snapshot,
            changesSummary: [])
    }

    private func restore(_ version: ContactVersion,
                         seeding live: CNMutableContact,
                         identifier: String) async throws -> CNMutableContact {
        let google = RecordingGoogleConnector()
        let mac = RecordingMacConnector()
        let engine = SyncEngine(googleConnector: google,
                                macConnector: mac,
                                mappingStore: ContactMappingStore.testStore())
        mac.seed(live, forIdentifier: identifier)
        _ = try await engine.restoreContactVersion(version)
        return try XCTUnwrap(mac.updatedContacts.first,
                             "the restore must write back through updateContactSync")
    }

    func test_v1Snapshot_restore_preservesFieldsTheSnapshotNeverCaptured() async throws {
        let snapshot = try JSONDecoder().decode(
            ContactSnapshot.self, from: Data(Self.v1SnapshotJSON.utf8))
        // The predicate's marker, proven from the genuine fixture: v1 encodes
        // no urls key at all, so a legacy snapshot decodes it as nil.
        XCTAssertNil(snapshot.urls)
        XCTAssertNil(snapshot.birthday)
        XCTAssertNil(snapshot.nickname)

        let identifier = "mac-legacy-restore-1"
        let written = try await restore(version(from: snapshot, identifier: identifier),
                                        seeding: seededMacContact(),
                                        identifier: identifier)

        // Fields v1 never captured must survive the restore untouched.
        XCTAssertEqual(written.nickname, "Vic")
        XCTAssertEqual(written.namePrefix, "Dr.")
        XCTAssertEqual(written.departmentName, "R&D")
        XCTAssertEqual(written.birthday?.year, 1990)
        XCTAssertEqual(written.urlAddresses.count, 1,
                       "a legacy restore must not blank the websites it never captured")

        // Fields v1 did capture still restore.
        XCTAssertEqual(written.givenName, "Legacy")
        XCTAssertEqual(written.familyName, "Person")
        XCTAssertEqual(written.organizationName, "Acme Corp")
        XCTAssertEqual(written.phoneNumbers.first?.value.stringValue, "+1 555 000 1234")
    }

    func test_v2Snapshot_restore_isFullFidelity_includingClears() async throws {
        // The same payload plus an (empty) urls array — the v2 marker. The
        // predicate must read this as current-format and restore at full
        // fidelity, clearing the fields the snapshot genuinely lacks.
        let v2JSON = Self.v1SnapshotJSON.replacingOccurrences(
            of: "\"customFields\": {}",
            with: "\"customFields\": {}, \"urls\": []")
        let snapshot = try JSONDecoder().decode(ContactSnapshot.self, from: Data(v2JSON.utf8))
        XCTAssertNotNil(snapshot.urls, "urls == [] is the current-format marker")

        let identifier = "mac-v2-restore-1"
        let written = try await restore(version(from: snapshot, identifier: identifier),
                                        seeding: seededMacContact(),
                                        identifier: identifier)

        XCTAssertEqual(written.nickname, "",
                       "a v2 snapshot with no nickname restores the clear")
        XCTAssertNil(written.birthday)
        XCTAssertTrue(written.urlAddresses.isEmpty)
        XCTAssertEqual(written.givenName, "Legacy")
    }
}
