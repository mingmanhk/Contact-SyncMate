//
//  DeduplicationCoordinator.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation
import SwiftUI
import Combine
import Contacts
import UserNotifications

/// Coordinates deduplication workflow with the sync engine
@MainActor
class DeduplicationCoordinator: ObservableObject {
    @Published var isScanning = false
    @Published var scanResult: DeduplicationResult?
    @Published var showingConfirmationSheet = false
    
    private let decisionStore: DeduplicationDecisionStore
    private let history = SyncHistory.shared

    // Build a fresh deduplicator from the latest AppSettings each time we scan,
    // so changes to AI matching settings are picked up without restarting the app.
    private func makeDeduplicator() -> ContactDeduplicator {
        let s = AppSettings.shared
        let config = ContactDeduplicator.Configuration(
            aiMatchingEnabled: s.aiMatchingEnabled,
            anthropicAPIKey:   s.anthropicAPIKey.isEmpty ? nil : s.anthropicAPIKey
        )
        // Thread in the user-configured score window via a small extension below.
        return ContactDeduplicator(
            config: config.withScoreRange(low: s.aiAPIScoreRangeLow, high: s.aiAPIScoreRangeHigh),
            decisionStore: decisionStore
        )
    }

    init(decisionStore: DeduplicationDecisionStore? = nil) {
        self.decisionStore = decisionStore ?? DeduplicationDecisionStore.shared
    }
    
    // MARK: - Public API
    
    /// Scan for duplicates before sync
    func scanForDuplicates(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        existingMappings: [ContactMapping],
        autoApplyIfSafe: Bool = false
    ) async -> DeduplicationResult {
        
        isScanning = true
        defer { isScanning = false }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "scanForDuplicates.start",
            details: "google=\(googleContacts.count), mac=\(macContacts.count)"
        )
        
        let deduplicator = makeDeduplicator()
        let result = await deduplicator.detectDuplicates(
            googleContacts: googleContacts,
            macContacts: macContacts,
            existingMappings: existingMappings
        )
        
        scanResult = result
        
        // If there are groups needing confirmation, show the sheet
        if result.needsUserConfirmation {
            showingConfirmationSheet = true
        }
        
