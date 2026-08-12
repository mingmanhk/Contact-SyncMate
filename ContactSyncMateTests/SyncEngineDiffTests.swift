// SyncEngineDiffTests.swift
// Sync engine diff logic and ContactMapper tests

import XCTest
import Contacts
@testable import Contact_SyncMate

extension ContactMappingStore {
    /// A hermetic store over a unique temp file — tests must never touch the
    /// real mapping file (github issue #45).
    static func testStore() -> ContactMappingStore {
        ContactMappingStore(persistenceURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mappings-\(UUID().uuidString).json"))
    }
}

extension UnifiedContact {
    /// Convenience factory for diff tests
    static func diffMake(
        id: UUID = UUID(),
        givenName: String? = nil,
        familyName: String? = nil,
        phones: [String] = [],
        emails: [String] = [],
        googleResourceName: String? = nil,
        macContactIdentifier: String? = nil,
        lastModified: Date? = nil
    ) -> UnifiedContact {
        var c = UnifiedContact(id: id)
        c.givenName = givenName
        c.familyName = familyName
        c.phoneNumbers = phones.map { UnifiedContact.PhoneNumber(value: $0, label: "mobile") }
        c.emailAddresses = emails.map { UnifiedContact.EmailAddress(value: $0, label: "work") }
        c.googleResourceName = googleResourceName
        c.macContactIdentifier = macContactIdentifier
        c.lastModified = lastModified
        return c
    }
}

final class SyncEngineDiffTests: XCTestCase {

    // Diff behaviour depends on user-configurable settings, and unit tests
    // share the app's UserDefaults domain. Pin every setting the diff logic
    // reads so tests stay hermetic regardless of what the user changed in
    // the running app.
    private var savedConflict: ConflictResolutionDefault!
    private var savedForceUpdate: Bool!
    private var savedPostalCodes: Bool!
    private var savedFilterByGroups: Bool!

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedConflict       = s.defaultConflictResolution
        savedForceUpdate    = s.forceUpdateAll
        savedPostalCodes    = s.syncPostalCountryCodes
        savedFilterByGroups = s.filterByGroups
        // `mergeContacts2Way` was pinned here too. It is now the `.mergeBoth`
        // case of defaultConflictResolution, which this already pins.
        s.defaultConflictResolution = .alwaysAsk
        s.forceUpdateAll = false
        s.syncPostalCountryCodes = true
        s.filterByGroups = false
    }

