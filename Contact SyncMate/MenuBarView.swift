//
//  MenuBarView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Menu Bar Popover View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var oauth = GoogleOAuthManager.shared

    let onOpenDashboard:  () -> Void
    let onOpenHistory:    () -> Void
    let onOpenPreferences:() -> Void

    // MARK: Computed

    private var syncStatus: SyncStatus {
        if appState.isSyncing { return .syncing }
        if let result = appState.lastSyncResult, !result.successful { return .error }
        return .idle
    }

    private var statusLabel: String {
        if appState.isSyncing { return "Syncing…" }
        guard let date = appState.lastSyncDate else { return "Never synced" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Last synced \(f.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status row
            statusRow
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Sync Now
            syncNowButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Account rows
            VStack(spacing: 0) {
                accountRow(
                    icon: "g.circle.fill",
                    iconColor: .red,
                    label: oauth.isAuthenticated
                        ? (oauth.userEmail ?? "Google")
                        : "Not connected",
                    caption: "Google Account"
                )

                Divider().padding(.leading, 44)

                accountRow(
                    icon: "desktopcomputer",
                    iconColor: .blue,
                    label: settings.macAccountMode.rawValue,
                    caption: "Mac Contacts"
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Auto-sync toggle
            HStack {
                Label("Auto-sync", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: $settings.autoSyncEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Navigation links
            VStack(spacing: 0) {
                menuLink(icon: "gauge.open.with.lines.needle.33percent", title: "Open Dashboard") {
                    onOpenDashboard()
                }
                menuLink(icon: "clock.fill", title: "Sync History") {
                    onOpenHistory()
                }
                menuLink(icon: "gear", title: "Preferences") {
                    onOpenPreferences()
                }
            }

            Divider()

            // Quit
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit Contact SyncMate", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    // MARK: - Sub-views

    private var statusRow: some View {
        HStack(spacing: 10) {
            if appState.isSyncing {
                Image(systemName: "infinity")
                    .foregroundStyle(Color.orange)
                    .font(.headline)
                    .symbolEffect(.pulse)
            } else {
                StatusDot(status: syncStatus)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(syncStatus.label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var syncNowButton: some View {
        Button {
            triggerSync()
        } label: {
            Label(appState.isSyncing ? "Syncing…" : "⟳ Sync Now", systemImage: "")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color("BrandIndigo"))
        .disabled(appState.isSyncing || !oauth.isAuthenticated)
    }

    private func accountRow(icon: String, iconColor: Color, label: String, caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func menuLink(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func triggerSync() {
        appState.isSyncing = true
        // TODO: call SyncEngine; for now simulated
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            appState.isSyncing = false
            appState.lastSyncDate = Date()
        }
    }
}

#Preview {
    MenuBarView(
        onOpenDashboard: {},
        onOpenHistory: {},
        onOpenPreferences: {}
    )
    .environmentObject(AppState())
}
