// SyncEngineDiffTests.swift
// Sync engine diff logic and ContactMapper tests

import XCTest
@testable import Contact_SyncMate

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
            mappingStore: ContactMappingStore()
        )
    }

    // MARK: - Photo diff convergence

    /// A photo only the Mac has cannot be pushed: the People API rejects
    /// `photos` in an update mask. Reporting it produced an update that wrote
    /// nothing and came back identical on the next sync, forever.
    func test_photoOnlyOnMac_isNotReportedAsAChange() {
        let gID = "people/photo-mac-only"
        let mID = "mac/photo-mac-only"
        let store = ContactMappingStore()
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
        let store = ContactMappingStore()
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
        let store = ContactMappingStore()
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
        let store = ContactMappingStore()
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

        let store = ContactMappingStore()
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

        let store = ContactMappingStore()
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