    override func tearDown() {
        let s = AppSettings.shared
        s.defaultConflictResolution = savedConflict
        s.forceUpdateAll = savedForceUpdate
        s.syncPostalCountryCodes = savedPostalCodes
        s.filterByGroups = savedFilterByGroups
        super.tearDown()
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore.testStore()
        )
    }

    // MARK: - Photo diff convergence

    /// A photo only the Mac has cannot be pushed: the People API rejects
    /// `photos` in an update mask. Reporting it produced an update that wrote
    /// nothing and came back identical on the next sync, forever.
    func test_photoOnlyOnMac_isNotReportedAsAChange() {
        let gID = "people/photo-mac-only"
        let mID = "mac/photo-mac-only"
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        Thread.sleep(forTimeInterval: 0.05)

        var google = UnifiedContact.diffMake(givenName: "Pat", googleResourceName: gID)
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Pat", macContactIdentifier: mID)
        mac.photoData = Data([0x01, 0x02])
        mac.lastModified = Date()

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [mac], direction: .twoWay)

        XCTAssertFalse(
            changes.flatMap(\.changes).contains { $0.contains("Photo") },
            "A Mac-only photo cannot be written to Google, so it must not be diffed")
    }

    /// The direction that *can* be applied still is.
    func test_photoOnlyOnGoogle_isReported() {
        let gID = "people/photo-google-only"
        let mID = "mac/photo-google-only"
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        Thread.sleep(forTimeInterval: 0.05)

        var google = UnifiedContact.diffMake(givenName: "Pat", googleResourceName: gID)
        google.photoData = Data([0x01, 0x02])
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Pat", macContactIdentifier: mID)
        mac.lastModified = Date(timeIntervalSince1970: 0)

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [mac], direction: .twoWay)

        XCTAssertTrue(
            changes.flatMap(\.changes).contains { $0.contains("Photo") },
            "Google → Mac is the direction photos can travel, so it must be diffed")
    }

    // MARK: - Diff convergence
    //
    // A sync that reports the same change every run never settles. These cover
    // the formatting differences the two providers introduce on their own —
    // which is what made every contact look edited on every sync.

    private func mappedPair(gID: String, mID: String) -> ContactMappingStore {
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        Thread.sleep(forTimeInterval: 0.05)
        return store
    }

    /// Apple Contacts reformats a number when it saves it; Google returns what
    /// it was sent. Same number, different string.
    func test_phoneFormattingDifference_isNotAChange() {
        let store = mappedPair(gID: "people/phone", mID: "mac/phone")
        var google = UnifiedContact.diffMake(givenName: "Dana", phones: ["+15551234567"],
                                             googleResourceName: "people/phone")
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Dana", phones: ["+1 (555) 123-4567"],
                                          macContactIdentifier: "mac/phone")
        mac.lastModified = Date()

        let changes = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store
        ).computeChanges(googleContacts: [google], macContacts: [mac], direction: .twoWay)

        XCTAssertFalse(changes.flatMap(\.changes).contains { $0.contains("Phone") },
                       "Identical numbers formatted differently must not diff")
    }

    /// A genuinely different number still has to be reported.
    func test_differentPhone_isAChange() {
        let store = mappedPair(gID: "people/phone2", mID: "mac/phone2")
        var google = UnifiedContact.diffMake(givenName: "Dana", phones: ["+15551234567"],
                                             googleResourceName: "people/phone2")
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Dana", phones: ["+15559999999"],
                                          macContactIdentifier: "mac/phone2")
        mac.lastModified = Date(timeIntervalSince1970: 0)

        let changes = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store
        ).computeChanges(googleContacts: [google], macContacts: [mac], direction: .twoWay)

        XCTAssertTrue(changes.flatMap(\.changes).contains { $0.contains("Phone") })
    }

    /// Contacts fills in `calendar` and `era`; Google does not.
    func test_birthday_comparesOnlyTheDateParts() {
        var withCalendar = DateComponents()
        withCalendar.year = 1990; withCalendar.month = 5; withCalendar.day = 20
        withCalendar.calendar = Calendar(identifier: .gregorian)
        withCalendar.era = 1

        var bare = DateComponents()
        bare.year = 1990; bare.month = 5; bare.day = 20

        XCTAssertEqual(SyncEngine.birthdayKey(withCalendar), SyncEngine.birthdayKey(bare))
    }

    /// 1604 (Apple) and 0 (Google) both mean "no year".
    func test_birthday_placeholderYearsAgree() {
        var apple = DateComponents(); apple.year = 1604; apple.month = 3; apple.day = 1
        var google = DateComponents(); google.year = 0; google.month = 3; google.day = 1
        XCTAssertEqual(SyncEngine.birthdayKey(apple), SyncEngine.birthdayKey(google))
    }

    /// Issue #100: nickname / prefix / suffix / department are written
    /// unconditionally by applyToMac, so the diff must track them too —
    /// undiffed, a Mac-only edit to one of them never propagated and was
    /// erased by the next inbound update.
    func test_extendedNameAndOrgFields_areDiffed() {
        let store = mappedPair(gID: "people/ext", mID: "mac/ext")
        var google = UnifiedContact.diffMake(givenName: "Sam",
                                             googleResourceName: "people/ext")
        google.nickname = "Ace"
        google.namePrefix = "Dr."
        google.nameSuffix = "Jr."
        google.department = "R&D"
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Sam",
                                          macContactIdentifier: "mac/ext")
        mac.lastModified = Date(timeIntervalSince1970: 0)

        let changes = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store
        ).computeChanges(googleContacts: [google], macContacts: [mac], direction: .twoWay)

        let diffs = changes.flatMap(\.changes)
        XCTAssertTrue(diffs.contains("Nickname changed"))
        XCTAssertTrue(diffs.contains("Name prefix changed"))
        XCTAssertTrue(diffs.contains("Name suffix changed"))
        XCTAssertTrue(diffs.contains("Department changed"))
    }

    func test_url_trailingSlashAndSchemeIgnored() {
        XCTAssertEqual(SyncEngine.normalizedURL("https://Example.com/"),
                       SyncEngine.normalizedURL("http://www.example.com"))
    }

    func test_url_differentPathsStillDiffer() {
        XCTAssertNotEqual(SyncEngine.normalizedURL("https://example.com/a"),
                          SyncEngine.normalizedURL("https://example.com/b"))
    }

    // MARK: - Postal country normalisation

    func test_countryName_yieldsISOCode() {
        let address = UnifiedContact.PostalAddress(
            street: "1 Infinite Loop", city: "Cupertino",
            country: "United States", countryCode: nil)
        let normalized = SyncEngine.normalizingCountry(address)
        XCTAssertEqual(normalized.countryCode, "US")
    }

    func test_lowercaseISOCode_isUppercasedAndNamed() {
        let address = UnifiedContact.PostalAddress(country: nil, countryCode: "hk")
        let normalized = SyncEngine.normalizingCountry(address)
        XCTAssertEqual(normalized.countryCode, "HK")
        XCTAssertNotNil(normalized.country)
    }

    func test_unrecognisedCountry_isLeftAlone() {
        let address = UnifiedContact.PostalAddress(country: "Freedonia", countryCode: nil)
        let normalized = SyncEngine.normalizingCountry(address)
        XCTAssertNil(normalized.countryCode)
        XCTAssertEqual(normalized.country, "Freedonia")
    }

    // MARK: - Diff-reason histogram keys (N-04)

    func test_histogramKey_emailMatchReason_isNameFree() {
        // The histogram promises to count reasons, not people: the reason
        // strings put per-contact detail after a colon, and the key stops there.
        let key = SyncEngine.histogramKey(for: "Matched on a shared email address: Dana Scully")
        XCTAssertEqual(key, "Matched on a shared email address")
        XCTAssertFalse(key.contains("Dana"))
    }

    func test_histogramKey_possibleMatchReason_isNameFree() {
        let key = SyncEngine.histogramKey(
            for: "Possible match: Fox Mulder (same name only — review before merging)")
        XCTAssertEqual(key, "Possible match")
    }

    func test_histogramKey_reasonWithoutColon_passesThrough() {
        XCTAssertEqual(SyncEngine.histogramKey(for: "New contact from Google"),
                       "New contact from Google")
    }

    // MARK: - Empty inputs

    func test_empty_returns_no_changes() {
        let changes = makeEngine().computeChanges(
            googleContacts: [], macContacts: [], direction: .twoWay)
        XCTAssertEqual(changes.count, 0)
    }

    // MARK: - 1-Way: Google → Mac

    func test_googleToMac_newContacts_scheduledAsAdds() {
        let google = [
            UnifiedContact.diffMake(givenName: "Alice", googleResourceName: "people/a"),
            UnifiedContact.diffMake(givenName: "Bob",   googleResourceName: "people/b"),
        ]
        let changes = makeEngine().computeChanges(
            googleContacts: google, macContacts: [], direction: .googleToMac)
        let adds = changes.filter { $0.action == .add }
        XCTAssertEqual(adds.count, 2, "Two new Google contacts → 2 adds")
        XCTAssertTrue(adds.allSatisfy { $0.direction == .googleToMac })
    }

    func test_googleToMac_alreadyMapped_noAdd() {
        let gID  = "people/mapped"
        let mID  = "mac/mapped"
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID, lastSyncedAt: Date()))
        // Allow async barrier write to flush
        Thread.sleep(forTimeInterval: 0.05)

        let google = [UnifiedContact.diffMake(givenName: "Mapped", googleResourceName: gID)]
        let mac    = [UnifiedContact.diffMake(givenName: "Mapped", macContactIdentifier: mID)]
        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        let changes = engine.computeChanges(
            googleContacts: google, macContacts: mac, direction: .googleToMac)
        let adds = changes.filter { $0.action == .add }
        XCTAssertEqual(adds.count, 0, "Already-mapped contact should not be re-added")
    }

    func test_googleToMac_changed_schedulesUpdate() {
        let gID  = "people/upd"
        let mID  = "mac/upd"
        let past = Date(timeIntervalSinceNow: -3600)
        let now  = Date()

        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID, lastSyncedAt: past))
        Thread.sleep(forTimeInterval: 0.05)

        // Google contact updated after last sync
        var gContact = UnifiedContact.diffMake(givenName: "Updated", googleResourceName: gID)
        gContact.lastModified = now

        var mContact = UnifiedContact.diffMake(givenName: "Old", macContactIdentifier: mID)
        mContact.lastModified = past

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        let changes = engine.computeChanges(
            googleContacts: [gContact], macContacts: [mContact], direction: .googleToMac)
        let updates = changes.filter { $0.action == .update }
        XCTAssertGreaterThanOrEqual(updates.count, 1, "Changed contact should produce update")
        XCTAssertEqual(updates.first?.direction, .googleToMac)
    }

    // MARK: - 1-Way: Mac → Google

    func test_macToGoogle_newContacts_scheduledAsAdds() {
        let mac = [
            UnifiedContact.diffMake(givenName: "Carol", macContactIdentifier: "mac/c"),
            UnifiedContact.diffMake(givenName: "Dave",  macContactIdentifier: "mac/d"),
        ]
        let changes = makeEngine().computeChanges(
            googleContacts: [], macContacts: mac, direction: .macToGoogle)
        let adds = changes.filter { $0.action == .add }
        XCTAssertEqual(adds.count, 2)
        XCTAssertTrue(adds.allSatisfy { $0.direction == .macToGoogle })
    }

    // MARK: - 2-Way

    func test_twoWay_newOnBothSides_addsOnBothDirections() {
        let google = [UnifiedContact.diffMake(givenName: "GoogleOnly", googleResourceName: "people/go")]
        let mac    = [UnifiedContact.diffMake(givenName: "MacOnly",    macContactIdentifier: "mac/mo")]
        let changes = makeEngine().computeChanges(
            googleContacts: google, macContacts: mac, direction: .twoWay)
        let googleToMac = changes.filter { $0.action == .add && $0.direction == .googleToMac }
        let macToGoogle = changes.filter { $0.action == .add && $0.direction == .macToGoogle }
        XCTAssertEqual(googleToMac.count, 1)
        XCTAssertEqual(macToGoogle.count, 1)
    }

    func test_twoWay_conflict_markedAsMerge() {
        let gID  = "people/conflict"
        let mID  = "mac/conflict"
        let past = Date(timeIntervalSinceNow: -7200)
        let now  = Date()

        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID, lastSyncedAt: past))
        Thread.sleep(forTimeInterval: 0.05)

        // Both changed after last sync
        var g = UnifiedContact.diffMake(givenName: "GoogleVersion", googleResourceName: gID)
        g.lastModified = now

        var m = UnifiedContact.diffMake(givenName: "MacVersion", macContactIdentifier: mID)
        m.lastModified = now

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        let changes = engine.computeChanges(
            googleContacts: [g], macContacts: [m], direction: .twoWay)
        let merges = changes.filter { $0.action == .merge }
        XCTAssertGreaterThanOrEqual(merges.count, 1, "Both sides changed → conflict → merge")
    }

    func test_twoWay_fuzzyEmailMatch_noDoubleAdd() {
        // Same person: in Google with email, in Mac with same email but no mapping
        var g = UnifiedContact.diffMake(givenName: "Fuzzy", familyName: "Match", googleResourceName: "people/fz")
        g.emailAddresses = [UnifiedContact.EmailAddress(value: "fuzzy@test.com", label: "work")]

        var m = UnifiedContact.diffMake(givenName: "Fuzzy", familyName: "Match", macContactIdentifier: "mac/fz")
        m.emailAddresses = [UnifiedContact.EmailAddress(value: "fuzzy@test.com", label: "home")]

        let changes = makeEngine().computeChanges(
            googleContacts: [g], macContacts: [m], direction: .twoWay)
        // Should produce a merge suggestion, NOT two separate adds
        let adds   = changes.filter { $0.action == .add }
        let merges = changes.filter { $0.action == .merge }
        XCTAssertEqual(adds.count, 0,   "Fuzzy-matched contacts should not produce two adds")
        XCTAssertEqual(merges.count, 1, "Fuzzy-matched contacts should produce one merge suggestion")
    }

    // MARK: - ContactMapper round-trips

    func test_mapper_googleToUnified_allFields() {
        var g = GoogleContact(id: "people/rt")
        g.givenName   = "Round"
        g.familyName  = "Trip"
        g.jobTitle    = "Tester"
        g.phoneNumbers     = [GooglePhoneNumber(value: "+1 555 0000", type: "mobile")]
        g.emailAddresses   = [GoogleEmailAddress(value: "round@test.com", type: "work")]
        g.note        = "Test note"

        let u = ContactMapper.toUnified(from: g)
        XCTAssertEqual(u.givenName,  "Round")
        XCTAssertEqual(u.familyName, "Trip")
        XCTAssertEqual(u.jobTitle,   "Tester")
        XCTAssertEqual(u.phoneNumbers.first?.value, "+1 555 0000")
        XCTAssertEqual(u.emailAddresses.first?.value, "round@test.com")
        XCTAssertEqual(u.note, "Test note")
        XCTAssertEqual(u.googleResourceName, "people/rt")
    }

    func test_mapper_unifiedToGoogle_roundTrip() {
        var u = UnifiedContact.diffMake(givenName: "Test", familyName: "User",
                                    phones: ["+44 20 0000"], emails: ["t@u.com"],
                                    googleResourceName: "people/x")
        u.note = "A note"
        let g = ContactMapper.toGoogle(from: u)
        XCTAssertEqual(g.givenName,  "Test")
        XCTAssertEqual(g.familyName, "User")
        XCTAssertEqual(g.phoneNumbers.first?.value, "+44 20 0000")
        XCTAssertEqual(g.emailAddresses.first?.value, "t@u.com")
        XCTAssertEqual(g.note, "A note")
    }

    func test_mapper_unifiedToMac_multiValueFields() {
        var u = UnifiedContact.diffMake(givenName: "Mac", familyName: "User",
                                    phones: ["555-0001", "555-0002"],
                                    emails: ["a@test.com", "b@test.com"])
        u.note = "Mac note"
        let mac = ContactMapper.toMac(from: u)
        XCTAssertEqual(mac.givenName, "Mac")
        XCTAssertEqual(mac.familyName, "User")
        XCTAssertEqual(mac.phoneNumbers.count, 2)
        XCTAssertEqual(mac.emailAddresses.count, 2)

        // `note` must track the entitlement, not the source data. Assigning it
        // without com.apple.developer.contacts.notes makes CNContactStore reject
        // the entire save with Cocoa error 134092 rather than dropping the field,
        // so the mapper deliberately leaves it empty in builds without it.
        if MacContactsConnector.notesFieldAvailable {
            XCTAssertEqual(mac.note, "Mac note")
        } else {
            XCTAssertEqual(mac.note, "",
                           "note must stay unset without the notes entitlement, "
                           + "otherwise every Mac write fails with Cocoa 134092")
        }
    }
}

