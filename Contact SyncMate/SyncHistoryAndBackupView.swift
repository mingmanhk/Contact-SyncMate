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
    @State private var selectedTab: HistoryTab = .timeline

    enum HistoryTab {
        case timeline
        case backups
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

                    // Refresh button
                    Button(action: { viewModel.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Color.appAccent)
                    }
                }

                // Tab selector
                Picker("View", selection: $selectedTab) {
                    Text("Timeline").tag(HistoryTab.timeline)
                    Text("Backups").tag(HistoryTab.backups)
                    Text("Stats").tag(HistoryTab.statistics)
                }
                .pickerStyle(.segmented)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            // Content
            switch selectedTab {
            case .timeline:
                SyncTimelineView(viewModel: viewModel)

            case .backups:
                BackupListView(
                    backups: backupManager.getAllBackupSessions(),
                    selectedBackup: $selectedBackup,
                    showRestoreConfirmation: $showRestoreConfirmation
                )

            case .statistics:
                BackupStatisticsView(backupManager: backupManager)
            }

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showRestoreConfirmation, onDismiss: {
            selectedBackup = nil
        }) {
            if let backup = selectedBackup {
                RestoreBackupConfirmationView(
                    backup: backup,
                    isPresented: $showRestoreConfirmation,
                    onRestore: { viewModel.restoreBackup(backup) }
                )
            }
        }
    }
}

// MARK: - Sync Timeline View

struct SyncTimelineView: View {
    @ObservedObject var viewModel: SyncHistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.syncEvents.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.appTextTertiary)

                        Text("No Sync History")
                            .font(.headline)

                        Text("Sync history will appear here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ForEach(viewModel.groupedEvents.keys.sorted(by: >), id: \.self) { date in
                        SectionDateHeader(date: date)

                        VStack(spacing: 0) {
                            ForEach(viewModel.groupedEvents[date] ?? [], id: \.id) { event in
                                SyncEventRow(event: event)
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

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
                    VStack(spacing: 16) {
                        Image(systemName: "externaldrive.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.appTextTertiary)

                        Text("No Backups")
                            .font(.headline)

                        Text("Backups will be created automatically during syncs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
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

// MARK: - Supporting Views

struct SectionDateHeader: View {
    let date: Date

    var body: some View {
        HStack {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct SyncEventRow: View {
    let event: SyncEvent

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(eventColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.action)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    Text(event.source)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let details = event.details {
                        Text("•")
                            .foregroundColor(.secondary)

                        Text(details)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private var eventColor: Color {
        if event.action.contains("error") || event.action.contains("failed") {
            return .red
        } else if event.action.contains("warning") {
            return .orange
        } else if event.action.contains("success") || event.action.contains("complete") {
            return .green
        } else {
            return .blue
        }
    }
}

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
