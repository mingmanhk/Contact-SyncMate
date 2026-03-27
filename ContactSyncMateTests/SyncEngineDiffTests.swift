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

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore()
        )
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
        XCTAssertEqual(mac.note, "Mac note")
    }
}
