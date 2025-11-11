//
//  SyncEngineDeduplicationIntegration.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//
//  Example integration of deduplication with the existing SyncEngine
//

import Foundation

// MARK: - Integration Example

extension SyncEngine {
    
    /// Enhanced manual sync with deduplication
    func prepareManualSyncWithDeduplication(
        direction: SyncDirection,
        coordinator: DeduplicationCoordinator
    ) async throws -> (session: SyncSession, deduplicationResult: DeduplicationResult?) {
        
        // 1. Fetch contacts from both sides
        let googleContacts = try await googleConnector.fetchAllContacts()
        let macContacts = try macConnector.fetchAllContacts()
        
        // 2. Convert to unified format
        let unifiedGoogleContacts = googleContacts.map { ContactMapper.toUnified(from: $0) }
        let unifiedMacContacts = macContacts.map { ContactMapper.toUnified(from: $0) }
        
        // 3. Get existing mappings
        let mappings = mappingStore.getAllMappings()
        
        // 4. Run deduplication scan
        let dedupResult = await coordinator.scanForDuplicates(
            googleContacts: unifiedGoogleContacts,
            macContacts: unifiedMacContacts,
            existingMappings: mappings,
            autoApplyIfSafe: false  // Manual sync: always ask user
        )
        
        // 5. If duplicates need confirmation, wait for user
        if dedupResult.needsUserConfirmation {
            // The coordinator will present the confirmation UI
            // Return early - user will call executeSync after confirming
            let session = SyncSession(
                mode: .manual,
                direction: direction,
                startTime: Date(),
                contactChanges: []  // Empty until after deduplication resolved
            )
            return (session, dedupResult)
        }
        
        // 6. Apply auto-resolved merges to mappings
        for group in dedupResult.autoMergeGroups {
            applyMergeToMappings(group: group)
        }
        
        // 7. Now compute sync changes with updated mappings
        let changes = computeChanges(
            googleContacts: unifiedGoogleContacts,
            macContacts: unifiedMacContacts,
            direction: direction
        )
        
        // 8. Create session
        let session = SyncSession(
            mode: .manual,
            direction: direction,
            startTime: Date(),
            contactChanges: changes
        )
        
        return (session, dedupResult)
    }
    
    /// Enhanced auto sync with deduplication
    func runAutoSyncWithDeduplication(
        coordinator: DeduplicationCoordinator
    ) async throws -> SyncResult {
        
        guard settings.autoSyncEnabled else {
            throw SyncEngineError.autoSyncDisabled
        }
        
        // 1. Fetch contacts
        let googleContacts = try await googleConnector.fetchAllContacts()
        let macContacts = try macConnector.fetchAllContacts()
        
        let unifiedGoogleContacts = googleContacts.map { ContactMapper.toUnified(from: $0) }
        let unifiedMacContacts = macContacts.map { ContactMapper.toUnified(from: $0) }
        
        let mappings = mappingStore.getAllMappings()
        
        // 2. Run deduplication scan with auto-apply enabled
        let dedupResult = await coordinator.scanForDuplicates(
            googleContacts: unifiedGoogleContacts,
            macContacts: unifiedMacContacts,
            existingMappings: mappings,
            autoApplyIfSafe: true  // Auto sync: apply safe merges automatically
        )
        
        // 3. Check if we should proceed
        if !coordinator.shouldProceedWithSync(result: dedupResult, mode: .auto) {
            // Duplicates need manual confirmation, skip this sync
            throw SyncEngineError.conditionsNotMet
        }
        
        // 4. Apply auto-resolved merges
        for group in dedupResult.autoMergeGroups {
            applyMergeToMappings(group: group)
        }
        
        // 5. Proceed with normal sync
        let direction = settings.autoSyncDirection
        let changes = computeChanges(
            googleContacts: unifiedGoogleContacts,
            macContacts: unifiedMacContacts,
            direction: direction
        )
        
        let session = SyncSession(
            mode: .auto,
            direction: direction,
            startTime: Date(),
            contactChanges: changes
        )
        
        return try await executeSync(session: session)
    }
    
    // MARK: - Helper Methods
    
    /// Apply a confirmed merge to the mapping store
    private func applyMergeToMappings(group: DuplicateGroup) {
        let contacts = group.contacts
        
        // Identify Google and Mac contacts in the group
        let googleCandidates = contacts.filter { $0.source == .google }
        let macCandidates = contacts.filter { $0.source == .mac }
        
        // Case 1: One Google + One Mac = Simple mapping
        if googleCandidates.count == 1 && macCandidates.count == 1,
           let googleID = googleCandidates.first?.contact.googleResourceName,
           let macID = macCandidates.first?.contact.macContactIdentifier {
            
            let mapping = ContactMapping(
                googleResourceName: googleID,
                macContactIdentifier: macID,
                lastSyncedAt: Date(),
                googleEtag: nil
            )
            mappingStore.saveMapping(mapping)
            
            SyncHistory.shared.log(
                source: "SyncEngine",
                action: "createMappingFromMerge",
                details: "google=\(googleID), mac=\(macID)"
            )
        }
        
        // Case 2: Multiple contacts in same source = Internal duplicate
        // These need to be merged within that source
        else if googleCandidates.count > 1 {
            // Multiple Google contacts are duplicates
            mergeDuplicatesInGoogle(googleCandidates.map { $0.contact })
        }
        else if macCandidates.count > 1 {
            // Multiple Mac contacts are duplicates
            mergeDuplicatesInMac(macCandidates.map { $0.contact })
        }
        
        // Case 3: One-to-many mapping (e.g., 1 Google → 2 Mac)
        // Choose primary mapping and delete/merge others
        else if googleCandidates.count == 1 && macCandidates.count > 1 {
            handleOneToManyMapping(
                googleContact: googleCandidates.first!.contact,
                macContacts: macCandidates.map { $0.contact }
            )
        }
    }
    
