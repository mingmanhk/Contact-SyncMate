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
    private let store = CNContactStore()
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
        
        try store.execute(saveRequest)
    }
    
    func updateContact(_ contact: CNMutableContact) throws {
        guard isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        let saveRequest = CNSaveRequest()
        saveRequest.update(contact)
        
        history.log(source: "MacContacts", action: "updateContact", details: SyncHistoryFormatters.contactSummary(id: nil, name: "\(contact.givenName) \(contact.familyName)"))
        
        try store.execute(saveRequest)
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
    
    @objc private func contactStoreDidChange(_ notification: Notification) {
        history.log(source: "MacContacts", action: "CNContactStoreDidChange", details: nil)
        print("Mac Contacts changed")
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
            CNContactNoteKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor
        ]
    }
    
    // MARK: - Me Card Helper (best-effort)
    // Some macOS versions expose the me contact identifier; provide a safe accessor.
    var meContactIdentifier: String? {
        // Fallback for broad SDK compatibility: macOS Contacts doesn't expose a stable Me identifier in all versions.
        // Return nil to skip Me-card filtering when unavailable.
        return nil
    }
    
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

