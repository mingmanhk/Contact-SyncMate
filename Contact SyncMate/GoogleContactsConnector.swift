//
//  GoogleContactsConnector.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import Combine

/// Connector for Google People API
class GoogleContactsConnector: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentAccountEmail: String?
    
    private let oauthManager = GoogleOAuthManager.shared
    private var syncToken: String? // For incremental sync
    
    // Google People API base URL
    private let baseURL = "https://people.googleapis.com/v1"
    
    init() {
        // Sync auth state with OAuth manager
        isAuthenticated = oauthManager.isAuthenticated
        currentAccountEmail = oauthManager.userEmail
        
        // Observe auth changes
        oauthManager.$isAuthenticated.assign(to: &$isAuthenticated)
        oauthManager.$userEmail.assign(to: &$currentAccountEmail)
    }
    
    // MARK: - Authentication
    
    func signIn() async throws {
        try await oauthManager.signIn()
    }
    
    func signOut() {
        oauthManager.signOut()
        syncToken = nil
    }
    
    // MARK: - API Request Helper
    
    private func makeRequest(url: URL) async throws -> (Data, URLResponse) {
        let token = try await oauthManager.getValidAccessToken()
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleContactsError.networkError(NSError(domain: "InvalidResponse", code: -1))
        }
        
        // Handle specific status codes
        switch httpResponse.statusCode {
        case 200...299:
            return (data, response)
        case 401:
            throw GoogleContactsError.invalidToken
        case 429:
            throw GoogleContactsError.rateLimitExceeded
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleContactsError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }
    
    private func makeRequest(url: URL, method: String, body: Data?) async throws -> (Data, URLResponse) {
        let token = try await oauthManager.getValidAccessToken()
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleContactsError.networkError(NSError(domain: "InvalidResponse", code: -1))
        }
        
        switch httpResponse.statusCode {
        case 200...299:
            return (data, response)
        case 401:
            throw GoogleContactsError.invalidToken
        case 429:
            throw GoogleContactsError.rateLimitExceeded
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleContactsError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }
    
    // MARK: - Fetching Contacts
    
    func fetchAllContacts() async throws -> [GoogleContact] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        var allContacts: [GoogleContact] = []
        var pageToken: String?
        
        let personFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames,metadata"
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/people/me/connections")!
            var queryItems = [
                URLQueryItem(name: "personFields", value: personFields),
                URLQueryItem(name: "pageSize", value: "1000")
            ]
            
            if let pageToken = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            
            components.queryItems = queryItems
            
            let (data, _) = try await makeRequest(url: components.url!)
            let response = try JSONDecoder().decode(PeopleAPIResponse.self, from: data)
            
            if let connections = response.connections {
                allContacts.append(contentsOf: connections.compactMap { convertToPerson($0) })
            }
            
            pageToken = response.nextPageToken
        } while pageToken != nil
        
        return allContacts
    }
    
    func fetchChangedContacts(since syncToken: String) async throws -> GoogleContactsChanges {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let personFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames,metadata"
        
        var components = URLComponents(string: "\(baseURL)/people/me/connections")!
        components.queryItems = [
            URLQueryItem(name: "personFields", value: personFields),
            URLQueryItem(name: "syncToken", value: syncToken),
            URLQueryItem(name: "requestSyncToken", value: "true")
        ]
        
        let (data, _) = try await makeRequest(url: components.url!)
        let response = try JSONDecoder().decode(PeopleAPIResponse.self, from: data)
        
        let added: [GoogleContact] = []
        var updated: [GoogleContact] = []
        var deleted: [String] = []
        
        if let connections = response.connections {
            for person in connections {
                if let contact = convertToPerson(person) {
                    // Check if deleted
                    if person.metadata?.deleted == true {
                        deleted.append(contact.id)
                    } else {
                        // Determine if new or updated based on metadata
                        // For simplicity, treat all as updated in incremental sync
                        updated.append(contact)
                    }
                }
            }
        }
        
        return GoogleContactsChanges(
            added: added,
            updated: updated,
            deleted: deleted,
            newSyncToken: response.nextSyncToken ?? syncToken
        )
    }
    
    func fetchContact(resourceName: String) async throws -> GoogleContact {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let personFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames,metadata"
        
        var components = URLComponents(string: "\(baseURL)/\(resourceName)")!
        components.queryItems = [
            URLQueryItem(name: "personFields", value: personFields)
        ]
        
        let (data, _) = try await makeRequest(url: components.url!)
        let person = try JSONDecoder().decode(PeopleAPIPerson.self, from: data)
        
        guard let contact = convertToPerson(person) else {
            throw GoogleContactsError.apiError(statusCode: 404, message: "Contact not found")
        }
        
        return contact
    }
    
    // MARK: - Creating/Updating Contacts
    
    func createContact(_ contact: GoogleContact) async throws -> GoogleContact {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/people:createContact")!
        let person = convertToAPIPerson(contact)
        let body = try JSONEncoder().encode(person)
        
        let (data, _) = try await makeRequest(url: url, method: "POST", body: body)
        let createdPerson = try JSONDecoder().decode(PeopleAPIPerson.self, from: data)
        
        guard let createdContact = convertToPerson(createdPerson) else {
            throw GoogleContactsError.apiError(statusCode: 500, message: "Failed to parse created contact")
        }
        
        return createdContact
    }
    
    func updateContact(_ contact: GoogleContact) async throws -> GoogleContact {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let updateFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames"
        
        var components = URLComponents(string: "\(baseURL)/\(contact.resourceName):updateContact")!
        components.queryItems = [
            URLQueryItem(name: "updatePersonFields", value: updateFields)
        ]
        
        let person = convertToAPIPerson(contact)
        let body = try JSONEncoder().encode(person)
        
        let (data, _) = try await makeRequest(url: components.url!, method: "PATCH", body: body)
        let updatedPerson = try JSONDecoder().decode(PeopleAPIPerson.self, from: data)
        
        guard let updatedContact = convertToPerson(updatedPerson) else {
            throw GoogleContactsError.apiError(statusCode: 500, message: "Failed to parse updated contact")
        }
        
        return updatedContact
    }
    
    func deleteContact(resourceName: String) async throws {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/\(resourceName):deleteContact")!
        _ = try await makeRequest(url: url, method: "DELETE", body: nil)
    }
    
    // MARK: - Batch Operations
    
    func batchCreateContacts(_ contacts: [GoogleContact]) async throws -> [GoogleContact] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        // Split into chunks of 200 (API limit)
        var results: [GoogleContact] = []
        let chunkSize = 200
        
        for chunk in stride(from: 0, to: contacts.count, by: chunkSize) {
            let endIndex = min(chunk + chunkSize, contacts.count)
            let contactChunk = Array(contacts[chunk..<endIndex])
            
            let batchResult = try await batchCreateChunk(contactChunk)
            results.append(contentsOf: batchResult)
        }
        
        return results
    }
    
    private func batchCreateChunk(_ contacts: [GoogleContact]) async throws -> [GoogleContact] {
        let url = URL(string: "\(baseURL)/people:batchCreateContacts")!
        
        let requests = contacts.map { contact -> [String: Any] in
            let person = convertToAPIPerson(contact)
            return ["contactPerson": person]
        }
        
        let bodyDict: [String: Any] = ["contacts": requests]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        
        let (data, _) = try await makeRequest(url: url, method: "POST", body: body)
        let response = try JSONDecoder().decode(BatchCreateResponse.self, from: data)
        
        return response.createdPeople.compactMap { convertToPerson($0.person) }
    }
    
    func batchUpdateContacts(_ contacts: [GoogleContact]) async throws -> [GoogleContact] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        // Split into chunks of 200 (API limit)
        var results: [GoogleContact] = []
        let chunkSize = 200
        
        for chunk in stride(from: 0, to: contacts.count, by: chunkSize) {
            let endIndex = min(chunk + chunkSize, contacts.count)
            let contactChunk = Array(contacts[chunk..<endIndex])
            
            let batchResult = try await batchUpdateChunk(contactChunk)
            results.append(contentsOf: batchResult)
        }
        
        return results
    }
    
    private func batchUpdateChunk(_ contacts: [GoogleContact]) async throws -> [GoogleContact] {
        let url = URL(string: "\(baseURL)/people:batchUpdateContacts")!
        
        let updateFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames"
        
        let requests = contacts.map { contact -> [String: Any] in
            let person = convertToAPIPerson(contact)
            return [
                "resourceName": contact.resourceName,
                "person": person,
                "updatePersonFields": updateFields
            ]
        }
        
        let bodyDict: [String: Any] = ["contacts": requests]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        
        let (data, _) = try await makeRequest(url: url, method: "POST", body: body)
        let response = try JSONDecoder().decode(BatchUpdateResponse.self, from: data)
        
        return response.updateResult.compactMap { convertToPerson($0.person) }
    }
    
    func batchDeleteContacts(resourceNames: [String]) async throws {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        // Split into chunks of 500 (API limit)
        let chunkSize = 500
        
        for chunk in stride(from: 0, to: resourceNames.count, by: chunkSize) {
            let endIndex = min(chunk + chunkSize, resourceNames.count)
            let nameChunk = Array(resourceNames[chunk..<endIndex])
            
            try await batchDeleteChunk(nameChunk)
        }
    }
    
    private func batchDeleteChunk(_ resourceNames: [String]) async throws {
        let url = URL(string: "\(baseURL)/people:batchDeleteContacts")!
        
        let bodyDict: [String: Any] = ["resourceNames": resourceNames]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        
        _ = try await makeRequest(url: url, method: "POST", body: body)
    }
    
    // MARK: - Contact Groups (Labels)
    
    func fetchContactGroups() async throws -> [GoogleContactGroup] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/contactGroups")!
        let (data, _) = try await makeRequest(url: url)
        let response = try JSONDecoder().decode(ContactGroupsResponse.self, from: data)
        
        return response.contactGroups.map { group in
            GoogleContactGroup(
                id: group.resourceName,
                name: group.name,
                memberCount: group.memberCount
            )
        }
    }
    
    // MARK: - Duplicate Detection
    
    func searchDuplicates() async throws -> [GoogleDuplicateSet] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        // Note: Google doesn't have a direct duplicate detection API
        // We'll fetch all contacts and detect duplicates locally
        let contacts = try await fetchAllContacts()
        return detectDuplicatesLocally(contacts)
    }
    
    private func detectDuplicatesLocally(_ contacts: [GoogleContact]) -> [GoogleDuplicateSet] {
        var duplicateSets: [GoogleDuplicateSet] = []
        var processedIDs = Set<String>()
        
        for contact in contacts {
            guard !processedIDs.contains(contact.id) else { continue }
            
            var duplicates = [contact]
            processedIDs.insert(contact.id)
            
            // Find duplicates by name or email
            for otherContact in contacts {
                guard !processedIDs.contains(otherContact.id) else { continue }
                
                if isDuplicate(contact, otherContact) {
                    duplicates.append(otherContact)
                    processedIDs.insert(otherContact.id)
                }
            }
            
            if duplicates.count > 1 {
                duplicateSets.append(GoogleDuplicateSet(contacts: duplicates))
            }
        }
        
        return duplicateSets
    }
    
    private func isDuplicate(_ contact1: GoogleContact, _ contact2: GoogleContact) -> Bool {
        // Check if names match
        if let name1 = contact1.givenName?.lowercased(),
           let name2 = contact2.givenName?.lowercased(),
           let family1 = contact1.familyName?.lowercased(),
           let family2 = contact2.familyName?.lowercased(),
           name1 == name2 && family1 == family2 {
            return true
        }
        
        // Check if emails match
        let emails1 = Set(contact1.emailAddresses.map { $0.value.lowercased() })
        let emails2 = Set(contact2.emailAddresses.map { $0.value.lowercased() })
        
        if !emails1.isEmpty && !emails2.isEmpty && !emails1.isDisjoint(with: emails2) {
            return true
        }
        
        return false
    }
    
    // MARK: - Conversion Helpers
    
    private func convertToPerson(_ apiPerson: PeopleAPIPerson) -> GoogleContact? {
        guard let resourceName = apiPerson.resourceName else { return nil }
        
        var contact = GoogleContact(id: resourceName)
        contact.etag = apiPerson.etag
        
        // Names
        if let names = apiPerson.names?.first {
            contact.givenName = names.givenName
            contact.middleName = names.middleName
            contact.familyName = names.familyName
            contact.namePrefix = names.honorificPrefix
            contact.nameSuffix = names.honorificSuffix
        }
        
        // Nicknames
        if let nickname = apiPerson.nicknames?.first {
            contact.nickname = nickname.value
        }
        
        // Organization
        if let org = apiPerson.organizations?.first {
            contact.organizationName = org.name
            contact.department = org.department
            contact.jobTitle = org.title
        }
        
        // Phone numbers
        contact.phoneNumbers = apiPerson.phoneNumbers?.map { phone in
            GooglePhoneNumber(value: phone.value, type: phone.type, label: phone.formattedType)
        } ?? []
        
        // Email addresses
        contact.emailAddresses = apiPerson.emailAddresses?.map { email in
            GoogleEmailAddress(value: email.value, type: email.type, label: email.formattedType)
        } ?? []
        
        // Addresses
        contact.addresses = apiPerson.addresses?.map { address in
            GoogleAddress(
                formattedValue: address.formattedValue,
                streetAddress: address.streetAddress,
                city: address.city,
                region: address.region,
                postalCode: address.postalCode,
                country: address.country,
                countryCode: address.countryCode,
                type: address.type,
                label: address.formattedType
            )
        } ?? []
        
        // URLs
        contact.urls = apiPerson.urls?.map { url in
            GoogleUrl(value: url.value, type: url.type, label: url.formattedType)
        } ?? []
        
        // Birthday
        if let birthday = apiPerson.birthdays?.first?.date {
            contact.birthday = GoogleDate(year: birthday.year, month: birthday.month, day: birthday.day)
        }
        
        // Photo
        if let photo = apiPerson.photos?.first {
            contact.photoUrl = photo.url
        }
        
        // Note
        if let bio = apiPerson.biographies?.first {
            contact.note = bio.value
        }
        
        // Update time
        if let metadata = apiPerson.metadata,
           let updateTime = metadata.sources?.first?.updateTime {
            contact.updateTime = ISO8601DateFormatter().date(from: updateTime)
        }
        
        return contact
    }
    
    private func convertToAPIPerson(_ contact: GoogleContact) -> PeopleAPIPerson {
        var person = PeopleAPIPerson(resourceName: contact.resourceName)
        person.etag = contact.etag
        
        // Names
        if contact.givenName != nil || contact.familyName != nil {
            person.names = [
                PersonName(
                    givenName: contact.givenName,
                    middleName: contact.middleName,
                    familyName: contact.familyName,
                    honorificPrefix: contact.namePrefix,
                    honorificSuffix: contact.nameSuffix
                )
            ]
        }
        
        // Nickname
        if let nickname = contact.nickname {
            person.nicknames = [PersonNickname(value: nickname)]
        }
        
        // Organization
        if contact.organizationName != nil || contact.jobTitle != nil {
            person.organizations = [
                PersonOrganization(
                    name: contact.organizationName,
                    department: contact.department,
                    title: contact.jobTitle
                )
            ]
        }
        
        // Phone numbers
        if !contact.phoneNumbers.isEmpty {
            person.phoneNumbers = contact.phoneNumbers.map { phone in
                PersonPhoneNumber(value: phone.value, type: phone.type)
            }
        }
        
        // Email addresses
        if !contact.emailAddresses.isEmpty {
            person.emailAddresses = contact.emailAddresses.map { email in
                PersonEmailAddress(value: email.value, type: email.type)
            }
        }
        
        // Addresses
        if !contact.addresses.isEmpty {
            person.addresses = contact.addresses.map { address in
                PersonAddress(
                    formattedValue: address.formattedValue,
                    streetAddress: address.streetAddress,
                    city: address.city,
                    region: address.region,
                    postalCode: address.postalCode,
                    country: address.country,
                    countryCode: address.countryCode,
                    type: address.type
                )
            }
        }
        
        // URLs
        if !contact.urls.isEmpty {
            person.urls = contact.urls.map { url in
                PersonUrl(value: url.value, type: url.type)
            }
        }
        
        // Birthday
        if let birthday = contact.birthday {
            person.birthdays = [
                PersonBirthday(
                    date: PersonDate(year: birthday.year, month: birthday.month, day: birthday.day)
                )
            ]
        }
        
        // Note
        if let note = contact.note {
            person.biographies = [PersonBiography(value: note)]
        }
        
        return person
    }
}

