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

    // An incremental-fetch path (syncToken / fetchChangedContacts) used to live
    // here, unused. It was removed rather than wired up: connections are fetched
    // 1000 per page, so a full fetch of a normal address book is a single request
    // — the same one an incremental fetch would cost. It saved nothing, while
    // requiring a locally cached copy of every Google contact for the diff to run
    // against. A stale or drifted cache feeding the diff is how contacts get
    // wrongly deleted, which is not a risk worth taking for zero saved requests.
    //
    // The request count that actually mattered was one write per contact; that is
    // fixed by the batch endpoints (see batchCreateContacts).

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
        etagCache.removeAll()
    }
    
    // MARK: - API Request Helper
    
    /// Fields `people.updateContact` accepts in its update mask.
    ///
    /// Deliberately a single constant used by both the single and batch update
    /// paths — they previously carried duplicate literals, and the invalid
    /// `photos` entry had to be removed from both.
    ///
    /// Photos are excluded because the API handles them through
    /// `people.updateContactPhoto`; passing them here is rejected outright.
    private static let updatablePersonFields =
        "names,emailAddresses,phoneNumbers,addresses,organizations,birthdays,urls,nicknames"

    /// Fields requested back from batch calls. Kept identical to the update mask
    /// plus `metadata`, which carries the fresh etag every subsequent update needs.
    private static let readablePersonFields =
        "names,emailAddresses,phoneNumbers,addresses,organizations,birthdays,urls,nicknames,metadata"

    /// How many times a request is retried before the error is surfaced.
    ///
    /// Google's People API applies a **per-minute** quota, so a sync touching a
    /// few hundred contacts will hit 429 during normal operation. That is not an
    /// error condition — it is the API asking us to slow down. Retrying with
    /// exponential backoff is the documented client contract; without it a large
    /// address book can never finish syncing, which is exactly the "sync never
    /// works" symptom this replaced.
    private static let maxRetryAttempts = 5

    /// Base delay, doubled per attempt: 1s, 2s, 4s, 8s, 16s.
    /// Total worst-case wait is ~31s, comfortably inside a per-minute window.
    private static let baseRetryDelay: Duration = .seconds(1)

    private func makeRequest(url: URL) async throws -> (Data, URLResponse) {
        try await makeRequest(url: url, method: "GET", body: nil)
    }

    private func makeRequest(url: URL, method: String, body: Data?) async throws -> (Data, URLResponse) {
        var attempt = 0

        while true {
            // Fetched inside the loop: a long backoff can outlive the access
            // token, and retrying with a stale one would fail as 401.
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

            // 429 = quota; 500/502/503/504 = transient server-side faults.
            // Both are retryable, and Google explicitly recommends backoff.
            case 429, 500, 502, 503, 504:
                attempt += 1
                guard attempt <= Self.maxRetryAttempts else {
                    if httpResponse.statusCode == 429 {
                        throw GoogleContactsError.rateLimitExceeded
                    }
                    let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw GoogleContactsError.apiError(statusCode: httpResponse.statusCode,
                                                       message: message)
                }

                let delay = Self.retryDelay(for: attempt, response: httpResponse)
                SyncHistory.shared.log(
                    source: "GoogleAPI",
                    action: "request.retrying",
                    details: "HTTP \(httpResponse.statusCode) — attempt \(attempt)/\(Self.maxRetryAttempts), waiting \(delay)"
                )
                try await Task.sleep(for: delay)
                continue

            default:
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw GoogleContactsError.apiError(statusCode: httpResponse.statusCode, message: message)
            }
        }
    }

    /// Backoff interval for `attempt` (1-based).
    ///
    /// A server-supplied `Retry-After` always wins — guessing shorter than what
    /// the server asked for just burns quota and earns another 429.
    private static func retryDelay(for attempt: Int, response: HTTPURLResponse) -> Duration {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header), seconds > 0 {
            return .seconds(min(seconds, 60))
        }

        // Exponential, with jitter so parallel requests don't retry in lockstep
        // and immediately re-trip the same quota.
        let exponential = pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.3)
        return .seconds(min(exponential + jitter, 30))
    }


    // MARK: - Fetching Contacts
    
    func fetchAllContacts() async throws -> [GoogleContact] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        var allContacts: [GoogleContact] = []
        var pageToken: String?
        
        let personFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames,metadata,memberships"
        
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
                let page = connections.compactMap { convertToPerson($0) }
                // Harvest etags while we have them: every update later in this
                // sync needs one, and without this each would pay its own GET.
                cacheETags(from: page)
                allContacts.append(contentsOf: page)
            }
            
            pageToken = response.nextPageToken
        } while pageToken != nil
        
        return allContacts
    }
    
    func fetchContact(resourceName: String) async throws -> GoogleContact {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }
        
        let personFields = "names,emailAddresses,phoneNumbers,addresses,organizations,photos,birthdays,urls,nicknames,metadata,memberships"
        
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

        // `updateContact` is rejected with
        //   400 "Request must set person.etag or person.metadata.sources[].etag"
        // unless a current etag is supplied — People API uses it for optimistic
        // concurrency, so it is mandatory, not optional.
        //
        // The etag lives on GoogleContact but not on UnifiedContact, so any
        // update rebuilt from the unified model arrives here with etag == nil and
        // every Mac → Google write failed. Rather than thread the token through
        // the whole model (where it would also go stale), fetch it at the point
        // of use: it is only valid for the version we are about to overwrite.
        var contact = contact
        if contact.etag == nil {
            contact.etag = try await currentETag(for: contact.resourceName)
        }

        do {
            return try await performUpdate(contact)
        } catch GoogleContactsError.apiError(let statusCode, let message)
                    where statusCode == 400 && message.contains("etag") {
            // A cached etag goes stale the moment the contact is edited anywhere
            // else — Gmail, an iPhone, another client. Re-read and retry once so
            // a concurrent edit costs a round trip instead of a failed sync.
            SyncHistory.shared.log(source: "GoogleAPI", action: "update.refreshingStaleETag",
                                   details: contact.resourceName)
            // Cache-bypassing on purpose: the cached value is precisely what the
            // server just rejected as stale.
            etagCache[contact.resourceName] = nil
            contact.etag = try await fetchETagFromServer(contact.resourceName)
            return try await performUpdate(contact)
        }
    }

    /// etags seen during the last full fetch, keyed by resourceName.
    ///
    /// `updateContact` needs an etag, and a `GoogleContact` rebuilt from a
    /// `UnifiedContact` has none — so each update was preceded by its own GET,
    /// doubling the request count for the most common operation. Every sync
    /// already fetches all Google contacts first, and those carry etags, so the
    /// information is on hand: caching it removes one round trip per update and
    /// is what lets contacts qualify for batching at all.
    private var etagCache: [String: String] = [:]

    /// Record etags from a freshly fetched page.
    func cacheETags(from contacts: [GoogleContact]) {
        for contact in contacts where contact.etag != nil {
            etagCache[contact.resourceName] = contact.etag
        }
    }

    /// Best known etag for a contact — cached first, network only as a fallback.
    func knownETag(for resourceName: String) -> String? {
        etagCache[resourceName]
    }

    /// Read the server's current etag for a person.
    private func currentETag(for resourceName: String) async throws -> String? {
        if let cached = etagCache[resourceName] { return cached }
        return try await fetchETagFromServer(resourceName)
    }

    private func fetchETagFromServer(_ resourceName: String) async throws -> String? {
        var components = URLComponents(string: "\(baseURL)/\(resourceName)")!
        components.queryItems = [URLQueryItem(name: "personFields", value: "metadata")]

        let (data, _) = try await makeRequest(url: components.url!, method: "GET", body: nil)
        return try JSONDecoder().decode(PeopleAPIPerson.self, from: data).etag
    }

    private func performUpdate(_ contact: GoogleContact) async throws -> GoogleContact {
        // `photos` is NOT a valid updatePersonFields path — People API rejects the
        // whole request with
        //   400 "Invalid updatePersonFields mask path: \"photos\""
        // because photos are written through people.updateContactPhoto instead.
        // Including it here failed every single update, whatever else changed.
        let updateFields = Self.updatablePersonFields

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
    
    /// Create contacts in bulk, returning one slot per input in input order.
    ///
    /// The result is positional and `nil` marks a create the API did not return a
    /// person for. The caller needs that correspondence: it has to write the new
    /// resourceName into the contact mapping, and there is no other way back from
    /// a created person to the Mac contact it came from. Returning a compacted
    /// array — as this used to — silently shifts every later contact onto the
    /// wrong mapping the moment one create fails.
    func batchCreateContacts(_ contacts: [GoogleContact]) async throws -> [GoogleContact?] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }

        // Split into chunks of 200 (API limit)
        var results: [GoogleContact?] = []
        let chunkSize = 200

        for chunk in stride(from: 0, to: contacts.count, by: chunkSize) {
            let endIndex = min(chunk + chunkSize, contacts.count)
            let contactChunk = Array(contacts[chunk..<endIndex])

            let batchResult = try await batchCreateChunk(contactChunk)
            results.append(contentsOf: batchResult)
        }

        return results
    }
    
    /// One `people:batchCreateContacts` call for up to 200 contacts.
    ///
    /// Same defect as the update path: a `PeopleAPIPerson` struct was handed to
    /// `JSONSerialization`, which only accepts foundation JSON types, so this
    /// threw before sending. `readMask` is also required by the API.
    private func batchCreateChunk(_ contacts: [GoogleContact]) async throws -> [GoogleContact?] {
        let url = URL(string: "\(baseURL)/people:batchCreateContacts")!

        let payload = BatchCreateRequest(
            contacts: contacts.map { BatchCreateRequest.Item(contactPerson: convertToAPIPerson($0)) },
            readMask: Self.readablePersonFields
        )

        let body = try JSONEncoder().encode(payload)
        let (data, _) = try await makeRequest(url: url, method: "POST", body: body)
        let response = try JSONDecoder().decode(BatchCreateResponse.self, from: data)

        // createdPeople comes back in request order. Pad to the request length so
        // a short response cannot silently misalign the caller's mapping writes.
        var created: [GoogleContact?] = response.people.map {
            $0.person.flatMap { convertToPerson($0) }
        }
        if created.count < contacts.count {
            created += Array(repeating: nil, count: contacts.count - created.count)
        }
        let aligned = Array(created.prefix(contacts.count))
        cacheETags(from: aligned.compactMap { $0 })
        return aligned
    }
    
    /// Update contacts in bulk, keyed by resourceName.
    ///
    /// A map rather than an array because that is the shape the API answers in and
    /// the shape the caller needs — it has to know *which* updates succeeded in
    /// order to record their mappings and report the rest as failures. An
    /// unordered array could not tell it that.
    func batchUpdateContacts(_ contacts: [GoogleContact]) async throws -> [String: GoogleContact] {
        guard isAuthenticated else {
            throw GoogleContactsError.notAuthenticated
        }

        // Split into chunks of 200 (API limit)
        var results: [String: GoogleContact] = [:]
        let chunkSize = 200

        for chunk in stride(from: 0, to: contacts.count, by: chunkSize) {
            let endIndex = min(chunk + chunkSize, contacts.count)
            let contactChunk = Array(contacts[chunk..<endIndex])

            for (name, updated) in try await batchUpdateChunk(contactChunk) {
                results[name] = updated
            }
        }

        return results
    }
    
    /// One `people:batchUpdateContacts` call for up to 200 contacts.
    ///
    /// The previous implementation could never have worked: it built the body with
    /// `JSONSerialization.data(withJSONObject:)` while embedding a `PeopleAPIPerson`
    /// *struct* as a value — not a JSON-representable type, so the call threw
    /// before reaching the network. It also used the wrong request shape entirely:
    /// `contacts` is a **map** of resourceName → Person with a single top-level
    /// `updateMask`, not an array of per-contact request objects.
    ///
    /// Encoding through `JSONEncoder` keeps the Person shape in one place
    /// (`convertToAPIPerson`) instead of duplicating it as dictionaries.
    private func batchUpdateChunk(_ contacts: [GoogleContact]) async throws -> [String: GoogleContact] {
        // Contacts with no etag cannot be updated — People API requires it for
        // optimistic concurrency and rejects the whole batch otherwise. Resolving
        // them one by one here would defeat the point of batching, so they fall
        // back to the single-contact path (which does fetch an etag).
        var batchable: [GoogleContact] = []
        var needsETag: [GoogleContact] = []
        for contact in contacts {
            if contact.etag != nil { batchable.append(contact) } else { needsETag.append(contact) }
        }

        var results: [String: GoogleContact] = [:]

        if !batchable.isEmpty {
            let url = URL(string: "\(baseURL)/people:batchUpdateContacts")!

            let payload = BatchUpdateRequest(
                contacts: Dictionary(
                    batchable.map { ($0.resourceName, convertToAPIPerson($0)) },
                    uniquingKeysWith: { _, latest in latest }
                ),
                updateMask: Self.updatablePersonFields,
                readMask: Self.readablePersonFields
            )

            let body = try JSONEncoder().encode(payload)
            let (data, _) = try await makeRequest(url: url, method: "POST", body: body)
            let response = try JSONDecoder().decode(BatchUpdateResponse.self, from: data)

            // `updateResult` is a map keyed by resource name, not an array. Keys
            // that came back without a person failed — leaving them out of the
            // result is what tells the caller to report them.
            for (name, outcome) in response.updateResult {
                if let person = outcome.person, let contact = convertToPerson(person) {
                    results[name] = contact
                }
            }
            cacheETags(from: Array(results.values))
        }

        for contact in needsETag {
            let updated = try await updateContact(contact)
            results[updated.resourceName] = updated
        }

        return results
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

        // Label membership, for group filtering.
        contact.groupResourceNames = apiPerson.memberships?.compactMap {
            $0.contactGroupMembership?.contactGroupResourceName
        } ?? []
        
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

    /// contactGroups/… resource names this contact belongs to.
    ///
    /// Populated on read only; never written back, so filtering by label cannot
    /// reorganise the user's labels as a side effect.
    var groupResourceNames: [String] = []

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
    /// Which contact groups (labels) this person belongs to.
    ///
    /// Read-only here — it is requested in `personFields` so group filtering can
    /// work, and deliberately left out of the update mask so a sync never
    /// reorganises the user's labels.
    var memberships: [PersonMembership]?
}