// MARK: - Conflict auto-resolution (AUDIT §3, Critical row 2)

/// One test per `defaultConflictResolution` mode, for both conflict branches:
/// "both timestamps moved" and "neither timestamp moved" (unknown-vs-unknown,
/// the CNContact-has-no-modification-date case).
final class ConflictAutoResolutionTests: XCTestCase {

    private var savedConflict: ConflictResolutionDefault!
    private var savedForceUpdate: Bool!
    private var savedPostalCodes: Bool!
    private var savedFilterByGroups: Bool!
    private var savedSyncDeleted: Bool!

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedConflict       = s.defaultConflictResolution
        savedForceUpdate    = s.forceUpdateAll
        savedPostalCodes    = s.syncPostalCountryCodes
        savedFilterByGroups = s.filterByGroups
        savedSyncDeleted    = s.syncDeletedContacts
        s.defaultConflictResolution = .alwaysAsk
        s.forceUpdateAll = false
        s.syncPostalCountryCodes = true
        s.filterByGroups = false
        s.syncDeletedContacts = false
    }

    override func tearDown() {
        let s = AppSettings.shared
        s.defaultConflictResolution = savedConflict
        s.forceUpdateAll = savedForceUpdate
        s.syncPostalCountryCodes = savedPostalCodes
        s.filterByGroups = savedFilterByGroups
        s.syncDeletedContacts = savedSyncDeleted
        super.tearDown()
    }

    /// A mapped pair whose given names differ, with the given modification
    /// timestamps, diffed under the given resolution mode.
    private func changes(resolution: ConflictResolutionDefault,
                         googleModified: Date?,
                         macModified: Date?,
                         lastSynced: Date) -> [ContactChange] {
        AppSettings.shared.defaultConflictResolution = resolution
        let gID = "people/conf-\(UUID().uuidString)"
        let mID = "mac/conf-\(UUID().uuidString)"
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID, lastSyncedAt: lastSynced))
        Thread.sleep(forTimeInterval: 0.05)

        var g = UnifiedContact.diffMake(givenName: "GoogleName", googleResourceName: gID)
        g.lastModified = googleModified
        var m = UnifiedContact.diffMake(givenName: "MacName", macContactIdentifier: mID)
        m.lastModified = macModified

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        return engine.computeChanges(googleContacts: [g], macContacts: [m], direction: .twoWay)
    }

    // Both sides changed since the last sync.

    func test_bothChanged_preferGoogle_updatesTowardMac() {
        let out = changes(resolution: .preferGoogle,
                          googleModified: Date(), macModified: Date(),
                          lastSynced: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .update)
        XCTAssertEqual(out.first?.direction, .googleToMac)
        XCTAssertNil(out.first?.userOverride)
        XCTAssertTrue(out.first?.changes.contains { $0.contains("Google preferred") } ?? false)
        XCTAssertEqual(out.first?.sourceContact?.givenName, "GoogleName",
                       "Google is the side being read from")
    }

    func test_bothChanged_preferMac_updatesTowardGoogle() {
        let out = changes(resolution: .preferMac,
                          googleModified: Date(), macModified: Date(),
                          lastSynced: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .update)
        XCTAssertEqual(out.first?.direction, .macToGoogle)
        XCTAssertTrue(out.first?.changes.contains { $0.contains("Mac preferred") } ?? false)
        XCTAssertEqual(out.first?.sourceContact?.givenName, "MacName")
    }

    func test_bothChanged_mergeBoth_emitsPreResolvedMerge() {
        let out = changes(resolution: .mergeBoth,
                          googleModified: Date(), macModified: Date(),
                          lastSynced: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .merge)
        XCTAssertEqual(out.first?.direction, .twoWay)
        XCTAssertEqual(out.first?.userOverride, .merge,
                       "mergeBoth pre-resolves the merge so it applies without asking")
    }

    // Neither timestamp moved (CNContact never reports one), fields differ.

    func test_unknownVsUnknown_alwaysAsk_emitsUnresolvedMerge() {
        let out = changes(resolution: .alwaysAsk,
                          googleModified: nil, macModified: nil,
                          lastSynced: Date())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .merge)
        XCTAssertEqual(out.first?.direction, .twoWay)
        XCTAssertNil(out.first?.userOverride,
                     "alwaysAsk must leave the merge for the user to resolve")
        XCTAssertTrue(out.first?.changes.contains { $0.contains("neither side reports") } ?? false)
    }

    func test_unknownVsUnknown_preferGoogle_updatesTowardMac() {
        let out = changes(resolution: .preferGoogle,
                          googleModified: nil, macModified: nil,
                          lastSynced: Date())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .update)
        XCTAssertEqual(out.first?.direction, .googleToMac)
    }

    func test_unknownVsUnknown_preferMac_updatesTowardGoogle() {
        let out = changes(resolution: .preferMac,
                          googleModified: nil, macModified: nil,
                          lastSynced: Date())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .update)
        XCTAssertEqual(out.first?.direction, .macToGoogle)
    }

    func test_unknownVsUnknown_mergeBoth_emitsPreResolvedMerge() {
        let out = changes(resolution: .mergeBoth,
                          googleModified: nil, macModified: nil,
                          lastSynced: Date())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.action, .merge)
        XCTAssertEqual(out.first?.userOverride, .merge)
    }
}