// MARK: - Models

struct GoogleContact: Identifiable, Codable {
    let id: String // resourceName like "people/c1234567890"
    var resourceName: String { id }
    
    var etag: String?
    
    // Name fields
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
    var phoneNumbers: [GooglePhoneNumber] = []
    var emailAddresses: [GoogleEmailAddress] = []
    var addresses: [GoogleAddress] = []
    var urls: [GoogleUrl] = []
    
    // Other
    var birthday: GoogleDate?
    var note: String?
    var photoUrl: String?
    var photoData: Data? // For local caching
    
    // Metadata
    var updateTime: Date?
}

struct GooglePhoneNumber: Codable {
    var value: String
    var type: String? // "home", "work", "mobile", etc.
    var label: String?
}

struct GoogleEmailAddress: Codable {
    var value: String
    var type: String?
    var label: String?
}

struct GoogleAddress: Codable {
    var formattedValue: String?
    var streetAddress: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?
    var countryCode: String?
    var type: String?
    var label: String?
}

struct GoogleUrl: Codable {
    var value: String
    var type: String?
    var label: String?
}

struct GoogleDate: Codable {
    var year: Int?
    var month: Int?
    var day: Int?
}

struct GoogleContactGroup: Identifiable, Codable {
    let id: String // resourceName like "contactGroups/myContacts"
    var resourceName: String { id }
    var name: String
    var memberCount: Int?
}