struct PersonMembership: Codable {
    struct ContactGroupMembership: Codable {
        let contactGroupResourceName: String?
    }
    let contactGroupMembership: ContactGroupMembership?
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

// MARK: - Batch request/response shapes
//
// Modelled directly on the People API reference rather than assembled as
// dictionaries — the previous hand-built bodies had the wrong shape *and* could
// not be serialised at all.

struct BatchCreateRequest: Codable {
    struct Item: Codable {
        let contactPerson: PeopleAPIPerson
    }
    let contacts: [Item]
    /// Required by the API; determines which fields come back on the created people.
    let readMask: String
}

struct BatchCreateResponse: Codable {
    let createdPeople: [CreatedPerson]?

    /// Absent when every create failed, so the array must be optional — decoding
    /// a partial failure should surface as an empty result, not a thrown
    /// `keyNotFound` that hides the real API error.
    var people: [CreatedPerson] { createdPeople ?? [] }
}

struct CreatedPerson: Codable {
    let person: PeopleAPIPerson?
}

struct BatchUpdateRequest: Codable {
    /// Keyed by resourceName — the API takes a map here, not a list.
    let contacts: [String: PeopleAPIPerson]
    let updateMask: String
    let readMask: String
}

struct BatchUpdateResponse: Codable {
    /// Also a map keyed by resourceName. Decoding it as an array was guaranteed
    /// to throw on the first real response.
    let updateResult: [String: UpdateResult]
}

struct UpdateResult: Codable {
    let person: PeopleAPIPerson?
}

