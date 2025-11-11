//
//  SyncEngine.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import Contacts
import Combine

/// Core sync engine that orchestrates the sync process
class SyncEngine: ObservableObject {
    private let googleConnector: GoogleContactsConnector
    private let macConnector: MacContactsConnector
    private let mappingStore: ContactMappingStore
    private let settings = AppSettings.shared
    
    @Published var isRunning = false
    @Published var progress: SyncProgress?
    @Published var lastError: Error?
    
    init(googleConnector: GoogleContactsConnector,
         macConnector: MacContactsConnector,
         mappingStore: ContactMappingStore) {
        self.googleConnector = googleConnector
        self.macConnector = macConnector
        self.mappingStore = mappingStore
    }
    
    // MARK: - Public Sync Methods
    
    /// Run a manual sync with preview
    func prepareManualSync(direction: SyncDirection) async throws -> SyncSession {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }
        
        await MainActor.run {
            isRunning = true
            progress = SyncProgress(currentStep: "Fetching contacts...", completedItems: 0, totalItems: 0)
        }
        
        defer {
            Task { @MainActor in
                isRunning = false
                progress = nil
            }
        }
        
        do {
            // Fetch contacts from both sides
            let googleContacts = try await googleConnector.fetchAllContacts()
            let macContacts = try macConnector.fetchAllContacts()
            
            // Convert to unified format
            let unifiedGoogleContacts = googleContacts.map { ContactMapper.toUnified(from: $0) }
            let unifiedMacContacts = macContacts.map { ContactMapper.toUnified(from: $0) }
            
            // Compute differences
            let changes = computeChanges(
                googleContacts: unifiedGoogleContacts,
                macContacts: unifiedMacContacts,
                direction: direction
            )
            
            // Create session
            let session = SyncSession(
                mode: .manual,
                direction: direction,
                startTime: Date(),
                contactChanges: changes
            )
            
            return session
            
        } catch {
            await MainActor.run {
                lastError = error
            }
            throw error
        }
    }
    
    /// Execute a prepared sync session
    func executeSync(session: SyncSession) async throws -> SyncResult {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }
        
        await MainActor.run {
            isRunning = true
            progress = SyncProgress(
                currentStep: "Syncing...",
                completedItems: 0,
                totalItems: session.contactChanges.count
            )
        }
        
        defer {
            Task { @MainActor in
                isRunning = false
                progress = nil
            }
        }
        
        let startTime = Date()
        var added = 0
        var updated = 0
        var deleted = 0
        var merged = 0
        var skipped = 0
        var errors: [SyncError] = []
        
        // Execute each change
        for (index, change) in session.contactChanges.enumerated() {
            // Update progress
            await MainActor.run {
                progress = SyncProgress(
                    currentStep: "Processing \(change.contactName)...",
                    completedItems: index,
                    totalItems: session.contactChanges.count
                )
            }
            
            // Use override if set, otherwise use planned action
            let action = change.userOverride ?? change.action
            
            do {
                switch action {
                case .add:
                    try await performAdd(change: change, direction: session.direction)
                    added += 1
                    
                case .update:
                    try await performUpdate(change: change, direction: session.direction)
                    updated += 1
                    
                case .delete:
                    try await performDelete(change: change, direction: session.direction)
                    deleted += 1
                    
                case .merge:
                    try await performMerge(change: change, direction: session.direction)
                    merged += 1
                    
                case .skip:
                    skipped += 1
                }
            } catch {
                errors.append(SyncError(
                    contactName: change.contactName,
                    message: error.localizedDescription,
                    timestamp: Date()
                ))
            }
        }
        
        let endTime = Date()
        
        // Create result
        let result = SyncResult(
            mode: session.mode,
            direction: session.direction,
            startTime: startTime,
            endTime: endTime,
            added: added,
            updated: updated,
            deleted: deleted,
            merged: merged,
            skipped: skipped,
            errors: errors
        )
        
        // Save to history
        try? await saveToHistory(result: result)
        
        return result
    }
    
    /// Run automatic sync (called by background agent)
    func runAutoSync() async throws -> SyncResult {
        guard settings.autoSyncEnabled else {
            throw SyncEngineError.autoSyncDisabled
        }
        
        // Check conditions
        if !checkAutoSyncConditions() {
            throw SyncEngineError.conditionsNotMet
        }
        
        // Use incremental sync with sync tokens
        let direction = settings.autoSyncDirection
        let session = try await prepareManualSync(direction: direction)
        
        // Auto-execute without user preview
        return try await executeSync(session: session)
    }
    
    // MARK: - Private Helpers
    
    private func computeChanges(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        direction: SyncDirection
    ) -> [ContactChange] {
        var changes: [ContactChange] = []
        
        // Get existing mappings
        let mappings = mappingStore.getAllMappings()
        
        // Create lookup dictionaries
        var googleByResourceName: [String: UnifiedContact] = [:]
        for contact in googleContacts {
            if let resourceName = contact.googleResourceName {
                googleByResourceName[resourceName] = contact
            }
        }
        
        var macByIdentifier: [String: UnifiedContact] = [:]
        for contact in macContacts {
            if let identifier = contact.macContactIdentifier {
                macByIdentifier[identifier] = contact
            }
        }
        
        switch direction {
        case .twoWay:
            changes = compute2WayChanges(
                googleByResourceName: googleByResourceName,
                macByIdentifier: macByIdentifier,
                mappings: mappings
            )
            
        case .googleToMac:
            changes = compute1WayChanges(
                source: googleByResourceName,
                target: macByIdentifier,
                mappings: mappings,
                sourceToTarget: true
            )
            
        case .macToGoogle:
            changes = compute1WayChanges(
                source: macByIdentifier,
                target: googleByResourceName,
                mappings: mappings,
                sourceToTarget: false
            )
        }
        
        return changes
    }
    
    private func compute2WayChanges(
        googleByResourceName: [String: UnifiedContact],
        macByIdentifier: [String: UnifiedContact],
        mappings: [ContactMapping]
    ) -> [ContactChange] {
        let changes: [ContactChange] = []
        
        // TODO: Implement sophisticated 2-way sync logic
        // 1. For each mapping, compare Google and Mac versions
        // 2. Detect conflicts (both changed since last sync)
        // 3. Apply merge rules
        // 4. Detect new contacts on both sides
        // 5. Handle deletions
        
        return changes
    }
    
    private func compute1WayChanges(
        source: [String: UnifiedContact],
        target: [String: UnifiedContact],
        mappings: [ContactMapping],
        sourceToTarget: Bool
    ) -> [ContactChange] {
        let changes: [ContactChange] = []
        
        // TODO: Implement 1-way sync logic
        // 1. For each source contact, check if exists in target
        // 2. If not, schedule add
        // 3. If exists, compare and schedule update if different
        // 4. Check for deletions on source side
        
        return changes
    }
    
    private func performAdd(change: ContactChange, direction: SyncDirection) async throws {
        // TODO: Implement add operation
        throw SyncEngineError.notImplemented
    }
    
    private func performUpdate(change: ContactChange, direction: SyncDirection) async throws {
        // TODO: Implement update operation
        throw SyncEngineError.notImplemented
    }
    
    private func performDelete(change: ContactChange, direction: SyncDirection) async throws {
        // TODO: Implement delete operation
        throw SyncEngineError.notImplemented
    }
    
    private func performMerge(change: ContactChange, direction: SyncDirection) async throws {
        // TODO: Implement merge operation
        throw SyncEngineError.notImplemented
    }
    
    private func checkAutoSyncConditions() -> Bool {
        // TODO: Check power, network, idle conditions
        return true
    }
    
    private func saveToHistory(result: SyncResult) async throws {
        // TODO: Save to Core Data or local storage
    }
}

