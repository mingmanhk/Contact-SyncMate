//
//  UnifiedContact.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation

/// Unified contact model that can represent both Google and Mac contacts
/// Used internally by the sync engine for mapping and comparison
struct UnifiedContact: Identifiable, Equatable {
    let id: UUID
    
    // Source identifiers
    var googleResourceName: String?
    var macContactIdentifier: String?
    
    // Name
    var givenName: String?
    var middleName: String?
    var familyName: String?
    var namePrefix: String?
    var nameSuffix: String?
    var nickname: String?
    var phoneticGivenName: String?
    var phoneticMiddleName: String?
    var phoneticFamilyName: String?
    
    // Organization
    var organizationName: String?
    var department: String?
    var jobTitle: String?
    
    // Multi-value fields
    var phoneNumbers: [PhoneNumber] = []
    var emailAddresses: [EmailAddress] = []
    var postalAddresses: [PostalAddress] = []
    var urls: [Url] = []
    
    // Other
    var birthday: DateComponents?
    var note: String?
    var photoData: Data?
    
    // Metadata
    var lastModified: Date?
    
    // MARK: - Computed Properties
    
    var displayName: String {
        var components: [String] = []
        if let prefix = namePrefix { components.append(prefix) }
        if let given = givenName { components.append(given) }
        if let middle = middleName { components.append(middle) }
        if let family = familyName { components.append(family) }
        if let suffix = nameSuffix { components.append(suffix) }
        
        let fullName = components.joined(separator: " ")
        return fullName.isEmpty ? (emailAddresses.first?.value ?? "Unknown Contact") : fullName
    }
    
    var primaryEmail: String? {
        emailAddresses.first?.value
    }
    
    var primaryPhone: String? {
        phoneNumbers.first?.value
    }
    
    // MARK: - Equatable
    
    static func == (lhs: UnifiedContact, rhs: UnifiedContact) -> Bool {
        // Two contacts are equal if their content is the same
        // (ignoring IDs and source identifiers)
        return lhs.givenName == rhs.givenName &&
               lhs.middleName == rhs.middleName &&
               lhs.familyName == rhs.familyName &&
               lhs.namePrefix == rhs.namePrefix &&
               lhs.nameSuffix == rhs.nameSuffix &&
               lhs.nickname == rhs.nickname &&
               lhs.organizationName == rhs.organizationName &&
               lhs.department == rhs.department &&
               lhs.jobTitle == rhs.jobTitle &&
               lhs.phoneNumbers == rhs.phoneNumbers &&
               lhs.emailAddresses == rhs.emailAddresses &&
               lhs.postalAddresses == rhs.postalAddresses &&
               lhs.urls == rhs.urls &&
               lhs.birthday == rhs.birthday &&
               lhs.note == rhs.note
        // Deliberately omitting photoData for performance
    }
}

// MARK: - Nested Types

extension UnifiedContact {
    struct PhoneNumber: Equatable, Hashable {
        var value: String
        var label: String?
        
        var normalizedValue: String {
            // Remove common formatting characters
            value.filter { $0.isNumber || $0 == "+" }
        }
    }
    
    struct EmailAddress: Equatable, Hashable {
        var value: String
        var label: String?
        
        var normalizedValue: String {
            value.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }
    
    struct PostalAddress: Equatable, Hashable {
        var street: String?
        var city: String?
        var state: String?
        var postalCode: String?
        var country: String?
        var countryCode: String?
        var label: String?
        
        var formattedAddress: String {
            var components: [String] = []
            if let street = street { components.append(street) }
            if let city = city { components.append(city) }
            if let state = state { components.append(state) }
            if let postalCode = postalCode { components.append(postalCode) }
            if let country = country { components.append(country) }
            return components.joined(separator: ", ")
        }
    }
    