// MARK: - SyncEngine merge helpers (AUDIT §3, Critical row 3; covers D-05)

final class SyncEngineMergeHelperTests: XCTestCase {

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore.testStore())
    }

    func test_mergeContacts_primaryWins_secondaryFillsGaps() {
        var primary = UnifiedContact.diffMake(
            givenName: "Alice", phones: ["+1 (555) 111-2222"],
            googleResourceName: "people/prim")
        primary.familyName = ""          // empty string counts as a gap
        primary.note = "P"

        var secondary = UnifiedContact.diffMake(
            givenName: "Alicia", phones: ["15551112222", "+1 555 333 4444"],
            macContactIdentifier: "mac/sec")
        secondary.familyName = "Ng"
        secondary.jobTitle = "Engineer"
        secondary.note = "S"

        let merged = makeEngine().mergeContacts(primary: primary, secondary: secondary)

        XCTAssertEqual(merged.givenName, "Alice", "primary wins when both have a value")
        XCTAssertEqual(merged.familyName, "Ng", "an empty primary field is filled from secondary")
        XCTAssertEqual(merged.jobTitle, "Engineer", "a nil primary field is filled from secondary")
        XCTAssertEqual(merged.googleResourceName, "people/prim")
        XCTAssertEqual(merged.macContactIdentifier, "mac/sec",
                       "identifiers union so the merged record targets both sides")
        XCTAssertEqual(merged.phoneNumbers.count, 2,
                       "the digit-identical number dedups, the new one is kept")
        XCTAssertEqual(merged.note, "P\n---\nS")
    }

    func test_mergePhoneNumbers_dedupsOnDigitsOnly() {
        let a = [UnifiedContact.PhoneNumber(value: "+1 (555) 123-4567", label: "mobile")]
        let b = [UnifiedContact.PhoneNumber(value: "1-555-123-4567", label: "home"),
                 UnifiedContact.PhoneNumber(value: "+1 555 999 0000", label: "work")]
        let merged = makeEngine().mergePhoneNumbers(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.value, "+1 (555) 123-4567",
                       "primary's formatting is the one kept")
        XCTAssertTrue(merged.contains { $0.value == "+1 555 999 0000" })
    }

    func test_mergeEmails_dedupsCaseInsensitively() {
        let a = [UnifiedContact.EmailAddress(value: "Alice@Test.com", label: "work")]
        let b = [UnifiedContact.EmailAddress(value: "alice@test.com", label: "home"),
                 UnifiedContact.EmailAddress(value: "b@test.com", label: "home")]
        let merged = makeEngine().mergeEmails(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.value, "Alice@Test.com")
        XCTAssertTrue(merged.contains { $0.value == "b@test.com" })
    }

    func test_mergeURLs_dedupsCaseInsensitively() {
        let a = [UnifiedContact.Url(value: "https://Example.com", label: "homepage")]
        let b = [UnifiedContact.Url(value: "https://example.com", label: "other"),
                 UnifiedContact.Url(value: "https://other.com", label: "blog")]
        let merged = makeEngine().mergeURLs(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.value == "https://other.com" })
    }

    func test_mergeNotes_allBranches() {
        let engine = makeEngine()
        XCTAssertNil(engine.mergeNotes(nil, nil))
        XCTAssertEqual(engine.mergeNotes("only A", nil), "only A")
        XCTAssertEqual(engine.mergeNotes(nil, "only B"), "only B")
        XCTAssertEqual(engine.mergeNotes("same", "same"), "same",
                       "identical notes must not be concatenated")
        XCTAssertEqual(engine.mergeNotes("A", "B"), "A\n---\nB")
    }

    func test_mergeAddresses_differentStreets_union() {
        let a = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        let b = [UnifiedContact.PostalAddress(street: "2 Oak Ave", city: "Shelbyville")]
        let merged = makeEngine().mergeAddresses(a, b)
        XCTAssertEqual(merged.count, 2)
    }

    func test_mergeAddresses_keepsSecondaryAddressWithoutStreet() {
        // D-05: an address whose street is nil (city/PO-box-only) carries real
        // data — the de-dup key is the full normalized address, not the street.
        let a = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        let b = [UnifiedContact.PostalAddress(city: "Shelbyville", postalCode: "62565")]
        let merged = makeEngine().mergeAddresses(a, b)
        XCTAssertEqual(merged.count, 2,
                       "a street-less secondary address carries real data and must survive the merge")
    }

    func test_mergeAddresses_keepsSameStreetDifferentCity() {
        // D-05: "1 Main St, Springfield" and "1 Main St, Shelbyville" are
        // different places; only the full address may collapse them.
        let a = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Springfield")]
        let b = [UnifiedContact.PostalAddress(street: "1 Main St", city: "Shelbyville")]
        let merged = makeEngine().mergeAddresses(a, b)
        XCTAssertEqual(merged.count, 2,
                       "same street in a different city is a different address")
    }
}

