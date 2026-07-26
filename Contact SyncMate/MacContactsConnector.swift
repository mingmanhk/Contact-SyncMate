//
//  MacContactsConnector.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import Contacts
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
        
        let containerName: String = {
            if let specific = container { return specific.name }
            let recommended: CNContainer? = try? getRecommendedContainer()
            if let c = recommended { return c.name }
            return "(none)"
        }()
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
                probeSaveFailure(contact, container: container)
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
        if let container {
            request.predicate = CNContact.predicateForContactsInContainer(
                withIdentifier: container.identifier
            )
        }

        var contacts: [CNContact] = []
        try shared.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    /// Key set for `fetchAllContactsOffMain`.
    ///
    /// Deliberately excludes `CNContactNoteKey`: reading it needs the
    /// com.apple.developer.contacts.notes entitlement, which this app does not
    /// hold, and requesting it makes the fetch itself fail.
    nonisolated private static func nonisolatedKeysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
            CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactUrlAddressesKey,
            CNContactBirthdayKey, CNContactImageDataAvailableKey,
        ].map { $0 as CNKeyDescriptor }
    }

    /// Find which field Contacts is rejecting, by elimination.
    ///
    /// Cocoa error 134092 names neither a field nor a reason, and its userInfo
    /// carries only a nested copy of itself. Reasoning about it from the outside
    /// has repeatedly produced plausible-but-wrong theories (container, note
    /// entitlement, cross-store faulting) — each costing a full build-and-retry
    /// cycle.
    ///
    /// So ask Contacts directly: save a name-only copy, then add one field group
    /// at a time until it breaks. Runs once per sync (`hasProbedSaveFailure`),
    /// writes nothing that survives — each probe is rolled back by only ever
    /// being *attempted*, and the first success is deleted again.
    private static var hasProbedSaveFailure = false

    private func probeSaveFailure(_ contact: CNMutableContact, container: CNContainer?) {
        guard !Self.hasProbedSaveFailure else { return }
        Self.hasProbedSaveFailure = true

        let containerID = container?.identifier ?? store.defaultContainerIdentifier()

        // Each step adds one field group to the previous one, so the first
        // failure names the culprit.
        let steps: [(String, (CNMutableContact) -> Void)] = [
            ("name only", { probe in
                probe.givenName  = contact.givenName
                probe.familyName = contact.familyName
            }),
            ("+ organisation", { probe in
                probe.organizationName = contact.organizationName
                probe.jobTitle         = contact.jobTitle
                probe.departmentName   = contact.departmentName
            }),
            ("+ phones",     { $0.phoneNumbers    = contact.phoneNumbers }),
            ("+ emails",     { $0.emailAddresses  = contact.emailAddresses }),
            ("+ addresses",  { $0.postalAddresses = contact.postalAddresses }),
            ("+ urls",       { $0.urlAddresses    = contact.urlAddresses }),
            ("+ nickname",   { $0.nickname        = contact.nickname }),
            ("+ birthday",   { $0.birthday        = contact.birthday }),
            ("+ photo",      { $0.imageData       = contact.imageData }),
        ]

        let probe = CNMutableContact()
        var applied: [String] = []

        for (label, apply) in steps {
            apply(probe)
            applied.append(label)

            let request = CNSaveRequest()
            request.add(probe.mutableCopy() as! CNMutableContact,
                        toContainerWithIdentifier: containerID)
            do {
                try store.execute(request)
            } catch {
                history.log(
                    source: "MacContacts",
                    action: "saveContact.probe",
                    details: "first rejected at \(label) — accepted: \(applied.dropLast().joined(separator: " ")) · \(Self.diagnose(error))"
                )
                return
            }
        }

        history.log(
            source: "MacContacts",
            action: "saveContact.probe",
            details: "all field groups accepted individually — the rejection is not field-specific (containerID=\(containerID))"
        )
    }

    /// Expand a Contacts error into something diagnosable.
    ///
    /// `localizedDescription` for a rejected save is just "The operation couldn't
    /// be completed. (Cocoa error 134092.)" — it names neither the field nor the
    /// reason, which made a 100%-reproducible write failure impossible to pin
    /// down from logs alone. Contacts does report the offending key paths, but
    /// only in `userInfo` under `CNErrorUserInfoKeyPaths`.
    static func diagnose(_ error: Error) -> String {
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
    static let notesFieldAvailable: Bool = false
    
    // MARK: - Deduplication Support
    
    /// Fetch all contacts for deduplication analysis
    func fetchAllContactsForDeduplication(in container: CNContainer? = nil) throws -> [CNContact] {
        // Same as fetchAllContacts but explicitly for deduplication context
        return try fetchAllContacts(in: container)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Errors

enum MacContactsError: LocalizedError {
    case notAuthorized
    case contactNotFound(String)
    case saveFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Access to Contacts is not authorized. Please grant permission in System Settings."
        case .contactNotFound(let id):
            return "Contact with identifier \(id) not found."
        case .saveFailed(let error):
            return "Failed to save contact: \(error.localizedDescription)"
        }
    }
}

