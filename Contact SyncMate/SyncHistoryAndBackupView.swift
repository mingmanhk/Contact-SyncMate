//
//  SyncHistoryAndBackupView.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  Unified view for showing sync history, backups, and restore functionality
//

import SwiftUI

// MARK: - Main Sync History & Backup View

struct SyncHistoryAndBackupView: View {
    @ObservedObject private var backupManager = ContactBackupManager.shared
    @StateObject private var viewModel = SyncHistoryViewModel()
    @State private var selectedBackup: BackupSession?
    @State private var showRestoreConfirmation = false
    /// Off by default: deleting is irreversible from the user's point of view,
    /// so it should be a deliberate choice rather than something that happens
    /// because they clicked through a dialog.
    @State private var removeContactsAddedSinceBackup = false
    @State private var selectedTab: HistoryTab = .timeline
    @State private var showClearHistoryConfirmation = false
    @State private var refreshSpin: Double = 0

    enum HistoryTab {
        case timeline
        case backups
        /// Per-contact version history — separate from `backups` because
        /// restoring one person is a much smaller decision than rolling both
        /// address books back to a snapshot.
        case contactVersions
        case statistics
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sync History & Backups")
                        .font(.title2)
                        .fontWeight(.bold)

                    Spacer()

                    // Clearing lived only in the other history view, which is not
                    // the one this window shows — so from here the log could be
                    // read but never cleared.
                    if selectedTab == .timeline && !viewModel.syncEvents.isEmpty {
                        Button(role: .destructive) {
                            showClearHistoryConfirmation = true
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .help("Delete all recorded sync events. Backups are not affected.")
                    }

                    // Refresh button.
                    //
                    // It always worked — the list also reloads on a 5-second timer,
                    // so a click landed on data that was already current and looked
                    // dead. The spin is the acknowledgement that was missing.
                    Button {
                        withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Color.appAccent)
                            .rotationEffect(.degrees(refreshSpin))
                    }
                    .help("Reload sync events and backups now")
                    .accessibilityLabel("Refresh")
                }