// MARK: - Failure key + deletion hold-back (AUDIT §3 rows 6-7; D-01)

final class SyncFailureKeyTests: XCTestCase {

    private var savedConfirmDeletions: Bool!

    override func setUp() {
        super.setUp()
        savedConfirmDeletions = AppSettings.shared.confirmPendingDeletions
        AppSettings.shared.confirmPendingDeletions = true
    }

    override func tearDown() {
        AppSettings.shared.confirmPendingDeletions = savedConfirmDeletions
        super.tearDown()
    }

    private func change(action: SyncAction = .update,
                        source: UnifiedContact?,
                        target: UnifiedContact?) -> ContactChange {
        ContactChange(contactName: "Test", action: action, direction: .twoWay,
                      changes: [], sourceContact: source, targetContact: target)
    }

    // MARK: failureKey(for:)

    func test_failureKey_prefersMacIdentifier() {
        let c = change(source: .diffMake(googleResourceName: "people/g1"),
                       target: .diffMake(macContactIdentifier: "mac-1"))
        XCTAssertEqual(SyncEngine.failureKey(for: c), "mac:mac-1")
    }

    func test_failureKey_findsMacIdentifierOnSource() {
        let c = change(source: .diffMake(googleResourceName: "people/g1",
                                         macContactIdentifier: "mac-src"),
                       target: .diffMake(googleResourceName: "people/g1"))
        XCTAssertEqual(SyncEngine.failureKey(for: c), "mac:mac-src",
                       "the Mac identifier wins wherever it lives")
    }

    func test_failureKey_fallsBackToGoogleResourceName() {
        let c = change(source: .diffMake(googleResourceName: "people/only"),
                       target: nil)
        XCTAssertEqual(SyncEngine.failureKey(for: c), "google:people/only")
    }

    func test_failureKey_emptyMacIdentifierIsIgnored() {
        let c = change(source: .diffMake(googleResourceName: "people/g2",
                                         macContactIdentifier: ""),
                       target: nil)
        XCTAssertEqual(SyncEngine.failureKey(for: c), "google:people/g2")
    }

    func test_failureKey_pureAdd_hasNoKey() {
        let c = change(action: .add, source: .diffMake(givenName: "Brand New"), target: nil)
        XCTAssertNil(SyncEngine.failureKey(for: c),
                     "an add has no record to blame, so it is never set aside")
    }

    // MARK: deletionIsHeldBack

    private func session(reviewed: Bool) -> SyncSession {
        var s = SyncSession(mode: .manual, direction: .twoWay,
                            startTime: Date(), contactChanges: [])
        s.userReviewed = reviewed
        return s
    }

    func test_delete_unreviewedSession_isHeldBack() {
        XCTAssertTrue(SyncEngine.deletionIsHeldBack(
            action: .delete, session: session(reviewed: false), settings: AppSettings.shared))
    }

