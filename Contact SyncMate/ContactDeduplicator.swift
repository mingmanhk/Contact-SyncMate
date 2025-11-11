//
//  ContactDeduplicator.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation

/// Core deduplication engine with scoring-based duplicate detection
class ContactDeduplicator {
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Threshold for auto-merge (≥80 by default)
        var autoMergeThreshold: Int = 80
        
        /// Threshold for user confirmation (50-79 by default)
        var confirmationThreshold: Int = 50
        
        /// Maximum contacts in a group to allow auto-merge
        var maxAutoMergeGroupSize: Int = 3
        
        /// Maximum Levenshtein distance for similar names
        var maxNameDistance: Int = 2
        
        /// Require confirmation even for high-scoring matches on first sync
        var requireConfirmationOnFirstSync: Bool = true
        
        /// Allow remembering user decisions for similar patterns
        var enablePatternMemory: Bool = true
    }
    
    private let config: Configuration
    private let decisionStore: DeduplicationDecisionStore
    private let history = SyncHistory.shared
    
    init(config: Configuration = Configuration(),
         decisionStore: DeduplicationDecisionStore = DeduplicationDecisionStore.shared) {
        self.config = config
        self.decisionStore = decisionStore
    }
    
    // MARK: - Public API
    
    /// Detect duplicates in a collection of contacts
    func detectDuplicates(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        existingMappings: [ContactMapping]
    ) async -> DeduplicationResult {
        
        let startTime = Date()
        var stats = DeduplicationStats()
        var allGroups: [DuplicateGroup] = []
        var errors: [DeduplicationError] = []
        
        stats.totalContactsScanned = googleContacts.count + macContacts.count
        
        history.log(source: "Deduplicator", action: "detectDuplicates.start",
                   details: "google=\(googleContacts.count), mac=\(macContacts.count)")
        
        // 1. Find duplicates within Google
        let googleGroups = await detectDuplicatesWithinSource(
            contacts: googleContacts,
            source: .google
        )
        allGroups.append(contentsOf: googleGroups)
        
        // 2. Find duplicates within Mac
        let macGroups = await detectDuplicatesWithinSource(
            contacts: macContacts,
            source: .mac
        )
        allGroups.append(contentsOf: macGroups)
        
        // 3. Find duplicates across sources
        let crossGroups = await detectDuplicatesAcrossSources(
            googleContacts: googleContacts,
            macContacts: macContacts,
            existingMappings: existingMappings
        )
        allGroups.append(contentsOf: crossGroups)
        
        // 4. Apply user's saved preferences
        allGroups = applyUserPreferences(to: allGroups)
        
        // 5. Calculate statistics
        stats.duplicateGroupsFound = allGroups.count
        stats.autoMergeGroups = allGroups.filter { $0.shouldAutoMerge }.count
        stats.userConfirmationGroups = allGroups.filter { $0.needsUserConfirmation }.count
        stats.separateGroups = allGroups.filter { $0.shouldKeepSeparate }.count
        stats.scanDuration = Date().timeIntervalSince(startTime)
        
        history.log(source: "Deduplicator", action: "detectDuplicates.end",
                   details: stats.summary)
        
        return DeduplicationResult(
            stats: stats,
            duplicateGroups: allGroups,
            errors: errors
        )
    }
    
    /// Calculate detailed match score between two contacts
    func calculateMatchScore(_ contact1: UnifiedContact, _ contact2: UnifiedContact) -> MatchScoreBreakdown {
        var breakdown = MatchScoreBreakdown()
        
        let norm1 = contact1.normalizedForDeduplication
        let norm2 = contact2.normalizedForDeduplication
        
        // Rule 1: Same normalized email → +60
        let emailIntersection = norm1.emails.intersection(norm2.emails)
        if !emailIntersection.isEmpty {
            breakdown.emailMatch = 60
        }
        
        // Rule 2: Same normalized phone → +60
        let phoneIntersection = norm1.phones.intersection(norm2.phones)
        if !phoneIntersection.isEmpty {
            breakdown.phoneMatch = 60
        }
        
        // Rule 3: Same normalized full name → +30
        if !norm1.fullName.isEmpty && norm1.fullName == norm2.fullName {
            breakdown.exactNameMatch = 30
        }
        // Rule 4: Very similar name (Levenshtein ≤ 2) → +20
        else if ContactNormalizer.areNamesSimilar(norm1.fullName, norm2.fullName, maxDistance: config.maxNameDistance) {
            breakdown.similarNameMatch = 20
        }
        
        // Rule 5: Same company/organization → +10
        if !norm1.organization.isEmpty && norm1.organization == norm2.organization {
            breakdown.organizationMatch = 10
        }
        
        // Rule 6: Same postal address → +10
        if !norm1.address.isEmpty && norm1.address == norm2.address {
            breakdown.addressMatch = 10
        }
        
        // Penalty Rule 7: Mismatch in email domain but same name → -10
        if breakdown.exactNameMatch > 0 || breakdown.similarNameMatch > 0 {
            if hasConflictingEmailDomains(contact1, contact2) {
                breakdown.emailDomainMismatch = -10
            }
        }
        
        // Penalty Rule 8: Different emails/phones but similar names only → -20
        if (breakdown.similarNameMatch > 0 || breakdown.exactNameMatch > 0) &&
            breakdown.emailMatch == 0 && breakdown.phoneMatch == 0 {
            if !norm1.hasContact && !norm2.hasContact {
                // Both lack contact info, don't penalize
            } else if norm1.hasContact && norm2.hasContact &&
                      emailIntersection.isEmpty && phoneIntersection.isEmpty {
                // Both have contact info but completely different
                breakdown.differentContactInfo = -20
            }
        }
        
        return breakdown
    }
    
    /// Generate a preview of what the merged contact would look like
    func generateMergePreview(for group: DuplicateGroup) -> MergePreview {
        let contacts = group.contacts.map { $0.contact }
        
        guard let first = contacts.first else {
            return MergePreview(originalContacts: [], mergedContact: UnifiedContact(id: UUID()), changes: [])
        }
        
        // Merge all contacts
        var merged = first
        for contact in contacts.dropFirst() {
            merged = merged.merging(with: contact, preferOther: false)
        }
        
        // Track changes
        var changes: [MergeChange] = []
        
        // Check name conflicts
        let givenNames = Set(contacts.compactMap { $0.givenName }.filter { !$0.isEmpty })
        if givenNames.count > 1 {
            changes.append(MergeChange(
                fieldName: "First Name",
                values: Array(givenNames),
                chosenValue: merged.givenName ?? "",
                isConflict: true
            ))
        }
        
        let familyNames = Set(contacts.compactMap { $0.familyName }.filter { !$0.isEmpty })
        if familyNames.count > 1 {
            changes.append(MergeChange(
                fieldName: "Last Name",
                values: Array(familyNames),
                chosenValue: merged.familyName ?? "",
                isConflict: true
            ))
        }
        
        // Check organization conflicts
        let orgs = Set(contacts.compactMap { $0.organizationName }.filter { !$0.isEmpty })
        if orgs.count > 1 {
            changes.append(MergeChange(
                fieldName: "Organization",
                values: Array(orgs),
                chosenValue: merged.organizationName ?? "",
                isConflict: true
            ))
        }
        
        // Email addresses (union, not conflict)
        let allEmails = contacts.flatMap { $0.emailAddresses.map { $0.value } }
        if !allEmails.isEmpty {
            changes.append(MergeChange(
                fieldName: "Email Addresses",
                values: allEmails,
                chosenValue: "\(allEmails.count) total",
                isConflict: false
            ))
        }
        
        // Phone numbers (union, not conflict)
        let allPhones = contacts.flatMap { $0.phoneNumbers.map { $0.value } }
        if !allPhones.isEmpty {
            changes.append(MergeChange(
                fieldName: "Phone Numbers",
                values: allPhones,
                chosenValue: "\(allPhones.count) total",
                isConflict: false
            ))
        }
        
        return MergePreview(
            originalContacts: contacts,
            mergedContact: merged,
            changes: changes
        )
    }
    
    /// Save user's decision for a duplicate group
    func recordUserDecision(_ decision: DuplicateDecision, for group: DuplicateGroup, rememberPattern: Bool = false) {
        history.log(
            source: "Deduplicator",
            action: "userDecision",
            details: "\(decision.rawValue) for \(group.contacts.count) contacts, score=\(group.matchScore)"
        )
        
        if rememberPattern && config.enablePatternMemory {
            let pattern = generatePattern(for: group)
            decisionStore.savePattern(pattern: pattern, decision: decision)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Detect duplicates within a single source (Google or Mac)
    private func detectDuplicatesWithinSource(
        contacts: [UnifiedContact],
        source: ContactSource
    ) async -> [DuplicateGroup] {
        
        var groups: [DuplicateGroup] = []
        var processedPairs = Set<String>()
        
        for i in 0..<contacts.count {
            for j in (i + 1)..<contacts.count {
                let contact1 = contacts[i]
                let contact2 = contacts[j]
                
                // Create unique pair ID
                let pairID = "\(contact1.id.uuidString)-\(contact2.id.uuidString)"
                guard !processedPairs.contains(pairID) else { continue }
                processedPairs.insert(pairID)
                
                let breakdown = calculateMatchScore(contact1, contact2)
                let score = breakdown.totalScore
                
                // Only create groups for scores above minimum threshold
                if score >= config.confirmationThreshold {
                    let candidates = [
                        DuplicateCandidate(contact: contact1, source: source),
                        DuplicateCandidate(contact: contact2, source: source)
                    ]
                    
                    let group = DuplicateGroup(
                        contacts: candidates,
                        matchScore: score,
                        matchReason: breakdown.primaryReason,
                        groupType: source == .google ? .withinGoogle : .withinMac
                    )
                    
                    groups.append(group)
                }
            }
        }
        
        return groups
    }
    
    /// Detect duplicates across Google and Mac
    private func detectDuplicatesAcrossSources(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        existingMappings: [ContactMapping]
    ) async -> [DuplicateGroup] {
        
        var groups: [DuplicateGroup] = []
        
        // Create mapping lookup
        let mappingByGoogle = Dictionary(uniqueKeysWithValues: existingMappings.map {
            ($0.googleResourceName, $0.macContactIdentifier)
        })
        
        for googleContact in googleContacts {
            for macContact in macContacts {
                // Skip if already mapped
                if let googleID = googleContact.googleResourceName,
                   let macID = macContact.macContactIdentifier,
                   mappingByGoogle[googleID] == macID {
                    continue
                }
                
                let breakdown = calculateMatchScore(googleContact, macContact)
                let score = breakdown.totalScore
                
                if score >= config.confirmationThreshold {
                    let candidates = [
                        DuplicateCandidate(contact: googleContact, source: .google),
                        DuplicateCandidate(contact: macContact, source: .mac)
                    ]
                    
                    let group = DuplicateGroup(
                        contacts: candidates,
                        matchScore: score,
                        matchReason: breakdown.primaryReason,
                        groupType: .acrossSources
                    )
                    
                    groups.append(group)
                }
            }
        }
        
        return groups
    }
    
    /// Check if two contacts have conflicting email domains
    private func hasConflictingEmailDomains(_ contact1: UnifiedContact, _ contact2: UnifiedContact) -> Bool {
        let domains1 = Set(contact1.emailAddresses.compactMap { extractDomain(from: $0.value) })
        let domains2 = Set(contact2.emailAddresses.compactMap { extractDomain(from: $0.value) })
        
        // If both have emails and no common domain, it's a conflict
        return !domains1.isEmpty && !domains2.isEmpty && domains1.intersection(domains2).isEmpty
    }
    
    /// Extract domain from email address
    private func extractDomain(from email: String) -> String? {
        let parts = email.split(separator: "@")
        return parts.count == 2 ? String(parts[1]).lowercased() : nil
    }
    
    /// Apply saved user preferences to duplicate groups
    private func applyUserPreferences(to groups: [DuplicateGroup]) -> [DuplicateGroup] {
        guard config.enablePatternMemory else { return groups }
        
        return groups.map { group in
            var updatedGroup = group
            let pattern = generatePattern(for: group)
            
            if let savedDecision = decisionStore.getDecision(for: pattern) {
                updatedGroup.userDecision = savedDecision
                history.log(
                    source: "Deduplicator",
                    action: "appliedSavedPreference",
                    details: "\(savedDecision.rawValue) for pattern \(pattern)"
                )
            }
            
            return updatedGroup
        }
    }
    
    /// Generate a pattern hash for similar duplicate groups
    private func generatePattern(for group: DuplicateGroup) -> String {
        // Create a pattern based on match characteristics
        var components: [String] = []
        
        components.append("type:\(group.groupType.rawValue)")
        components.append("score:\(group.matchScore / 10 * 10)") // Round to nearest 10
        components.append("reason:\(group.matchReason)")
        components.append("count:\(group.contacts.count)")
        
        return components.joined(separator: "|")
    }
}

// MARK: - Auto-Merge Safety

extension ContactDeduplicator {
    
    /// Check if a group is safe to auto-merge
    func isSafeToAutoMerge(_ group: DuplicateGroup) -> Bool {
        // Never auto-merge if score is below threshold
        guard group.matchScore >= config.autoMergeThreshold else {
            return false
        }
        
        // Never auto-merge large groups
        guard group.contacts.count <= config.maxAutoMergeGroupSize else {
            return false
        }
        
        // Check for key field conflicts
        let preview = generateMergePreview(for: group)
        
        // Don't auto-merge if there are conflicts in critical fields
        if preview.hasConflicts {
            let criticalConflicts = preview.changes.filter { change in
                change.isConflict && (
                    change.fieldName == "First Name" ||
                    change.fieldName == "Last Name" ||
                    change.fieldName == "Organization"
                )
            }
            
            if !criticalConflicts.isEmpty {
                return false
            }
        }
        
        return true
    }
}