    /// Merge duplicate contacts within Google
    private func mergeDuplicatesInGoogle(_ contacts: [UnifiedContact]) {
        guard contacts.count >= 2 else { return }
        
        // Merge all into first contact
        var merged = contacts[0]
        for contact in contacts.dropFirst() {
            merged = merged.merging(with: contact, preferOther: false)
        }
        
        // TODO: Update Google contact via API
        // TODO: Delete the duplicate contacts
        
        SyncHistory.shared.log(
            source: "SyncEngine",
            action: "mergeGoogleDuplicates",
            details: "merged \(contacts.count) contacts"
        )
    }
    
    /// Merge duplicate contacts within Mac
    private func mergeDuplicatesInMac(_ contacts: [UnifiedContact]) {
        guard contacts.count >= 2 else { return }
        
        // Merge all into first contact
        var merged = contacts[0]
        for contact in contacts.dropFirst() {
            merged = merged.merging(with: contact, preferOther: false)
        }
        
        // Convert to CNMutableContact and update
        let mutableContact = ContactMapper.toMac(from: merged)
        
        do {
            // Update the first contact
            if let macID = contacts[0].macContactIdentifier {
                if let existing = try macConnector.fetchContact(withIdentifier: macID) {
                    let mutable = existing.mutableCopy() as! CNMutableContact
                    // Apply merged fields to mutable contact
                    // ... (copy fields from merged to mutable)
                    try macConnector.updateContact(mutable)
                }
            }
            
            // Delete the duplicate contacts
            for contact in contacts.dropFirst() {
                if let macID = contact.macContactIdentifier {
                    try? macConnector.deleteContact(withIdentifier: macID)
                }
            }
            
            SyncHistory.shared.log(
                source: "SyncEngine",
                action: "mergeMacDuplicates",
                details: "merged \(contacts.count) contacts"
            )
        } catch {
            SyncHistory.shared.log(
                source: "SyncEngine",
                action: "mergeMacDuplicates.error",
                details: error.localizedDescription
            )
        }
    }
    
    /// Handle one-to-many mapping (e.g., 1 Google contact → 2 Mac contacts)
    private func handleOneToManyMapping(googleContact: UnifiedContact, macContacts: [UnifiedContact]) {
        // Strategy: Merge Mac contacts, then create single mapping
        
        // 1. Merge all Mac contacts
        mergeDuplicatesInMac(macContacts)
        
        // 2. Create mapping with first Mac contact (which now has merged data)
        if let googleID = googleContact.googleResourceName,
           let macID = macContacts.first?.macContactIdentifier {
            
            let mapping = ContactMapping(
                googleResourceName: googleID,
                macContactIdentifier: macID,
                lastSyncedAt: Date(),
                googleEtag: nil
            )
            mappingStore.saveMapping(mapping)
            
            SyncHistory.shared.log(
                source: "SyncEngine",
                action: "oneToManyMapping",
                details: "google=\(googleID) → mac=\(macID) (merged \(macContacts.count) Mac contacts)"
            )
        }
    }
}

// MARK: - Models Extension

extension SyncSession {
    /// Add deduplication statistics to session
    var deduplicationStats: DeduplicationStats? {
        // Store in session if needed
        return nil
    }
}

extension SyncResult {
    /// Create result with deduplication info
    static func withDeduplication(
        base: SyncResult,
        deduplicationStats: DeduplicationStats
    ) -> SyncResult {
        var result = base
        // Add dedup info to result if model supports it
        return result
    }
}

// MARK: - Usage Example in View

/*
 
 Example integration in a SwiftUI view:
 
 struct ManualSyncView: View {
     @StateObject private var syncEngine: SyncEngine
     @StateObject private var dedupCoordinator = DeduplicationCoordinator()
     
     @State private var currentSession: SyncSession?
     @State private var isProcessing = false
     
     var body: some View {
         VStack {
             Button("Start Manual Sync") {
                 Task {
                     await startSync()
                 }
             }
             .disabled(isProcessing)
         }
         .deduplicationConfirmation(
             isPresented: $dedupCoordinator.showingConfirmationSheet,
             coordinator: dedupCoordinator
         )
     }
     
     func startSync() async {
         isProcessing = true
         defer { isProcessing = false }
         
         do {
             // Prepare sync with deduplication
             let (session, dedupResult) = try await syncEngine.prepareManualSyncWithDeduplication(
                 direction: .twoWay,
                 coordinator: dedupCoordinator
             )
             
             // If duplicates found, wait for user confirmation
             if let result = dedupResult, result.needsUserConfirmation {
                 print("⚠️ Found \(result.groupsNeedingConfirmation.count) duplicate groups")
                 print("   Waiting for user confirmation...")
                 
                 // Store session for later
                 currentSession = session
                 
                 // Sheet will be presented automatically by coordinator
                 // User will make decisions, then we continue
                 
                 // TODO: Add observation/callback to know when user is done
                 return
             }
             
             // No duplicates or all resolved, proceed
             let result = try await syncEngine.executeSync(session: session)
             print("✅ Sync complete: +\(result.added), ~\(result.updated), -\(result.deleted)")
             
         } catch {
             print("❌ Sync failed: \(error)")
         }
     }
 }
 
 */
