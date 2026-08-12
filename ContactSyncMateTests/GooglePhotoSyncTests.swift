// GooglePhotoSyncTests.swift
// Google → Mac photo sync (issue #59): default-photo skip at conversion,
// the photoUrl-aware diff rule, and photoUrl propagation through merges.

import XCTest
@testable import Contact_SyncMate

final class GooglePhotoSyncTests: XCTestCase {

    // MARK: - Default-photo skip (usablePhotoUrl)

    private func photo(_ url: String, isDefault: Bool? = nil, primary: Bool? = nil) -> PersonPhoto {
        PersonPhoto(url: url,
                    metadata: PhotoMetadata(primary: primary, source: nil, isDefault: isDefault))
    }

    func test_usablePhotoUrl_skipsDefaultSilhouette() {
        let photos = [photo("https://example.com/default.jpg", isDefault: true)]
        XCTAssertNil(GoogleContactsConnector.usablePhotoUrl(from: photos),
                     "Google's auto-generated placeholder is not a photo worth syncing")
    }

    func test_usablePhotoUrl_returnsFirstNonDefault() {
        let photos = [
            photo("https://example.com/default.jpg", isDefault: true),
            photo("https://example.com/real.jpg", primary: true),
            photo("https://example.com/second.jpg")
        ]
        XCTAssertEqual(GoogleContactsConnector.usablePhotoUrl(from: photos),
                       "https://example.com/real.jpg")
    }

    func test_usablePhotoUrl_treatsMissingMetadataAsReal() {
        // Most real photos come back with no `default` key at all.
        let photos = [photo("https://example.com/real.jpg")]
        XCTAssertEqual(GoogleContactsConnector.usablePhotoUrl(from: photos),
                       "https://example.com/real.jpg")
    }

    func test_usablePhotoUrl_nilForNilOrEmpty() {
        XCTAssertNil(GoogleContactsConnector.usablePhotoUrl(from: nil))
        XCTAssertNil(GoogleContactsConnector.usablePhotoUrl(from: []))
    }

    // MARK: - "default" JSON key decoding

    func test_photoMetadata_decodesDefaultKey() throws {
        let json = Data("""
        {"url": "https://example.com/p.jpg", "metadata": {"primary": true, "default": true}}
        """.utf8)
        let decoded = try JSONDecoder().decode(PersonPhoto.self, from: json)
        XCTAssertEqual(decoded.metadata?.isDefault, true)
        XCTAssertEqual(decoded.metadata?.primary, true)
    }

    // MARK: - decodePage (issue #58's off-main seam, end to end)

    func test_decodePage_convertsContactsAndCarriesPageToken() throws {
        let json = Data("""
        {
          "connections": [
            {
              "resourceName": "people/c1",
              "etag": "etag-1",
              "names": [{"givenName": "Ada", "familyName": "Lovelace"}],
              "photos": [
                {"url": "https://example.com/default.jpg", "metadata": {"default": true}},
                {"url": "https://example.com/real.jpg", "metadata": {"primary": true}}
              ]
            }
          ],
          "nextPageToken": "tok-2"
        }
        """.utf8)

        let page = try GoogleContactsConnector.decodePage(json)
        XCTAssertEqual(page.nextPageToken, "tok-2")
        XCTAssertEqual(page.contacts.count, 1)
        XCTAssertEqual(page.contacts.first?.givenName, "Ada")
        XCTAssertEqual(page.contacts.first?.etag, "etag-1")
        XCTAssertEqual(page.contacts.first?.photoUrl, "https://example.com/real.jpg",
                       "Conversion must skip the default photo and keep the real one")
    }

    func test_decodePage_emptyResponse() throws {
        let page = try GoogleContactsConnector.decodePage(Data("{}".utf8))
        XCTAssertTrue(page.contacts.isEmpty)
        XCTAssertNil(page.nextPageToken)
    }

    // MARK: - Photo diff rule (photoUrl counts as "Google has a photo")