        // Auto-apply safe merges if enabled
        if autoApplyIfSafe {
            let safeGroups = result.duplicateGroups.filter { group in
                makeDeduplicator().isSafeToAutoMerge(group)
            }
            
            for group in safeGroups {
                await applySafeMerge(group: group)
            }
        }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "scanForDuplicates.end",
            details: result.stats.summary
        )

        // Drop cached AI verdicts so a subsequent scan after the user edits
        // contacts cannot serve stale results. (Cache keys are also
        // content-fingerprinted as a second line of defence.)
        AIContactMatcher.shared.clearCache()

        return result
    }
    
    /// Apply user decisions from the confirmation UI
    func applyUserDecisions(
        _ decisions: [UUID: DuplicateDecision],
        rememberPatterns: Set<UUID> = []
    ) async {
        
        guard let result = scanResult else { return }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "applyUserDecisions",
            details: "\(decisions.count) decisions"
        )
        
        for (groupID, decision) in decisions {
            guard let group = result.duplicateGroups.first(where: { $0.id == groupID }) else {
                continue
            }
            
            // Record the decision
            let rememberPattern = rememberPatterns.contains(groupID)
            makeDeduplicator().recordUserDecision(decision, for: group, rememberPattern: rememberPattern)
            
            // Execute the decision
            switch decision {
            case .merge:
                await executeMerge(group: group)
                
            case .keepSeparate:
                await markAsKeepSeparate(group: group)
                
            case .skip:
                // Do nothing, just skip this group
                break
            }
        }
    }
    
    /// Present confirmation UI
    func presentConfirmationUI() -> some View {
        DeduplicationConfirmationView(
            duplicateGroups: scanResult?.groupsNeedingConfirmation ?? [],
            onDecisionsMade: { decisions, rememberPatterns in
                Task {
                    await self.applyUserDecisions(decisions, rememberPatterns: rememberPatterns)
                }
            }
        )
    }
    
    // MARK: - Private Helpers
    
    /// Apply a safe auto-merge for a group of duplicate contacts
    private func applySafeMerge(group: DuplicateGroup) async {
        await executeMergeLogic(group: group, trigger: "autoMerge")
    }

    /// Execute user-confirmed merge
    private func executeMerge(group: DuplicateGroup) async {
        await executeMergeLogic(group: group, trigger: "userMerge")
    }

    /// Shared merge execution: pick primary contact, merge data, update stores, delete extras
    private func executeMergeLogic(group: DuplicateGroup, trigger: String) async {
        guard group.contacts.count >= 2 else { return }

        // Pick the primary contact (prefer the one with the most data)
        let sorted = group.contacts.sorted {
            contactDataScore($0.contact) > contactDataScore($1.contact)
        }
        let primary = sorted[0]
        let others = Array(sorted.dropFirst())

        // Merge all others into primary
        var merged = primary.contact
        for other in others {
            merged = mergeInto(primary: merged, secondary: other.contact)
        }

        // Write merged result back to the primary contact's source
        do {
            let googleConnector = GoogleContactsConnector()
            let macConnector = MacContactsConnector()

            if let gID = merged.googleResourceName, !gID.isEmpty {
                var googleContact = GoogleContact(id: gID)
                ContactMapper.applyToGoogle(from: merged, to: &googleContact)
                _ = try await googleConnector.updateContact(googleContact)
            }
            if let mID = merged.macContactIdentifier, !mID.isEmpty {
                // Fetch + write together, off the main actor. CNContactStore is
                // synchronous XPC to contactsd at background QoS; driving it from
                // the main actor inverts priority and the resulting contention
                // shows up as Cocoa 134092 during faulting.
                let c = macConnector
                let unified = merged
                try await MacContactsConnector.performWriteOffMain {
                    guard let existing = try c.fetchContactSync(withIdentifier: mID) else { return }
                    let mutable = existing.mutableCopy() as! CNMutableContact
                    ContactMapper.applyToMac(from: unified, to: mutable)
                    try c.updateContactSync(mutable)
                }
            }

            // Delete the duplicate contacts (not the primary).
            //
            // `try?` here was the worst possible combination: the merged payload
            // has already been written into the primary above, so a swallowed
            // deletion leaves N copies each holding the merged data — and the
            // success log below still claimed the merge worked. A failure has to
            // reach the catch, because a half-done merge is worse than none.
            for other in others {
                // Mapping cleanup rides with each deletion, not after the loop:
                // if a later deletion throws, the records already gone must not
                // keep mappings pointing at them — a stale mapping to a deleted
                // record is exactly the corruption Unlink exists to clean up.
                if other.source == .google, let gID = other.contact.googleResourceName {
                    try await googleConnector.deleteContact(resourceName: gID)
                    ContactMappingStore.shared.deleteMapping(googleResourceName: gID)
                }
                if other.source == .mac, let mID = other.contact.macContactIdentifier {
                    let c = macConnector
                    try await MacContactsConnector.performWriteOffMain {
                        try c.deleteContactSync(withIdentifier: mID)
                    }
                    ContactMappingStore.shared.deleteMapping(macContactIdentifier: mID)
                }
            }

            // The survivor holds the merged payload on both sides as of now —
            // record that, or the next sync re-diffs the merge as a change.
            if let gID = merged.googleResourceName?.nonBlank,
               let mID = merged.macContactIdentifier?.nonBlank {
                ContactMappingStore.shared.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

            history.log(
                source: "DeduplicationCoordinator",
                action: trigger,
                details: "group=\(group.id), merged \(group.contacts.count) contacts → \(merged.displayName)"
            )
        } catch {
            // A thrown deletion means the merged payload is already written and
            // some duplicates may already be gone — a partial merge. The history
            // line alone made that invisible; record it where the user actually
            // looks (Settings → Sync Failures), keyed the same way SyncEngine
            // keys its per-contact failures.
            let explained = SyncErrorExplanation.describe(error)
            var failureKey: String?
            if let mID = merged.macContactIdentifier?.nonBlank {
                failureKey = "mac:" + mID
            } else if let gID = merged.googleResourceName?.nonBlank {
                failureKey = "google:" + gID
            }
            if let failureKey {
                _ = SyncFailureStore.shared.recordFailure(
                    key: failureKey,
                    name: merged.displayName,
                    reason: "Merge did not complete — \(explained)")
            }
            history.log(
                source: "DeduplicationCoordinator",
                action: "\(trigger).failed",
                details: "group=\(group.id), error=\(error.localizedDescription)"
            )
        }
    }

    /// Score how "complete" a contact's data is (more fields = higher score)
    private func contactDataScore(_ c: UnifiedContact) -> Int {
        var score = 0
        if c.givenName?.isEmpty == false { score += 1 }
        if c.familyName?.isEmpty == false { score += 1 }
        score += c.phoneNumbers.count * 2
        score += c.emailAddresses.count * 2
        score += c.postalAddresses.count
        if c.organizationName?.isEmpty == false { score += 1 }
        if c.jobTitle?.isEmpty == false { score += 1 }
        if c.photoData != nil { score += 1 }
        if c.note?.isEmpty == false { score += 1 }
        return score
    }

    /// Merge secondary's data into primary (primary wins for conflicts, secondary fills gaps)
    func mergeInto(primary: UnifiedContact, secondary: UnifiedContact) -> UnifiedContact { // internal for testing
        UnifiedContact(
            id: primary.id,
            googleResourceName: primary.googleResourceName ?? secondary.googleResourceName,
            macContactIdentifier: primary.macContactIdentifier ?? secondary.macContactIdentifier,
            givenName: primary.givenName?.isEmpty == false ? primary.givenName : secondary.givenName,
            middleName: primary.middleName?.isEmpty == false ? primary.middleName : secondary.middleName,
            familyName: primary.familyName?.isEmpty == false ? primary.familyName : secondary.familyName,
            namePrefix: primary.namePrefix ?? secondary.namePrefix,
            nameSuffix: primary.nameSuffix ?? secondary.nameSuffix,
            nickname: primary.nickname ?? secondary.nickname,
            phoneticGivenName: primary.phoneticGivenName ?? secondary.phoneticGivenName,
            phoneticMiddleName: primary.phoneticMiddleName ?? secondary.phoneticMiddleName,
            phoneticFamilyName: primary.phoneticFamilyName ?? secondary.phoneticFamilyName,
            organizationName: primary.organizationName?.isEmpty == false ? primary.organizationName : secondary.organizationName,
            department: primary.department ?? secondary.department,
            jobTitle: primary.jobTitle?.isEmpty == false ? primary.jobTitle : secondary.jobTitle,
            phoneNumbers: mergeUniquePhones(primary.phoneNumbers, secondary.phoneNumbers),
            emailAddresses: mergeUniqueEmails(primary.emailAddresses, secondary.emailAddresses),
            postalAddresses: mergeUniqueAddresses(primary.postalAddresses, secondary.postalAddresses),
            urls: primary.urls + secondary.urls.filter { u in !primary.urls.contains { $0.value == u.value } },
            birthday: primary.birthday ?? secondary.birthday,
            note: {
                let parts = [primary.note, secondary.note].compactMap { $0 }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: "\n---\n")
            }(),
            photoData: primary.photoData ?? secondary.photoData,
            lastModified: Date()
        )
    }

    func mergeUniquePhones(_ a: [UnifiedContact.PhoneNumber], _ b: [UnifiedContact.PhoneNumber]) -> [UnifiedContact.PhoneNumber] { // internal for testing
        var result = a
        let existing = Set(a.map { $0.value.filter(\.isNumber) })
        for p in b where !existing.contains(p.value.filter(\.isNumber)) { result.append(p) }
        return result
    }

    func mergeUniqueEmails(_ a: [UnifiedContact.EmailAddress], _ b: [UnifiedContact.EmailAddress]) -> [UnifiedContact.EmailAddress] { // internal for testing
        var result = a
        let existing = Set(a.map { $0.value.lowercased() })
        for e in b where !existing.contains(e.value.lowercased()) { result.append(e) }
        return result
    }

    /// Union, keyed on the full normalized address. "Primary wins if it has
    /// any" threw away every secondary address the moment the primary had one —
    /// a merge is supposed to combine the two records, and a distinct address
    /// is exactly the data a duplicate pair tends to disagree on.
    func mergeUniqueAddresses(_ a: [UnifiedContact.PostalAddress], _ b: [UnifiedContact.PostalAddress]) -> [UnifiedContact.PostalAddress] { // internal for testing
        var result = a
        var seen = Set(a.map(SyncEngine.normalizedAddress))
        for addr in b where seen.insert(SyncEngine.normalizedAddress(addr)).inserted {
            result.append(addr)
        }
        return result
    }

    /// Mark contacts as intentionally separate (prevents re-flagging)
    private func markAsKeepSeparate(group: DuplicateGroup) async {
        // Record in the decision store so future scans skip this pair
        for i in 0..<group.contacts.count {
            for j in (i+1)..<group.contacts.count {
                let c1 = group.contacts[i].contact
                let c2 = group.contacts[j].contact
                let id1 = c1.googleResourceName ?? c1.macContactIdentifier ?? c1.id.uuidString
                let id2 = c2.googleResourceName ?? c2.macContactIdentifier ?? c2.id.uuidString
                // Use a stable pattern key so this pair is remembered across sessions
                let patternKey = [id1, id2].sorted().joined(separator: "<>")
                decisionStore.savePattern(pattern: patternKey, decision: .keepSeparate)
            }
        }

        history.log(
            source: "DeduplicationCoordinator",
            action: "keepSeparate",
            details: "group=\(group.id), \(group.contacts.count) contacts marked as intentionally separate"
        )
    }
    
    // MARK: - Statistics & History
    
    /// Get deduplication statistics
    func getStatistics() -> PatternStatistics {
        return decisionStore.getStatistics()
    }
    
    /// Clear all saved patterns
    func clearSavedPatterns() {
        decisionStore.clearAll()
        history.log(
            source: "DeduplicationCoordinator",
            action: "clearPatterns",
            details: nil
        )
    }
}

