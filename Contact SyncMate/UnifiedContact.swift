//
//  UnifiedContact.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation

extension String {
    /// The trimmed string, or nil when it holds nothing but whitespace.
    ///
    /// Providers disagree about how to say "missing" — Google omits the key,
    /// Contacts hands back "". Treating both as absent stops empty strings from
    /// masquerading as real values.
    ///
    /// `nonisolated`: the project builds with default MainActor isolation, which
    /// would otherwise pin this to the main actor and make it unusable from the
    /// off-main paths — the Contacts write queue, the batch pre-pass, the
    /// country normaliser. It is a pure function of `self` on a value type, so
    /// there is nothing for the isolation to protect.
    nonisolated var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
    /// Where Google keeps this contact's photo, when the contact came from
    /// Google and carries a real (non-default) photo. The bytes are downloaded
    /// just in time by the Google → Mac apply path — carrying the URL through
    /// the diff lets "Google has a photo the Mac lacks" be detected without
    /// downloading every photo up front.
    var photoUrl: String?

    // Metadata
    var lastModified: Date?
    
    // MARK: - Computed Properties
    
    var displayName: String {
        // Trimmed, and empty parts dropped before joining.
        //
        // `if let given = givenName` succeeds for an *empty string* — it is
        // non-nil — so a contact whose name fields are all "" produced
        // components ["", ""], joined to " ". A single space is not `.isEmpty`,
        // so the fallback below never fired and the contact appeared in logs and
        // sync previews as blank whitespace.
        let components = [namePrefix, givenName, middleName, familyName, nameSuffix]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !components.isEmpty {
            return components.joined(separator: " ")
        }

        // Fall back through anything that identifies the person, widest first.
        // Phone and organisation were missing: a contact holding only a number is
        // perfectly ordinary, and showing it beats "Unknown Contact".
        if let email = emailAddresses.first?.value.nonBlank { return email }
        if let phone = phoneNumbers.first?.value.nonBlank { return phone }
        if let org = organizationName?.nonBlank { return org }
        if let nickname = nickname?.nonBlank { return nickname }
        return "Unnamed contact"
    }

    /// Whether this contact carries anything worth syncing.
    ///
    /// A record with no name, no phone, no email and no organisation is an empty
    /// row — usually a stray created by another app. Pushing it to Google makes a
    /// permanent blank contact there, so the diff skips it instead.
    var hasSyncableContent: Bool {
        let hasName = [namePrefix, givenName, middleName, familyName, nameSuffix, nickname]
            .contains { $0?.nonBlank != nil }
        return hasName
            || !phoneNumbers.isEmpty
            || !emailAddresses.isEmpty
            || !postalAddresses.isEmpty
            || organizationName?.nonBlank != nil
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

    
    // isDuplicateOf and similarityScore lived here. Matching goes through
    // ContactDeduplicator and AIContactMatcher; these were a third,
    // unreferenced scoring implementation.
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
        merged.photoUrl = choose(photoUrl, other.photoUrl)
        
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
