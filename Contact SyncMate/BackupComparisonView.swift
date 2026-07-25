//
//  BackupComparisonView.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  Side-by-side comparison view for contact versions
//

import SwiftUI
import Combine

struct BackupComparisonView: View {
    let contactIdentifier: String
    let contactName: String
    @StateObject private var viewModel = BackupComparisonViewModel()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text(contactName)
                        .font(.headline)

                    Text("Version History")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.appSurfaceTinted)

                if viewModel.versions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.appTextTertiary)

                        Text("No Version History")
                            .font(.headline)

                        Text("This contact has no previous versions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Version timeline
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Versions (\(viewModel.versions.count))")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(Array(viewModel.versions.enumerated()), id: \.element.id) { index, version in
                                    VersionTimelineItem(
                                        version: version,
                                        isSelected: viewModel.selectedVersionIndex == index,
                                        onSelect: {
                                            viewModel.selectVersion(at: index)
                                        },
                                        onCompare: {
                                            viewModel.compareWithVersion(at: index)
                                        }
                                    )
                                }
                            }
                            .padding(16)
                        }
                    }

                    Divider()

                    // Comparison view
                    if let selectedIndex = viewModel.selectedVersionIndex,
                       selectedIndex < viewModel.versions.count {
                        let version = viewModel.versions[selectedIndex]

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Version \(version.versionNumber)")
                                        .font(.headline)

                                    Text(version.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(version.source.rawValue.uppercased())
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(4)
                                        .background(sourceColor(version.source))
                                        .foregroundStyle(Color.appTextInverse)
                                        .cornerRadius(4)
                                }
                            }
                            .padding(12)
                            .background(Color.appSurfaceTinted)
                            .cornerRadius(8)

                            // Contact details
                            VStack(alignment: .leading, spacing: 12) {
                                    DetailSection(title: "Name", content: [
                                        "Display: \(version.data.displayName)",
                                        "Given: \(version.data.givenName ?? "-")",
                                        "Family: \(version.data.familyName ?? "-")"
                                    ])

                                    if !version.data.phoneNumbers.isEmpty {
                                        DetailSection(
                                            title: "Phone Numbers (\(version.data.phoneNumbers.count))",
                                            content: version.data.phoneNumbers.map { phone in
                                                "\(phone.label ?? "General"): \(phone.value)"
                                            }
                                        )
                                    }

                                    if !version.data.emailAddresses.isEmpty {
                                        DetailSection(
                                            title: "Emails (\(version.data.emailAddresses.count))",
                                            content: version.data.emailAddresses.map { email in
                                                "\(email.label ?? "Work"): \(email.value)"
                                            }
                                        )
                                    }

                                    if let org = version.data.organization {
                                        DetailSection(title: "Organization", content: [org])
                                    }

                                    if let title = version.data.jobTitle {
                                        DetailSection(title: "Job Title", content: [title])
                                    }

                                    if let notes = version.data.notes {
                                        DetailSection(title: "Notes", content: [notes])
                                    }
                            }
                        }
                        .padding(16)
                    }

                    Spacer()
                }

                // Actions
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Text("Close")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    }
                    .buttonStyle(.bordered)

                    if viewModel.selectedVersionIndex != nil {
                        Button(action: { viewModel.restoreSelectedVersion() }) {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .foregroundStyle(Color.appTextInverse)
                                .background(Color.appAccent)
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(16)
                .background(Color.appSurfaceTinted)
            }
            .navigationTitle("Version History")
            .onAppear {
                viewModel.loadVersionHistory(for: contactIdentifier)
            }
        }
    }

    private func sourceColor(_ source: ContactVersion.ContactSource) -> Color {
        switch source {
        case .google: return .appSourceGoogle
        case .mac:    return .appSourceApple
        case .merged: return .appBrand
        }
    }
}

// MARK: - Version Timeline Item

struct VersionTimelineItem: View {
    let version: ContactVersion
    let isSelected: Bool
    let onSelect: () -> Void
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(version.versionNumber)")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(version.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .foregroundColor(sourceColor(version.source))

                        Text(version.source.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !version.changesSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(version.changesSummary.prefix(2), id: \.self) { change in
                        HStack(spacing: 4) {
                            Text("•")
                                .foregroundColor(.secondary)

                            Text(change)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if version.changesSummary.count > 2 {
                        Text("+ \(version.changesSummary.count - 2) more")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Text(isSelected ? "Selected" : "Select")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .buttonStyle(.bordered)

                Button(action: onCompare) {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(isSelected ? Color.appAccent.opacity(0.10) : Color.appSurfaceTinted)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.appAccent : Color.clear, lineWidth: 1)
        )
    }

    private func sourceColor(_ source: ContactVersion.ContactSource) -> Color {
        switch source {
        case .google: return .appSourceGoogle
        case .mac:    return .appSourceApple
        case .merged: return .appBrand
        }
    }
}

// MARK: - Detail Section

struct DetailSection: View {
    let title: String
    let content: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(content, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
    }
}

// MARK: - ViewModel

class BackupComparisonViewModel: ObservableObject {
    @Published var versions: [ContactVersion] = []
    @Published var selectedVersionIndex: Int?
    @Published var compareWithIndex: Int?

    private let backupManager = ContactBackupManager.shared

    func loadVersionHistory(for contactIdentifier: String) {
        DispatchQueue.main.async {
            self.versions = self.backupManager.getVersionHistory(for: contactIdentifier)
        }
    }

    func selectVersion(at index: Int) {
        selectedVersionIndex = index
    }

    func compareWithVersion(at index: Int) {
        compareWithIndex = index
    }

    func restoreSelectedVersion() {
        if let index = selectedVersionIndex, index < versions.count {
            let version = versions[index]
            _ = backupManager.restoreContactVersion(version)

            SyncHistory.shared.log(
                source: "BackupComparison",
                action: "restore_contact_version",
                details: "Restored \(version.contactName) to version \(version.versionNumber)"
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
struct BackupComparisonView_Previews: PreviewProvider {
    static var previews: some View {
        BackupComparisonView(
            contactIdentifier: "contact-123",
            contactName: "John Doe"
        )
    }
}
#endif