// MARK: - Sync Engine Integration

extension DeduplicationCoordinator {
    
    /// Check if sync should proceed or wait for dedup confirmation
    func shouldProceedWithSync(result: DeduplicationResult, mode: SyncMode) -> Bool {
        switch mode {
        case .manual:
            // Manual sync: always wait for user confirmation if duplicates found
            return !result.needsUserConfirmation
            
        case .automatic:
            // Auto sync: skip duplicates and log notification
            if result.needsUserConfirmation {
                sendNotification(duplicateCount: result.groupsNeedingConfirmation.count)
                return false
            }
            return true
        }
    }
    
    /// Send system notification about skipped duplicates in auto mode
    private func sendNotification(duplicateCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Contact SyncMate"
        content.body = "\(duplicateCount) potential duplicate\(duplicateCount == 1 ? "" : "s") found. Open the app to review."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dedup-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.history.log(source: "DeduplicationCoordinator", action: "notification.failed",
                    details: error.localizedDescription)
            }
        }

        history.log(
            source: "DeduplicationCoordinator",
            action: "skippedDuplicatesNotification",
            details: "count=\(duplicateCount)"
        )
    }
}

// MARK: - Supporting Types
// SyncMode is defined in SyncTypes.swift

// MARK: - View Extension

extension View {
    /// Present deduplication confirmation sheet
    func deduplicationConfirmation(
        isPresented: Binding<Bool>,
        coordinator: DeduplicationCoordinator
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            coordinator.presentConfirmationUI()
        }
    }
}