                // Tab selector
                Picker("View", selection: $selectedTab) {
                    Text("Timeline").tag(HistoryTab.timeline)
                    Text("Backups").tag(HistoryTab.backups)
                    Text("Contacts").tag(HistoryTab.contactVersions)
                    Text("Stats").tag(HistoryTab.statistics)
                }
                .pickerStyle(.segmented)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            // Content
            switch selectedTab {
            case .timeline:
                // The one timeline implementation, shared with the ⌘2 window.
                SyncHistoryView(embedded: true)

            case .backups:
                BackupListView(
                    backups: backupManager.getAllBackupSessions(),
                    selectedBackup: $selectedBackup,
                    showRestoreConfirmation: $showRestoreConfirmation
                )

            case .contactVersions:
                ContactVersionHistoryView()

            case .statistics:
                BackupStatisticsView(backupManager: backupManager)
            }

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // A macOS sheet sizes itself to its content unless told otherwise. With
        // no frame this window collapsed to roughly the height of its header, so
        // the Contacts tab showed its search field and nothing else — the list
        // underneath had no room to draw and looked like a broken search.
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .confirmationDialog("Delete all sync events?",
                            isPresented: $showClearHistoryConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All Events", role: .destructive) {
                SyncHistory.shared.clear()
                viewModel.refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the recorded activity log only. Your backups and contacts are not affected.")
        }
        .sheet(isPresented: $showRestoreConfirmation, onDismiss: {
            selectedBackup = nil
        }) {
            if let backup = selectedBackup {
                RestoreBackupConfirmationView(
                    backup: backup,
                    isPresented: $showRestoreConfirmation,
                    onRestore: {
                        viewModel.restoreBackup(
                            backup,
                            extras: removeContactsAddedSinceBackup ? .remove : .keep
                        )
                    },
                    removeExtras: $removeContactsAddedSinceBackup
                )
            }
        }
        // The outcome was previously never shown: restoreSuccess and restoreError
        // were published and nothing observed them, so a restore — the operation
        // a user reaches for after losing data — gave no confirmation either way.
        .alert("Contacts restored", isPresented: $viewModel.restoreSuccess) {
            Button("OK") { viewModel.restoreSuccess = false }
        } message: {
            Text("Your contacts were rolled back to the selected backup.")
        }
        .alert("Restore incomplete",
               isPresented: .constant(viewModel.restoreError != nil)) {
            Button("OK") { viewModel.restoreError = nil }
        } message: {
            Text(viewModel.restoreError?.localizedDescription ?? "")
        }
        .overlay {
            if viewModel.isRestoring {
                // A restore rewrites the address book; blocking input while it
                // runs prevents a second restore being started on top of it.
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Restoring contacts…")
                        .padding(24)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// SyncTimelineView used to live here — a second, weaker rendering of the same
// events as SyncHistoryView, with no search, no filtering, no export and no
// name redaction. The timeline tab now uses SyncHistoryView(embedded:) so there
// is one implementation to fix when something is wrong with it.


// MARK: - Backup List View

struct BackupListView: View {
    let backups: [BackupSession]
    @Binding var selectedBackup: BackupSession?
    @Binding var showRestoreConfirmation: Bool
    @State private var expandedBackupId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if backups.isEmpty {
                    EmptyState(icon: "externaldrive.badge.xmark",
                               title: "No backups yet",
                               message: "Backups are created automatically during syncs.")
                } else {
                    ForEach(backups) { backup in
                        BackupRowView(
                            backup: backup,
                            isExpanded: expandedBackupId == backup.id,
                            onTap: {
                                withAnimation {
                                    expandedBackupId = expandedBackupId == backup.id ? nil : backup.id
                                }
                            },
                            onRestore: {
                                selectedBackup = backup
                                showRestoreConfirmation = true
                            }
                        )
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Backup Row View

struct BackupRowView: View {
    let backup: BackupSession
    let isExpanded: Bool
    let onTap: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // Icon based on type
                    Image(systemName: backupTypeIcon)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color.appTextInverse)
                        .background(backupTypeColor)
                        .cornerRadius(6)

                    // Info
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(backup.type.rawValue.replacingOccurrences(of: "Backup", with: "").trimmingCharacters(in: .whitespaces))
                                .font(.headline)

                            Spacer()

                            Text(backup.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 12) {
                            Label("\(backup.googleContactsCount) Google", systemImage: "globe")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Label("\(backup.macContactsCount) Mac", systemImage: "laptopcomputer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .foregroundColor(.primary)

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 8)

                    // Backup details
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        HStack {
                            Label("Total Contacts", systemImage: "person.2")
                                .font(.caption)

                            Spacer()

                            Text("\(backup.contactVersions.count)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }

                        HStack {
                            Label("Created", systemImage: "calendar")
                                .font(.caption)

                            Spacer()

                            Text(backup.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                        }

                        if let notes = backup.metadata.customNotes {
                            HStack(alignment: .top) {
                                Label("Notes", systemImage: "note.text")
                                    .font(.caption)

                                Spacer()

                                Text(notes)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                    // Action buttons
                    HStack(spacing: 8) {
                        Button(action: { exportBackup(backup) }) {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: onRestore) {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var backupTypeIcon: String {
        switch backup.type {
        case .preSyncBackup:
            return "arrow.down.doc"
        case .postSyncBackup:
            return "arrow.up.doc"
        case .manualBackup:
            return "hand.thumbsup"
        case .autoBackup:
            return "gear"
        }
    }

    private var backupTypeColor: Color {
        switch backup.type {
        case .preSyncBackup:
            return .orange
        case .postSyncBackup:
            return .green
        case .manualBackup:
            return .blue
        case .autoBackup:
            return .purple
        }
    }

    private func exportBackup(_ backup: BackupSession) {
        ContactBackupManager.shared.exportBackupToFile(id: backup.id)
    }
}

// MARK: - Backup Statistics View

struct BackupStatisticsView: View {
    @ObservedObject var backupManager: ContactBackupManager
    @State private var stats: ContactBackupManager.BackupStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stats = stats {
                    // Summary cards
                    VStack(spacing: 12) {
                        StatisticCard(
                            title: "Total Backups",
                            value: "\(stats.totalBackups)",
                            icon: "externaldrive.fill",
                            color: .blue
                        )

                        StatisticCard(
                            title: "Total Contact Versions",
                            value: "\(stats.totalContactVersions)",
                            icon: "person.2.fill",
                            color: .green
                        )

                        StatisticCard(
                            title: "Storage Used",
                            value: formatBytes(stats.estimatedSizeBytes),
                            icon: "hardrive.fill",
                            color: .orange
                        )
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Timeline info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backup Timeline")
                            .font(.headline)

                        if let oldest = stats.oldestBackup {
                            HStack {
                                Label("Oldest Backup", systemImage: "calendar")
                                Spacer()
                                Text(oldest.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let newest = stats.newestBackup {
                            HStack {
                                Label("Newest Backup", systemImage: "calendar")
                                Spacer()
                                Text(newest.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)

                    Divider()
                        .padding(.vertical, 8)

                    // Recommendations
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendations")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            if stats.totalBackups > 50 {
                                Label("Consider cleaning up old backups (>50 total)", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.appWarning)
                                    .font(.caption)
                            }

                            if stats.estimatedSizeBytes > 1_000_000_000 { // > 1 GB
                                Label("Backup storage exceeds 1 GB", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.appError)
                                    .font(.caption)
                            }

                            if stats.totalBackups == 0 {
                                Label("No backups yet - run a sync to create backups", systemImage: "info.circle")
                                    .foregroundStyle(Color.appAccent)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)

                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
        }
        .onAppear {
            stats = backupManager.getBackupStats()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Statistics Card

struct StatisticCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.appTextInverse)
                .frame(width: 44, height: 44)
                .background(color)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
// SectionDateHeader and SyncEventRow went with SyncTimelineView — they had no
// other callers.


// MARK: - Preview

#if DEBUG
struct SyncHistoryAndBackupView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SyncHistoryAndBackupView()
        }
    }
}
#endif