    func test_googlePhotoNeedsCopy_firesOnPhotoUrl() {
        var google = UnifiedContact(id: UUID())
        google.googleResourceName = "people/c1"
        google.photoUrl = "https://example.com/real.jpg"
        var mac = UnifiedContact(id: UUID())
        mac.macContactIdentifier = "mac-1"

        XCTAssertTrue(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac),
                      "A non-default photoUrl means Google has a photo, even before download")
    }

    func test_googlePhotoNeedsCopy_convergesOnceMacHasAnImage() {
        var google = UnifiedContact(id: UUID())
        google.googleResourceName = "people/c1"
        google.photoUrl = "https://example.com/real.jpg"
        var mac = UnifiedContact(id: UUID())
        mac.macContactIdentifier = "mac-1"
        mac.photoData = Data([0x01])

        XCTAssertFalse(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac),
                       "Once the Mac side has an image there is nothing left to copy")
    }

    func test_googlePhotoNeedsCopy_falseWithNoGooglePhoto() {
        var google = UnifiedContact(id: UUID())
        google.googleResourceName = "people/c1"
        var mac = UnifiedContact(id: UUID())
        mac.macContactIdentifier = "mac-1"

        XCTAssertFalse(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac))
    }

    func test_googlePhotoNeedsCopy_suppressedAfterFailedDownload() {
        // Issue #125: a persistently failing photo URL re-armed "Photo
        // changed" — and the full update plus pre/post backup pair it
        // triggers — on every scheduled sync. Once a download has failed this
        // launch, the rule goes quiet for that contact.
        var google = UnifiedContact(id: UUID())
        google.googleResourceName = "people/failing"
        google.photoUrl = "https://example.com/broken.jpg"
        var mac = UnifiedContact(id: UUID())
        mac.macContactIdentifier = "mac-1"

        XCTAssertTrue(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac),
                      "with no failure recorded the rule still fires")
        XCTAssertFalse(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac,
                                                       failedDownloads: ["people/failing"]),
                       "a URL that failed this launch must stop re-arming the diff")

        google.photoData = Data([0x01])
        XCTAssertTrue(SyncEngine.googlePhotoNeedsCopy(google: google, mac: mac,
                                                      failedDownloads: ["people/failing"]),
                      "bytes already in hand always copy — suppression is only about the URL")
    }

    // MARK: - photoUrl propagation

    func test_toUnified_carriesPhotoUrl() {
        var google = GoogleContact(id: "people/c9")
        google.givenName = "Grace"
        google.photoUrl = "https://example.com/grace.jpg"

        let unified = ContactMapper.toUnified(from: google)
        XCTAssertEqual(unified.photoUrl, "https://example.com/grace.jpg")
    }

    func test_mergeContacts_propagatesPhotoUrl() {
        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore.testStore())

        var google = UnifiedContact(id: UUID())
        google.googleResourceName = "people/c1"
        google.photoUrl = "https://example.com/real.jpg"
        var mac = UnifiedContact(id: UUID())
        mac.macContactIdentifier = "mac-1"

        let merged = engine.mergeContacts(primary: mac, secondary: google)
        XCTAssertEqual(merged.photoUrl, "https://example.com/real.jpg",
                       "The merge write path needs the URL to download the photo just in time")
    }

    func test_merging_propagatesPhotoUrl() {
        var google = UnifiedContact(id: UUID())
        google.photoUrl = "https://example.com/real.jpg"
        let mac = UnifiedContact(id: UUID())

        XCTAssertEqual(mac.merging(with: google, preferOther: true).photoUrl,
                       "https://example.com/real.jpg")
    }
}

/// The diff path end to end: photoUrl must make "Photo changed" fire, and
/// stop firing once the Mac side has an image. Mirrors the photoData tests in
/// SyncEngineDiffTests, with the settings the photo rule reads pinned.
final class GooglePhotoDiffTests: SettingsPinnedTestCase {

