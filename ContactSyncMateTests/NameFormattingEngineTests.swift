//
//  NameFormattingEngineTests.swift
//  ContactSyncMateTests
//
//  Unit tests for the opt-in name casing engine: particle awareness,
//  special prefixes (Mc/Mac/O'), hyphenation, CJK safety, idempotence.
//

import XCTest
@testable import Contact_SyncMate

final class NameFormattingEngineTests: XCTestCase {

    // MARK: - Title case basics

    func test_titleCase_basicLowercase() {
        XCTAssertEqual(NameFormattingEngine.format("john", convention: .titleCase), "John")
    }

    func test_titleCase_basicUppercase() {
        XCTAssertEqual(NameFormattingEngine.format("SMITH", convention: .titleCase), "Smith")
    }

    func test_titleCase_mixedChaos() {
        XCTAssertEqual(NameFormattingEngine.format("jOhN", convention: .titleCase), "John")
    }

    // MARK: - Special prefixes

    func test_titleCase_mcPrefix() {
        XCTAssertEqual(NameFormattingEngine.format("mcdonald", convention: .titleCase), "McDonald")
    }

    func test_titleCase_macPrefix_longEnough() {
        XCTAssertEqual(NameFormattingEngine.format("macintyre", convention: .titleCase), "MacIntyre")
    }

    func test_titleCase_macShortName_notOverCapitalised() {
        // "Mack" must NOT become "MacK"
        XCTAssertEqual(NameFormattingEngine.format("mack", convention: .titleCase), "Mack")
    }

    func test_titleCase_apostropheO() {
        XCTAssertEqual(NameFormattingEngine.format("o'brien", convention: .titleCase), "O'Brien")
    }

    func test_titleCase_apostropheD() {
        XCTAssertEqual(NameFormattingEngine.format("d'angelo", convention: .titleCase), "D'Angelo")
    }

    // MARK: - Particles

    func test_titleCase_dutchParticles_interiorStayLowercase() {
        XCTAssertEqual(NameFormattingEngine.format("ludwig van der berg", convention: .titleCase),
                       "Ludwig van der Berg")
    }

    func test_titleCase_particleAsFirstWord_isCapitalised() {
        XCTAssertEqual(NameFormattingEngine.format("van der berg", convention: .titleCase),
                       "Van der Berg")
    }

    func test_titleCase_spanishParticles() {
        XCTAssertEqual(NameFormattingEngine.format("maria de la cruz", convention: .titleCase),
                       "Maria de la Cruz")
    }

    // MARK: - Hyphenation

    func test_titleCase_hyphenatedGivenName() {
        XCTAssertEqual(NameFormattingEngine.format("jean-luc", convention: .titleCase), "Jean-Luc")
    }

    func test_titleCase_hyphenatedFamilyName() {
        XCTAssertEqual(NameFormattingEngine.format("smith-jones", convention: .titleCase), "Smith-Jones")
    }

    // MARK: - CJK safety

    func test_cjk_chineseUnchanged_allConventions() {
        for convention in NameCasingConvention.allCases {
            XCTAssertEqual(NameFormattingEngine.format("王小明", convention: convention), "王小明")
        }
    }

    func test_cjk_japaneseUnchanged() {
        XCTAssertEqual(NameFormattingEngine.format("たなか", convention: .upperCase), "たなか")
    }

    func test_cjk_koreanUnchanged() {
        XCTAssertEqual(NameFormattingEngine.format("김철수", convention: .titleCase), "김철수")
    }

    func test_cjk_mixedLatinCJK_unchanged() {
        // Names mixing scripts are left alone entirely (conservative).
        XCTAssertEqual(NameFormattingEngine.format("david 王", convention: .titleCase), "david 王")
    }

    func test_containsCJK_detection() {
        XCTAssertTrue(NameFormattingEngine.containsCJK("王"))
        XCTAssertTrue(NameFormattingEngine.containsCJK("たなか"))
        XCTAssertTrue(NameFormattingEngine.containsCJK("김"))
        XCTAssertFalse(NameFormattingEngine.containsCJK("Smith"))
        XCTAssertFalse(NameFormattingEngine.containsCJK("Müller"))
    }

    // MARK: - Upper / lower / as-is

    func test_upperCase() {
        XCTAssertEqual(NameFormattingEngine.format("John Smith", convention: .upperCase), "JOHN SMITH")
    }

    func test_lowerCase() {
        XCTAssertEqual(NameFormattingEngine.format("John SMITH", convention: .lowerCase), "john smith")
    }

    func test_asIs_neverTouches() {
        XCTAssertEqual(NameFormattingEngine.format("jOhN sMiTh", convention: .asIs), "jOhN sMiTh")
    }

    // MARK: - Edge cases

    func test_nil_passthrough() {
        XCTAssertNil(NameFormattingEngine.format(nil, convention: .titleCase))
    }

    func test_empty_passthrough() {
        XCTAssertEqual(NameFormattingEngine.format("", convention: .titleCase), "")
    }

    func test_idempotence_titleCase() {
        let once  = NameFormattingEngine.format("ludwig van der berg-o'brien", convention: .titleCase)
        let twice = NameFormattingEngine.format(once, convention: .titleCase)
        XCTAssertEqual(once, twice)
    }

    func test_accentedLatin_isFormatted() {
        XCTAssertEqual(NameFormattingEngine.format("josé", convention: .titleCase), "José")
        XCTAssertEqual(NameFormattingEngine.format("müller", convention: .titleCase), "Müller")
    }

    // MARK: - applyToContact