    func test_delete_reviewedSession_isNotHeldBack() {
        XCTAssertFalse(SyncEngine.deletionIsHeldBack(
            action: .delete, session: session(reviewed: true), settings: AppSettings.shared))
    }

    func test_delete_settingOff_isNotHeldBack() {
        AppSettings.shared.confirmPendingDeletions = false
        XCTAssertFalse(SyncEngine.deletionIsHeldBack(
            action: .delete, session: session(reviewed: false), settings: AppSettings.shared))
    }

    func test_undecidedMerge_isDeferred_reviewedOrNot() {
        // #1 and #85 regressions: a `.merge` nobody explicitly confirmed is a
        // proposal on reviewed and unreviewed runs alike. "Reviewed" used to
        // release every unconfirmed merge, so pressing Apply without opening
        // each conflict silently fused same-name strangers (issue #85 — the
        // review sheet was discarding decisions AND the gate trusted it).
        let proposal = ContactChange(
            contactName: "David Chan", action: .merge, direction: .twoWay,
            changes: ["Possible match: same name only"],
            sourceContact: .diffMake(givenName: "David"),
            targetContact: .diffMake(givenName: "David"))
        XCTAssertTrue(SyncEngine.mergeIsHeldBack(change: proposal),
            "an undecided merge rewrites both sides and must wait for an explicit decision")
    }

    func test_confirmedMerge_isNotDeferred() {
        // The auto-apply set is deliberate: a shared-email match, an explicit
        // "merge both sides" preference, or a diff-sheet decision carries
        // userOverride == .merge and applies on any run.
        let confirmed = ContactChange(
            contactName: "David Chan", action: .merge, direction: .twoWay,
            changes: ["Matched on a shared email address"],
            userOverride: .merge,
            sourceContact: .diffMake(givenName: "David"),
            targetContact: .diffMake(givenName: "David"))
        XCTAssertFalse(SyncEngine.mergeIsHeldBack(change: confirmed))
    }

    func test_transientErrors_doNotCountTowardSetAside() {
        // P-03 regression (github issue #53): environmental failures must not
        // advance a contact's strike count.
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(CancellationError()))
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(GoogleContactsError.rateLimitExceeded))
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(GoogleContactsError.invalidToken))
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(
            GoogleContactsError.apiError(statusCode: 503, message: "backend error")))
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(
            GoogleContactsError.apiError(statusCode: 429, message: "quota")))
    }

    func test_contactSpecificErrors_doCountTowardSetAside() {
        XCTAssertTrue(SyncEngine.failureCountsTowardSetAside(
            GoogleContactsError.apiError(statusCode: 400, message: "invalid field")),
            "a 400 judges this contact's payload and should strike")
        XCTAssertTrue(SyncEngine.failureCountsTowardSetAside(
            NSError(domain: CNErrorDomain, code: 134092)),
            "a Contacts validation rejection is exactly what set-aside exists for")
    }

    func test_authAndPermissionStatuses_doNotCountTowardSetAside() {
        // Issue #102: 401 and 403 judge the session and its permissions —
        // they hit every contact alike, so striking individuals inverts the
        // store's purpose.
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(
            GoogleContactsError.apiError(statusCode: 401, message: "unauthorized")),
            "401 judges the session, not the contact")
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(
            GoogleContactsError.apiError(statusCode: 403, message: "forbidden")),
            "403 judges permissions, not the contact")
    }

    func test_chunkLevelBatchFailure_neverStrikes_itemRejectionDoes() {
        // Issue #102: one stale etag fails a whole ~200-contact chunk with a
        // single HTTP error. Chunk-level failures say nothing about any
        // member; only the per-item rejection is Google's judgement on a
        // specific contact.
        XCTAssertFalse(SyncEngine.failureCountsTowardSetAside(
            SyncEngineError.batchChunkFailed(
                underlying: GoogleContactsError.apiError(statusCode: 400, message: "stale etag"))),
            "a chunk-level 4xx must not strike ~200 innocent contacts at once")
        XCTAssertTrue(SyncEngine.failureCountsTowardSetAside(
            SyncEngineError.batchItemRejected("Test Contact")),
            "a per-item batch rejection still strikes")
    }

    func test_setAsideContact_isExcludedFromBatch() {
        // N-01 regression (github issue #24): set aside means set aside — the
        // batch pre-pass must not submit what the per-contact loop would skip.
        let key = "mac:test-batch-setaside"
        defer { SyncFailureStore.shared.clearFailure(key: key) }

        var s = SyncSession(mode: .manual, direction: .macToGoogle,
                            startTime: Date(), contactChanges: [])
        s.userReviewed = true
        let c = change(source: .diffMake(macContactIdentifier: "test-batch-setaside"),
                       target: .diffMake(googleResourceName: "people/g9"))

        XCTAssertTrue(SyncEngine.batchMaySend(c, session: s, settings: AppSettings.shared))

        for _ in 1...SyncFailureStore.attemptsBeforeSkipping {
            _ = SyncFailureStore.shared.recordFailure(key: key, name: "T", reason: "x")
        }
        XCTAssertFalse(SyncEngine.batchMaySend(c, session: s, settings: AppSettings.shared),
                       "a set-aside contact must not reach the wire via the batch")

        SyncFailureStore.shared.clearFailure(key: key)
        XCTAssertTrue(SyncEngine.batchMaySend(c, session: s, settings: AppSettings.shared),
                      "clearing the failure restores batch eligibility")
    }
}

// MARK: - D-02 regression: field clearing propagates and converges (github issue #2)

final class ApplyToMacClearingTests: XCTestCase {

    func test_emptiedPhones_clearMacPhones() {
        let mac = CNMutableContact()
        mac.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+15551234567"))]
        ContactMapper.applyToMac(from: .diffMake(givenName: "Ann"), to: mac)
        XCTAssertTrue(mac.phoneNumbers.isEmpty,
                      "all phones deleted on the other side must delete here, or the diff re-fires forever")
    }

    func test_clearedGivenName_clearsMacGivenName() {
        let mac = CNMutableContact()
        mac.givenName = "Old"
        mac.familyName = "Name"
        ContactMapper.applyToMac(from: .diffMake(familyName: "Name"), to: mac)
        XCTAssertEqual(mac.givenName, "",
                       "Google reports a cleared name as nil; the Mac stores it as \"\" — the diff's nonBlank comparison treats them as equal, so this converges")
        XCTAssertEqual(mac.familyName, "Name")
    }

