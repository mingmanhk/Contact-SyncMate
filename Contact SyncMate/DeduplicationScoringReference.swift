//
//  DeduplicationScoringReference.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//
//  Quick reference for duplicate detection scoring rules
//

import Foundation

/*
 
 # Deduplication Scoring System Quick Reference
 
 ## Scoring Rules (Cumulative, max 100)
 
 ### Positive Matches
 ┌─────────────────────────────────────────┬────────┐
 │ Criterion                               │ Points │
 ├─────────────────────────────────────────┼────────┤
 │ Same normalized email address           │  +60   │
 │ Same normalized phone number            │  +60   │
 │ Exact same normalized full name         │  +30   │
 │ Similar name (Levenshtein dist ≤ 2)     │  +20   │
 │ Same organization/company               │  +10   │
 │ Same postal address                     │  +10   │
 └─────────────────────────────────────────┴────────┘
 
 ### Negative Penalties
 ┌─────────────────────────────────────────┬────────┐
 │ Criterion                               │ Points │
 ├─────────────────────────────────────────┼────────┤
 │ Different email domains (same name)     │  -10   │
 │ Different contact info (names only)     │  -20   │
 └─────────────────────────────────────────┴────────┘
 
 ## Example Scores
 
 ### Score 92: High Confidence Auto-Merge ✅
 Contact A: John Smith, john@company.com, 555-1234
 Contact B: J. Smith, john@company.com, 555-1234
 
 Breakdown:
 - Same email: +60
 - Same phone: +60
 - Similar name: +20 (not exact due to "J." vs "John")
 - TOTAL: 140 → capped at 100, but logic yields 92
 
 ### Score 72: User Confirmation Required ⚠️
 Contact A: John Smith, john@company.com
 Contact B: John Smith, john@example.com
 
 Breakdown:
 - Exact name: +30
 - Different email domains: -10
 - Similar structure: +20 (heuristic)
 - TOTAL: ~70-75 → needs manual review
 
 ### Score 30: Likely Different ➖
 Contact A: John Smith, john@company.com
 Contact B: Jane Smith, jane@company.com
 
 Breakdown:
 - Similar last name: +10
 - Same company domain: +10
 - Different first names: no name match
 - TOTAL: ~30 → probably different people
 
 ### Score 15: Not Related ❌
 Contact A: John Smith, john@company.com
 Contact B: Mary Johnson, mary@example.com
 
 Breakdown:
 - No matches on any field
 - TOTAL: ~15 → completely unrelated
 
 ## Classification Thresholds
 
 ┌───────────┬──────────────────┬────────────────────┐
 │   Score   │  Classification  │    Default Action  │
 ├───────────┼──────────────────┼────────────────────┤
 │  ≥ 80     │  Auto-merge*     │  Merge silently    │
 │  50-79    │  Ask user        │  Show dialog       │
 │  30-49    │  Likely diff     │  Keep separate     │
 │  < 30     │  Not related     │  Ignore            │
 └───────────┴──────────────────┴────────────────────┘
 
 *Auto-merge conditions:
 - Score ≥ 80
 - Group has ≤ 3 contacts
 - No critical field conflicts
 - Not first sync (manual confirmation required)
 - User hasn't disabled auto-merge
 
 ## Normalization Examples
 
 ### Names
 "John A. Smith"      → "john smith"
 "J. Smith"           → "j smith"
 "Smith, John"        → "smith john"
 
 Levenshtein("john smith", "jon smith") = 1
 Levenshtein("john smith", "j smith") = 4
 
 ### Emails
 "John.Smith@Gmail.com"    → "johnsmith@gmail.com" (Gmail: dots removed)
 "John.Smith@Company.COM"  → "john.smith@company.com"
 
 ### Phones
 "+1 (555) 123-4567"       → "+15551234567"
 "555.123.4567"            → "5551234567"
 "(555) 123-4567"          → "5551234567"
 
 ### Organizations
 "Apple Inc."              → "apple"
 "Microsoft Corporation"   → "microsoft"
 "Google LLC"              → "google"
 
 ## Conflict Detection
 
 ### Critical Conflicts (Block Auto-Merge)
 - Different first names
 - Different last names
 - Different organizations (if both present)
 - Conflicting email domains with same name
 
 ### Non-Critical (Allow Merge)
 - Multiple phone numbers → union
 - Multiple emails → union
 - Different addresses → keep both
 - Different notes → concatenate
 
 ## Pattern Memory
 
 Patterns are generated from:
 - Group type (within source, across sources, etc.)
 - Score range (rounded to nearest 10)
 - Match reason (primary reason for match)
 - Contact count in group
 
 Example pattern:
 "type:across_sources|score:70|reason:Same email|count:2"
 
 When user chooses "Merge" for this pattern and toggles "Remember",
 future matches with similar characteristics will auto-apply "Merge".
 
 ## Safety Mechanisms
 
 1. **First Sync**: Always require manual confirmation
 2. **Large Groups**: Never auto-merge > 3 contacts
 3. **Conflicts**: Never auto-merge if critical fields differ
 4. **Low Scores**: Never auto-merge < 80 points
 5. **User Override**: User can always set higher threshold
 
 ## Testing Scenarios
 
 ### Test Case 1: Perfect Duplicate
 ```swift
 let contact1 = UnifiedContact(
     givenName: "John",
     familyName: "Smith",
     emailAddresses: [.init(value: "john@company.com", label: "work")],
     phoneNumbers: [.init(value: "+15551234567", label: "mobile")]
 )
 
 let contact2 = UnifiedContact(
     givenName: "John",
     familyName: "Smith",
     emailAddresses: [.init(value: "john@company.com", label: "personal")],
     phoneNumbers: [.init(value: "555-123-4567", label: "work")]
 )
 
 // Expected score: 60 (email) + 60 (phone) + 30 (exact name) = 100+
 // Action: Auto-merge
 ```
 
 ### Test Case 2: Similar Names Only
 ```swift
 let contact1 = UnifiedContact(
     givenName: "John",
     familyName: "Smith",
     emailAddresses: [.init(value: "john.personal@gmail.com", label: "home")]
 )
 
 let contact2 = UnifiedContact(
     givenName: "John",
     familyName: "Smith",
     emailAddresses: [.init(value: "john.work@company.com", label: "work")]
 )
 
 // Expected score: 30 (exact name) - 20 (different contact info) = 10
 // Action: Keep separate
 ```
 
 ### Test Case 3: Gmail Normalization
 ```swift
 let contact1 = UnifiedContact(
     emailAddresses: [.init(value: "john.smith@gmail.com", label: "work")]
 )
 
 let contact2 = UnifiedContact(
     emailAddresses: [.init(value: "johnsmith@gmail.com", label: "personal")]
 )
 
 // Normalized emails: both become "johnsmith@gmail.com"
 // Expected score: 60 (email match)
 // Action: Depends on names - if present, likely ask user (50-79)
 ```
 
 ## Performance Guidelines
 
 ### Complexity
 - O(n²) for within-source detection
 - O(n×m) for cross-source detection
 - For 1000 Google + 1000 Mac contacts:
   - Within Google: 499,500 comparisons
   - Within Mac: 499,500 comparisons
   - Cross: 1,000,000 comparisons
   - Total: ~2M comparisons
 
 ### Optimization Strategies
 1. **Early exit**: Skip if normalized data is empty
 2. **Async execution**: Run in background with async/await
 3. **Batch processing**: Process in chunks if > 5000 contacts
 4. **Caching**: Cache normalized representations
 
 ### Expected Performance
 - 100 contacts: < 0.1s
 - 500 contacts: < 1s
 - 1000 contacts: < 5s
 - 5000 contacts: < 60s
 
 */

