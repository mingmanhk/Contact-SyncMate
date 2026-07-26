//
//  GroupFilterPickerView.swift
//  Contact SyncMate
//
//  Group / label sync filtering. When `AppSettings.filterByGroups` is on,
//  the user can restrict sync to selected Mac groups and Google labels.
//  Selections persist in `AppSettings.selectedMacGroups` (CNGroup
//  identifiers) and `AppSettings.selectedGoogleLabels` (contactGroups
//  resource names).
//
//  This replaces the previous "Group & label picker coming soon" stub.
//

import SwiftUI
import Contacts

// MARK: - Inline picker (embedded in Settings → Sync Fields → Filters)

struct GroupFilterPickerView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var oauth = GoogleOAuthManager.shared

    @State private var macGroups: [(id: String, name: String)] = []
    @State private var googleLabels: [GoogleContactGroup] = []
    @State private var isLoadingMac = false
    @State private var isLoadingGoogle = false
    @State private var macError: String?
    @State private var googleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Mac groups ─────────────────────────────────────────────
            sectionHeader(icon: AppIcon.sourceApple, color: .appSourceApple,
                          title: "Mac Groups",
                          selectedCount: settings.selectedMacGroups.count)

            if isLoadingMac {
                loadingRow
            } else if let macError {
                errorRow(macError)
            } else if macGroups.isEmpty {
                emptyRow("No groups found in Mac Contacts")
            } else {
                ForEach(macGroups, id: \.id) { group in
                    toggleRow(
                        name: group.name,
                        isOn: Binding(
                            get: { settings.selectedMacGroups.contains(group.id) },
                            set: { on in
                                if on { settings.selectedMacGroups.append(group.id) }
                                else  { settings.selectedMacGroups.removeAll { $0 == group.id } }
                            }
                        )
                    )
                }
            }

            Divider().padding(.vertical, 2)

            // ── Google labels ──────────────────────────────────────────
            sectionHeader(icon: AppIcon.sourceGoogle, color: .appSourceGoogle,
                          title: "Google Labels",
                          selectedCount: settings.selectedGoogleLabels.count)

            if !oauth.isAuthenticated {
                emptyRow("Sign in to Google (Settings → Accounts) to load labels")
            } else if isLoadingGoogle {
                loadingRow
            } else if let googleError {
                errorRow(googleError)
            } else if googleLabels.isEmpty {
                emptyRow("No labels found in Google Contacts")
            } else {
                ForEach(googleLabels) { label in
                    toggleRow(
                        name: labelDisplayName(label),
                        detail: label.memberCount.map { "\($0)" },
                        isOn: Binding(
                            get: { settings.selectedGoogleLabels.contains(label.resourceName) },
                            set: { on in
                                if on { settings.selectedGoogleLabels.append(label.resourceName) }
                                else  { settings.selectedGoogleLabels.removeAll { $0 == label.resourceName } }
                            }
                        )
                    )
                }
            }

            // ── Summary footer ─────────────────────────────────────────
            if settings.selectedMacGroups.isEmpty && settings.selectedGoogleLabels.isEmpty {
                Label {
                    Text("No groups selected — the filter matches nothing. Select at least one group or label, or turn filtering off.")
                } icon: {
                    Image(systemName: AppIcon.statusWarning)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appWarning)
                }
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            }
        }
        .onAppear(perform: loadAll)
    }

    // MARK: - Row builders

    private func sectionHeader(icon: String, color: Color, title: String, selectedCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .font(.caption)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer()
        }
    }

    private func toggleRow(name: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .monospacedDigit()
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.leading, 4)
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.caption).foregroundStyle(Color.appTextSecondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label {
            Text(message).font(.caption)
        } icon: {
            Image(systemName: AppIcon.statusError)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.appError)
        }
        .foregroundStyle(Color.appTextSecondary)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)
            .padding(.leading, 4)
    }

    /// Strip the "System Group: " prefix Google puts on built-in labels.
    private func labelDisplayName(_ label: GoogleContactGroup) -> String {
        label.name.replacingOccurrences(of: "System Group: ", with: "")
    }

    // MARK: - Loading

    private func loadAll() {
        loadMacGroups()
        if oauth.isAuthenticated { loadGoogleLabels() }
    }

    private func loadMacGroups() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            macError = "Contacts access not granted"
            return
        }
        isLoadingMac = true
        macError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = MacContactsConnector.shared
                let groups = try store.groups(matching: nil)
                let mapped = groups.map { (id: $0.identifier, name: $0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                DispatchQueue.main.async {
                    macGroups = mapped
                    isLoadingMac = false
                }
            } catch {
                DispatchQueue.main.async {
                    macError = error.localizedDescription
                    isLoadingMac = false
                }
            }
        }
    }

    private func loadGoogleLabels() {
        isLoadingGoogle = true
        googleError = nil
        Task {
            do {
                let connector = GoogleContactsConnector()
                let labels = try await connector.fetchContactGroups()
                await MainActor.run {
                    googleLabels = labels.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    isLoadingGoogle = false
                }
            } catch {
                await MainActor.run {
                    googleError = error.localizedDescription
                    isLoadingGoogle = false
                }
            }
        }
    }
}

#Preview {
    Form {
        GroupFilterPickerView()
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 500)
}