struct GoogleContactsChanges {
    var added: [GoogleContact]
    var updated: [GoogleContact]
    var deleted: [String] // resourceNames
    var newSyncToken: String
}

struct GoogleDuplicateSet: Identifiable {
    let id = UUID()
    var contacts: [GoogleContact]
}

// MARK: - Errors

enum GoogleContactsError: LocalizedError {
    case notAuthenticated
    case notImplemented
    case networkError(Error)
    case apiError(statusCode: Int, message: String)
    case rateLimitExceeded
    case invalidToken
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to Google. Please authenticate first."
        case .notImplemented:
            return "This feature is not yet implemented."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .invalidToken:
            return "Invalid or expired token. Please sign in again."
        }
    }
}

// MARK: - Google People API Models

struct PeopleAPIResponse: Codable {
    let connections: [PeopleAPIPerson]?
    let nextPageToken: String?
    let nextSyncToken: String?
    let totalPeople: Int?
    let totalItems: Int?
}

struct PeopleAPIPerson: Codable {
    var resourceName: String?
    var etag: String?
    var metadata: PersonMetadata?
    var names: [PersonName]?
    var nicknames: [PersonNickname]?
    var emailAddresses: [PersonEmailAddress]?
    var phoneNumbers: [PersonPhoneNumber]?
    var addresses: [PersonAddress]?
    var organizations: [PersonOrganization]?
    var birthdays: [PersonBirthday]?
    var photos: [PersonPhoto]?
    var urls: [PersonUrl]?
    var biographies: [PersonBiography]?
}

