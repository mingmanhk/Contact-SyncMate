//
//  SyncEngine.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import Contacts
import Combine

// MARK: - String helpers

private extension String {
    /// Returns nil if the string is empty or whitespace-only
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Map a generic label string to a CNLabel constant where possible
private func cnLabelFromString(_ label: String?) -> String? {
    guard let label = label?.lowercased() else { return nil }
    switch label {
    case "home":   return CNLabelHome
    case "work":   return CNLabelWork
    case "other":  return CNLabelOther
    case "mobile", "cell": return CNLabelPhoneNumberMobile
    case "main":   return CNLabelPhoneNumberMain
    case "iphone": return CNLabelPhoneNumberiPhone
    default:       return label.isEmpty ? nil : label
    }
}

/// Core sync engine that orchestrates the sync process
class SyncEngine: ObservableObject {
    let googleConnector: GoogleContactsConnector
    let macConnector: MacContactsConnector
    let mappingStore: ContactMappingStore
    let settings = AppSettings.shared
    
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
    
    func computeChanges(
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
    
    // MARK: - 2-Way Diff

    private func compute2WayChanges(
        googleByResourceName: [String: UnifiedContact],
        macByIdentifier: [String: UnifiedContact],
        mappings: [ContactMapping]
    ) -> [ContactChange] {
        var changes: [ContactChange] = []

        // Build lookup maps from mappings
        let mappingByGoogle = Dictionary(uniqueKeysWithValues: mappings.map { ($0.googleResourceName, $0) })
        let mappingByMac    = Dictionary(uniqueKeysWithValues: mappings.map { ($0.macContactIdentifier, $0) })

        var processedGoogle = Set<String>()
        var processedMac    = Set<String>()

        // --- Step 1: Walk all existing mappings ---
        for mapping in mappings {
            let gID  = mapping.googleResourceName
            let mID  = mapping.macContactIdentifier
            let gContact = googleByResourceName[gID]
            let mContact = macByIdentifier[mID]

            processedGoogle.insert(gID)
            processedMac.insert(mID)

            switch (gContact, mContact) {
            case (nil, nil):
                // Both deleted — clean up mapping (handled after loop)
                continue

            case (.some(let g), nil):
                if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: g.displayName, action: .delete,
                        direction: .macToGoogle, changes: ["Deleted on Mac side"],
                        sourceContact: g, targetContact: nil))
                }

            case (nil, .some(let m)):
                if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: m.displayName, action: .delete,
                        direction: .googleToMac, changes: ["Deleted on Google side"],
                        sourceContact: m, targetContact: nil))
                }

            case (.some(let g), .some(let m)):
                let fieldDiffs = diffFields(g, m)
                if fieldDiffs.isEmpty { continue }

                let gModified = g.lastModified ?? .distantPast
                let mModified = m.lastModified ?? .distantPast
                let syncedAt  = mapping.lastSyncedAt
                let gChanged  = gModified > syncedAt
                let mChanged  = mModified > syncedAt

                if gChanged && mChanged {
                    changes.append(ContactChange(
                        contactName: g.displayName, action: .merge,
                        direction: .twoWay,
                        changes: fieldDiffs + ["⚠️ Conflict: both sides changed since last sync"],
                        sourceContact: g, targetContact: m))
                } else if gChanged {
                    changes.append(ContactChange(
                        contactName: g.displayName, action: .update,
                        direction: .googleToMac, changes: fieldDiffs,
                        sourceContact: g, targetContact: m))
                } else if mChanged {
                    changes.append(ContactChange(
                        contactName: m.displayName, action: .update,
                        direction: .macToGoogle, changes: fieldDiffs,
                        sourceContact: m, targetContact: g))
                }
            }
        }

        // --- Step 2: New on Google, not yet mapped ---
        for (gID, gContact) in googleByResourceName where !processedGoogle.contains(gID) {
            let fuzzyMatch = findFuzzyMatch(for: gContact,
                                            in: macByIdentifier.filter { !processedMac.contains($0.key) })
            if let (mID, mContact) = fuzzyMatch {
                changes.append(ContactChange(
                    contactName: gContact.displayName, action: .merge,
                    direction: .twoWay,
                    changes: ["Potential match: \(mContact.displayName) (fuzzy — review before merging)"],
                    sourceContact: gContact, targetContact: mContact))
                processedMac.insert(mID)
            } else {
                changes.append(ContactChange(
                    contactName: gContact.displayName, action: .add,
                    direction: .googleToMac, changes: ["New contact from Google"],
                    sourceContact: gContact, targetContact: nil))
            }
        }

        // --- Step 3: New on Mac, not yet mapped ---
        for (_, mContact) in macByIdentifier where !processedMac.contains(mContact.macContactIdentifier ?? "") {
            changes.append(ContactChange(
                contactName: mContact.displayName, action: .add,
                direction: .macToGoogle, changes: ["New contact from Mac"],
                sourceContact: mContact, targetContact: nil))
        }

        return changes
    }

    // MARK: - 1-Way Diff

    private func compute1WayChanges(
        source: [String: UnifiedContact],
        target: [String: UnifiedContact],
        mappings: [ContactMapping],
        sourceToTarget: Bool
    ) -> [ContactChange] {
        var changes: [ContactChange] = []

        // Build source→target ID lookup from mappings
        let sourceToTargetMap: [String: String]
        let direction: SyncDirection
        if sourceToTarget {
            sourceToTargetMap = Dictionary(uniqueKeysWithValues: mappings.map {
                ($0.googleResourceName, $0.macContactIdentifier)
            })
            direction = .googleToMac
        } else {
            sourceToTargetMap = Dictionary(uniqueKeysWithValues: mappings.map {
                ($0.macContactIdentifier, $0.googleResourceName)
            })
            direction = .macToGoogle
        }

        var mappedTargetIDs = Set<String>()

        // Walk source contacts
        for (sourceID, sourceContact) in source {
            if let targetID = sourceToTargetMap[sourceID] {
                mappedTargetIDs.insert(targetID)
                if let targetContact = target[targetID] {
                    let diffs = diffFields(sourceContact, targetContact)
                    if !diffs.isEmpty {
                        changes.append(ContactChange(
                            contactName: sourceContact.displayName,
                            action: .update, direction: direction, changes: diffs,
                            sourceContact: sourceContact, targetContact: targetContact))
                    }
                } else if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: sourceContact.displayName,
                        action: .delete, direction: direction,
                        changes: ["Deleted on target side"],
                        sourceContact: sourceContact, targetContact: nil))
                }
            } else {
                changes.append(ContactChange(
                    contactName: sourceContact.displayName,
                    action: .add, direction: direction, changes: ["New contact"],
                    sourceContact: sourceContact, targetContact: nil))
            }
        }

        return changes
    }

    // MARK: - Field Diff

    /// Returns human-readable list of changed fields between two contacts
    private func diffFields(_ a: UnifiedContact, _ b: UnifiedContact) -> [String] {
        var diffs: [String] = []

        func check<T: Equatable>(_ label: String, _ lhs: T?, _ rhs: T?) {
            if lhs != rhs { diffs.append("\(label) changed") }
        }

        check("First name",   a.givenName,       b.givenName)
        check("Last name",    a.familyName,       b.familyName)
        check("Middle name",  a.middleName,       b.middleName)
        check("Company",      a.organizationName, b.organizationName)
        check("Job title",    a.jobTitle,         b.jobTitle)
        check("Note",         a.note,             b.note)

        let aPhones = Set(a.phoneNumbers.map(\.value))
        let bPhones = Set(b.phoneNumbers.map(\.value))
        if aPhones != bPhones { diffs.append("Phone numbers changed") }

        let aEmails = Set(a.emailAddresses.map { $0.value.lowercased() })
        let bEmails = Set(b.emailAddresses.map { $0.value.lowercased() })
        if aEmails != bEmails { diffs.append("Email addresses changed") }

        if settings.syncPhotos {
            if (a.photoData == nil) != (b.photoData == nil) { diffs.append("Photo changed") }
        }

        return diffs
    }

    // MARK: - Fuzzy Match

    /// Find a probable match for a contact in an unmapped pool using name + email
    private func findFuzzyMatch(
        for contact: UnifiedContact,
        in pool: [String: UnifiedContact]
    ) -> (String, UnifiedContact)? {
        let normalizedName = ContactNormalizer.normalizeFullName(
            given: contact.givenName, middle: nil, family: contact.familyName)
        let contactEmails = Set(contact.emailAddresses.map { $0.value.lowercased() })

        for (id, candidate) in pool {
            // Email exact match — high confidence
            let candidateEmails = Set(candidate.emailAddresses.map { $0.value.lowercased() })
            if !contactEmails.isEmpty && !contactEmails.isDisjoint(with: candidateEmails) {
                return (id, candidate)
            }
            // Name match — medium confidence (require both given + family)
            let candidateName = ContactNormalizer.normalizeFullName(
                given: candidate.givenName, middle: nil, family: candidate.familyName)
            if !normalizedName.isEmpty && normalizedName == candidateName {
                return (id, candidate)
            }
        }
        return nil
    }

    // MARK: - Apply Changes

    private func performAdd(change: ContactChange, direction: SyncDirection) async throws {
        guard let source = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }

        switch direction {
        case .googleToMac:
            // Add Google contact to Mac
            let cnContact = ContactMapper.toMac(from: source)
            try macConnector.saveContact(cnContact, to: nil)
            // Store mapping using the new Mac identifier
            if let gID = source.googleResourceName {
                let mID = cnContact.identifier
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .macToGoogle:
            // Add Mac contact to Google
            let googleContact = ContactMapper.toGoogle(from: source)
            let created = try await googleConnector.createContact(googleContact)
            // Store mapping
            if let mID = source.macContactIdentifier {
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: created.resourceName,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .twoWay:
            // twoWay adds go toward the side that doesn't have the contact
            if source.googleResourceName != nil {
                try await performAdd(change: change, direction: .googleToMac)
            } else {
                try await performAdd(change: change, direction: .macToGoogle)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "add",
            details: "\(change.contactName) → \(direction == .googleToMac ? "Mac" : "Google")")
    }

    private func performUpdate(change: ContactChange, direction: SyncDirection) async throws {
        guard let source = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }

        switch direction {
        case .googleToMac:
            // Update Mac contact with Google data
            guard let mID = change.targetContact?.macContactIdentifier else { return }
            guard let existing = try macConnector.fetchContact(withIdentifier: mID) else { return }
            let mutableContact = existing.mutableCopy() as! CNMutableContact
            ContactMapper.applyToMac(from: source, to: mutableContact)
            try macConnector.updateContact(mutableContact)
            mappingStore.saveMapping(ContactMapping(
                googleResourceName: source.googleResourceName ?? "",
                macContactIdentifier: mID,
                lastSyncedAt: Date()))

        case .macToGoogle:
            // Update Google contact with Mac data
            guard let gID = change.targetContact?.googleResourceName else { return }
            var googleContact = ContactMapper.toGoogle(from: source)
            googleContact = GoogleContact(id: gID) // preserve resource name
            ContactMapper.applyToGoogle(from: source, to: &googleContact)
            _ = try await googleConnector.updateContact(googleContact)
            if let mID = source.macContactIdentifier {
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .twoWay:
            // 2-way updates: source drives the direction
            if source.googleResourceName != nil {
                try await performUpdate(change: change, direction: .googleToMac)
            } else {
                try await performUpdate(change: change, direction: .macToGoogle)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "update",
            details: "\(change.contactName): \(change.changes.joined(separator: ", "))")
    }

    private func performDelete(change: ContactChange, direction: SyncDirection) async throws {
        guard let source = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }

        switch direction {
        case .googleToMac:
            // Delete from Mac (Google side was deleted)
            if let mID = source.macContactIdentifier {
                try macConnector.deleteContact(withIdentifier: mID)
                if let gID = source.googleResourceName {
                    mappingStore.deleteMapping(googleResourceName: gID)
                }
            }

        case .macToGoogle:
            // Delete from Google (Mac side was deleted)
            if let gID = source.googleResourceName {
                try await googleConnector.deleteContact(resourceName: gID)
                mappingStore.deleteMapping(googleResourceName: gID)
            }

        case .twoWay:
            if source.googleResourceName != nil {
                try await performDelete(change: change, direction: .macToGoogle)
            } else {
                try await performDelete(change: change, direction: .googleToMac)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "delete",
            details: change.contactName)
    }

    private func performMerge(change: ContactChange, direction: SyncDirection) async throws {
        // Merge is a user-guided operation — by the time executeSync runs,
        // the user should have resolved conflicts (userOverride set to .add/.update/.skip).
        // If it reaches here unresolved, treat as skip and flag for review.
        SyncHistory.shared.log(source: "SyncEngine", action: "merge.deferred",
            details: "\(change.contactName) — needs user review")
    }

    private func checkAutoSyncConditions() -> Bool {
        // Network check
        // (Full Reachability implementation can be added; for now always allow)
        return true
    }

    private func saveToHistory(result: SyncResult) async throws {
        SyncHistory.shared.log(
            source: "SyncEngine",
            action: "sync.complete",
            details: result.summary
        )
    }
}

// MARK: - Contact Mapper

/// Converts between Google, Mac, and Unified contact formats
enum ContactMapper {
    static func toUnified(from googleContact: GoogleContact) -> UnifiedContact {
        var unified = UnifiedContact(id: UUID())
        unified.googleResourceName  = googleContact.resourceName
        unified.givenName           = googleContact.givenName?.nilIfEmpty
        unified.middleName          = googleContact.middleName?.nilIfEmpty
        unified.familyName          = googleContact.familyName?.nilIfEmpty
        unified.namePrefix          = googleContact.namePrefix?.nilIfEmpty
        unified.nameSuffix          = googleContact.nameSuffix?.nilIfEmpty
        unified.nickname            = googleContact.nickname?.nilIfEmpty
        unified.phoneticGivenName   = googleContact.phoneticGivenName?.nilIfEmpty
        unified.phoneticMiddleName  = googleContact.phoneticMiddleName?.nilIfEmpty
        unified.phoneticFamilyName  = googleContact.phoneticFamilyName?.nilIfEmpty
        unified.organizationName    = googleContact.organizationName?.nilIfEmpty
        unified.department          = googleContact.department?.nilIfEmpty
        unified.jobTitle            = googleContact.jobTitle?.nilIfEmpty
        unified.note                = googleContact.note?.nilIfEmpty
        unified.photoData           = googleContact.photoData
        unified.lastModified        = googleContact.updateTime

        // Phone numbers
        unified.phoneNumbers = googleContact.phoneNumbers.map {
            UnifiedContact.PhoneNumber(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Email addresses
        unified.emailAddresses = googleContact.emailAddresses.map {
            UnifiedContact.EmailAddress(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Postal addresses
        unified.postalAddresses = googleContact.addresses.map { addr in
            UnifiedContact.PostalAddress(
                street: addr.streetAddress ?? "",
                city: addr.city ?? "",
                state: addr.region ?? "",
                postalCode: addr.postalCode ?? "",
                country: addr.country ?? "",
                countryCode: addr.countryCode ?? "",
                label: addr.label ?? addr.type ?? ""
            )
        }

        // URLs
        unified.urls = googleContact.urls.map {
            UnifiedContact.Url(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Birthday
        if let bd = googleContact.birthday {
            var comps = DateComponents()
            comps.year  = bd.year
            comps.month = bd.month
            comps.day   = bd.day
            unified.birthday = comps
        }

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
        var google = GoogleContact(id: unified.googleResourceName ?? "")
        google.givenName          = unified.givenName
        google.middleName         = unified.middleName
        google.familyName         = unified.familyName
        google.namePrefix         = unified.namePrefix
        google.nameSuffix         = unified.nameSuffix
        google.nickname           = unified.nickname
        google.phoneticGivenName  = unified.phoneticGivenName
        google.phoneticMiddleName = unified.phoneticMiddleName
        google.phoneticFamilyName = unified.phoneticFamilyName
        google.organizationName   = unified.organizationName
        google.department         = unified.department
        google.jobTitle           = unified.jobTitle
        google.note               = unified.note
        google.photoData          = unified.photoData

        google.phoneNumbers = unified.phoneNumbers.map {
            GooglePhoneNumber(value: $0.value, type: $0.label, label: $0.label)
        }
        google.emailAddresses = unified.emailAddresses.map {
            GoogleEmailAddress(value: $0.value, type: $0.label, label: $0.label)
        }
        google.addresses = unified.postalAddresses.map { addr in
            GoogleAddress(
                streetAddress: addr.street,
                city: addr.city,
                region: addr.state,
                postalCode: addr.postalCode,
                country: addr.country,
                countryCode: addr.countryCode,
                type: addr.label,
                label: addr.label
            )
        }
        google.urls = unified.urls.map {
            GoogleUrl(value: $0.value, type: $0.label, label: $0.label)
        }

        if let bd = unified.birthday {
            google.birthday = GoogleDate(year: bd.year, month: bd.month, day: bd.day)
        }

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

        // Phone numbers
        mac.phoneNumbers = unified.phoneNumbers.map { phone in
            let cnPhone = CNPhoneNumber(stringValue: phone.value)
            let label   = CNLabeledValue<CNPhoneNumber>(
                label: cnLabelFromString(phone.label), value: cnPhone)
            return label
        }

        // Email addresses
        mac.emailAddresses = unified.emailAddresses.map { email in
            CNLabeledValue<NSString>(
                label: cnLabelFromString(email.label),
                value: email.value as NSString)
        }

        // Postal addresses
        mac.postalAddresses = unified.postalAddresses.map { addr in
            let cnAddr = CNMutablePostalAddress()
            cnAddr.street     = addr.street     ?? ""
            cnAddr.city       = addr.city       ?? ""
            cnAddr.state      = addr.state      ?? ""
            cnAddr.postalCode = addr.postalCode ?? ""
            cnAddr.country    = addr.country    ?? ""
            if let cc = addr.countryCode, !cc.isEmpty {
                cnAddr.isoCountryCode = cc
            }
            return CNLabeledValue<CNPostalAddress>(
                label: cnLabelFromString(addr.label),
                value: cnAddr)
        }

        // URLs
        mac.urlAddresses = unified.urls.map { url in
            CNLabeledValue<NSString>(
                label: cnLabelFromString(url.label),
                value: url.value as NSString)
        }

        // Birthday
        if let bd = unified.birthday {
            mac.birthday = bd
        }

        if let note = unified.note {
            mac.note = note
        }
        
        if let photoData = unified.photoData {
            mac.imageData = photoData
        }

        return mac
    }

    /// Apply fields from a UnifiedContact onto an existing CNMutableContact (for updates)
    /// Preserves the contact's identifier — only overwrites changed fields.
    static func applyToMac(from unified: UnifiedContact, to mac: CNMutableContact) {
        if let v = unified.givenName          { mac.givenName          = v }
        if let v = unified.middleName         { mac.middleName         = v }
        if let v = unified.familyName         { mac.familyName         = v }
        if let v = unified.namePrefix         { mac.namePrefix         = v }
        if let v = unified.nameSuffix         { mac.nameSuffix         = v }
        if let v = unified.nickname           { mac.nickname           = v }
        if let v = unified.phoneticGivenName  { mac.phoneticGivenName  = v }
        if let v = unified.phoneticFamilyName { mac.phoneticFamilyName = v }
        if let v = unified.organizationName   { mac.organizationName   = v }
        if let v = unified.department         { mac.departmentName     = v }
        if let v = unified.jobTitle           { mac.jobTitle           = v }
        if let v = unified.note               { mac.note               = v }
        if let v = unified.photoData          { mac.imageData          = v }
        if let v = unified.birthday           { mac.birthday           = v }

        if !unified.phoneNumbers.isEmpty {
            mac.phoneNumbers = unified.phoneNumbers.map {
                CNLabeledValue<CNPhoneNumber>(
                    label: cnLabelFromString($0.label),
                    value: CNPhoneNumber(stringValue: $0.value))
            }
        }
        if !unified.emailAddresses.isEmpty {
            mac.emailAddresses = unified.emailAddresses.map {
                CNLabeledValue<NSString>(
                    label: cnLabelFromString($0.label),
                    value: $0.value as NSString)
            }
        }
        if !unified.postalAddresses.isEmpty {
            mac.postalAddresses = unified.postalAddresses.map { addr in
                let cn = CNMutablePostalAddress()
                cn.street = addr.street ?? ""; cn.city = addr.city ?? ""
                cn.state  = addr.state  ?? ""; cn.postalCode = addr.postalCode ?? ""
                cn.country = addr.country ?? ""
                if let cc = addr.countryCode, !cc.isEmpty { cn.isoCountryCode = cc }
                return CNLabeledValue<CNPostalAddress>(label: cnLabelFromString(addr.label), value: cn)
            }
        }
        if !unified.urls.isEmpty {
            mac.urlAddresses = unified.urls.map {
                CNLabeledValue<NSString>(
                    label: cnLabelFromString($0.label),
                    value: $0.value as NSString)
            }
        }
    }

    /// Apply fields from UnifiedContact onto an existing GoogleContact (for updates)
    static func applyToGoogle(from unified: UnifiedContact, to google: inout GoogleContact) {
        google.givenName          = unified.givenName
        google.middleName         = unified.middleName
        google.familyName         = unified.familyName
        google.namePrefix         = unified.namePrefix
        google.nameSuffix         = unified.nameSuffix
        google.nickname           = unified.nickname
        google.phoneticGivenName  = unified.phoneticGivenName
        google.phoneticMiddleName = unified.phoneticMiddleName
        google.phoneticFamilyName = unified.phoneticFamilyName
        google.organizationName   = unified.organizationName
        google.department         = unified.department
        google.jobTitle           = unified.jobTitle
        google.note               = unified.note
        google.photoData          = unified.photoData

        google.phoneNumbers    = unified.phoneNumbers.map    { GooglePhoneNumber(value: $0.value,    type: $0.label, label: $0.label) }
        google.emailAddresses  = unified.emailAddresses.map  { GoogleEmailAddress(value: $0.value,  type: $0.label, label: $0.label) }
        google.urls            = unified.urls.map            { GoogleUrl(value: $0.value, type: $0.label, label: $0.label) }
        google.addresses       = unified.postalAddresses.map { addr in
            GoogleAddress(streetAddress: addr.street, city: addr.city, region: addr.state,
                         postalCode: addr.postalCode, country: addr.country,
                         countryCode: addr.countryCode, type: addr.label, label: addr.label)
        }
        if let bd = unified.birthday {
            google.birthday = GoogleDate(year: bd.year, month: bd.month, day: bd.day)
        }
    }
}

// MARK: - Contact Mapping Store

/// Stores mappings between Google and Mac contact IDs
class ContactMappingStore {

    // In-memory store (backed by JSON on disk for persistence)
    private var mappings: [String: ContactMapping] = [:] // keyed by googleResourceName
    private let queue = DispatchQueue(label: "ContactMappingStore", attributes: .concurrent)
    private let persistenceURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "ContactSyncMate", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        persistenceURL = dir.appendingPathComponent("contact_mappings.json")
        loadFromDisk()
    }

    func getAllMappings() -> [ContactMapping] {
        queue.sync { Array(mappings.values) }
    }

    func getMapping(googleResourceName: String) -> ContactMapping? {
        queue.sync { mappings[googleResourceName] }
    }

    func getMapping(macIdentifier: String) -> ContactMapping? {
        queue.sync { mappings.values.first { $0.macContactIdentifier == macIdentifier } }
    }

    func saveMapping(_ mapping: ContactMapping) {
        queue.async(flags: .barrier) {
            self.mappings[mapping.googleResourceName] = mapping
            self.saveToDisk()
        }
    }

    func deleteMapping(googleResourceName: String) {
        queue.async(flags: .barrier) {
            self.mappings.removeValue(forKey: googleResourceName)
            self.saveToDisk()
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        struct CodableMapping: Codable {
            var googleResourceName: String
            var macContactIdentifier: String
            var lastSyncedAt: Date
            var googleEtag: String?
        }
        let codable = mappings.values.map {
            CodableMapping(googleResourceName: $0.googleResourceName,
                           macContactIdentifier: $0.macContactIdentifier,
                           lastSyncedAt: $0.lastSyncedAt,
                           googleEtag: $0.googleEtag)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(codable) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        struct CodableMapping: Codable {
            var googleResourceName: String
            var macContactIdentifier: String
            var lastSyncedAt: Date
            var googleEtag: String?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: persistenceURL),
              let loaded = try? decoder.decode([CodableMapping].self, from: data) else { return }
        for m in loaded {
            mappings[m.googleResourceName] = ContactMapping(
                googleResourceName: m.googleResourceName,
                macContactIdentifier: m.macContactIdentifier,
                lastSyncedAt: m.lastSyncedAt,
                googleEtag: m.googleEtag)
        }
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
    case missingContactData(String)

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
        case .missingContactData(let name):
            return "Missing contact data for: \(name)"
        }
    }
}