// MARK: - Contact Mapper

/// Converts between Google, Mac, and Unified contact formats
enum ContactMapper {
    static func toUnified(from googleContact: GoogleContact) -> UnifiedContact {
        // TODO: Implement full mapping
        var unified = UnifiedContact(id: UUID())
        unified.googleResourceName = googleContact.resourceName
        unified.givenName = googleContact.givenName
        unified.middleName = googleContact.middleName
        unified.familyName = googleContact.familyName
        unified.organizationName = googleContact.organizationName
        // ... map all fields
        return unified
    }
    
    static func toUnified(from macContact: CNContact) -> UnifiedContact {
        var unified = UnifiedContact(id: UUID())
        unified.macContactIdentifier = macContact.identifier
        unified.givenName = macContact.givenName
        unified.middleName = macContact.middleName
        unified.familyName = macContact.familyName
        unified.namePrefix = macContact.namePrefix
        unified.nameSuffix = macContact.nameSuffix
        unified.nickname = macContact.nickname
        unified.phoneticGivenName = macContact.phoneticGivenName
        unified.phoneticMiddleName = macContact.phoneticMiddleName
        unified.phoneticFamilyName = macContact.phoneticFamilyName
        unified.organizationName = macContact.organizationName
        unified.department = macContact.departmentName
        unified.jobTitle = macContact.jobTitle
        
        // Phone numbers
        unified.phoneNumbers = macContact.phoneNumbers.map { phoneNumber in
            UnifiedContact.PhoneNumber(
                value: phoneNumber.value.stringValue,
                label: CNLabeledValue<NSString>.localizedString(forLabel: phoneNumber.label ?? "")
            )
        }
        
        // Email addresses
        unified.emailAddresses = macContact.emailAddresses.map { email in
            UnifiedContact.EmailAddress(
                value: email.value as String,
                label: CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "")
            )
        }
        