    func test_applyToContact_formatsNameComponents_only() {
        var contact = UnifiedContact(id: UUID())
        contact.givenName = "john"
        contact.familyName = "mcdonald"
        contact.nickname = "johnny boy"       // must NOT be touched
        contact.organizationName = "acme inc" // must NOT be touched

        NameFormattingEngine.applyToContact(&contact, convention: .titleCase)

        XCTAssertEqual(contact.givenName, "John")
        XCTAssertEqual(contact.familyName, "McDonald")
        XCTAssertEqual(contact.nickname, "johnny boy")
        XCTAssertEqual(contact.organizationName, "acme inc")
    }

    func test_applyToContact_asIs_noChanges() {
        var contact = UnifiedContact(id: UUID())
        contact.givenName = "jOhN"
        NameFormattingEngine.applyToContact(&contact, convention: .asIs)
        XCTAssertEqual(contact.givenName, "jOhN")
    }
}

// MARK: - SyncHistory retention tests

final class SyncHistoryRetentionTests: XCTestCase {

    private func event(daysAgo: Int) -> SyncEvent {
        SyncEvent(
            timestamp: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            source: "test", action: "test", details: nil
        )
    }

    func test_prune_dropsEventsOlderThanRetention() {
        let events = [event(daysAgo: 40), event(daysAgo: 10), event(daysAgo: 1)]
        let pruned = SyncHistory.prune(events, retentionDays: 30, maxCount: 1000)
        XCTAssertEqual(pruned.count, 2)
    }

    func test_prune_zeroRetention_keepsAllAges() {
        let events = [event(daysAgo: 400), event(daysAgo: 1)]
        let pruned = SyncHistory.prune(events, retentionDays: 0, maxCount: 1000)
        XCTAssertEqual(pruned.count, 2)
    }

    func test_prune_countCap_keepsMostRecent() {
        let events = (0..<20).map { event(daysAgo: $0) }  // index 0 = newest... appended oldest last
        let pruned = SyncHistory.prune(events, retentionDays: 0, maxCount: 5)
        XCTAssertEqual(pruned.count, 5)
        // removeFirst drops the head — the survivors are the LAST 5 elements.
        XCTAssertEqual(pruned.first?.timestamp, events[15].timestamp)
    }

    func test_prune_bothLimits() {
        let events = [event(daysAgo: 40)] + (0..<10).map { event(daysAgo: $0) }
        let pruned = SyncHistory.prune(events, retentionDays: 30, maxCount: 5)
        XCTAssertEqual(pruned.count, 5)
        XCTAssertTrue(pruned.allSatisfy {
            $0.timestamp > Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        })
    }
}

// MARK: - Dedup blocking tests

final class DedupBlockingTests: XCTestCase {

    private func contact(given: String? = nil, family: String? = nil,
                         email: String? = nil, phone: String? = nil) -> UnifiedContact {
        var c = UnifiedContact(id: UUID())
        c.givenName = given
        c.familyName = family
        if let email { c.emailAddresses = [.init(value: email, label: "work")] }
        if let phone { c.phoneNumbers   = [.init(value: phone, label: "mobile")] }
        return c
    }

    func test_blockingKeys_emailAndPhoneAndInitials() {
        let c = contact(given: "John", family: "Smith",
                        email: "John@Example.com", phone: "+1 (555) 123-4567")
        let keys = ContactDeduplicator.blockingKeys(for: c)
        XCTAssertTrue(keys.contains("e:john@example.com"))
        XCTAssertTrue(keys.contains("p:1234567"))
        XCTAssertTrue(keys.contains("f:s"))
        XCTAssertTrue(keys.contains("g:j"))
    }

    func test_blockingKeys_emptyContact_getsCatchAll() {
        let keys = ContactDeduplicator.blockingKeys(for: contact())
        XCTAssertEqual(keys, ["∅"])
    }

    func test_nicknameVariants_shareFamilyInitialBucket() {
        // Bob Smith vs Robert Smith: given initials differ (b/r) but family
        // initial "s" is shared → the pair is still compared.
        let bob    = ContactDeduplicator.blockingKeys(for: contact(given: "Bob", family: "Smith"))
        let robert = ContactDeduplicator.blockingKeys(for: contact(given: "Robert", family: "Smith"))
        XCTAssertFalse(bob.intersection(robert).isEmpty)
    }

    func test_transposedNames_shareBuckets() {
        // Wei Li ↔ Li Wei: g:w matches f:w? No — keys are namespaced.
        // Wei Li  → g:w, f:l ; Li Wei → g:l, f:w. No shared key from initials
        // alone… but sharing an email or phone still pairs them, and the
        // exhaustive scan (<500 contacts) always covers them. Document the
        // tradeoff: at >500 contacts transposed-name-only pairs need a
        // shared email/phone to be candidates.
        let a = ContactDeduplicator.blockingKeys(for: contact(given: "Wei", family: "Li",
                                                              email: "wei@x.com"))
        let b = ContactDeduplicator.blockingKeys(for: contact(given: "Li", family: "Wei",
                                                              email: "wei@x.com"))
        XCTAssertFalse(a.intersection(b).isEmpty) // via shared email
    }

    func test_candidatePairs_smallSet_isExhaustive() {
        let contacts = (0..<10).map { i in contact(given: "P\(i)", family: "Q\(i)") }
        let pairs = ContactDeduplicator.candidatePairs(for: contacts)
        XCTAssertEqual(pairs.count, 45) // C(10,2) — exhaustive below threshold
    }
}