    struct Url: Equatable, Hashable {
        var value: String
        var label: String?
    }
}

// MARK: - Matching & Duplicate Detection

extension UnifiedContact {
    /// Calculate a similarity score between two contacts (0.0 to 1.0)
    func similarityScore(to other: UnifiedContact) -> Double {
        var score = 0.0
        var totalWeight = 0.0
        
        // Name matching (highest weight)
        let nameWeight = 3.0
        if let myName = givenName?.lowercased(), let otherName = other.givenName?.lowercased() {
            if myName == otherName {
                score += nameWeight
            } else if myName.contains(otherName) || otherName.contains(myName) {
                score += nameWeight * 0.5
            }
        }
        totalWeight += nameWeight
        
        if let myFamily = familyName?.lowercased(), let otherFamily = other.familyName?.lowercased() {
            if myFamily == otherFamily {
                score += nameWeight
            } else if myFamily.contains(otherFamily) || otherFamily.contains(myFamily) {
                score += nameWeight * 0.5
            }
        }
        totalWeight += nameWeight
        
        // Email matching (high weight)
        let emailWeight = 2.5
        let myEmails = Set(emailAddresses.map { $0.normalizedValue })
        let otherEmails = Set(other.emailAddresses.map { $0.normalizedValue })
        let emailIntersection = myEmails.intersection(otherEmails)
        if !emailIntersection.isEmpty {
            score += emailWeight
        }
        totalWeight += emailWeight
        
        // Phone matching (high weight)
        let phoneWeight = 2.0
        let myPhones = Set(phoneNumbers.map { $0.normalizedValue })
        let otherPhones = Set(other.phoneNumbers.map { $0.normalizedValue })
        let phoneIntersection = myPhones.intersection(otherPhones)
        if !phoneIntersection.isEmpty {
            score += phoneWeight
        }
        totalWeight += phoneWeight
        
        // Organization matching (medium weight)
        let orgWeight = 1.0
        if let myOrg = organizationName?.lowercased(), let otherOrg = other.organizationName?.lowercased() {
            if myOrg == otherOrg {
                score += orgWeight
            }
        }
        totalWeight += orgWeight
        
        return score / totalWeight
    }
    
    /// Check if this contact is likely a duplicate of another
    func isDuplicateOf(_ other: UnifiedContact, threshold: Double = 0.7) -> Bool {
        return similarityScore(to: other) >= threshold
    }
}

// MARK: - Merging

extension UnifiedContact {
    /// Merge another contact into this one
    /// - Parameters:
    ///   - other: The contact to merge from
    ///   - preferOther: If true, prefer non-nil values from other contact
    /// - Returns: A new merged contact
    func merging(with other: UnifiedContact, preferOther: Bool = false) -> UnifiedContact {
        var merged = self
        
        // Simple merge strategy: prefer non-nil values
        // If both have values, prefer based on preferOther flag
        
        func choose<T>(_ mine: T?, _ theirs: T?) -> T? {
            if preferOther {
                return theirs ?? mine
            } else {
                return mine ?? theirs
            }
        }
        
        // Name fields
        merged.givenName = choose(givenName, other.givenName)
        merged.middleName = choose(middleName, other.middleName)
        merged.familyName = choose(familyName, other.familyName)
        merged.namePrefix = choose(namePrefix, other.namePrefix)
        merged.nameSuffix = choose(nameSuffix, other.nameSuffix)
        merged.nickname = choose(nickname, other.nickname)
        merged.phoneticGivenName = choose(phoneticGivenName, other.phoneticGivenName)
        merged.phoneticMiddleName = choose(phoneticMiddleName, other.phoneticMiddleName)
        merged.phoneticFamilyName = choose(phoneticFamilyName, other.phoneticFamilyName)
        
        // Organization
        merged.organizationName = choose(organizationName, other.organizationName)
        merged.department = choose(department, other.department)
        merged.jobTitle = choose(jobTitle, other.jobTitle)
        
        // Multi-value fields: union of both (removing duplicates)
        merged.phoneNumbers = Array(Set(phoneNumbers + other.phoneNumbers))
        merged.emailAddresses = Array(Set(emailAddresses + other.emailAddresses))
        merged.postalAddresses = Array(Set(postalAddresses + other.postalAddresses))
        merged.urls = Array(Set(urls + other.urls))
        
        // Other
        merged.birthday = choose(birthday, other.birthday)
        merged.note = mergeNotes(note, other.note)
        merged.photoData = choose(photoData, other.photoData)
        
        // Metadata: prefer most recent
        if let myDate = lastModified, let theirDate = other.lastModified {
            merged.lastModified = max(myDate, theirDate)
        } else {
            merged.lastModified = lastModified ?? other.lastModified
        }
        
        return merged
    }
    
    private func mergeNotes(_ note1: String?, _ note2: String?) -> String? {
        switch (note1, note2) {
        case (nil, nil): return nil
        case (let n?, nil): return n
        case (nil, let n?): return n
        case (let n1?, let n2?):
            if n1 == n2 {
                return n1
            } else {
                return n1 + "\n\n---\n\n" + n2
            }
        }
    }
}
