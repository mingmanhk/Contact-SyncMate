//
//  DeduplicationModels.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation

// MARK: - Duplicate Group

/// Represents a group of contacts that are potential duplicates
struct DuplicateGroup: Identifiable {
    let id: UUID
    var contacts: [DuplicateCandidate]
    var matchScore: Int  // 0-100 score
    var matchReason: String
    var groupType: DuplicateGroupType
    var userDecision: DuplicateDecision?
    var detectedAt: Date
    
    init(id: UUID = UUID(),
         contacts: [DuplicateCandidate],
         matchScore: Int,
         matchReason: String,
         groupType: DuplicateGroupType,
         userDecision: DuplicateDecision? = nil,
         detectedAt: Date = Date()) {
        self.id = id
        self.contacts = contacts
        self.matchScore = matchScore
        self.matchReason = matchReason
        self.groupType = groupType
        self.userDecision = userDecision
        self.detectedAt = detectedAt
    }
    
    var shouldAutoMerge: Bool {
        return matchScore >= 80 && contacts.count <= 3
    }
    
    var shouldPromptUser: Bool {
        return matchScore >= 50 && matchScore < 80
    }
    
    var shouldKeepSeparate: Bool {
        return matchScore < 50
    }
    
    var needsUserConfirmation: Bool {
        return shouldPromptUser || (shouldAutoMerge && userDecision == nil)
    }
}

// MARK: - Duplicate Candidate

/// Represents a single contact that's part of a duplicate group
struct DuplicateCandidate: Identifiable {
    let id: UUID
    let contact: UnifiedContact
    let source: ContactSource
    
    var displayName: String {
        contact.displayName
    }
    
    var primaryEmail: String? {
        contact.primaryEmail
    }
    
    var primaryPhone: String? {
        contact.primaryPhone
    }
    
    init(id: UUID = UUID(), contact: UnifiedContact, source: ContactSource) {
        self.id = id
        self.contact = contact
        self.source = source
    }
}

// MARK: - Enums

/// Type of duplicate group based on where duplicates were found
enum DuplicateGroupType: String, Codable {
    case withinGoogle = "within_google"
    case withinMac = "within_mac"
    case acrossSources = "across_sources"
    case crossMapping = "cross_mapping"
    
    var description: String {
        switch self {
        case .withinGoogle:
            return "Within Google Contacts"
        case .withinMac:
            return "Within Mac Contacts"
        case .acrossSources:
            return "Across Google ↔ Mac"
        case .crossMapping:
            return "One-to-Many Mapping"
        }
    }
}

/// Source of a contact
enum ContactSource: String, Codable {
    case google
    case mac
    
    var displayName: String {
        switch self {
        case .google: return "Google"
        case .mac: return "Mac"
        }
    }
}

/// User's decision for a duplicate group
enum DuplicateDecision: String, Codable {
    case merge          // Combine into one contact
    case keepSeparate   // Treat as different people
    case skip           // Ignore for now
    
    var displayName: String {
        switch self {
        case .merge: return "✅ Merge as same person"
        case .keepSeparate: return "➖ Keep separate"
        case .skip: return "🚫 Ignore for now"
        }
    }
}

// MARK: - Match Score Breakdown

/// Detailed breakdown of why contacts were matched
struct MatchScoreBreakdown {
    var emailMatch: Int = 0
    var phoneMatch: Int = 0
    var exactNameMatch: Int = 0
    var similarNameMatch: Int = 0
    var organizationMatch: Int = 0
    var addressMatch: Int = 0
    var emailDomainMismatch: Int = 0
    var differentContactInfo: Int = 0
    
    var totalScore: Int {
        return max(0, emailMatch + phoneMatch + exactNameMatch + similarNameMatch +
                   organizationMatch + addressMatch + emailDomainMismatch + differentContactInfo)
    }
    
