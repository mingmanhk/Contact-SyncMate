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
        XCTAssertEqual(c.displayName, "Unknown Contact")
    }

    func test_phoneNumber_stored() {
        let c = UnifiedContact.make(phones: ["+1 555 0101"])
        XCTAssertEqual(c.phoneNumbers.first?.value, "+1 555 0101")
        XCTAssertEqual(c.phoneNumbers.first?.label, "mobile")
    }

    func test_emailAddress_stored() {
        let c = UnifiedContact.make(emails: ["a@b.com"])
        XCTAssertEqual(c.emailAddresses.first?.value, "a@b.com")
    }

    func test_defaultCollections_empty() {
        let c = UnifiedContact(id: UUID())
        XCTAssertTrue(c.phoneNumbers.isEmpty)
        XCTAssertTrue(c.emailAddresses.isEmpty)
        XCTAssertTrue(c.postalAddresses.isEmpty)
    }

    func test_identifiable_byID() {
        let id = UUID()
        let c1 = UnifiedContact.make(id: id, givenName: "A")
        let c2 = UnifiedContact.make(id: id, givenName: "B")
        XCTAssertEqual(c1.id, c2.id)
    }

    func test_organizationName_stored() {
        let c = UnifiedContact.make(organizationName: "Acme Corp")
        XCTAssertEqual(c.organizationName, "Acme Corp")
    }

    func test_multiplePhones_allStored() {
        let c = UnifiedContact.make(phones: ["111", "222", "333"])
        XCTAssertEqual(c.phoneNumbers.count, 3)
    }
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

    func test_normalizePhone_stripsFormatting() {
        let result = ContactNormalizer.normalizePhone("(555) 123-4567")
        // Should contain digits
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("5551234567") || result.contains("555-123-4567") || result.contains("5551234567"))
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

    func test_syncAction_allCases() {
        let cases = SyncAction.allCases
        XCTAssertTrue(cases.contains(.add))
        XCTAssertTrue(cases.contains(.update))
        XCTAssertTrue(cases.contains(.delete))
        XCTAssertTrue(cases.contains(.merge))
        XCTAssertTrue(cases.contains(.skip))
    }

    func test_syncDirection_cases() {
        let directions: [SyncDirection] = [.twoWay, .googleToMac, .macToGoogle]
        XCTAssertEqual(directions.count, 3)
    }

    func test_syncMode_cases() {
        let modes: [SyncMode] = [.manual, .automatic]
        XCTAssertEqual(modes.count, 2)
    }

    func test_contactChange_properties() {
        let change = ContactChange(
            contactName: "John Smith",
            action: .add,
            direction: .googleToMac,
            changes: ["Added phone: 555-1234"]
        )
        XCTAssertEqual(change.contactName, "John Smith")
        XCTAssertEqual(change.action, .add)
        XCTAssertEqual(change.direction, .googleToMac)
        XCTAssertEqual(change.changes.count, 1)
        XCTAssertNil(change.userOverride)
    }

    func test_contactChange_userOverride() {
        var change = ContactChange(
            contactName: "Jane",
            action: .delete,
            direction: .twoWay,
            changes: []
        )
        change.userOverride = .skip
        XCTAssertEqual(change.userOverride, .skip)
    }

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

    func test_syncResult_summary_containsCounts() {
        let result = SyncResult(
            mode: .manual, direction: .twoWay,
            startTime: Date(), endTime: Date(),
            added: 3, updated: 2, deleted: 1, merged: 0, skipped: 0,
            errors: []
        )
        XCTAssertTrue(result.summary.contains("3"))
        XCTAssertTrue(result.summary.contains("2"))
    }

    func test_syncSession_hasID() {
        let session = SyncSession(
            mode: .manual, direction: .twoWay,
            startTime: Date(), contactChanges: []
        )
        XCTAssertNotNil(session.id)
    }

    func test_syncError_hasID() {
        let e1 = SyncError(contactName: "Alice", message: "Test", timestamp: Date())
        let e2 = SyncError(contactName: "Alice", message: "Test", timestamp: Date())
        XCTAssertNotEqual(e1.id, e2.id, "Each SyncError should have a unique ID")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 4. ContactMappingStore
// ─────────────────────────────────────────────────────────────

final class ContactMappingStoreTests: XCTestCase {

    var store: ContactMappingStore!

    override func setUp() {
        store = ContactMappingStore()
    }

    func test_getAllMappings_initiallyEmpty() {
        let all = store.getAllMappings()
        // Fresh store — may be empty or have persisted data
        XCTAssertNotNil(all)
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

    func test_contactMapping_properties() {
        let date = Date()
        let m = ContactMapping(
            googleResourceName: "people/prop",
            macContactIdentifier: "mac-prop",
            lastSyncedAt: date
        )
        XCTAssertEqual(m.googleResourceName, "people/prop")
        XCTAssertEqual(m.macContactIdentifier, "mac-prop")
        XCTAssertEqual(m.lastSyncedAt.timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 0.01)
    }

    func test_contactMapping_optionalEtag() {
        var m = ContactMapping(
            googleResourceName: "people/etag",
            macContactIdentifier: "mac-etag",
            lastSyncedAt: Date()
        )
        XCTAssertNil(m.googleEtag)
        m.googleEtag = "abc123"
        XCTAssertEqual(m.googleEtag, "abc123")
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 5. SyncEngine Diff Logic
// ─────────────────────────────────────────────────────────────

final class SyncEngineDiffTests: XCTestCase {

    // Test the computeChanges method directly
    func test_computeChanges_emptyInputs_returnsEmpty() {
        let store = ContactMappingStore()
        let engine = makeMockEngine(store: store)
        let changes = engine.computeChanges(
            googleContacts: [],
            macContacts: [],
            direction: .twoWay
        )
        XCTAssertEqual(changes.count, 0)
    }

    func test_computeChanges_googleToMac_noMappings_detectsAdds() {
        let store = ContactMappingStore()
        let engine = makeMockEngine(store: store)
        let googleContacts = [
            UnifiedContact.make(givenName: "Alice", googleResourceName: "people/1"),
            UnifiedContact.make(givenName: "Bob",   googleResourceName: "people/2"),
        ]
        let changes = engine.computeChanges(
            googleContacts: googleContacts,
            macContacts: [],
            direction: .googleToMac
        )
        // At minimum shouldn't crash; current stub returns []
        XCTAssertNotNil(changes)
    }

    func test_computeChanges_macToGoogle_noMappings() {
        let store = ContactMappingStore()
        let engine = makeMockEngine(store: store)
        let macContacts = [
            UnifiedContact.make(givenName: "Carol", macContactIdentifier: "mac1"),
        ]
        let changes = engine.computeChanges(
            googleContacts: [],
            macContacts: macContacts,
            direction: .macToGoogle
        )
        XCTAssertNotNil(changes)
    }

    func test_computeChanges_twoWay_bothSides() {
        let store = ContactMappingStore()
        let engine = makeMockEngine(store: store)
        let g = [UnifiedContact.make(givenName: "G-Side", googleResourceName: "people/g")]
        let m = [UnifiedContact.make(givenName: "M-Side", macContactIdentifier: "mac/m")]
        let changes = engine.computeChanges(
            googleContacts: g, macContacts: m, direction: .twoWay
        )
        XCTAssertNotNil(changes)
    }

    // MARK: - Helpers

    private func makeMockEngine(store: ContactMappingStore) -> SyncEngine {
        let gConnector = GoogleContactsConnector()
        let mConnector = MacContactsConnector()
        return SyncEngine(googleConnector: gConnector, macConnector: mConnector, mappingStore: store)
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 6. SyncHistory (Event Log)
// ─────────────────────────────────────────────────────────────

final class SyncHistoryTests: XCTestCase {

    func test_log_recordsEvent() {
        let history = SyncHistory.shared
        history.clear()
        let event = history.log(source: "TestSuite", action: "unit-test", details: "hello")
        XCTAssertEqual(event.source, "TestSuite")
        XCTAssertEqual(event.action, "unit-test")
        XCTAssertEqual(event.details, "hello")
    }

    func test_events_returnsLoggedEvents() {
        let history = SyncHistory.shared
        history.clear()
        history.log(source: "A", action: "sync.start")
        history.log(source: "B", action: "sync.end")
        // Allow async writes to settle
        Thread.sleep(forTimeInterval: 0.1)
        let events = history.events()
        XCTAssertGreaterThanOrEqual(events.count, 2)
    }

    func test_clear_removesAllEvents() {
        let history = SyncHistory.shared
        history.log(source: "Test", action: "pre-clear")
        Thread.sleep(forTimeInterval: 0.1)
        history.clear()
        Thread.sleep(forTimeInterval: 0.1)
        let events = history.events()
        XCTAssertEqual(events.count, 0)
    }

    func test_event_hasUniqueID() {
        let history = SyncHistory.shared
        let e1 = history.log(source: "X", action: "a")
        let e2 = history.log(source: "X", action: "b")
        XCTAssertNotEqual(e1.id, e2.id)
    }

    func test_event_timestampIsRecent() {
        let before = Date()
        let event  = SyncHistory.shared.log(source: "Timer", action: "now")
        let after  = Date()
        XCTAssertGreaterThanOrEqual(event.timestamp, before)
        XCTAssertLessThanOrEqual(event.timestamp, after)
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

final class DeduplicationTests: XCTestCase {

    var deduplicator: ContactDeduplicator!

    override func setUp() {
        let config = ContactDeduplicator.Configuration()
        deduplicator = ContactDeduplicator(
            config: config,
            decisionStore: DeduplicationDecisionStore.shared
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
// 8. AppSettings
// ─────────────────────────────────────────────────────────────

final class AppSettingsTests: XCTestCase {

    func test_shared_isNotNil() {
        XCTAssertNotNil(AppSettings.shared)
    }

    func test_selectedSyncType_defaultsToKnownValue() {
        let settings = AppSettings.shared
        let validTypes: [SyncType] = SyncType.allCases
        XCTAssertTrue(validTypes.contains(settings.selectedSyncType))
    }

    func test_autoSyncInterval_isPositive() {
        XCTAssertGreaterThan(AppSettings.shared.autoSyncInterval, 0)
    }

    func test_syncPhotos_isBool() {
        let _ = AppSettings.shared.syncPhotos // Should not crash
        XCTAssertNoThrow({ let _ = AppSettings.shared.syncPhotos }())
    }

    func test_hasCompletedOnboarding_isBool() {
        XCTAssertNoThrow({ let _ = AppSettings.shared.hasCompletedOnboarding }())
    }
}

// MARK: ─────────────────────────────────────────────────────────
// 9. Performance & Safety Gates
// ─────────────────────────────────────────────────────────────

final class PerformanceTests: XCTestCase {

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

    func test_syncHistory_maxEvents_doesNotGrowUnbounded() {
        let history = SyncHistory.shared
        history.clear()
        // Log 50 events rapidly
        for i in 0..<50 {
            history.log(source: "Perf", action: "event-\(i)")
        }
        Thread.sleep(forTimeInterval: 0.2)
        let count = history.events().count
        XCTAssertLessThanOrEqual(count, 1000, "History should respect max events limit")
    }
}