        // Postal addresses
        unified.postalAddresses = macContact.postalAddresses.map { addressValue in
            let address = addressValue.value
            return UnifiedContact.PostalAddress(
                street: address.street,
                city: address.city,
                state: address.state,
                postalCode: address.postalCode,
                country: address.country,
                countryCode: address.isoCountryCode,
                label: CNLabeledValue<NSString>.localizedString(forLabel: addressValue.label ?? "")
            )
        }
        
        // URLs
        unified.urls = macContact.urlAddresses.map { urlValue in
            UnifiedContact.Url(
                value: urlValue.value as String,
                label: CNLabeledValue<NSString>.localizedString(forLabel: urlValue.label ?? "")
            )
        }
        
        // Birthday
        unified.birthday = macContact.birthday
        
        // Note
        unified.note = macContact.note
        
        // Photo
        unified.photoData = macContact.imageData
        
        return unified
    }
    
    static func toGoogle(from unified: UnifiedContact) -> GoogleContact {
        // TODO: Implement full mapping
        var google = GoogleContact(id: unified.googleResourceName ?? "")
        google.givenName = unified.givenName
        google.middleName = unified.middleName
        google.familyName = unified.familyName
        // ... map all fields
        return google
    }
    
    static func toMac(from unified: UnifiedContact) -> CNMutableContact {
        let mac = CNMutableContact()
        
        mac.givenName = unified.givenName ?? ""
        mac.middleName = unified.middleName ?? ""
        mac.familyName = unified.familyName ?? ""
        mac.namePrefix = unified.namePrefix ?? ""
        mac.nameSuffix = unified.nameSuffix ?? ""
        mac.nickname = unified.nickname ?? ""
        mac.phoneticGivenName = unified.phoneticGivenName ?? ""
        mac.phoneticMiddleName = unified.phoneticMiddleName ?? ""
        mac.phoneticFamilyName = unified.phoneticFamilyName ?? ""
        mac.organizationName = unified.organizationName ?? ""
        mac.departmentName = unified.department ?? ""
        mac.jobTitle = unified.jobTitle ?? ""
        
        // TODO: Map multi-value fields (phone numbers, emails, etc.)
        
        if let note = unified.note {
            mac.note = note
        }
        
        if let photoData = unified.photoData {
            mac.imageData = photoData
        }
        
        return mac
    }
}

// MARK: - Contact Mapping Store

/// Stores mappings between Google and Mac contact IDs
class ContactMappingStore {
    // TODO: Implement with Core Data or SQLite
    
    func getAllMappings() -> [ContactMapping] {
        return []
    }
    
    func getMapping(googleResourceName: String) -> ContactMapping? {
        return nil
    }
    
    func getMapping(macIdentifier: String) -> ContactMapping? {
        return nil
    }
    
    func saveMapping(_ mapping: ContactMapping) {
        // TODO: Implement
    }
    
    func deleteMapping(googleResourceName: String) {
        // TODO: Implement
    }
}

struct ContactMapping {
    var googleResourceName: String
    var macContactIdentifier: String
    var lastSyncedAt: Date
    var googleEtag: String?
}

// MARK: - Errors

enum SyncEngineError: LocalizedError {
    case syncAlreadyInProgress
    case autoSyncDisabled
    case conditionsNotMet
    case notImplemented
    
    var errorDescription: String? {
        switch self {
        case .syncAlreadyInProgress:
            return "A sync operation is already in progress."
        case .autoSyncDisabled:
            return "Automatic sync is disabled in settings."
        case .conditionsNotMet:
            return "Auto-sync conditions not met (check power/network/idle settings)."
        case .notImplemented:
            return "This feature is not yet implemented."
        }
    }
}