    var reasons: [String] {
        var list: [String] = []
        
        if emailMatch > 0 {
            list.append("Same email address")
        }
        if phoneMatch > 0 {
            list.append("Same phone number")
        }
        if exactNameMatch > 0 {
            list.append("Exact name match")
        }
        if similarNameMatch > 0 {
            list.append("Similar names")
        }
        if organizationMatch > 0 {
            list.append("Same company")
        }
        if addressMatch > 0 {
            list.append("Same address")
        }
        if emailDomainMismatch < 0 {
            list.append("⚠️ Different email domains")
        }
        if differentContactInfo < 0 {
            list.append("⚠️ Different contact info")
        }
        
        return list
    }
    
    var primaryReason: String {
        return reasons.first ?? "Similar contacts"
    }
}

// MARK: - Deduplication Statistics

/// Statistics about duplicate detection
struct DeduplicationStats {
    var totalContactsScanned: Int = 0
    var duplicateGroupsFound: Int = 0
    var autoMergeGroups: Int = 0
    var userConfirmationGroups: Int = 0
    var separateGroups: Int = 0
    var totalMergedContacts: Int = 0
    var scanDuration: TimeInterval = 0
    
    var summary: String {
        """
        Scanned: \(totalContactsScanned) contacts
        Found: \(duplicateGroupsFound) duplicate groups
        Auto-merge: \(autoMergeGroups)
        Needs confirmation: \(userConfirmationGroups)
        Duration: \(String(format: "%.2f", scanDuration))s
        """
    }
}

// MARK: - Deduplication Result

/// Result of a deduplication operation
struct DeduplicationResult {
    var stats: DeduplicationStats
    var duplicateGroups: [DuplicateGroup]
    var errors: [DeduplicationError]
    
    var needsUserConfirmation: Bool {
        return duplicateGroups.contains { $0.needsUserConfirmation }
    }
    
    var groupsNeedingConfirmation: [DuplicateGroup] {
        return duplicateGroups.filter { $0.needsUserConfirmation }
    }
    
    var autoMergeGroups: [DuplicateGroup] {
        return duplicateGroups.filter { $0.shouldAutoMerge && $0.userDecision == .merge }
    }
}

// MARK: - Deduplication Error

/// Error during deduplication
struct DeduplicationError: Identifiable {
    let id: UUID
    let message: String
    let contactName: String?
    let timestamp: Date
    
    init(id: UUID = UUID(),
         message: String,
         contactName: String? = nil,
         timestamp: Date = Date()) {
        self.id = id
        self.message = message
        self.contactName = contactName
        self.timestamp = timestamp
    }
}

// MARK: - Merge Preview

/// Preview of what a merged contact would look like
struct MergePreview {
    let originalContacts: [UnifiedContact]
    let mergedContact: UnifiedContact
    let changes: [MergeChange]
    
    var hasConflicts: Bool {
        return changes.contains { $0.isConflict }
    }
    
    var conflictCount: Int {
        return changes.filter { $0.isConflict }.count
    }
}

/// Individual change in a merge operation
struct MergeChange: Identifiable {
    let id: UUID
    let fieldName: String
    let values: [String]  // All different values found
    let chosenValue: String
    let isConflict: Bool
    
    init(id: UUID = UUID(),
         fieldName: String,
         values: [String],
         chosenValue: String,
         isConflict: Bool) {
        self.id = id
        self.fieldName = fieldName
        self.values = values
        self.chosenValue = chosenValue
        self.isConflict = isConflict
    }
}

// MARK: - User Preference

/// User's preference for handling similar duplicate patterns
struct DuplicatePattern: Codable, Identifiable {
    let id: UUID
    let pattern: String  // Hash of the match characteristics
    let decision: DuplicateDecision
    let createdAt: Date
    
    init(id: UUID = UUID(),
         pattern: String,
         decision: DuplicateDecision,
         createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.decision = decision
        self.createdAt = createdAt
    }
}
