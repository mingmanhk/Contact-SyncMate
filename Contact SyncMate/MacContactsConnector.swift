//
//  MacContactsConnector.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
@preconcurrency import Contacts
import Combine
import os.log

/// Connector for macOS Contacts framework
///
/// This connector integrates with the deduplication system by:
/// - Providing `fetchAllContactsForDeduplication()` for duplicate scanning
/// - Filtering out the Me card contact to avoid false duplicates
/// - Supporting container-specific operations for isolated deduplication
///
/// See `DEDUPLICATION_GUIDE.md` for full deduplication workflow details.
class MacContactsConnector: ObservableObject {
    /// One `CNContactStore` for the whole process.
    ///
    /// Every store owns its own Core Data context, and a `CNContact` fetched
    /// through one store belongs to that context. Passing it to a *different*
    /// store's `CNSaveRequest` makes Core Data fault properties against a context
    /// that no longer owns the object, which surfaces as
    ///   NSCocoaErrorDomain 134092 · "Unhandled error … occurred during faulting"
    /// — an opaque failure with no mention of the real cause.
    ///
    /// The app was creating a connector (and therefore a store) per call site —
    /// SyncEngine, DeduplicationCoordinator, Settings, the exporters — so merges
    /// routinely fetched through one store and saved through another. Every Mac
    /// write failed. Sharing the store removes the mismatch by construction, and
    /// is what Apple documents: CNContactStore is expensive to create and meant
    /// to be shared.
    /// `nonisolated(unsafe)` rather than main-actor isolated: `CNContactStore` is
    /// documented as safe to use from any thread, and its calls are synchronous
    /// XPC that *must* run off the main actor to avoid a priority inversion. The
    /// isolation the compiler would infer here is exactly the thing we need not
    /// to have.
    nonisolated(unsafe) static let shared = CNContactStore()
    private var store: CNContactStore { Self.shared }
    private let history = SyncHistory.shared
    
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    @Published var availableContainers: [CNContainer] = []
    
    // MARK: - Container Helpers
    /// Heuristic to exclude Google/Gmail CardDAV containers
    private func isLikelyGoogleContainer(_ container: CNContainer) -> Bool {
        let name = container.name.lowercased()
        if name.contains("google") || name.contains("gmail") { return true }
        // Some Google accounts may appear as CardDAV without obvious name; prefer iCloud/local only
        return false
    }

    /// Returns the iCloud container if present (CardDAV with name containing iCloud)
    func getICloudContainerOnly() throws -> CNContainer? {
        let containers = try store.containers(matching: nil)
        return containers.first(where: { $0.type == .cardDAV && $0.name.lowercased().contains("icloud") })
    }
    
    init() {
        updateAuthorizationStatus()
        startMonitoringChanges()
    }
    
    // MARK: - Authorization
    