    func test_optedOutFields_areNeverTouched() {
        // The engine strips opted-out fields to nil/empty before writing.
        // Stripped-because-opted-out must not read as cleared-by-the-user.
        let mac = CNMutableContact()
        mac.jobTitle = "Engineer"
        mac.birthday = DateComponents(year: 1990, month: 5, day: 1)
        mac.urlAddresses = [CNLabeledValue(
            label: CNLabelURLAddressHomePage,
            value: "https://example.com" as NSString)]
        let postal = CNMutablePostalAddress()
        postal.street = "1 Main St"
        mac.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]

        var mask = ContactMapper.MacWriteFields.all
        mask.jobTitle = false; mask.birthday = false
        mask.websites = false; mask.addresses = false
        ContactMapper.applyToMac(from: .diffMake(givenName: "Ann"), to: mac, fields: mask)

        XCTAssertEqual(mac.jobTitle, "Engineer")
        XCTAssertNotNil(mac.birthday)
        XCTAssertEqual(mac.urlAddresses.count, 1)
        XCTAssertEqual(mac.postalAddresses.count, 1)
    }

    func test_absentPhoto_doesNotClearMacPhoto() {
        // Photos travel Google → Mac only, and diffFields never reports a photo
        // removal — clearing here would wipe a photo no preview ever showed.
        let mac = CNMutableContact()
        mac.imageData = Data([0xFF, 0xD8])
        ContactMapper.applyToMac(from: .diffMake(givenName: "Ann"), to: mac)
        XCTAssertNotNil(mac.imageData)
    }

    func test_legacyRestoreMask_preservesFieldsTheSnapshotNeverCaptured() {
        // R-03 regression (github issue #44): pre-v2 snapshots decode the
        // extended fields as nil — "never captured", not "cleared" — and a
        // restore must not blank them on the live contact.
        let mac = CNMutableContact()
        mac.nickname = "Vic"
        mac.namePrefix = "Dr."
        mac.departmentName = "R&D"
        mac.birthday = DateComponents(year: 1990, month: 1, day: 2)
        mac.urlAddresses = [CNLabeledValue(
            label: CNLabelURLAddressHomePage,
            value: "https://example.com" as NSString)]

        let mask = ContactMapper.MacWriteFields.forRestore(ofLegacySnapshot: true)
        ContactMapper.applyToMac(from: .diffMake(givenName: "Ann"), to: mac, fields: mask)

        XCTAssertEqual(mac.nickname, "Vic")
        XCTAssertEqual(mac.namePrefix, "Dr.")
        XCTAssertEqual(mac.departmentName, "R&D")
        XCTAssertNotNil(mac.birthday)
        XCTAssertEqual(mac.urlAddresses.count, 1)
        XCTAssertEqual(mac.givenName, "Ann", "v1-captured fields still restore")

        // A v2 snapshot restores at full fidelity — including clears.
        let full = ContactMapper.MacWriteFields.forRestore(ofLegacySnapshot: false)
        ContactMapper.applyToMac(from: .diffMake(givenName: "Ann"), to: mac, fields: full)
        XCTAssertEqual(mac.nickname, "")
    }
}

// MARK: - D-04 regression: Google HTTP statuses map to actionable messages (github issue #4)

final class GoogleErrorMessageTests: XCTestCase {

    private func message(forStatus code: Int, body: String = "x") -> String {
        SyncCoordinator.friendlyMessage(
            for: GoogleContactsError.apiError(statusCode: code, message: body))
    }

    func test_401_promptsSignIn() {
        XCTAssertTrue(message(forStatus: 401).contains("Sign in again"),
                      "an expired session must tell the user the one action that fixes it")
    }

    func test_429_namesTheRateLimit() {
        XCTAssertTrue(message(forStatus: 429).contains("rate limit"))
    }

    func test_5xx_blamesGoogleNotTheUser() {
        XCTAssertTrue(message(forStatus: 500).contains("Google's servers"))
        XCTAssertTrue(message(forStatus: 503).contains("Google's servers"))
    }

    func test_403_keepsTheSpecificDiagnosis() {
        // 403s carry their own diagnosis in errorDescription (API disabled /
        // missing scope / test user) — friendlyMessage must not flatten it.
        let msg = message(forStatus: 403, body: "SERVICE_DISABLED for project")
        XCTAssertTrue(msg.contains("People API"))
    }

    func test_invalidToken_promptsSignIn() {
        let msg = SyncCoordinator.friendlyMessage(for: GoogleContactsError.invalidToken)
        XCTAssertTrue(msg.contains("Sign in again"))
    }
}

// MARK: - Group filter vs deletion, both-deleted cleanup, 1-way target-gone
// (issues #87, #124, #101)

final class GroupFilterAndTargetGoneTests: XCTestCase {