    override func setUp() {
        super.setUp()
        // Issue #107: shared pinner instead of hand-rolled save/restore.
        pinDiffDefaults()
        pin(\.syncPhotos, to: true)
    }

    private func changes(google: UnifiedContact, mac: UnifiedContact,
                         gID: String, mID: String) -> [ContactChange] {
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        store.flush()

        return SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: store
        ).computeChanges(googleContacts: [google], macContacts: [mac], direction: .twoWay)
    }

    func test_googlePhotoUrl_isReportedAsPhotoChanged() {
        var google = UnifiedContact.diffMake(givenName: "Pat",
                                             googleResourceName: "people/photo-url")
        google.photoUrl = "https://example.com/pat.jpg"
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Pat",
                                          macContactIdentifier: "mac/photo-url")
        mac.lastModified = Date(timeIntervalSince1970: 0)

        let result = changes(google: google, mac: mac,
                             gID: "people/photo-url", mID: "mac/photo-url")
        XCTAssertTrue(result.flatMap(\.changes).contains { $0.contains("Photo") },
                      "photoUrl is how the fetch says Google has a photo — the rule must fire on it")
    }

    func test_googlePhotoUrl_doesNotRefire_onceMacHasPhoto() {
        var google = UnifiedContact.diffMake(givenName: "Pat",
                                             googleResourceName: "people/photo-done")
        google.photoUrl = "https://example.com/pat.jpg"
        google.lastModified = Date()
        var mac = UnifiedContact.diffMake(givenName: "Pat",
                                          macContactIdentifier: "mac/photo-done")
        mac.photoData = Data([0x01, 0x02])
        mac.lastModified = Date()

        let result = changes(google: google, mac: mac,
                             gID: "people/photo-done", mID: "mac/photo-done")
        XCTAssertFalse(result.flatMap(\.changes).contains { $0.contains("Photo") },
                       "After one sync copies the photo, the diff must go quiet — that is convergence")
    }

    func test_photoOnlyDiff_isDirectUpdate_notAConflictMerge() {
        // Issue #86: photos travel one way, so "photo differs" is not a
        // conflict. With no timestamps on either side (the CNContact-has-no-
        // modification-date normality) a photo-only diff used to fall into
        // the unknown-vs-unknown conflict switch — deferring a merge forever
        // under .alwaysAsk, which this class pins.
        var google = UnifiedContact.diffMake(givenName: "Pat",
                                             googleResourceName: "people/photo-only")
        google.photoUrl = "https://example.com/pat.jpg"
        let mac = UnifiedContact.diffMake(givenName: "Pat",
                                          macContactIdentifier: "mac/photo-only")

        let result = changes(google: google, mac: mac,
                             gID: "people/photo-only", mID: "mac/photo-only")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.action, .update,
                       "a photo-only diff has exactly one applicable action")
        XCTAssertEqual(result.first?.direction, .googleToMac,
                       "Google → Mac is the only direction a photo can travel")
        XCTAssertNil(result.first?.userOverride)
    }

    func test_photoAlongsideOtherDiffs_keepsConflictRouting() {
        // When the photo change rides along with real field differences the
        // normal conflict routing stands — under .alwaysAsk with no
        // timestamps that is an unresolved merge carrying both reasons.
        var google = UnifiedContact.diffMake(givenName: "Patricia",
                                             googleResourceName: "people/photo-mixed")
        google.photoUrl = "https://example.com/pat.jpg"
        let mac = UnifiedContact.diffMake(givenName: "Pat",
                                          macContactIdentifier: "mac/photo-mixed")

        let result = changes(google: google, mac: mac,
                             gID: "people/photo-mixed", mID: "mac/photo-mixed")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.action, .merge)
        XCTAssertTrue(result.first?.changes.contains("Photo changed") ?? false,
                      "the photo component still rides along with the other diffs")
    }
}