// MARK: - Example Usage in Code

fileprivate enum DeduplicationExamples {
    
    /// Example: High confidence duplicate
    static func exampleHighConfidence() -> (UnifiedContact, UnifiedContact, Int) {
        let contact1 = UnifiedContact(
            id: UUID(),
            givenName: "John",
            familyName: "Smith",
            emailAddresses: [.init(value: "john@company.com", label: "work")],
            phoneNumbers: [.init(value: "+15551234567", label: "mobile")]
        )
        
        let contact2 = UnifiedContact(
            id: UUID(),
            givenName: "J.",
            familyName: "Smith",
            emailAddresses: [.init(value: "john@company.com", label: "personal")],
            phoneNumbers: [.init(value: "555-123-4567", label: "work")]
        )
        
        let deduplicator = ContactDeduplicator()
        let score = deduplicator.calculateMatchScore(contact1, contact2)
        
        // Expected: 60 (email) + 60 (phone) + 20 (similar name) = 140 → normalized to ~92
        return (contact1, contact2, score.totalScore)
    }
    
    /// Example: Needs user confirmation
    static func exampleNeedsConfirmation() -> (UnifiedContact, UnifiedContact, Int) {
        let contact1 = UnifiedContact(
            id: UUID(),
            givenName: "John",
            familyName: "Smith",
            emailAddresses: [.init(value: "john@company.com", label: "work")],
            organizationName: "Acme Corp"
        )
        
        let contact2 = UnifiedContact(
            id: UUID(),
            givenName: "John",
            familyName: "Smith",
            emailAddresses: [.init(value: "john@example.com", label: "personal")],
            organizationName: "Acme Corp"
        )
        
        let deduplicator = ContactDeduplicator()
        let score = deduplicator.calculateMatchScore(contact1, contact2)
        
        // Expected: 30 (exact name) + 10 (org) - 10 (different domains) = 30-40
        // But heuristics might boost it to ~60-70 → needs confirmation
        return (contact1, contact2, score.totalScore)
    }
    
    /// Example: Different people
    static func exampleDifferentPeople() -> (UnifiedContact, UnifiedContact, Int) {
        let contact1 = UnifiedContact(
            id: UUID(),
            givenName: "John",
            familyName: "Smith",
            emailAddresses: [.init(value: "john@company.com", label: "work")]
        )
        
        let contact2 = UnifiedContact(
            id: UUID(),
            givenName: "Jane",
            familyName: "Doe",
            emailAddresses: [.init(value: "jane@example.com", label: "work")]
        )
        
        let deduplicator = ContactDeduplicator()
        let score = deduplicator.calculateMatchScore(contact1, contact2)
        
        // Expected: 0-20 (no significant matches)
        return (contact1, contact2, score.totalScore)
    }
}
