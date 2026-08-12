// ContactSyncMateTests.swift
// Automated test suite for Contact SyncMate — matches real API signatures
// Run via Xcode Test navigator (⌘U) or xcodebuild test

import XCTest
@testable import Contact_SyncMate

// MARK: - Test Helpers

extension UnifiedContact {
    static func make(
        id: UUID = UUID(),
        givenName: String? = nil,
        familyName: String? = nil,
        organizationName: String? = nil,
        phones: [String] = [],
        emails: [String] = [],
        googleResourceName: String? = nil,
        macContactIdentifier: String? = nil,
        lastModified: Date? = nil
    ) -> UnifiedContact {
        var c = UnifiedContact(id: id)
        c.givenName             = givenName
        c.familyName            = familyName
        c.organizationName      = organizationName
        c.phoneNumbers          = phones.map  { UnifiedContact.PhoneNumber(value: $0, label: "mobile") }
        c.emailAddresses        = emails.map  { UnifiedContact.EmailAddress(value: $0, label: "work") }
        c.googleResourceName    = googleResourceName
        c.macContactIdentifier  = macContactIdentifier
        c.lastModified          = lastModified
        return c
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 1. UnifiedContact Model
// ─────────────────────────────────────────────────────────────

final class UnifiedContactTests: XCTestCase {

    func test_displayName_fullName() {
        let c = UnifiedContact.make(givenName: "John", familyName: "Smith")
        XCTAssertEqual(c.displayName, "John Smith")
    }

    func test_displayName_givenNameOnly() {
        let c = UnifiedContact.make(givenName: "Madonna")
        XCTAssertEqual(c.displayName, "Madonna")
    }

    func test_displayName_fallsBackToEmail() {
        let c = UnifiedContact.make(emails: ["test@example.com"])
        XCTAssertEqual(c.displayName, "test@example.com")
    }

    func test_displayName_unknownWhenEmpty() {
        let c = UnifiedContact.make()
        XCTAssertEqual(c.displayName, "Unnamed contact")
    }

    /// Empty strings are not nil, so `if let givenName` used to succeed for them
    /// and produce a name of pure whitespace — which is not `.isEmpty`, so the
    /// fallback never ran and contacts showed up blank in logs and previews.
    func test_displayName_treatsBlankNamePartsAsMissing() {
        var c = UnifiedContact.make(emails: ["blank@example.com"])
        c.givenName = ""
        c.familyName = "   "
        XCTAssertEqual(c.displayName, "blank@example.com")
    }

    /// The bug that pushed 229 duplicates into Google: a Mac contact that already
    /// exists on the other side must be matched, not re-added.
    func test_identityKeys_matchOnEmailAndPhone() {
        let mac = UnifiedContact.make(phones: ["+852 9123 4567"], emails: ["Person@Example.COM"])
        let google = UnifiedContact.make(phones: ["91234567"], emails: ["person@example.com"])

        let macKeys = Set(SyncEngine.identityKeys(for: mac))
        let googleKeys = Set(SyncEngine.identityKeys(for: google))

        XCTAssertFalse(macKeys.isDisjoint(with: googleKeys),
                       "same person stored with different case and country code must still match")
        XCTAssertTrue(macKeys.contains("email:person@example.com"))
        XCTAssertTrue(macKeys.contains("phone:91234567"))
    }

    /// Names are deliberately not identity keys — two different "David Chan"
    /// records must not be fused, which loses data rather than merely duplicating.
    func test_identityKeys_ignoreNames() {
        let c = UnifiedContact.make(givenName: "David", familyName: "Chan")
        XCTAssertTrue(SyncEngine.identityKeys(for: c).isEmpty)
    }

    /// A short extension is not enough to identify a person.
    func test_identityKeys_ignoreShortNumbers() {
        let c = UnifiedContact.make(phones: ["1234"])
        XCTAssertTrue(SyncEngine.identityKeys(for: c).isEmpty)
    }

    func test_displayName_fallsBackToPhoneWhenNoName() {
        let c = UnifiedContact.make(phones: ["+1 555 0101"])
        XCTAssertEqual(c.displayName, "+1 555 0101")
    }

    /// A row with nothing in it must not be pushed to the other side — doing so
    /// creates a permanent blank contact there.
    func test_hasSyncableContent_rejectsEmptyRow() {
        var c = UnifiedContact.make()
        c.givenName = "  "
        XCTAssertFalse(c.hasSyncableContent)

        XCTAssertTrue(UnifiedContact.make(phones: ["+1 555 0101"]).hasSyncableContent)
        XCTAssertTrue(UnifiedContact.make(emails: ["a@b.com"]).hasSyncableContent)
    }

    // Issue #128: the construct-and-read tests that used to live here
    // (test_phoneNumber_stored and friends) asserted memberwise semantics the
    // compiler already guarantees, and were deleted rather than kept as padding.
}

// MARK: ─────────────────────────────────────────────────────────
// 2. ContactNormalizer
// ─────────────────────────────────────────────────────────────

final class ContactNormalizerTests: XCTestCase {

    func test_normalizeName_trimsWhitespace() {
        let result = ContactNormalizer.normalizeName("  John  ")
        XCTAssertEqual(result, "john") // normalizer lowercases for fuzzy matching
    }

    func test_normalizeName_emptyString() {
        let result = ContactNormalizer.normalizeName("")
        XCTAssertEqual(result, "")
    }

    func test_normalizeName_nil() {
        let result = ContactNormalizer.normalizeName(nil)
        XCTAssertEqual(result, "")
    }

    func test_normalizeEmail_lowercased() {
        let result = ContactNormalizer.normalizeEmail("Test@Example.COM")
        XCTAssertEqual(result, "test@example.com")
    }

    func test_normalizeEmail_trimsWhitespace() {
        let result = ContactNormalizer.normalizeEmail("  user@test.com  ")
        XCTAssertEqual(result, "user@test.com")
    }

    func test_normalizeEmail_nil() {
        let result = ContactNormalizer.normalizeEmail(nil)
        XCTAssertEqual(result, "")
    }

    /// Issue #131: the exact normalized output, not an OR over literals that
    /// accepted both stripped and unstripped results.
    func test_normalizePhone_stripsFormatting() {
        XCTAssertEqual(ContactNormalizer.normalizePhone("(555) 123-4567"), "5551234567")
        XCTAssertEqual(ContactNormalizer.normalizePhone("+1 (555) 123-4567"), "+15551234567",
                       "a leading + survives; every other non-digit is stripped")
        XCTAssertEqual(ContactNormalizer.normalizePhone("ext."), "",
                       "no digits means no key — not a stray '+' or punctuation")
    }

    func test_normalizePhone_nil() {
        let result = ContactNormalizer.normalizePhone(nil)
        XCTAssertEqual(result, "")
    }

    func test_normalizeEmails_deduplicates() {
        let emails = ["A@test.com", "a@test.com", "B@test.com"]
        let result = ContactNormalizer.normalizeEmails(emails)
        XCTAssertTrue(result.contains("a@test.com"))
        XCTAssertTrue(result.contains("b@test.com"))
        // "a@test.com" should only appear once (deduplicated)
        XCTAssertEqual(result.count, 2)
    }

    func test_normalizeOrganization_trimsWhitespace() {
        let result = ContactNormalizer.normalizeOrganization("  Apple Inc.  ")
        XCTAssertEqual(result, "apple") // normalizer lowercases + strips "inc."
    }

    func test_normalizeFullName_combined() {
        let result = ContactNormalizer.normalizeFullName(given: "John", middle: "A.", family: "Smith")
        XCTAssertTrue(result.contains("john")) // normalizer lowercases
        XCTAssertTrue(result.contains("smith"))
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 3. SyncEngine Model Types
// ─────────────────────────────────────────────────────────────

final class SyncEngineModelTests: XCTestCase {

    // Issues #128/#129: the construct-and-read tests (contactChange
    // properties, session/error IDs) and the self-asserting case-count tests
    // (test_syncDirection_cases / test_syncMode_cases, which measured a
    // literal array's own length) were deleted — they could never fail.

    func test_syncResult_duration() {
        let start = Date()
        let end   = start.addingTimeInterval(2.5)
        let result = SyncResult(
            mode: .manual, direction: .twoWay,
            startTime: start, endTime: end,
            added: 3, updated: 1, deleted: 0, merged: 0, skipped: 1,
            errors: []
        )
        XCTAssertEqual(result.duration, 2.5, accuracy: 0.01)
    }

    func test_syncResult_successful_whenNoErrors() {
        let result = SyncResult(
            mode: .manual, direction: .googleToMac,
            startTime: Date(), endTime: Date(),
            added: 5, updated: 0, deleted: 0, merged: 0, skipped: 0,
            errors: []
        )
        XCTAssertTrue(result.successful)
    }

    func test_syncResult_unsuccessful_whenErrors() {
        let err = SyncError(contactName: "Bob", message: "API error", timestamp: Date())
        let result = SyncResult(
            mode: .manual, direction: .googleToMac,
            startTime: Date(), endTime: Date(),
            added: 0, updated: 0, deleted: 0, merged: 0, skipped: 0,
            errors: [err]
        )
        XCTAssertFalse(result.successful)
    }

    /// Issue #132: the full formatted line, not `contains("3")` — which
    /// passed for any 3 anywhere in any count.
    func test_syncResult_summary_isTheFullFormattedLine() {
        let result = SyncResult(
            mode: .manual, direction: .twoWay,
            startTime: Date(), endTime: Date(),
            added: 3, updated: 2, deleted: 1, merged: 0, skipped: 0,
            errors: []
        )
        XCTAssertEqual(result.summary,
                       "Added: 3, Updated: 2, Deleted: 1, Merged: 0, Skipped: 0")
    }

    func test_syncResult_summary_appendsFailureAndHoldBackLines() {
        let err = SyncError(contactName: "Bob", message: "boom", timestamp: Date())
        let result = SyncResult(
            mode: .manual, direction: .twoWay,
            startTime: Date(), endTime: Date(),
            added: 0, updated: 0, deleted: 0, merged: 0, skipped: 3,
            errors: [err],
            deferredDeletions: 1, deferredMerges: 2, setAside: 1
        )
        XCTAssertEqual(result.summary, """
            Added: 0, Updated: 0, Deleted: 0, Merged: 0, Skipped: 3
            Failed: 1
            Set aside after repeated failures: 1
            Held back for review: 1 deletion
            Held back for review: 2 unconfirmed merges
            """)
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 4. ContactMappingStore
// ─────────────────────────────────────────────────────────────

final class ContactMappingStoreTests: XCTestCase {

    var store: ContactMappingStore!

    override func setUp() {
        store = ContactMappingStore.testStore()
    }

    /// Issue #108: the store is a fresh temp file, so empty *is* the
    /// contract — not "NotNil" on a non-optional return.
    func test_getAllMappings_initiallyEmpty() {
        XCTAssertTrue(store.getAllMappings().isEmpty,
                      "a store over a fresh temp file must start with no mappings")
    }

    func test_saveAndRetrieveMapping_byGoogleID() {
        let mapping = ContactMapping(
            googleResourceName: "people/test-\(UUID().uuidString)",
            macContactIdentifier: "mac-\(UUID().uuidString)",
            lastSyncedAt: Date()
        )
        store.saveMapping(mapping)
        let found = store.getMapping(googleResourceName: mapping.googleResourceName)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.macContactIdentifier, mapping.macContactIdentifier)
    }

    func test_saveAndRetrieveMapping_byMacID() {
        let macID = "mac-lookup-\(UUID().uuidString)"
        let mapping = ContactMapping(
            googleResourceName: "people/lookup-\(UUID().uuidString)",
            macContactIdentifier: macID,
            lastSyncedAt: Date()
        )
        store.saveMapping(mapping)
        let found = store.getMapping(macIdentifier: macID)
        XCTAssertNotNil(found)
    }

    func test_deleteMapping_removesEntry() {
        let gID = "people/del-\(UUID().uuidString)"
        let mapping = ContactMapping(
            googleResourceName: gID,
            macContactIdentifier: "mac-del",
            lastSyncedAt: Date()
        )
        store.saveMapping(mapping)
        store.deleteMapping(googleResourceName: gID)
        let found = store.getMapping(googleResourceName: gID)
        XCTAssertNil(found, "Deleted mapping should not be retrievable")
    }

    // Issue #128: test_contactMapping_properties / test_contactMapping_optionalEtag
    // (construct-and-read on a plain struct) were deleted.
}

// MARK: ─────────────────────────────────────────────────────────
// 5. SyncEngine Diff Logic
// ─────────────────────────────────────────────────────────────



// MARK: ─────────────────────────────────────────────────────────
// 6. SyncHistory (Event Log)
// ─────────────────────────────────────────────────────────────

extension SyncHistory {
    /// A hermetic history over a unique temp file (issue #92) — mirror of
    /// `ContactMappingStore.testStore()`. Tests must never log to or clear
    /// `SyncHistory.shared`, whose file lives in the app's real container.
    static func testHistory(
        url: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-history-\(UUID().uuidString).json")
    ) -> SyncHistory {
        SyncHistory(persistenceURL: url)
    }
}

final class SyncHistoryTests: SettingsPinnedTestCase {

    override func setUp() {
        super.setUp()
        // `log` prunes with the user-configurable retention window — pin it
        // so a "0 days" (or tiny) user setting cannot change test behaviour.
        pin(\.historyRetentionDays, to: 30)
    }

    func test_log_recordsEvent() {
        let history = SyncHistory.testHistory()
        let event = history.log(source: "TestSuite", action: "unit-test", details: "hello")
        XCTAssertEqual(event.source, "TestSuite")
        XCTAssertEqual(event.action, "unit-test")
        XCTAssertEqual(event.details, "hello")
    }

    func test_events_returnsExactlyTheLoggedEvents() {
        let history = SyncHistory.testHistory()
        history.log(source: "A", action: "sync.start")
        history.log(source: "B", action: "sync.end")
        // events() syncs on the same queue as the log barriers — no sleeps.
        XCTAssertEqual(history.events().map(\.action), ["sync.start", "sync.end"],
                       "a hermetic instance holds exactly what this test logged")
    }

    func test_clear_removesAllEvents() {
        let history = SyncHistory.testHistory()
        history.log(source: "Test", action: "pre-clear")
        history.clear()
        XCTAssertEqual(history.events().count, 0)
    }

    func test_event_hasUniqueID() {
        let history = SyncHistory.testHistory()
        let e1 = history.log(source: "X", action: "a")
        let e2 = history.log(source: "X", action: "b")
        XCTAssertNotEqual(e1.id, e2.id)
    }

    func test_event_timestampIsRecent() {
        let before = Date()
        let event  = SyncHistory.testHistory().log(source: "Timer", action: "now")
        let after  = Date()
        XCTAssertGreaterThanOrEqual(event.timestamp, before)
        XCTAssertLessThanOrEqual(event.timestamp, after)
    }

    func test_persistence_roundTripsThroughInjectedURL() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-history-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = SyncHistory.testHistory(url: url)
        history.log(source: "Persist", action: "event", details: "survives")
        history.flush()

        let reloaded = SyncHistory(persistenceURL: url)
        XCTAssertEqual(reloaded.events().map(\.action), ["event"],
                       "a second instance over the same file sees the flushed event")
        XCTAssertEqual(reloaded.events().first?.details, "survives")
    }

    func test_clear_writesThroughToDisk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-history-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = SyncHistory.testHistory(url: url)
        history.log(source: "Clear", action: "doomed")
        history.flush()
        history.clear()
        // clear() is write-through; events() syncs past its barrier.
        XCTAssertEqual(history.events().count, 0)

        let reloaded = SyncHistory(persistenceURL: url)
        XCTAssertTrue(reloaded.events().isEmpty,
                      "a crash after clear must not resurrect the cleared events")
    }

    func test_instances_areIsolated() {
        let a = SyncHistory.testHistory()
        let b = SyncHistory.testHistory()
        a.log(source: "A", action: "only-in-a")
        XCTAssertTrue(b.events().isEmpty,
                      "separate temp files means separate histories — and neither is the real one")
    }

    func test_formatters_contactSummary_bothPresent() {
        let s = SyncHistoryFormatters.contactSummary(id: "abc", name: "John")
        XCTAssertTrue(s.contains("abc"))
        XCTAssertTrue(s.contains("John"))
    }

    func test_formatters_contactSummary_noName() {
        let s = SyncHistoryFormatters.contactSummary(id: "xyz", name: nil)
        XCTAssertTrue(s.contains("xyz"))
    }

    func test_formatters_contactSummary_neither() {
        let s = SyncHistoryFormatters.contactSummary(id: nil, name: nil)
        XCTAssertTrue(s.contains("unknown"))
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 7. Deduplication Engine
// ─────────────────────────────────────────────────────────────

extension DeduplicationDecisionStore {
    /// A hermetic decision store over a unique temp directory (issue #106),
    /// with pattern-memory logging pointed at a temp-file history — so dedup
    /// tests neither read the user's real `dedup_decisions.json` nor write
    /// events into the real sync history.
    static func testStore(
        directoryURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dedup-\(UUID().uuidString)", isDirectory: true)
    ) -> DeduplicationDecisionStore {
        DeduplicationDecisionStore(directoryURL: directoryURL,
                                   history: SyncHistory.testHistory())
    }
}

final class DeduplicationTests: XCTestCase {

    var deduplicator: ContactDeduplicator!

    override func setUp() {
        let config = ContactDeduplicator.Configuration()
        deduplicator = ContactDeduplicator(
            config: config,
            decisionStore: DeduplicationDecisionStore.testStore()
        )
    }

    func test_detectDuplicates_emptyLists_noGroups() async {
        let result = await deduplicator.detectDuplicates(
            googleContacts: [],
            macContacts: [],
            existingMappings: []
        )
        XCTAssertTrue(result.duplicateGroups.isEmpty)
    }

    func test_detectDuplicates_singleContact_noGroups() async {
        let c = UnifiedContact.make(givenName: "Solo", familyName: "Contact", googleResourceName: "people/solo")
        let result = await deduplicator.detectDuplicates(
            googleContacts: [c],
            macContacts: [],
            existingMappings: []
        )
        XCTAssertTrue(result.duplicateGroups.isEmpty,
            "A single contact cannot be a duplicate")
    }

    func test_detectDuplicates_exactNameMatch_flagged() async {
        // Give contacts matching names AND emails to ensure score >= confirmationThreshold (50)
        var g = UnifiedContact.make(givenName: "John", familyName: "Smith", googleResourceName: "people/j1")
        var m = UnifiedContact.make(givenName: "John", familyName: "Smith", macContactIdentifier: "mac/j1")
        g.emailAddresses = [UnifiedContact.EmailAddress(value: "john.smith@test.com", label: "work")]
        m.emailAddresses = [UnifiedContact.EmailAddress(value: "john.smith@test.com", label: "home")]
        let result = await deduplicator.detectDuplicates(
            googleContacts: [g],
            macContacts: [m],
            existingMappings: []
        )
        // Same name + same email = high confidence duplicate
        XCTAssertFalse(result.duplicateGroups.isEmpty,
            "Same name + email across sources should be flagged as potential duplicates")
    }

    func test_detectDuplicates_differentNames_noMatch() async {
        let g = UnifiedContact.make(givenName: "Alice", familyName: "Smith", googleResourceName: "people/a")
        let m = UnifiedContact.make(givenName: "Bob",   familyName: "Jones", macContactIdentifier: "mac/b")
        let result = await deduplicator.detectDuplicates(
            googleContacts: [g],
            macContacts: [m],
            existingMappings: []
        )
        XCTAssertTrue(result.duplicateGroups.isEmpty,
            "Completely different contacts should not match")
    }

    func test_detectDuplicates_sameEmail_flagged() async {
        var g = UnifiedContact.make(givenName: "John A", googleResourceName: "people/email1")
        var m = UnifiedContact.make(givenName: "John B", macContactIdentifier: "mac/email1")
        g.emailAddresses = [UnifiedContact.EmailAddress(value: "john@test.com", label: "work")]
        m.emailAddresses = [UnifiedContact.EmailAddress(value: "john@test.com", label: "home")]
        let result = await deduplicator.detectDuplicates(
            googleContacts: [g],
            macContacts: [m],
            existingMappings: []
        )
        XCTAssertFalse(result.duplicateGroups.isEmpty,
            "Same email address should flag as potential duplicate")
    }

    func test_detectDuplicates_stats_scannedCount() async {
        let contacts = (0..<5).map { i in
            UnifiedContact.make(givenName: "Person\(i)", googleResourceName: "people/\(i)")
        }
        let result = await deduplicator.detectDuplicates(
            googleContacts: contacts,
            macContacts: [],
            existingMappings: []
        )
        XCTAssertEqual(result.stats.totalContactsScanned, 5)
    }

    func test_detectDuplicates_alreadyMapped_skipped() async {
        let g = UnifiedContact.make(givenName: "Mapped", familyName: "Person", googleResourceName: "people/mapped")
        let m = UnifiedContact.make(givenName: "Mapped", familyName: "Person", macContactIdentifier: "mac/mapped")
        let mapping = ContactMapping(
            googleResourceName: "people/mapped",
            macContactIdentifier: "mac/mapped",
            lastSyncedAt: Date()
        )
        let result = await deduplicator.detectDuplicates(
            googleContacts: [g],
            macContacts: [m],
            existingMappings: [mapping]
        )
        // Already-mapped contacts should not be flagged as duplicates
        XCTAssertTrue(result.duplicateGroups.isEmpty,
            "Already-mapped contacts should not appear as duplicates")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 7b. DeduplicationDecisionStore (issue #106 — via the directory seam)
// ─────────────────────────────────────────────────────────────

final class DeduplicationDecisionStoreTests: XCTestCase {

    func test_savePattern_isRetrievable() {
        let store = DeduplicationDecisionStore.testStore()
        store.savePattern(pattern: "john smith|john smith", decision: .merge)
        // getDecision syncs on the store's queue, past the save barrier.
        XCTAssertEqual(store.getDecision(for: "john smith|john smith"), .merge)
        XCTAssertNil(store.getDecision(for: "unknown|pattern"))
    }

    func test_deletePattern_removesOnlyThatPattern() {
        let store = DeduplicationDecisionStore.testStore()
        store.savePattern(pattern: "a|b", decision: .keepSeparate)
        store.savePattern(pattern: "c|d", decision: .skip)
        store.deletePattern("a|b")
        XCTAssertNil(store.getDecision(for: "a|b"))
        XCTAssertEqual(store.getDecision(for: "c|d"), .skip)
    }

    func test_clearAll_emptiesStore_andStatisticsAgree() {
        let store = DeduplicationDecisionStore.testStore()
        store.savePattern(pattern: "a|b", decision: .merge)
        store.savePattern(pattern: "c|d", decision: .keepSeparate)

        var stats = store.getStatistics()
        XCTAssertEqual(stats.totalPatterns, 2)
        XCTAssertEqual(stats.mergePatterns, 1)
        XCTAssertEqual(stats.keepSeparatePatterns, 1)

        store.clearAll()
        stats = store.getStatistics()
        XCTAssertEqual(stats.totalPatterns, 0)
        XCTAssertTrue(store.getAllPatterns().isEmpty)
    }

    func test_persistence_roundTripsAcrossInstancesInSameDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dedup-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = DeduplicationDecisionStore.testStore(directoryURL: dir)
        first.savePattern(pattern: "pat lee|pat lee", decision: .merge)
        // Barrier sync via a read: saveToDisk ran inside the save barrier.
        XCTAssertEqual(first.getDecision(for: "pat lee|pat lee"), .merge)

        let second = DeduplicationDecisionStore.testStore(directoryURL: dir)
        XCTAssertEqual(second.getDecision(for: "pat lee|pat lee"), .merge,
                       "a second instance over the same directory reloads the decision")
    }

    func test_testStores_areIsolatedFromEachOther() {
        let a = DeduplicationDecisionStore.testStore()
        let b = DeduplicationDecisionStore.testStore()
        a.savePattern(pattern: "only|in-a", decision: .merge)
        XCTAssertEqual(a.getDecision(for: "only|in-a"), .merge)
        XCTAssertNil(b.getDecision(for: "only|in-a"),
                     "separate temp directories — and neither is the user's real store")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 8. AppSettings
// ─────────────────────────────────────────────────────────────

/// Issue #130: the previous five tests asserted non-optionals and no-throw on
/// non-throwing reads — no-ops, one of them reading the user's live defaults.
///
/// `AppSettings` hard-codes `UserDefaults.standard`, and AppSettings.swift is
/// not open for a suite-scoping seam in this change — so these are genuine
/// round-trip tests through the singleton's `didSet` persistence instead,
/// with every touched key pinned and restored by `SettingsPinnedTestCase` so
/// the user's real values survive the run.
final class AppSettingsTests: SettingsPinnedTestCase {

    func test_boolSetting_roundTripsThroughDefaults() {
        pin(\.syncPhotos, to: true)
        AppSettings.shared.syncPhotos = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "syncPhotos") as? Bool, false,
                       "didSet must persist the new value under its key")
        XCTAssertFalse(AppSettings.shared.syncPhotos)
        AppSettings.shared.syncPhotos = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "syncPhotos") as? Bool, true)
    }

    func test_autoSyncInterval_roundTripsThroughDefaults() {
        pin(\.autoSyncInterval, to: 14400)
        AppSettings.shared.autoSyncInterval = 3600
        XCTAssertEqual(UserDefaults.standard.object(forKey: "autoSyncInterval") as? TimeInterval,
                       3600)
        XCTAssertEqual(AppSettings.shared.autoSyncInterval, 3600)
    }

    func test_historyRetentionDays_roundTripsThroughDefaults() {
        pin(\.historyRetentionDays, to: 30)
        AppSettings.shared.historyRetentionDays = 7
        XCTAssertEqual(UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int, 7)
        XCTAssertEqual(SyncHistory.retentionDays(), 7,
                       "SyncHistory reads the same key the setting writes — the two must agree")
    }

    func test_conflictResolution_roundTripsAsRawValue() {
        pin(\.defaultConflictResolution, to: .alwaysAsk)
        AppSettings.shared.defaultConflictResolution = .preferMac
        XCTAssertEqual(UserDefaults.standard.string(forKey: "defaultConflictResolution"),
                       ConflictResolutionDefault.preferMac.rawValue)
        XCTAssertEqual(AppSettings.shared.defaultConflictResolution, .preferMac)
    }

    func test_syncDeletedContacts_roundTripsThroughDefaults() {
        pin(\.syncDeletedContacts, to: false)
        AppSettings.shared.syncDeletedContacts = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "syncDeletedContacts") as? Bool, true)
        XCTAssertTrue(AppSettings.shared.syncDeletedContacts)
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 9. Performance & Safety Gates
// ─────────────────────────────────────────────────────────────

final class PerformanceTests: SettingsPinnedTestCase {

    func test_buildLookupMap_1000Contacts_under1Second() {
        let contacts = (0..<1000).map { i in
            UnifiedContact.make(givenName: "Contact\(i)", googleResourceName: "people/\(i)")
        }
        let start = Date()
        var map: [String: UnifiedContact] = [:]
        for c in contacts {
            if let rn = c.googleResourceName { map[rn] = c }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "Building map for 1000 contacts must be < 1s")
        XCTAssertEqual(map.count, 1000)
    }

    func test_normalizeEmails_largeSet_under1Second() {
        let emails = (0..<500).map { "user\($0)@example.com" }
        let start = Date()
        let _ = ContactNormalizer.normalizeEmails(emails)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "Normalizing 500 emails must be < 1s")
    }

    func test_syncProgress_percentageEdgeCases() {
        var p = SyncProgress(currentStep: "Test", completedItems: 0, totalItems: 0)
        XCTAssertEqual(p.percentage, 0.0, accuracy: 0.001)

        p = SyncProgress(currentStep: "Test", completedItems: 1, totalItems: 2)
        XCTAssertEqual(p.percentage, 0.5, accuracy: 0.001)

        p = SyncProgress(currentStep: "Test", completedItems: 100, totalItems: 100)
        XCTAssertEqual(p.percentage, 1.0, accuracy: 0.001)
    }

    /// Issue #92: against a hermetic temp-file history, never `shared` —
    /// the old version cleared the user's real diagnostic ledger to run.
    func test_syncHistory_maxEvents_doesNotGrowUnbounded() {
        pin(\.historyRetentionDays, to: 30)
        let history = SyncHistory.testHistory()
        // Log past the 1000-event cap; the prune on each append must hold
        // the line rather than letting the ledger grow without bound.
        for i in 0..<1005 {
            history.log(source: "Perf", action: "event-\(i)")
        }
        let survivors = history.events()
        XCTAssertEqual(survivors.count, 1000,
                       "the cap keeps exactly the most recent 1000 events")
        // Set comparison, not positional: rapid logging can produce equal
        // timestamps, and events() sorts by timestamp.
        XCTAssertEqual(Set(survivors.map(\.action)),
                       Set((5..<1005).map { "event-\($0)" }),
                       "the oldest five events are the ones pruned")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 10. ContactDeduplicator.calculateMatchScore (AUDIT §3, Critical row 1)
// ─────────────────────────────────────────────────────────────

final class ContactDeduplicatorScoreTests: XCTestCase {

    private var deduplicator: ContactDeduplicator!

    override func setUp() {
        super.setUp()
        deduplicator = ContactDeduplicator(config: ContactDeduplicator.Configuration(),
                                           decisionStore: DeduplicationDecisionStore.testStore())
    }

    /// The signed sum of every rule contribution — what `totalScore` clamps.
    private func componentSum(_ b: MatchScoreBreakdown) -> Int {
        b.emailMatch + b.phoneMatch + b.exactNameMatch + b.similarNameMatch +
        b.organizationMatch + b.addressMatch + b.emailDomainMismatch + b.differentContactInfo
    }

    func test_sameEmail_scores60() {
        let a = UnifiedContact.make(emails: ["pat@example.com"])
        let b = UnifiedContact.make(emails: ["pat@example.com"])
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.emailMatch, 60)
        XCTAssertEqual(score.totalScore, 60)
    }

    func test_samePhone_scores60() {
        let a = UnifiedContact.make(phones: ["+15551234567"])
        let b = UnifiedContact.make(phones: ["+1 (555) 123-4567"])
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.phoneMatch, 60, "formatting differences normalize away")
        XCTAssertEqual(score.totalScore, 60)
    }

    func test_exactName_scores30() {
        let a = UnifiedContact.make(givenName: "Pat", familyName: "Lee")
        let b = UnifiedContact.make(givenName: "Pat", familyName: "Lee")
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.exactNameMatch, 30)
        XCTAssertEqual(score.similarNameMatch, 0, "rules 3 and 4 are exclusive")
        XCTAssertEqual(score.totalScore, 30)
    }

    func test_similarName_scores20_notBoth() {
        let a = UnifiedContact.make(givenName: "Jon", familyName: "Smith")
        let b = UnifiedContact.make(givenName: "John", familyName: "Smith")
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.exactNameMatch, 0)
        XCTAssertEqual(score.similarNameMatch, 20, "Levenshtein distance 1 is 'very similar'")
        XCTAssertEqual(score.totalScore, 20,
                       "no contact info on either side, so the similar-name score stands alone")
    }

    func test_sameOrganization_scores10() {
        let a = UnifiedContact.make(organizationName: "Acme Corp")
        let b = UnifiedContact.make(organizationName: "Acme Corp")
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.organizationMatch, 10)
        XCTAssertEqual(score.totalScore, 10)
    }

    func test_sameAddress_scores10() {
        var a = UnifiedContact.make()
        var b = UnifiedContact.make()
        a.postalAddresses = [UnifiedContact.PostalAddress(street: "1 Infinite Loop", city: "Cupertino")]
        b.postalAddresses = [UnifiedContact.PostalAddress(street: "1 Infinite Loop", city: "Cupertino")]
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.addressMatch, 10)
        XCTAssertEqual(score.totalScore, 10)
    }

