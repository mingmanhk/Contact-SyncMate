//
//  ContactNormalizer.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation

/// Utility for normalizing contact fields for comparison
enum ContactNormalizer {
    
    // MARK: - Name Normalization
    
    /// Normalize a name for comparison
    /// - Converts to lowercase
    /// - Removes punctuation
    /// - Removes middle initials
    /// - Trims whitespace
    static func normalizeName(_ name: String?) -> String {
        guard let name = name else { return "" }
        
        var normalized = name.lowercased()
        
        // Remove punctuation
        let punctuation = CharacterSet.punctuationCharacters
        normalized = normalized.components(separatedBy: punctuation).joined()
        
        // Remove extra whitespace
        normalized = normalized.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        // Remove single-letter middle initials
        let components = normalized.split(separator: " ")
        let filtered = components.filter { $0.count > 1 || components.count <= 2 }
        normalized = filtered.joined(separator: " ")
        
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Create a full normalized name from components
    static func normalizeFullName(given: String?, middle: String?, family: String?) -> String {
        let components = [given, middle, family]
            .compactMap { $0 }
            .map { normalizeName($0) }
            .filter { !$0.isEmpty }
        
        return components.joined(separator: " ")
    }
    
    // MARK: - Email Normalization
    
    /// Normalize an email address for comparison
    /// - Converts to lowercase
    /// - Trims whitespace
    /// - Removes dots before @ for Gmail addresses (john.smith@gmail.com ≈ johnsmith@gmail.com)
    static func normalizeEmail(_ email: String?) -> String {
        guard let email = email else { return "" }
        
        let normalized = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Special handling for Gmail: remove dots before @
        if normalized.contains("@gmail.com") || normalized.contains("@googlemail.com") {
            let parts = normalized.split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                let localPart = String(parts[0]).replacingOccurrences(of: ".", with: "")
                let domain = String(parts[1])
                return "\(localPart)@\(domain)"
            }
        }
        
        return normalized
    }
    
    /// Normalize a collection of emails
    static func normalizeEmails(_ emails: [String]) -> Set<String> {
        return Set(emails.map { normalizeEmail($0) }.filter { !$0.isEmpty })
    }
    
    // MARK: - Phone Normalization
    
    /// Normalize a phone number for comparison
    /// - Extracts digits only
    /// - Keeps leading + for international numbers
    /// - Example: +1 (555) 123-4567 → +15551234567
    static func normalizePhone(_ phone: String?) -> String {
        guard let phone = phone else { return "" }
        
        var normalized = ""
        var hasPlus = false
        
        for char in phone {
            if char == "+" && normalized.isEmpty {
                hasPlus = true
                normalized.append(char)
            } else if char.isNumber {
                normalized.append(char)
            }
        }
        
        // If no digits extracted, return empty
        if normalized == "+" || (!hasPlus && normalized.isEmpty) {
            return ""
        }
        
        return normalized
    }
    
    /// Normalize a collection of phone numbers
    static func normalizePhones(_ phones: [String]) -> Set<String> {
        return Set(phones.map { normalizePhone($0) }.filter { !$0.isEmpty })
    }
    
    // MARK: - Organization Normalization
    
    /// Normalize organization/company name
    /// - Converts to lowercase
    /// - Removes common suffixes (Inc, LLC, Corp, etc.)
    /// - Trims whitespace
    static func normalizeOrganization(_ org: String?) -> String {
        guard let org = org else { return "" }
        
        var normalized = org.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common company suffixes
        let suffixes = [
            " inc", " inc.", " incorporated",
            " llc", " l.l.c.", " l.l.c",
            " corp", " corp.", " corporation",
            " ltd", " ltd.", " limited",
            " co", " co.", " company",
            " plc", " plc."
        ]
        
        for suffix in suffixes {
            if normalized.hasSuffix(suffix) {
                normalized = String(normalized.dropLast(suffix.count))
                break
            }
        }
        
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Address Normalization
    
    /// Normalize a postal address for comparison
    static func normalizeAddress(street: String?, city: String?, state: String?, postalCode: String?, country: String?) -> String {
        let components = [street, city, state, postalCode, country]
            .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        return components.joined(separator: " ")
    }
    
    // MARK: - String Similarity
    
    /// Calculate Levenshtein distance between two strings
    /// Used for fuzzy name matching
    static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1 = Array(s1)
        let s2 = Array(s2)
        
        var dist = Array(repeating: Array(repeating: 0, count: s2.count + 1), count: s1.count + 1)
        
        for i in 0...s1.count {
            dist[i][0] = i
        }
        
        for j in 0...s2.count {
            dist[0][j] = j
        }
        
        for i in 1...s1.count {
            for j in 1...s2.count {
                let cost = s1[i - 1] == s2[j - 1] ? 0 : 1
                dist[i][j] = min(
                    dist[i - 1][j] + 1,      // deletion
                    dist[i][j - 1] + 1,      // insertion
                    dist[i - 1][j - 1] + cost // substitution
                )
            }
        }
        
        return dist[s1.count][s2.count]
    }
    
    /// Check if two names are similar (allowing for small typos)
    static func areNamesSimilar(_ name1: String, _ name2: String, maxDistance: Int = 2) -> Bool {
        let n1 = normalizeName(name1)
        let n2 = normalizeName(name2)
        
        if n1.isEmpty || n2.isEmpty {
            return false
        }
        
        if n1 == n2 {
            return true
        }
        
        let distance = levenshteinDistance(n1, n2)
        return distance <= maxDistance
    }
}

// MARK: - UnifiedContact Extension for Normalization

extension UnifiedContact {
    
    /// Get normalized representation for deduplication
    var normalizedForDeduplication: NormalizedContact {
        return NormalizedContact(
            fullName: ContactNormalizer.normalizeFullName(
                given: givenName,
                middle: middleName,
                family: familyName
            ),
            givenName: ContactNormalizer.normalizeName(givenName),
            familyName: ContactNormalizer.normalizeName(familyName),
            emails: ContactNormalizer.normalizeEmails(emailAddresses.map { $0.value }),
            phones: ContactNormalizer.normalizePhones(phoneNumbers.map { $0.value }),
            organization: ContactNormalizer.normalizeOrganization(organizationName),
            address: ContactNormalizer.normalizeAddress(
                street: postalAddresses.first?.street,
                city: postalAddresses.first?.city,
                state: postalAddresses.first?.state,
                postalCode: postalAddresses.first?.postalCode,
                country: postalAddresses.first?.country
            )
        )
    }
}

/// Normalized contact fields for comparison
struct NormalizedContact {
    let fullName: String
    let givenName: String
    let familyName: String
    let emails: Set<String>
    let phones: Set<String>
    let organization: String
    let address: String
    
    var isEmpty: Bool {
        return fullName.isEmpty && emails.isEmpty && phones.isEmpty
    }
    
    var hasName: Bool {
        return !fullName.isEmpty
    }
    
    var hasContact: Bool {
        return !emails.isEmpty || !phones.isEmpty
    }
}
