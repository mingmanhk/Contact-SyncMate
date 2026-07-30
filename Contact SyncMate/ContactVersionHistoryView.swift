//
//  ContactVersionHistoryView.swift
//  Contact SyncMate
//
//  Browse and restore individual contact versions captured in backups.
//

import SwiftUI

/// Per-contact version history.
///
/// Every backup already stored a full `ContactVersion` for each contact, but
/// there was no way to reach it: `getVersionHistory(for:)` takes an identifier
/// and nothing in the app listed identifiers to choose from. So the data was
/// written on every sync and never read.
///
/// Restoring one contact is deliberately separate from rolling back a whole
/// backup — recovering a single person's details should not mean reverting both
/// address books.
struct ContactVersionHistoryView: View {
    @ObservedObject private var backupManager = ContactBackupManager.shared

    @State private var contacts: [(identifier: String, name: String, versions: Int, latest: Date)] = []
    @State private var searchText = ""
    @State private var selectedIdentifier: String?
    @State private var versions: [ContactVersion] = []
    @State private var restoringVersionID: String?
    @State private var resultMessage: String?
    @State private var isError = false

    private var filteredContacts: [(identifier: String, name: String, versions: Int, latest: Date)] {
        guard let query = searchText.nonBlank else { return contacts }
        return contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HSplitView {
            contactList
                .frame(minWidth: 240, idealWidth: 280)

            versionDetail
                .frame(minWidth: 340)
        }
        .onAppear(perform: reload)
        .alert(isError ? "Couldn't restore the contact" : "Contact restored",
               isPresented: .constant(resultMessage != nil)) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: - Left: contacts that have history

    private var contactList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .controlSurface()
            .padding(12)

            if filteredContacts.isEmpty {
                if contacts.isEmpty {
                    EmptyState(icon: "clock.arrow.circlepath",
                               title: "No version history yet",
                               message: "It builds up as syncs create backups.")
                } else {
                    EmptyState(icon: "magnifyingglass",
                               title: "No contacts match your search")
                }
            } else {
                List(filteredContacts, id: \.identifier, selection: $selectedIdentifier) { contact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .lineLimit(1)
                        Text("\(contact.versions) versions · \(contact.latest, style: .date)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(contact.identifier)
                }
                .onChange(of: selectedIdentifier) { _, identifier in
                    versions = identifier.map {
                        backupManager.getVersionHistory(for: $0).reversed()
                    } ?? []
                }
            }
        }
    }

    // MARK: - Right: versions of the selected contact

    @ViewBuilder
    private var versionDetail: some View {
        if versions.isEmpty {
            EmptyState(icon: "clock.arrow.circlepath",
                       title: "Select a contact to see its saved versions")
        } else {
            List(versions) { version in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Version \(version.versionNumber)")
                            .fontWeight(.medium)
                        Text(version.source.rawValue.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.appInfo.opacity(0.15))
                            .clipShape(Capsule())

                        Spacer()

                        Text(version.timestamp, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !version.changesSummary.isEmpty {
                        Text(version.changesSummary.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    snapshotSummary(version.data)

                    Button {
                        restore(version)
                    } label: {
                        if restoringVersionID == version.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restore This Version")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(restoringVersionID != nil)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Enough detail to tell versions apart without opening each one.
    private func snapshotSummary(_ snapshot: ContactSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let phone = snapshot.phoneNumbers.first?.value {
                Text(phone).font(.caption).foregroundStyle(.secondary)
            }
            if let email = snapshot.emailAddresses.first?.value {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
            if let org = snapshot.organization?.nonBlank {
                Text(org).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        contacts = backupManager.allVersionedContacts()
    }

    private func restore(_ version: ContactVersion) {
        restoringVersionID = version.id

        Task { @MainActor in
            defer { restoringVersionID = nil }

            let engine = SyncEngine(
                googleConnector: GoogleContactsConnector(),
                macConnector: MacContactsConnector(),
                mappingStore: ContactMappingStore()
            )

            do {
                let name = try await engine.restoreContactVersion(version)
                isError = false
                resultMessage = String(
                    format: NSLocalizedString("%@ was restored to version %lld.",
                                              comment: "Single contact version restored"),
                    name, version.versionNumber
                )
                reload()
            } catch {
                isError = true
                resultMessage = error.localizedDescription
            }
        }
    }
}
