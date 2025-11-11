//
//  GoogleContactsExamples.swift
//  Contact SyncMate
//
//  Example usage of GoogleContactsConnector
//

import Foundation

// MARK: - Example Usage

/*
 
 // Example 1: Sign In and Fetch All Contacts
 
 let connector = GoogleContactsConnector()
 
 do {
     // Sign in to Google
     try await connector.signIn()
     
     // Fetch all contacts
     let contacts = try await connector.fetchAllContacts()
     print("Found \(contacts.count) contacts")
     
     for contact in contacts {
         let name = [contact.givenName, contact.familyName]
             .compactMap { $0 }
             .joined(separator: " ")
         print("- \(name)")
     }
 } catch {
     print("Error: \(error.localizedDescription)")
 }
 
 
 // Example 2: Create a New Contact
 
 var newContact = GoogleContact(id: "")
 newContact.givenName = "John"
 newContact.familyName = "Doe"
 newContact.emailAddresses = [
     GoogleEmailAddress(value: "john.doe@example.com", type: "work")
 ]
 newContact.phoneNumbers = [
     GooglePhoneNumber(value: "+1 555-0123", type: "mobile")
 ]
 newContact.organizationName = "Acme Corp"
 newContact.jobTitle = "Software Engineer"
 
 do {
     let created = try await connector.createContact(newContact)
     print("Created contact: \(created.resourceName)")
 } catch {
     print("Failed to create: \(error)")
 }
 
 
 // Example 3: Update an Existing Contact
 
 var contact = existingContact
 contact.emailAddresses.append(
     GoogleEmailAddress(value: "john.personal@example.com", type: "home")
 )
 contact.phoneNumbers.append(
     GooglePhoneNumber(value: "+1 555-9999", type: "work")
 )
 
 do {
     let updated = try await connector.updateContact(contact)
     print("Updated contact: \(updated.resourceName)")
 } catch {
     print("Failed to update: \(error)")
 }
 
 
 // Example 4: Batch Create Multiple Contacts
 
 var contacts: [GoogleContact] = []
 
 for i in 1...10 {
     var contact = GoogleContact(id: "")
     contact.givenName = "Test"
     contact.familyName = "User \(i)"
     contact.emailAddresses = [
         GoogleEmailAddress(value: "test\(i)@example.com", type: "home")
     ]
     contacts.append(contact)
 }
 
 do {
     let created = try await connector.batchCreateContacts(contacts)
     print("Created \(created.count) contacts")
 } catch {
     print("Batch create failed: \(error)")
 }
 
 
 // Example 5: Incremental Sync (Changes Only)
 
 // First time - full sync
 let allContacts = try await connector.fetchAllContacts()
 
 // Save sync token (in your app's persistent storage)
 let syncToken = "saved_from_previous_sync"
 
 // Later - get only changes
 do {
     let changes = try await connector.fetchChangedContacts(since: syncToken)
     
     print("Changes since last sync:")
     print("- Added: \(changes.added.count)")
     print("- Updated: \(changes.updated.count)")
     print("- Deleted: \(changes.deleted.count)")
     
     // Process changes
     for contact in changes.added {
         print("New contact: \(contact.givenName ?? "") \(contact.familyName ?? "")")
     }
     
     for contact in changes.updated {
         print("Updated contact: \(contact.givenName ?? "") \(contact.familyName ?? "")")
     }
     
     for resourceName in changes.deleted {
         print("Deleted contact: \(resourceName)")
     }
     
     // Save new sync token for next time
     // saveSyncToken(changes.newSyncToken)
 } catch {
     print("Incremental sync failed: \(error)")
 }
 
 
 // Example 6: Search for Duplicates
 
 do {
     let duplicates = try await connector.searchDuplicates()
     
     print("Found \(duplicates.count) duplicate sets")
     
     for (index, set) in duplicates.enumerated() {
         print("\nDuplicate Set \(index + 1):")
         for contact in set.contacts {
             let name = [contact.givenName, contact.familyName]
                 .compactMap { $0 }
                 .joined(separator: " ")
             print("  - \(name)")
             if !contact.emailAddresses.isEmpty {
                 print("    Emails: \(contact.emailAddresses.map { $0.value }.joined(separator: ", "))")
             }
         }
     }
 } catch {
     print("Duplicate search failed: \(error)")
 }
 
 
 // Example 7: Fetch Contact Groups (Labels)
 
 do {
     let groups = try await connector.fetchContactGroups()
     
     print("Contact Groups:")
     for group in groups {
         print("- \(group.name): \(group.memberCount ?? 0) members")
     }
 } catch {
     print("Failed to fetch groups: \(error)")
 }
 
 
 // Example 8: Delete a Contact
 
 let resourceName = "people/c1234567890"
 
 do {
     try await connector.deleteContact(resourceName: resourceName)
     print("Contact deleted successfully")
 } catch {
     print("Delete failed: \(error)")
 }
 
 
 // Example 9: Batch Delete Multiple Contacts
 
 let resourceNames = [
     "people/c1234567890",
     "people/c0987654321",
     "people/c5555555555"
 ]
 
 do {
     try await connector.batchDeleteContacts(resourceNames: resourceNames)
     print("Deleted \(resourceNames.count) contacts")
 } catch {
     print("Batch delete failed: \(error)")
 }
 
 
 // Example 10: Working with Contact Photos
 
 var contact = GoogleContact(id: "")
 contact.givenName = "Jane"
 contact.familyName = "Smith"
 
 // Google API handles photos via URL
 // The photo URL is provided when fetching contacts
 // To update photos, you need to upload them separately
 
 do {
     let created = try await connector.createContact(contact)
     
     if let photoUrl = created.photoUrl {
         print("Contact has photo at: \(photoUrl)")
         
         // Download photo data
         let url = URL(string: photoUrl)!
         let (data, _) = try await URLSession.shared.data(from: url)
         print("Downloaded \(data.count) bytes")
     }
 } catch {
     print("Error: \(error)")
 }
 
 
 // Example 11: Create Contact with Full Details
 
 var detailedContact = GoogleContact(id: "")
 
 // Name
 detailedContact.givenName = "Robert"
 detailedContact.middleName = "James"
 detailedContact.familyName = "Johnson"
 detailedContact.namePrefix = "Dr."
 detailedContact.nameSuffix = "Jr."
 detailedContact.nickname = "Bobby"
 
 // Organization
 detailedContact.organizationName = "Tech Innovations Inc."
 detailedContact.department = "Engineering"
 detailedContact.jobTitle = "Senior Software Architect"
 
 // Email addresses
 detailedContact.emailAddresses = [
     GoogleEmailAddress(value: "robert.johnson@techinnovations.com", type: "work"),
     GoogleEmailAddress(value: "bobby@personal.com", type: "home")
 ]
 
 // Phone numbers
 detailedContact.phoneNumbers = [
     GooglePhoneNumber(value: "+1-555-0100", type: "work"),
     GooglePhoneNumber(value: "+1-555-0200", type: "mobile"),
     GooglePhoneNumber(value: "+1-555-0300", type: "home")
 ]
 
 // Addresses
 detailedContact.addresses = [
     GoogleAddress(
         streetAddress: "123 Tech Street",
         city: "San Francisco",
         region: "CA",
         postalCode: "94102",
         country: "United States",
         countryCode: "US",
         type: "work"
     ),
     GoogleAddress(
         streetAddress: "456 Home Avenue",
         city: "Palo Alto",
         region: "CA",
         postalCode: "94301",
         country: "United States",
         countryCode: "US",
         type: "home"
     )
 ]
 
 // URLs
 detailedContact.urls = [
     GoogleUrl(value: "https://linkedin.com/in/robertjohnson", type: "profile"),
     GoogleUrl(value: "https://robertjohnson.dev", type: "homePage")
 ]
 
 // Birthday
 detailedContact.birthday = GoogleDate(year: 1985, month: 6, day: 15)
 
 // Notes
 detailedContact.note = "Met at tech conference 2024. Interested in iOS development."
 
 do {
     let created = try await connector.createContact(detailedContact)
     print("Created detailed contact: \(created.resourceName)")
 } catch {
     print("Failed to create: \(error)")
 }
 
 
 // Example 12: Error Handling
 
 func syncContactsSafely() async {
     let connector = GoogleContactsConnector()
     
     do {
         let contacts = try await connector.fetchAllContacts()
         print("Success! Got \(contacts.count) contacts")
         
     } catch GoogleContactsError.notAuthenticated {
         print("Not signed in - please authenticate first")
         
     } catch GoogleContactsError.rateLimitExceeded {
         print("Rate limit hit - waiting before retry...")
         try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
         // Retry logic here
         
     } catch GoogleContactsError.invalidToken {
         print("Token expired - signing in again...")
         try? await connector.signIn()
         
     } catch GoogleContactsError.networkError(let error) {
         print("Network problem: \(error.localizedDescription)")
         
     } catch GoogleContactsError.apiError(let statusCode, let message) {
         print("API error \(statusCode): \(message)")
         
     } catch {
         print("Unexpected error: \(error)")
     }
 }
 
 
 // Example 13: Monitoring Authentication State
 
 class MyViewModel: ObservableObject {
     @Published var isSignedIn = false
     @Published var userEmail: String?
     
     private let connector = GoogleContactsConnector()
     private var cancellables = Set<AnyCancellable>()
     
     init() {
         // Observe authentication state
         connector.$isAuthenticated
             .assign(to: &$isSignedIn)
         
         connector.$currentAccountEmail
             .assign(to: &$userEmail)
     }
     
     func signIn() {
         Task {
             try await connector.signIn()
         }
     }
     
     func signOut() {
         connector.signOut()
     }
 }
 
 */