    private var savedConflict: ConflictResolutionDefault!
    private var savedForceUpdate: Bool!
    private var savedFilterByGroups: Bool!
    private var savedSyncDeleted: Bool!
    private var savedMerge1Way: Bool!

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedConflict       = s.defaultConflictResolution
        savedForceUpdate    = s.forceUpdateAll
        savedFilterByGroups = s.filterByGroups
        savedSyncDeleted    = s.syncDeletedContacts
        savedMerge1Way      = s.mergeContacts1Way
        s.defaultConflictResolution = .alwaysAsk
        s.forceUpdateAll = false
        s.filterByGroups = false
        // Pinned *on*: these tests prove that filtered-out contacts are not
        // deleted even when deletion sync is active.
        s.syncDeletedContacts = true
        s.mergeContacts1Way = false
    }

    override func tearDown() {
        let s = AppSettings.shared
        s.defaultConflictResolution = savedConflict
        s.forceUpdateAll = savedForceUpdate
        s.filterByGroups = savedFilterByGroups
        s.syncDeletedContacts = savedSyncDeleted
        s.mergeContacts1Way = savedMerge1Way
        super.tearDown()
    }

    private func engineWithMapping(gID: String, mID: String)
        -> (SyncEngine, ContactMappingStore) {
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store)
        return (engine, store)
    }

    // MARK: #87 — out-of-group is not deleted

    func test_mappedPair_outsideGroupFilter_isNotClassifiedAsDeleted() {
        let gID = "people/out-of-group"
        let mID = "mac/out-of-group"
        let (engine, store) = engineWithMapping(gID: gID, mID: mID)

        let google = UnifiedContact.diffMake(givenName: "Out", googleResourceName: gID)
        // The Mac twin is absent from the *filtered* input but present in the
        // unfiltered fetch: it exists, it is merely outside the selected groups.
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [], direction: .twoWay,
            unfilteredGoogleIDs: [gID], unfilteredMacIDs: [mID])

        XCTAssertTrue(changes.isEmpty,
                      "an out-of-group contact must be skipped — not deleted, not re-added")
        XCTAssertNotNil(store.getMapping(googleResourceName: gID),
                        "the pair still exists, so the mapping must survive")
    }

    func test_mappedPair_trulyGoneOnMac_isStillADeletion() {
        let gID = "people/really-gone"
        let mID = "mac/really-gone"
        let (engine, _) = engineWithMapping(gID: gID, mID: mID)

        let google = UnifiedContact.diffMake(givenName: "Gone", googleResourceName: gID)
        // Present in neither the filtered list nor the unfiltered fetch:
        // genuinely deleted, and deletion sync is pinned on.
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [], direction: .twoWay,
            unfilteredGoogleIDs: [gID], unfilteredMacIDs: [])

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.action, .delete)
        XCTAssertEqual(changes.first?.direction, .macToGoogle)
    }

    // MARK: #124 — both-deleted mappings actually get removed

    func test_bothDeletedMapping_isRemovedAfterTheWalk() {
        let gID = "people/dead"
        let mID = "mac/dead"
        let (engine, store) = engineWithMapping(gID: gID, mID: mID)

        let changes = engine.computeChanges(
            googleContacts: [], macContacts: [], direction: .twoWay)

        XCTAssertTrue(changes.isEmpty, "both sides gone — nothing to sync")
        XCTAssertNil(store.getMapping(googleResourceName: gID),
                     "a (nil, nil) mapping is dead and must be removed, not kept forever")
    }

    func test_pairOutsideFilterOnBothSides_keepsItsMapping() {
        let gID = "people/filtered-both"
        let mID = "mac/filtered-both"
        let (engine, store) = engineWithMapping(gID: gID, mID: mID)

        let changes = engine.computeChanges(
            googleContacts: [], macContacts: [], direction: .twoWay,
            unfilteredGoogleIDs: [gID], unfilteredMacIDs: [mID])

        XCTAssertTrue(changes.isEmpty)
        XCTAssertNotNil(store.getMapping(googleResourceName: gID),
                        "out-of-group on both sides is not deleted-on-both-sides")
    }

    // MARK: #101 — 1-way "deleted on target" re-creates from source

    func test_oneWay_targetGone_reAddsFromSource_andClearsStaleMapping() {
        let gID = "people/oneway-src"
        let mID = "mac/oneway-gone"
        let (engine, store) = engineWithMapping(gID: gID, mID: mID)

        let google = UnifiedContact.diffMake(givenName: "Mirror", googleResourceName: gID)
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [], direction: .googleToMac)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.action, .add,
                       "a 1-way sync mirrors the source: the target copy is re-created, "
                       + "not phantom-deleted")
        XCTAssertEqual(changes.first?.direction, .googleToMac)
        XCTAssertEqual(changes.first?.sourceContact?.googleResourceName, gID)
        XCTAssertFalse(changes.contains { $0.action == .delete },
                       "the old phantom delete must be gone")
        XCTAssertNil(store.getMapping(googleResourceName: gID),
                     "the stale mapping must be removed so the add re-links the pair")
    }

    func test_oneWay_targetMerelyOutsideFilter_isSkipped() {
        let gID = "people/oneway-filtered"
        let mID = "mac/oneway-filtered"
        let (engine, store) = engineWithMapping(gID: gID, mID: mID)

        let google = UnifiedContact.diffMake(givenName: "Filtered", googleResourceName: gID)
        let changes = engine.computeChanges(
            googleContacts: [google], macContacts: [], direction: .googleToMac,
            unfilteredGoogleIDs: [gID], unfilteredMacIDs: [mID])

        XCTAssertTrue(changes.isEmpty,
                      "an out-of-group target is not deleted — nothing to re-create")
        XCTAssertNotNil(store.getMapping(googleResourceName: gID))
    }
}

// MARK: - Google updateTime parsing + phonetic round-trip (issues #91, #88)

final class GoogleUpdateTimeParsingTests: XCTestCase {

    func test_fractionalSeconds_parse() {
        // What the People API actually sends.
        XCTAssertNotNil(GoogleContactsConnector.parseUpdateTime("2026-08-11T09:41:30.123456Z"),
                        "a nil parse here demoted every Google edit to the conflict branch")
    }

    func test_wholeSeconds_parse() {
        XCTAssertNotNil(GoogleContactsConnector.parseUpdateTime("2026-08-11T09:41:30Z"))
    }

    func test_bothFormsAgreeOnTheSecond() {
        let fractional = GoogleContactsConnector.parseUpdateTime("2026-08-11T09:41:30.500Z")
        let whole = GoogleContactsConnector.parseUpdateTime("2026-08-11T09:41:30Z")
        guard let fractional, let whole else { return XCTFail("both forms must parse") }
        XCTAssertEqual(fractional.timeIntervalSince(whole), 0.5, accuracy: 0.001)
    }

    func test_garbage_returnsNil() {
        XCTAssertNil(GoogleContactsConnector.parseUpdateTime("not a date"))
    }

    func test_decodePage_prefersContactSource_andReadsPhonetics() throws {
        // One payload covers both fixes: metadata carries a PROFILE source
        // first (whose updateTime describes a different record) and the
        // CONTACT source second with fractional seconds; the name block
        // carries the phonetic fields that never used to round-trip.
        let json = Data("""
        {
          "connections": [
            {
              "resourceName": "people/c7",
              "names": [{
                "givenName": "Tai",
                "familyName": "Lam",
                "phoneticGivenName": "タイ",
                "phoneticMiddleName": "チュン",
                "phoneticFamilyName": "ラム"
              }],
              "metadata": {
                "sources": [
                  {"type": "PROFILE", "updateTime": "2020-01-01T00:00:00Z"},
                  {"type": "CONTACT", "updateTime": "2026-08-11T09:41:30.250Z"}
                ]
              }
            }
          ]
        }
        """.utf8)

        let page = try GoogleContactsConnector.decodePage(json)
        let contact = try XCTUnwrap(page.contacts.first)

        XCTAssertEqual(contact.phoneticGivenName, "タイ")
        XCTAssertEqual(contact.phoneticMiddleName, "チュン")
        XCTAssertEqual(contact.phoneticFamilyName, "ラム")

        let expected = try XCTUnwrap(
            GoogleContactsConnector.parseUpdateTime("2026-08-11T09:41:30.250Z"))
        XCTAssertEqual(contact.updateTime, expected,
                       "the CONTACT source's updateTime wins over PROFILE's")
    }
}