struct PersonMetadata: Codable {
    let sources: [PersonSource]?
    let deleted: Bool?
}

struct PersonSource: Codable {
    let type: String?
    let id: String?
    let etag: String?
    let updateTime: String?
}

struct PersonName: Codable {
    var givenName: String?
    var middleName: String?
    var familyName: String?
    var honorificPrefix: String?
    var honorificSuffix: String?
    var displayName: String?
}

struct PersonNickname: Codable {
    var value: String
}

struct PersonEmailAddress: Codable {
    var value: String
    var type: String?
    var formattedType: String?
}

struct PersonPhoneNumber: Codable {
    var value: String
    var type: String?
    var formattedType: String?
}

struct PersonAddress: Codable {
    var formattedValue: String?
    var streetAddress: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?
    var countryCode: String?
    var type: String?
    var formattedType: String?
}

struct PersonOrganization: Codable {
    var name: String?
    var department: String?
    var title: String?
    var type: String?
}

struct PersonBirthday: Codable {
    var date: PersonDate
}

struct PersonDate: Codable {
    var year: Int?
    var month: Int?
    var day: Int?
}

struct PersonPhoto: Codable {
    var url: String?
    var metadata: PhotoMetadata?
}

struct PhotoMetadata: Codable {
    let primary: Bool?
    let source: PhotoSource?
}

struct PhotoSource: Codable {
    let type: String?
    let id: String?
}

struct PersonUrl: Codable {
    var value: String
    var type: String?
    var formattedType: String?
}

struct PersonBiography: Codable {
    var value: String
}

struct ContactGroupsResponse: Codable {
    let contactGroups: [ContactGroupAPI]
}

struct ContactGroupAPI: Codable {
    let resourceName: String
    let name: String
    let memberCount: Int?
}

struct BatchCreateResponse: Codable {
    let createdPeople: [CreatedPerson]
}

struct CreatedPerson: Codable {
    let person: PeopleAPIPerson
}

struct BatchUpdateResponse: Codable {
    let updateResult: [UpdateResult]
}

struct UpdateResult: Codable {
    let person: PeopleAPIPerson
}