    func updateAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }
    
    func requestAccess() async throws -> Bool {
        let granted = try await store.requestAccess(for: .contacts)
        await MainActor.run {
            updateAuthorizationStatus()
            history.log(source: "MacContacts", action: "requestAccess", details: "granted=\(granted)")
        }
        return granted
    }
    
    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }
    
    // MARK: - Container Discovery
    
    func fetchAvailableContainers() throws -> [CNContainer] {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        let containers = try store.containers(matching: nil)

        // Keep only iCloud and local containers, exclude likely Google/Gmail
        let filtered = containers.filter { container in
            if isLikelyGoogleContainer(container) { return false }
            return container.type == .cardDAV || container.type == .local
        }
        
        history.log(source: "MacContacts", action: "fetchAvailableContainers", details: "total=\(containers.count), filtered=\(filtered.count)")

        availableContainers = filtered
        return filtered
    }
    
    func getRecommendedContainer() throws -> CNContainer? {
        let containers = try fetchAvailableContainers()

        // Prefer iCloud container (CardDAV with iCloud name)
        if let iCloud = containers.first(where: { $0.type == .cardDAV && $0.name.lowercased().contains("icloud") }) {
            history.log(source: "MacContacts", action: "recommendedContainer", details: "iCloud: \(iCloud.name)")
            return iCloud
        }

        // Fall back to local container
        if let local = containers.first(where: { $0.type == .local }) {
            history.log(source: "MacContacts", action: "recommendedContainer", details: "local: \(local.name)")
            return local
        }

        // As a last resort, return the first filtered container if any
        if let first = containers.first { history.log(source: "MacContacts", action: "recommendedContainer", details: "fallback: \(first.name)") }
        return containers.first
    }
    
    // MARK: - Fetching Contacts
    
    /// Serial queue for every Contacts write.
    ///
    /// Serial rather than concurrent on purpose: `CNSaveRequest` execution against
    /// one store is not something to parallelise, and keeping all writes on a
    /// single thread means a `CNMutableContact` is only ever touched from one
    /// place after it leaves the main actor.
    ///
    /// `.userInitiated` — high enough that contactsd does not deprioritise us,
    /// low enough that we are not a user-interactive thread blocking on its
    /// background one.
    private nonisolated static let writeQueue = DispatchQueue(
        label: "com.victorlam.ContactSyncMate.contacts-write",
        qos: .userInitiated
    )

    /// Run a Contacts mutation off the main actor.
    ///
    /// The store operations are synchronous XPC; performing them on the main
    /// actor is what produced both the Hang Risk warnings and — via contention
    /// on the same XPC connection that faulting uses — the 134092 save failures.
    nonisolated static func performWriteOffMain<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T where T: Sendable {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Off-main equivalent of `fetchAllContacts(in:)`.
    ///
    /// Every CNContactStore call is synchronous XPC to contactsd, which runs at
    /// background QoS. Driving them from the main actor (user-interactive QoS)
    /// makes the high-priority thread block on a low-priority one — the
    /// priority inversion Xcode reports as a Hang Risk at
    /// `NSXPCStoreConnectionManager _checkoutConnection`.
    ///
    /// This is not merely a responsiveness issue. Faulting a CNContact property
    /// travels over that same XPC connection, so contention there surfaces as
    /// "Unhandled error … occurred during faulting" — Cocoa 134092 — on save.
    /// SyncEngine drove the whole sync from the main actor, so the inversion was
    /// present for the entire run.
    ///
    /// Returns identifiers-and-values only: `CNContact` is not `Sendable`, so the
    /// objects themselves must not cross the isolation boundary casually. They
    /// are safe here because the detached task hands back a freshly built array
    /// that nothing else retains.
    nonisolated func fetchAllContactsOffMainActor(
        in container: CNContainer? = nil
    ) async throws -> [CNContact] {
        // `.utility`, not `.userInitiated`.
        //
        // contactsd serves these calls at background QoS, so a user-initiated
        // requester waiting on it is an inversion by definition — there is no
        // way to call this synchronous API from a higher band without one. This
        // is the mild form: the earlier warnings came from the *main* actor,
        // user-interactive, and that contention corrupted faulting mid-save
        // (Cocoa 134092). Asking at utility removes the inversion honestly
        // rather than silencing the warning, and a full address-book fetch is
        // exactly the sort of bulk work utility describes.
        try await Task.detached(priority: .utility) {
            try Self.fetchAllContactsOffMain(in: container)
        }.value
    }

    func fetchAllContacts(in container: CNContainer? = nil) throws -> [CNContact] {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }

        let keysToFetch = self.keysToFetch()
        var contacts: [CNContact] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)

        // If specific container, set predicate; otherwise do NOT use "All Accounts" implicitly.
        let recommendedContainerOpt: CNContainer? = try? getRecommendedContainer()
        if let specific = container {
            fetchRequest.predicate = CNContact.predicateForContactsInContainer(withIdentifier: specific.identifier)
        } else if let recommended = recommendedContainerOpt {
            fetchRequest.predicate = CNContact.predicateForContactsInContainer(withIdentifier: recommended.identifier)
        }
        
        // Reuse the lookup from above rather than repeating it. Each
        // getRecommendedContainer() is a synchronous XPC round trip to contactsd,
        // and this one existed only to produce a name for the log line — which
        // doubled the container queries on every fetch.
        let containerName = container?.name ?? recommendedContainerOpt?.name ?? "(none)"
        history.log(source: "MacContacts", action: "fetchAllContacts.begin", details: "container=\(containerName)")

        try store.enumerateContacts(with: fetchRequest) { contact, stop in
            contacts.append(contact)
        }

        // Best-effort: remove any contact matching the current Me card identifier if available
        if let meIdentifier = meContactIdentifier, !meIdentifier.isEmpty {
            contacts.removeAll { $0.identifier == meIdentifier }
        }
        
        history.log(source: "MacContacts", action: "fetchAllContacts.end", details: "count=\(contacts.count)")

        return contacts
    }
    
    func fetchContact(withIdentifier identifier: String) throws -> CNContact? {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        let keysToFetch = self.keysToFetch()
        
        do {
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            history.log(source: "MacContacts", action: "fetchContact", details: "id=\(identifier) found=true")
            return contact
        } catch let error as NSError {
            if error.domain == CNErrorDomain && error.code == CNError.recordDoesNotExist.rawValue {
                history.log(source: "MacContacts", action: "fetchContact", details: "id=\(identifier) found=false")
                return nil
            }
            throw error
        }
    }
    
    // MARK: - Saving Contacts
    
    /// `saveContact` callable from the write queue.
    ///
    /// Same body, minus the actor isolation, so `performWriteOffMain` can invoke
    /// it without hopping back to main — which would defeat the entire point.
    nonisolated func saveContactSync(_ contact: CNMutableContact,
                                     to container: CNContainer? = nil) throws {
        let history = SyncHistory.shared
        let containerID = container?.identifier ?? Self.shared.defaultContainerIdentifier()

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: containerID)

        history.log(source: "MacContacts", action: "saveContact",
                    details: container?.name ?? "default: \(containerID)")

        do {
            try Self.shared.execute(request)
        } catch {
            history.log(source: "MacContacts", action: "saveContact.failed",
                        details: "\(containerID): \(Self.diagnose(error))")
            throw error
        }
    }

    /// `deleteContact` callable from the write queue. See `saveContactSync`.
    nonisolated func deleteContactSync(withIdentifier identifier: String) throws {
        guard let existing = try fetchContactSync(withIdentifier: identifier) else { return }

        let request = CNSaveRequest()
        request.delete(existing.mutableCopy() as! CNMutableContact)

        do {
            try Self.shared.execute(request)
            SyncHistory.shared.log(source: "MacContacts", action: "deleteContact",
                                   details: "id=\(identifier)")
        } catch {
            SyncHistory.shared.log(source: "MacContacts", action: "deleteContact.failed",
                                   details: Self.diagnose(error))
            throw error
        }
    }

    /// `updateContact` callable from the write queue. See `saveContactSync`.
    /// `fetchContact` callable from the write queue.
    ///
    /// The sync applies changes by fetching the live record and mutating it, so
    /// the fetch sits on the same hot path as the write. Leaving it main-actor
    /// isolated kept the priority inversion alive for exactly the operation the
    /// off-main write queue was built to protect.
    /// The individual record, not the unified one.
    ///
    /// `unifiedContact(withIdentifier:)` returns Contacts' *linked* view — one
    /// merged object standing for the same person across several accounts. That
    /// view is fine to read and cannot be saved: `CNSaveRequest.update` on it
    /// fails with Cocoa 134092, because there is no single underlying record to
    /// write it back to.
    ///
    /// It failed precisely on the contacts this app calls merges — those are
    /// duplicates, which is exactly what a user links, so they are the ones with
    /// a unified view. Adds and updates of unlinked contacts went through fine,
    /// which is why the failures looked specific to merging.
    ///
    /// A fetch request with an identifier predicate returns the real records.
    nonisolated func fetchContactSync(withIdentifier identifier: String) throws -> CNContact? {
        let request = CNContactFetchRequest(keysToFetch: Self.nonisolatedKeysToFetch())
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])

        var found: CNContact?
        do {
            try Self.shared.enumerateContacts(with: request) { contact, stop in
                found = contact
                stop.pointee = true
            }
        } catch let error as NSError {
            if error.domain == CNErrorDomain && error.code == CNError.recordDoesNotExist.rawValue {
                return nil
            }
            throw error
        }
        return found
    }

    nonisolated func updateContactSync(_ contact: CNMutableContact) throws {
        let history = SyncHistory.shared
        let request = CNSaveRequest()
        request.update(contact)

        do {
            try Self.shared.execute(request)
        } catch {
            history.log(source: "MacContacts", action: "updateContact.failed",
                        details: Self.diagnose(error))
            throw error
        }
    }

    func saveContact(_ contact: CNMutableContact, to container: CNContainer? = nil) throws {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        let saveRequest = CNSaveRequest()
        
        if let container = container {
            saveRequest.add(contact, toContainerWithIdentifier: container.identifier)
        } else {
            saveRequest.add(contact, toContainerWithIdentifier: store.defaultContainerIdentifier())
        }
        
        let targetContainerName: String = {
            if let container = container { return container.name }
            return "default: \(store.defaultContainerIdentifier())"
        }()
        history.log(source: "MacContacts", action: "saveContact", details: targetContainerName)

        do {
            try store.execute(saveRequest)
        } catch {
            // The default container is not guaranteed to be writable. On this
            // machine it can be a Google/Exchange CardDAV account, which rejects
            // adds with Cocoa error 134092 ("could not complete the operation") —
            // an opaque message that gave no hint the *destination* was the
            // problem. Retry once against a container we know accepts writes.
            guard container == nil,
                  let fallback = try? firstWritableContainer(),
                  fallback.identifier != store.defaultContainerIdentifier()
            else {
                history.log(source: "MacContacts", action: "saveContact.failed",
                            details: "\(targetContainerName): \(Self.diagnose(error))")
                throw error
            }

            history.log(
                source: "MacContacts",
                action: "saveContact.retryingInFallbackContainer",
                details: "\(targetContainerName) rejected the write (\(error.localizedDescription)); retrying in \(fallback.name)"
            )

            let retry = CNSaveRequest()
            retry.add(contact, toContainerWithIdentifier: fallback.identifier)
            try store.execute(retry)
        }
    }

    /// Fetch contacts without touching the main actor.
    ///
    /// `CNContactStore` calls are synchronous XPC to contactsd at background QoS,
    /// so they must run off the main actor or they risk a priority inversion. The
    /// call sites therefore use `Task.detached` — but constructing a
    /// `MacContactsConnector` there is main-actor work, which Swift 6 rejects
    /// outright rather than warning about.
    ///
    /// This is `nonisolated` and goes straight to the shared store, so a detached
    /// task needs no actor hop and no connector instance.
    nonisolated static func fetchAllContactsOffMain(
        in container: CNContainer? = nil
    ) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: nonisolatedKeysToFetch())

        // Never fall through to "all accounts".
        //
        // This is the duplicate factory. macOS Contacts can hold the user's
        // Google account as a CardDAV account, which mirrors the very contacts
        // this app is syncing. Fetching with no predicate returns that mirror
        // too, so every Google contact appeared a second time as a "Mac
        // contact" — with a different local identifier, so no mapping matched —
        // and the sync dutifully pushed it back to Google as new.
        //
        // The main-actor twin `fetchAllContacts(in:)` has always resolved a
        // container before fetching and says why. This path, the one every sync
        // actually uses, did not.
        let scope = container ?? recommendedContainerOffMain()
        if let scope {
            request.predicate = CNContact.predicateForContactsInContainer(
                withIdentifier: scope.identifier
            )
        } else {
            // No writable container resolved. Fetching everything here is what
            // caused the duplicates, so refuse instead of guessing.
            SyncHistory.shared.log(
                source: "MacContacts", action: "fetch.noContainerResolved",
                details: "refusing an unscoped fetch — see Settings → Accounts → Mac Contacts")
            throw MacContactsError.noWritableContainer
        }

        var contacts: [CNContact] = []
        try shared.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    /// The container a sync should read and write, resolved off the main actor.
    ///
    /// Mirrors the main-actor `getRecommendedContainer()`: iCloud when present,
    /// otherwise the local one, and never a Google/Exchange CardDAV account —
    /// those mirror the remote side and syncing against them creates duplicates.
    nonisolated static func recommendedContainerOffMain() -> CNContainer? {
        guard let containers = try? shared.containers(matching: nil) else { return nil }

        let candidates = containers.filter { !isLikelyRemoteMirror($0) }
        return candidates.first { $0.type == .cardDAV && $0.name.localizedCaseInsensitiveContains("icloud") }
            ?? candidates.first { $0.type == .local }
            ?? candidates.first
    }

    /// Whether a container is a mirror of a remote account we also sync directly.
    nonisolated static func isLikelyRemoteMirror(_ container: CNContainer) -> Bool {
        if container.type == .exchange { return true }
        let name = container.name.lowercased()
        return ["google", "gmail", "exchange", "outlook"].contains { name.contains($0) }
    }

    /// Identifiers of every contact belonging to any of `groupIDs`.
    ///
    /// Group membership is not a property of `CNContact`; it is queried with
    /// `predicateForContactsInGroup`. Fetching identifiers only keeps this cheap —
    /// the caller already has the full contacts and just needs to know which of
    /// them are in scope.
    ///
    /// A group that no longer exists is skipped rather than failing the sync: a
    /// deleted group in the saved filter should not stop contacts syncing.
    nonisolated static func contactIdentifiers(inGroups groupIDs: [String]) -> Set<String> {
        var identifiers: Set<String> = []
        for groupID in groupIDs {
            let request = CNContactFetchRequest(
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
            do {
                try shared.enumerateContacts(with: request) { contact, _ in
                    identifiers.insert(contact.identifier)
                }
            } catch {
                SyncHistory.shared.log(
                    source: "MacContacts", action: "groupFilter.skippedGroup",
                    details: "\(groupID): \(error.localizedDescription)")
            }
        }
        return identifiers
    }

    /// Whether photo sync is on, readable from a nonisolated context.
    ///
    /// `AppSettings` is main-actor isolated under the project's default
    /// isolation, so `AppSettings.shared.syncPhotos` cannot be read here — and
    /// should not be: this runs on the Contacts fetch queue, and reaching onto
    /// the main actor from there is the priority inversion this whole file
    /// exists to avoid.
    ///
    /// Reading the backing store directly is the honest way to get one Bool off
    /// the main actor. The default matches `AppSettings.syncPhotos` — `true`
    /// when the key has never been written.
    private nonisolated static func photoSyncEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "syncPhotos") as? Bool ?? true
    }

    /// Key set for `fetchAllContactsOffMain`.
    ///
    /// Deliberately excludes `CNContactNoteKey`: reading it needs the
    /// com.apple.developer.contacts.notes entitlement, which this app does not
    /// hold, and requesting it makes the fetch itself fail.
    nonisolated static func nonisolatedKeysToFetch() -> [CNKeyDescriptor] {
        // Must stay a superset of everything ContactMapper.toUnified reads.
        // Reading an unfetched property raises CNContactPropertyNotFetchedException
        // — an ObjC exception, so it is not catchable as a Swift error and takes
        // the process down. This list had drifted from the main-actor
        // `keysToFetch()` and was missing the phonetic names and image data that
        // the mapper reads on every contact.
        [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
            CNContactPhoneticFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactUrlAddressesKey,
            CNContactBirthdayKey,
            CNContactDatesKey, CNContactSocialProfilesKey,
            CNContactInstantMessageAddressesKey,
            // Deliberately absent: CNContactNoteKey needs the
            // com.apple.developer.contacts.notes entitlement, and requesting it
            // without one makes the fetch itself fail.
        ].map { $0 as CNKeyDescriptor }
        // Full-resolution photo bytes, only when photo sync is on.
        //
        // `CNContactImageDataKey` was fetched unconditionally, so every sync
        // pulled every contact photo at full size over XPC, carried it through
        // the diff, and wrote it into both the pre- and post-sync backup — for a
        // field `applyFieldSettings` then discards when the setting is off.
        // Photos are the largest thing in a contact by a wide margin; a few
        // hundred of them is the difference between a backup of a few megabytes
        // and one of a few hundred.
        //
        // `ImageDataAvailable` stays either way: it is a flag, not the bytes,
        // and the mapper reads it.
        + (photoSyncEnabled()
           ? [CNContactImageDataKey as CNKeyDescriptor,
              CNContactImageDataAvailableKey as CNKeyDescriptor]
           : [CNContactImageDataAvailableKey as CNKeyDescriptor])
        // Callers that format a display name go through CNContactFormatter, which
        // has its own required-key descriptor. Omitting it raises
        // CNContactPropertyNotFetchedException — an ObjC exception, so it kills
        // the process rather than surfacing as a Swift error.
        + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }

    // A field-bisecting `probeSaveFailure` used to live here. It saved
    // progressively larger probe contacts to find which field Contacts was
    // rejecting — and its doc comment claimed each probe was deleted again.
    // It never deleted anything, so a save failure left up to nine junk contacts
    // in the user's real address book, which then synced to Google.
    //
    // Removed rather than fixed: the 134092 failures it was written to diagnose
    // turned out to be the main-actor priority inversion (see
    // `fetchAllContactsOffMainActor`), not a bad field. Diagnostics that write to
    // user data are not worth keeping around on the chance they are needed again.

    /// Expand a Contacts error into something diagnosable.
    ///
    /// `localizedDescription` for a rejected save is just "The operation couldn't
    /// be completed. (Cocoa error 134092.)" — it names neither the field nor the
    /// reason, which made a 100%-reproducible write failure impossible to pin
    /// down from logs alone. Contacts does report the offending key paths, but
    /// only in `userInfo` under `CNErrorUserInfoKeyPaths`.
    nonisolated static func diagnose(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code)"]

        // Enumerated generically rather than reading named Contacts constants:
        // the useful ones (offending key paths, validation errors, affected
        // records) are spelled differently across SDK versions, and guessing a
        // name wrong costs another whole reproduce-and-export cycle. Whatever
        // Contacts chose to attach, we log.
        for key in nsError.userInfo.keys.sorted() where key != NSLocalizedDescriptionKey {
            let value = nsError.userInfo[key]

            let rendered: String
            switch value {
            case let underlying as NSError:
                rendered = "\(underlying.domain) \(underlying.code)"
            case let list as [Any]:
                rendered = "[\(list.count)] " + list.prefix(4).map { "\($0)" }.joined(separator: ",")
            case let some?:
                rendered = "\(some)"
            default:
                rendered = "nil"
            }

            parts.append("\(key)=\(rendered.prefix(160))")
        }

        parts.append(nsError.localizedDescription)
        return parts.joined(separator: " · ")
    }

    /// A container that accepts new contacts.
    ///
    /// Prefers local, then iCloud. Google/Gmail CardDAV containers are excluded
    /// on purpose: writing Google contacts through Apple's CardDAV mirror would
    /// race this app's own Google People API writes and produce duplicates.
    private func firstWritableContainer() throws -> CNContainer? {
        let containers = try store.containers(matching: nil)
            .filter { !isLikelyGoogleContainer($0) }

        if let local = containers.first(where: { $0.type == .local }) {
            return local
        }
        return containers.first(where: {
            $0.type == .cardDAV && $0.name.lowercased().contains("icloud")
        }) ?? containers.first
    }
    
    func updateContact(_ contact: CNMutableContact) throws {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        let saveRequest = CNSaveRequest()
        saveRequest.update(contact)

        history.log(source: "MacContacts", action: "updateContact", details: SyncHistoryFormatters.contactSummary(id: nil, name: "\(contact.givenName) \(contact.familyName)"))

        do {
            try store.execute(saveRequest)
        } catch {
            history.log(source: "MacContacts", action: "updateContact.failed",
                        details: Self.diagnose(error))
            throw error
        }
    }
    
    func deleteContact(withIdentifier identifier: String) throws {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        guard let contact = try fetchContact(withIdentifier: identifier) else {
            throw MacContactsError.contactNotFound(identifier)
        }
        
        let mutableContact = contact.mutableCopy() as! CNMutableContact
        let saveRequest = CNSaveRequest()
        saveRequest.delete(mutableContact)
        
        history.log(source: "MacContacts", action: "deleteContact", details: "id=\(identifier)")
        
        try store.execute(saveRequest)
    }
    
    // MARK: - Change Monitoring
    
    private func startMonitoringChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contactStoreDidChange),
            name: .CNContactStoreDidChange,
            object: nil
        )
    }
    
    /// Coalescing window for store-change notifications.
    ///
    /// contactsd posts `CNContactStoreDidChange` per underlying write, so a sync
    /// that touches a few dozen contacts generates hundreds of notifications —
    /// an exported log showed 674 of them inside 12 seconds. Because history is
    /// capped, that storm evicted every genuinely useful entry: the whole 1000-
    /// event export covered only those 12 seconds and the actual failures were
    /// already gone. Debouncing keeps the signal.
    private static let storeChangeCoalescingWindow: TimeInterval = 2.0
    private var pendingStoreChangeCount = 0
    private var storeChangeFlushTask: Task<Void, Never>?

    @objc private func contactStoreDidChange(_ notification: Notification) {
        pendingStoreChangeCount += 1

        // Restart the window on each notification so a burst logs once, at the
        // end, with a count — rather than once per write.
        storeChangeFlushTask?.cancel()
        storeChangeFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.storeChangeCoalescingWindow))
            guard !Task.isCancelled, let self else { return }

            await MainActor.run {
                let count = self.pendingStoreChangeCount
                self.pendingStoreChangeCount = 0
                guard count > 0 else { return }
                self.history.log(
                    source: "MacContacts",
                    action: "cnContactStoreDidChange",
                    details: count == 1 ? nil : "\(count) changes coalesced"
                )
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func keysToFetch() -> [CNKeyDescriptor] {
        return [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneticGivenNameKey as CNKeyDescriptor,
            CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
            CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            // CNContactNoteKey requires com.apple.developer.contacts.notes entitlement (restricted by Apple)
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
    }
    
    // MARK: - Me Card Helper (best-effort)
    // Some macOS versions expose the me contact identifier; provide a safe accessor.
    var meContactIdentifier: String? {
        // Fallback for broad SDK compatibility: macOS Contacts doesn't expose a stable Me identifier in all versions.
        // Return nil to skip Me-card filtering when unavailable.
        return nil
    }

    // MARK: - Notes Field Availability
    //
    // Reading and writing the Contacts `note` field requires the special
    // `com.apple.developer.contacts.notes` entitlement, which must be
    // granted by Apple in the developer portal. Without it the API returns
    // an empty string and writes silently fail.
    //
    // This flag is checked at runtime by:
    //   • SyncEngine → skips the notes field in diff + apply when false.
    //   • SettingsView → Sync Fields → Notes toggle is disabled with an
    //     explanatory footer.
    //
    // To re-enable Notes sync: get the entitlement approved, re-add the
    // key to the .entitlements file, and change this to `true` (or make
    // it read the entitlement at runtime).
    /// `nonisolated`: a compile-time constant, consulted by the contact mappers
    /// which run on the Contacts write queue.
    nonisolated static let notesFieldAvailable: Bool = false
    
    // MARK: - Deduplication Support
    
    // fetchAllContactsForDeduplication had no callers.
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Errors

enum MacContactsError: LocalizedError {
    case notAuthorized
    case contactNotFound(String)
    /// `saveFailed` used to sit here and was never constructed — every save path
    /// rethrows the Contacts error, which carries far more than a wrapped
    /// description (see `diagnose`).
    case noWritableContainer

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Access to Contacts is not authorized. Please grant permission in System Settings."
        case .contactNotFound(let id):
            return "Contact with identifier \(id) not found."
        case .noWritableContainer:
            return String(localized: "No Mac Contacts account could be used for syncing. Open Settings → Accounts → Mac Contacts and choose one.")
        }
    }
}

