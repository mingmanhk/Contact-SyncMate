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
final class GooglePhotoDiffTests: XCTestCase {

    private var savedSyncPhotos: Bool!
    private var savedConflict: ConflictResolutionDefault!
    private var savedForceUpdate: Bool!
    private var savedFilterByGroups: Bool!

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedSyncPhotos     = s.syncPhotos
        savedConflict       = s.defaultConflictResolution
        savedForceUpdate    = s.forceUpdateAll
        savedFilterByGroups = s.filterByGroups
        s.syncPhotos = true
        s.defaultConflictResolution = .alwaysAsk
        s.forceUpdateAll = false
        s.filterByGroups = false
    }

    override func tearDown() {
        let s = AppSettings.shared
        s.syncPhotos = savedSyncPhotos
        s.defaultConflictResolution = savedConflict
        s.forceUpdateAll = savedForceUpdate
        s.filterByGroups = savedFilterByGroups
        super.tearDown()
    }

    private func changes(google: UnifiedContact, mac: UnifiedContact,
                         gID: String, mID: String) -> [ContactChange] {
        let store = ContactMappingStore.testStore()
        store.saveMapping(ContactMapping(
            googleResourceName: gID, macContactIdentifier: mID,
            lastSyncedAt: Date(timeIntervalSince1970: 0)))
        Thread.sleep(forTimeInterval: 0.05)

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
}