    func test_sameName_conflictingEmailDomains_minus10() {
        let a = UnifiedContact.make(givenName: "Pat", familyName: "Lee", emails: ["pat@gmail.com"])
        let b = UnifiedContact.make(givenName: "Pat", familyName: "Lee", emails: ["pat@yahoo.com"])
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.emailDomainMismatch, -10)
    }

    func test_sameName_differentContactInfo_minus20() {
        let a = UnifiedContact.make(givenName: "Pat", familyName: "Lee", phones: ["+15551111111"])
        let b = UnifiedContact.make(givenName: "Pat", familyName: "Lee", phones: ["+15552222222"])
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.differentContactInfo, -20)
        XCTAssertEqual(score.emailDomainMismatch, 0, "no emails on either side")
        XCTAssertEqual(score.totalScore, 10, "30 (name) - 20 (different numbers)")
    }

    func test_sameName_bothLackContactInfo_noPenalty() {
        let a = UnifiedContact.make(givenName: "Pat", familyName: "Lee")
        let b = UnifiedContact.make(givenName: "Pat", familyName: "Lee")
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.differentContactInfo, 0,
                       "two bare name-only cards are not evidence of different people")
        XCTAssertEqual(score.totalScore, 30)
    }

    func test_sameName_oneSidedContactInfo_noPenalty() {
        let a = UnifiedContact.make(givenName: "Pat", familyName: "Lee", phones: ["+15551111111"])
        let b = UnifiedContact.make(givenName: "Pat", familyName: "Lee")
        let score = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(score.differentContactInfo, 0,
                       "the penalty needs contact info on both sides to disagree")
    }

    func test_breakdown_sumsToTotal() {
        // Positive case: every additive rule fires.
        var a = UnifiedContact.make(givenName: "Pat", familyName: "Lee",
                                    organizationName: "Acme Corp",
                                    phones: ["+15551234567"], emails: ["pat@example.com"])
        var b = UnifiedContact.make(givenName: "Pat", familyName: "Lee",
                                    organizationName: "Acme Corp",
                                    phones: ["+15551234567"], emails: ["pat@example.com"])
        a.postalAddresses = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        b.postalAddresses = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        let rich = deduplicator.calculateMatchScore(a, b)
        XCTAssertEqual(rich.totalScore, componentSum(rich))
        XCTAssertEqual(componentSum(rich), 60 + 60 + 30 + 10 + 10)

        // Negative sum clamps to zero rather than going below.
        let p = UnifiedContact.make(givenName: "Pat", familyName: "Lee", emails: ["pat@gmail.com"])
        let q = UnifiedContact.make(givenName: "Pat", familyName: "Lee", emails: ["pat@yahoo.com"])
        let clamped = deduplicator.calculateMatchScore(p, q)
        XCTAssertEqual(clamped.totalScore, max(0, componentSum(clamped)))
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 11. DeduplicationCoordinator write-back merge (AUDIT §3, Critical row 4)
// ─────────────────────────────────────────────────────────────

@MainActor
final class DeduplicationMergeIntoTests: XCTestCase {

    private var coordinator: DeduplicationCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = DeduplicationCoordinator()
    }

    func test_mergeInto_primaryWinsOnConflicts() {
        let primary = UnifiedContact.make(givenName: "Amy", familyName: "Wu",
                                          organizationName: "Acme",
                                          googleResourceName: "people/prim")
        let secondary = UnifiedContact.make(givenName: "Amelia", familyName: "Woo",
                                            organizationName: "Other Inc",
                                            macContactIdentifier: "mac/sec")
        let merged = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(merged.givenName, "Amy")
        XCTAssertEqual(merged.familyName, "Wu")
        XCTAssertEqual(merged.organizationName, "Acme")
        XCTAssertEqual(merged.id, primary.id)
        XCTAssertEqual(merged.googleResourceName, "people/prim")
        XCTAssertEqual(merged.macContactIdentifier, "mac/sec",
                       "identifiers union so both records stay addressable")
    }

    func test_mergeInto_secondaryFillsGaps() {
        var primary = UnifiedContact.make(givenName: "")   // empty string is a gap
        primary.jobTitle = nil
        var secondary = UnifiedContact.make(givenName: "Bea", organizationName: "Acme")
        secondary.jobTitle = "Designer"
        secondary.nickname = "B"
        let merged = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(merged.givenName, "Bea")
        XCTAssertEqual(merged.organizationName, "Acme")
        XCTAssertEqual(merged.jobTitle, "Designer")
        XCTAssertEqual(merged.nickname, "B")
    }

    func test_mergeUniquePhones_digitOnlyDedup() {
        let a = [UnifiedContact.PhoneNumber(value: "(555) 123-4567", label: "mobile")]
        let b = [UnifiedContact.PhoneNumber(value: "555.123.4567", label: "home"),
                 UnifiedContact.PhoneNumber(value: "555-999-0000", label: "work")]
        let merged = coordinator.mergeUniquePhones(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.value, "(555) 123-4567", "primary's formatting survives")
        XCTAssertTrue(merged.contains { $0.value == "555-999-0000" })
    }

    func test_mergeUniqueEmails_caseInsensitiveDedup() {
        let a = [UnifiedContact.EmailAddress(value: "Pat@Example.com", label: "work")]
        let b = [UnifiedContact.EmailAddress(value: "pat@example.com", label: "home"),
                 UnifiedContact.EmailAddress(value: "pat.other@example.com", label: "other")]
        let merged = coordinator.mergeUniqueEmails(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.value == "pat.other@example.com" })
    }

    func test_mergeInto_concatenatesDistinctNotes() {
        var primary = UnifiedContact.make(givenName: "Amy")
        primary.note = "Primary note"
        var secondary = UnifiedContact.make(givenName: "Amy")
        secondary.note = "Secondary note"
        let merged = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(merged.note, "Primary note\n---\nSecondary note")

        primary.note = nil
        let filled = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(filled.note, "Secondary note", "a nil primary note takes secondary's")

        secondary.note = nil
        let empty = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertNil(empty.note)
    }

    func test_mergeInto_urlsUnionByValue() {
        var primary = UnifiedContact.make(givenName: "Amy")
        primary.urls = [UnifiedContact.Url(value: "https://a.com", label: "homepage")]
        var secondary = UnifiedContact.make(givenName: "Amy")
        secondary.urls = [UnifiedContact.Url(value: "https://a.com", label: "other"),
                          UnifiedContact.Url(value: "https://b.com", label: "blog")]
        let merged = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(merged.urls.count, 2)
        XCTAssertTrue(merged.urls.contains { $0.value == "https://b.com" })
    }

    func test_mergeInto_keepsSecondaryAddresses() {
        // D-05: postal addresses union like phones and emails do — a distinct
        // secondary address must not be dropped because the primary has one.
        var primary = UnifiedContact.make(givenName: "Amy")
        primary.postalAddresses = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        var secondary = UnifiedContact.make(givenName: "Amy")
        secondary.postalAddresses = [UnifiedContact.PostalAddress(street: "2 Oak Ave", city: "Shelbyville")]
        let merged = coordinator.mergeInto(primary: primary, secondary: secondary)
        XCTAssertEqual(merged.postalAddresses.count, 2,
                       "a distinct secondary address must survive the merge")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 12. Backup snapshot round-trip (AUDIT §3, Critical row 5)
// ─────────────────────────────────────────────────────────────

final class BackupSnapshotRoundTripTests: XCTestCase {

    private let manager = ContactBackupManager.shared

    func test_roundTrip_preservesFieldsAndIdentifiers() throws {
        var original = UnifiedContact.make(
            givenName: "Round", familyName: "Trip", organizationName: "Acme Corp",
            phones: ["+1 555 000 1111"], emails: ["round@trip.com"],
            googleResourceName: "people/rt-1", macContactIdentifier: "mac/rt-1")
        original.middleName = "Mid"
        original.namePrefix = "Dr."
        original.nameSuffix = "Jr."
        original.nickname = "Trippy"
        original.phoneticGivenName = "Rownd"
        original.department = "QA"
        original.jobTitle = "Tester"
        original.note = "A round-trip note"
        original.photoData = Data([0xAB, 0xCD])
        original.urls = [UnifiedContact.Url(value: "https://round.trip", label: "homepage")]
        original.postalAddresses = [UnifiedContact.PostalAddress(
            street: "1 Loop Rd", city: "Cupertino", state: "CA",
            postalCode: "95014", country: "United States", countryCode: nil, label: "work")]
        var birthday = DateComponents()
        birthday.year = 1990; birthday.month = 5; birthday.day = 20
        original.birthday = birthday

        let snapshot = try XCTUnwrap(manager.createSnapshot(from: original))
        // `identifier` is deliberately wrong: the snapshot's own captured
        // identifiers must win over the fallback.
        let restored = try XCTUnwrap(manager.snapshotToUnifiedContact(
            snapshot, identifier: "people/should-not-be-used", source: .google))

        XCTAssertEqual(restored.givenName, original.givenName)
        XCTAssertEqual(restored.middleName, original.middleName)
        XCTAssertEqual(restored.familyName, original.familyName)
        XCTAssertEqual(restored.namePrefix, original.namePrefix)
        XCTAssertEqual(restored.nameSuffix, original.nameSuffix)
        XCTAssertEqual(restored.nickname, original.nickname)
        XCTAssertEqual(restored.phoneticGivenName, original.phoneticGivenName)
        XCTAssertEqual(restored.organizationName, original.organizationName)
        XCTAssertEqual(restored.department, original.department)
        XCTAssertEqual(restored.jobTitle, original.jobTitle)
        XCTAssertEqual(restored.phoneNumbers, original.phoneNumbers)
        XCTAssertEqual(restored.emailAddresses, original.emailAddresses)
        XCTAssertEqual(restored.postalAddresses, original.postalAddresses)
        XCTAssertEqual(restored.urls, original.urls)
        XCTAssertEqual(restored.birthday, original.birthday)
        XCTAssertEqual(restored.note, original.note)
        XCTAssertEqual(restored.photoData, original.photoData)
        XCTAssertEqual(restored.googleResourceName, "people/rt-1")
        XCTAssertEqual(restored.macContactIdentifier, "mac/rt-1",
                       "both identifiers must survive so a restore targets the exact records")
    }

    /// Backups written before the identifier fields existed fall back to
    /// `identifier` + `source` — and must land on the correct side.
    func test_legacySnapshot_reconstructsIdentifierBySource() throws {
        let legacy = ContactSnapshot(
            displayName: "Legacy", givenName: "Leg", familyName: "Acy", middleName: nil,
            phoneNumbers: [], emailAddresses: [], postalAddresses: [],
            organization: nil, jobTitle: nil, notes: nil, imageData: nil, customFields: [:],
            namePrefix: nil, nameSuffix: nil, nickname: nil,
            phoneticGivenName: nil, phoneticMiddleName: nil, phoneticFamilyName: nil,
            department: nil, urls: nil, birthday: nil,
            googleResourceName: nil, macContactIdentifier: nil)

        let mac = try XCTUnwrap(manager.snapshotToUnifiedContact(
            legacy, identifier: "mac-legacy-1", source: .mac))
        XCTAssertEqual(mac.macContactIdentifier, "mac-legacy-1")
        XCTAssertNil(mac.googleResourceName,
                     "a Mac-sourced restore must not invent a Google identity")

        let google = try XCTUnwrap(manager.snapshotToUnifiedContact(
            legacy, identifier: "people/legacy-1", source: .google))
        XCTAssertEqual(google.googleResourceName, "people/legacy-1")
        XCTAssertNil(google.macContactIdentifier)
    }

    /// A backup written by the first release is missing every v2 field; it must
    /// still decode (optionals absorb the missing keys) and restore.
    func test_oldBackupJSON_missingV2Fields_stillDecodes() throws {
        let oldJSON = """
        {
          "displayName": "Old Backup",
          "givenName": "Old",
          "phoneNumbers": [{"value": "+1 555 777 8888", "label": "mobile"}],
          "emailAddresses": [],
          "postalAddresses": [],
          "customFields": {}
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(ContactSnapshot.self, from: oldJSON)
        XCTAssertNil(snapshot.urls)
        XCTAssertNil(snapshot.googleResourceName)
        XCTAssertNil(snapshot.macContactIdentifier)

        let restored = try XCTUnwrap(manager.snapshotToUnifiedContact(
            snapshot, identifier: "mac-old-1", source: .mac))
        XCTAssertEqual(restored.givenName, "Old")
        XCTAssertEqual(restored.phoneNumbers.first?.value, "+1 555 777 8888")
        XCTAssertEqual(restored.macContactIdentifier, "mac-old-1")
        XCTAssertTrue(restored.urls.isEmpty, "missing v2 lists restore as empty, not as a crash")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 13. SyncFailureStore (AUDIT §3, row 6)
// ─────────────────────────────────────────────────────────────

extension SyncFailureStore {
    /// A hermetic store over a unique temp file (issue #105) — tests never
    /// touch the user's real `sync_failures.json`, so a crash mid-test can no
    /// longer leave `test:` entries visible in the app's Sync Failures UI.
    static func testStore(
        fileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-failures-\(UUID().uuidString).json")
    ) -> SyncFailureStore {
        SyncFailureStore(fileURL: fileURL)
    }
}

final class SyncFailureStoreTests: XCTestCase {

    /// Fresh temp-file store per test — no shared singleton, no cleanup debt.
    private var store: SyncFailureStore!

    override func setUp() {
        super.setUp()
        store = SyncFailureStore.testStore()
    }

    func test_threeStrikes_skipStartsOnFourthAttempt() {
        let key = "strikes-1"

        XCTAssertFalse(store.shouldSkip(key: key), "an unknown contact is never skipped")

        XCTAssertEqual(store.recordFailure(key: key, name: "Strikes", reason: "134092"), 1)
        XCTAssertFalse(store.shouldSkip(key: key), "attempt 2 still runs after 1 failure")

        XCTAssertEqual(store.recordFailure(key: key, name: "Strikes", reason: "134092"), 2)
        XCTAssertFalse(store.shouldSkip(key: key), "attempt 3 still runs after 2 failures")

        XCTAssertEqual(store.recordFailure(key: key, name: "Strikes", reason: "134092"), 3)
        XCTAssertTrue(store.shouldSkip(key: key),
                      "after the third strike the contact is set aside")
    }

    func test_clearFailure_forgetsHistory() {
        let key = "recovers-1"
        for _ in 0..<3 { store.recordFailure(key: key, name: "Recovers", reason: "x") }
        XCTAssertTrue(store.shouldSkip(key: key))

        store.clearFailure(key: key)
        XCTAssertFalse(store.shouldSkip(key: key),
                       "a contact that recovers is not held against its past")
        XCTAssertEqual(store.recordFailure(key: key, name: "Recovers", reason: "x"), 1,
                       "the count restarts from scratch")
    }

    func test_ignore_skipsRegardlessOfCount() {
        let key = "ignored-1"
        store.recordFailure(key: key, name: "Ignored", reason: "x")
        XCTAssertFalse(store.shouldSkip(key: key))

        store.ignore(key: key)
        XCTAssertTrue(store.shouldSkip(key: key),
                      "ignore short-circuits the 3-strike threshold")
    }

    func test_retry_isClear() {
        let key = "retry-1"
        for _ in 0..<3 { store.recordFailure(key: key, name: "Retry", reason: "x") }
        store.retry(key: key)
        XCTAssertFalse(store.shouldSkip(key: key))
    }

    func test_clearAll_removesEverything() {
        store.recordFailure(key: "a", name: "A", reason: "x")
        store.recordFailure(key: "b", name: "B", reason: "y")
        store.ignore(key: "b")
        store.clearAll()
        XCTAssertTrue(store.allFailures().isEmpty)
        XCTAssertFalse(store.shouldSkip(key: "b"),
                       "clearing everything also forgets ignores")
    }

    func test_persistence_roundTripsThroughInjectedFileURL() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-failures-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SyncFailureStore.testStore(fileURL: url)
        first.recordFailure(key: "mac:persist-1", name: "Persisted", reason: "134092")
        first.recordFailure(key: "mac:persist-1", name: "Persisted", reason: "134092")
        first.recordFailure(key: "mac:persist-2-ignored", name: "Quiet", reason: "x")
        first.ignore(key: "mac:persist-2-ignored")

        // recordFailure/ignore save synchronously under the barrier, so a
        // second instance over the same file must see the same ledger.
        let second = SyncFailureStore.testStore(fileURL: url)
        let reloaded = second.allFailures().first { $0.id == "mac:persist-1" }
        XCTAssertEqual(reloaded?.failureCount, 2)
        XCTAssertEqual(reloaded?.contactName, "Persisted")
        XCTAssertTrue(second.shouldSkip(key: "mac:persist-2-ignored"),
                      "the ignore flag survives a relaunch")
    }

    func test_syncFailure_codableRoundTrip() throws {
        let failure = SyncFailure(id: "mac:ABC-123", contactName: "Codable Person",
                                  reason: "Cocoa 134092", failureCount: 2,
                                  lastFailedAt: Date(), ignored: true)
        let decoded = try JSONDecoder().decode(SyncFailure.self,
                                               from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded.id, failure.id)
        XCTAssertEqual(decoded.contactName, failure.contactName)
        XCTAssertEqual(decoded.reason, failure.reason)
        XCTAssertEqual(decoded.failureCount, failure.failureCount)
        XCTAssertTrue(decoded.ignored)
        XCTAssertEqual(decoded.lastFailedAt.timeIntervalSinceReferenceDate,
                       failure.lastFailedAt.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 14. Backup index: summaries, legacy migration, version numbering (#56/#57)
// ─────────────────────────────────────────────────────────────

/// Pure decode/derive tests — no manager instance and no files, so nothing
/// here can touch (or prune) the user's real backups.
final class BackupIndexFormatTests: XCTestCase {

    // Whole seconds on purpose: the index uses ISO-8601 dates, which drop
    // sub-second precision, and the round-trip asserts equality.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(name: String) -> ContactSnapshot {
        ContactSnapshot(
            displayName: name, givenName: name, familyName: nil, middleName: nil,
            phoneNumbers: [], emailAddresses: [], postalAddresses: [],
            organization: nil, jobTitle: nil, notes: nil, imageData: nil, customFields: [:],
            namePrefix: nil, nameSuffix: nil, nickname: nil,
            phoneticGivenName: nil, phoneticMiddleName: nil, phoneticFamilyName: nil,
            department: nil, urls: [], birthday: nil,
            googleResourceName: nil, macContactIdentifier: nil)
    }

    private func makeVersion(identifier: String, number: Int,
                             name: String = "Someone") -> ContactVersion {
        ContactVersion(
            id: UUID().uuidString,
            contactIdentifier: identifier,
            contactName: name,
            versionNumber: number,
            timestamp: fixedDate,
            syncSessionId: "sync-1",
            source: .google,
            data: makeSnapshot(name: name),
            changesSummary: [])
    }

    private func makeSession(id: String = UUID().uuidString,
                             versions: [ContactVersion] = []) -> BackupSession {
        BackupSession(
            id: id,
            timestamp: fixedDate,
            syncSessionId: "sync-1",
            type: .preSyncBackup,
            googleContactsCount: 2,
            macContactsCount: 3,
            contactVersions: versions,
            metadata: BackupMetadata(appVersion: "1.0.0", syncDirection: "2-way",
                                     syncMode: "manual", autoResolution: nil,
                                     customNotes: "index test"))
    }

    private var iso8601Encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: #56 — summary derivation and round-trip

    func test_summary_carriesMetadataAndVersionCount() {
        let session = makeSession(versions: [
            makeVersion(identifier: "people/a", number: 1),
            makeVersion(identifier: "mac/b", number: 4),
        ])
        let summary = session.summary

        XCTAssertEqual(summary.id, session.id)
        XCTAssertEqual(summary.timestamp, session.timestamp)
        XCTAssertEqual(summary.syncSessionId, session.syncSessionId)
        XCTAssertEqual(summary.type, session.type)
        XCTAssertEqual(summary.googleContactsCount, session.googleContactsCount)
        XCTAssertEqual(summary.macContactsCount, session.macContactsCount)
        XCTAssertEqual(summary.versionCount, 2,
                       "the summary keeps the count, not the versions themselves")
        XCTAssertEqual(summary.metadata, session.metadata)
    }

    func test_summaryIndex_roundTrip() throws {
        let summaries = [
            makeSession(versions: [makeVersion(identifier: "people/a", number: 1)]).summary,
            makeSession().summary,
        ]
        let data = try iso8601Encoder.encode(summaries)

        guard case .current(let decoded) =
                try ContactBackupManager.decodeBackupIndex(data) else {
            return XCTFail("a metadata-only index must decode as the current format")
        }
        XCTAssertEqual(decoded, summaries, "every summary field survives the round-trip")
    }

    // MARK: #56 — legacy index migration

    func test_legacyIndex_decodesAndPreservesSessions() throws {
        let sessions = [
            makeSession(id: "legacy-1", versions: [
                makeVersion(identifier: "people/a", number: 1),
                makeVersion(identifier: "people/a", number: 2),
            ]),
            makeSession(id: "legacy-2", versions: [
                makeVersion(identifier: "mac/b", number: 1, name: "Bea"),
            ]),
        ]
        // What pre-#56 builds wrote: full sessions, ISO-8601 dates.
        let legacyData = try iso8601Encoder.encode(sessions)

        guard case .legacy(let decoded) =
                try ContactBackupManager.decodeBackupIndex(legacyData) else {
            return XCTFail("an old full-session index must be detected as legacy, "
                           + "not silently half-read as the current format")
        }

        XCTAssertEqual(decoded.map(\.id), ["legacy-1", "legacy-2"])
        XCTAssertEqual(decoded[0].contactVersions.count, 2,
                       "the full bodies survive so migration can write missing session files")
        XCTAssertEqual(decoded[1].contactVersions.first?.contactName, "Bea")

        // The summaries migration derives from them are complete.
        let summaries = decoded.map(\.summary)
        XCTAssertEqual(summaries.map(\.versionCount), [2, 1])
        XCTAssertEqual(summaries[0].type, .preSyncBackup)
        XCTAssertEqual(summaries[0].timestamp, fixedDate)
    }

    func test_corruptIndex_throws() {
        let garbage = Data("not json at all".utf8)
        XCTAssertThrowsError(try ContactBackupManager.decodeBackupIndex(garbage))
    }

    // MARK: #57 — version numbering in one pass

    func test_maxVersionNumbers_singlePassOverAllSessions() {
        let sessions = [
            makeSession(versions: [
                makeVersion(identifier: "people/a", number: 1),
                makeVersion(identifier: "mac/x", number: 1),
            ]),
            makeSession(versions: [
                makeVersion(identifier: "people/a", number: 3),
                makeVersion(identifier: "people/a", number: 2),
                makeVersion(identifier: "mac/x", number: 2),
            ]),
        ]
        let map = ContactBackupManager.maxVersionNumbers(in: sessions)
        XCTAssertEqual(map, ["people/a": 3, "mac/x": 2])
    }

    func test_nextVersionNumber_incrementsFromStoredMax() {
        var map = ContactBackupManager.maxVersionNumbers(in: [
            makeSession(versions: [makeVersion(identifier: "people/a", number: 2)]),
        ])

        XCTAssertEqual(ContactBackupManager.nextVersionNumber(for: "people/a", in: &map), 3)
        XCTAssertEqual(ContactBackupManager.nextVersionNumber(for: "people/a", in: &map), 4,
                       "a contact captured twice in one batch keeps stepping")
        XCTAssertEqual(ContactBackupManager.nextVersionNumber(for: "mac/new", in: &map), 1,
                       "an unseen contact starts at version 1")
        XCTAssertEqual(map["people/a"], 4, "the map records what was handed out")
    }
}
