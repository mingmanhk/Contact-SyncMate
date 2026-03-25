//
//  DashboardView.swift
//  Contact SyncMate
//

import SwiftUI
import Contacts

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var oauth = GoogleOAuthManager.shared

    @State private var showSyncPreview = false
    @State private var recentEvents: [SyncEvent] = []

    // MARK: Computed helpers

    private var syncStatus: SyncStatus {
        if appState.isSyncing { return .syncing }
        if let result = appState.lastSyncResult, !result.successful { return .error }
        return .idle
    }

    private var lastSyncLabel: String {
        guard let date = appState.lastSyncDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Header toolbar
            headerBar

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Account cards
                    accountCardsSection

                    // Sync direction picker
                    syncDirectionSection

                    // Sync Now button
                    syncNowSection

                    // Recent activity
                    recentActivitySection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showSyncPreview) {
            if let session = appState.currentSyncSession {
                SyncPreviewView(session: session, isPresented: $showSyncPreview)
            }
        }
        .onAppear { recentEvents = Array(SyncHistory.shared.events().suffix(5).reversed()) }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Contact SyncMate")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            HStack(spacing: 8) {
                StatusDot(status: syncStatus)
                Text(appState.isSyncing ? "Syncing…" : "Last synced \(lastSyncLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Account Cards

    private var accountCardsSection: some View {
        HStack(spacing: 16) {
            accountCard(
                icon: "person.crop.circle.fill",
                iconColor: .red,
                title: "Google Account",
                detail: oauth.isAuthenticated
                    ? (oauth.userEmail ?? "Connected")
                    : "Not connected",
                isConnected: oauth.isAuthenticated
            )

            accountCard(
                icon: "desktopcomputer",
                iconColor: .blue,
                title: "Mac Contacts",
                detail: CNContactStore.authorizationStatus(for: .contacts) == .authorized
                    ? settings.macAccountMode.rawValue
                    : "No access",
                isConnected: CNContactStore.authorizationStatus(for: .contacts) == .authorized
            )
        }
    }

    private func accountCard(icon: String, iconColor: Color, title: String, detail: String, isConnected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isConnected ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sync Direction

    private var syncDirectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Direction")
                .font(.headline)

            Picker("Sync direction", selection: $settings.autoSyncDirection) {
                Text("2-Way").tag(SyncDirection.twoWay)
                Text("Google → Mac").tag(SyncDirection.googleToMac)
                Text("Mac → Google").tag(SyncDirection.macToGoogle)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Sync Now

    private var syncNowSection: some View {
        HStack {
            Button {
                triggerSync()
            } label: {
                HStack {
                    Image(systemName: appState.isSyncing ? "infinity" : "arrow.triangle.2.circlepath")
                    Text(appState.isSyncing ? "Syncing…" : "Sync Now")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandIndigo"))
            .controlSize(.large)
            .disabled(appState.isSyncing || !oauth.isAuthenticated)
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            if recentEvents.isEmpty {
                Text("No sync history yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentEvents) { event in
                        recentEventRow(event)
                        if event.id != recentEvents.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
            }
        }
    }

    private func recentEventRow(_ event: SyncEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.action)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let detail = event.details {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
    }

    // MARK: - Actions

    private func triggerSync() {
        // For manual mode, show preview; otherwise sync directly
        if settings.selectedSyncType == .manual {
            showSyncPreview = true
        } else {
            // TODO: invoke SyncEngine directly
            appState.isSyncing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                appState.isSyncing = false
                appState.lastSyncDate = Date()
            }
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
