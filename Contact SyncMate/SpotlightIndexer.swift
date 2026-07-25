//
//  SpotlightIndexer.swift
//  Contact SyncMate
//
//  Core Spotlight integration. Indexes each completed sync as a searchable
//  item so the user can find sync results from system-wide Spotlight
//  (⌘Space → "contact sync").
//
//  Only sync summaries are indexed — never contact data. This keeps the
//  index useful ("when did my last sync run?") without leaking personal
//  information into the Spotlight store.
//

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

enum SpotlightIndexer {

    private static let domainID = "com.victorlam.ContactSyncMate.syncEvents"
    /// Keep at most this many sync events in the Spotlight index.
    private static let maxIndexedEvents = 25

    /// Index a completed sync. Old items beyond `maxIndexedEvents` are
    /// pruned by re-indexing under stable identifiers (sync-0 = newest).
    static func indexSyncResult(added: Int, updated: Int, deleted: Int,
                                errorCount: Int, date: Date) {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = errorCount == 0
            ? "Contact sync — success"
            : "Contact sync — \(errorCount) error\(errorCount == 1 ? "" : "s")"
        attributes.contentDescription =
            "Added \(added), updated \(updated), deleted \(deleted). " +
            date.formatted(date: .abbreviated, time: .shortened)
        attributes.contentCreationDate = date
        attributes.keywords = ["contact", "sync", "google", "contacts", "SyncMate"]

        let item = CSSearchableItem(
            uniqueIdentifier: "sync-\(date.timeIntervalSince1970)",
            domainIdentifier: domainID,
            attributeSet: attributes
        )
        item.expirationDate = Calendar.current.date(byAdding: .day, value: 90, to: date)

        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                SyncHistory.shared.log(
                    source: "SpotlightIndexer",
                    action: "index.failed",
                    details: error.localizedDescription
                )
            }
        }
    }

    /// Remove everything this app put into Spotlight (called from
    /// Settings → General → Reset, and useful for privacy-minded users).
    static func clearIndex() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainID]) { _ in }
    }
}
