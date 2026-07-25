//
//  RestoreBackupDialog.swift
//  Contact SyncMate
//
//  Created by Claude AI on March 29, 2026
//
//  Confirmation dialog for restoring from backup
//

import SwiftUI

struct RestoreBackupConfirmationView: View {
    let backup: BackupSession
    @Binding var isPresented: Bool
    let onRestore: () -> Void

    @State private var isRestoring = false
    @State private var showBackupDetails = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: AppIcon.restore)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 24))
                            .foregroundStyle(Color.appWarning)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Restore from Backup")
                                .font(.headline)

                            Text("This will restore all contacts to a previous state")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(16)
                }
                .background(Color.appSurfaceTinted)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Warning
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: AppIcon.statusWarning)
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.appWarning)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Important")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)

                                    Text("Current contacts will be replaced. Make sure you want to continue.")
                                        .font(.caption)
                                }

                                Spacer()
                            }
                            .padding(12)
                        }
                        .background(Color.appWarning.opacity(0.10))
                        .cornerRadius(8)
                        .accessibilityElement(children: .combine)

                        Divider()

                        // Backup info
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Backup Information")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            VStack(alignment: .leading, spacing: 10) {
                                InfoRow(label: "Type", value: backup.type.rawValue)

                                InfoRow(
                                    label: "Created",
                                    value: backup.timestamp.formatted(date: .abbreviated, time: .standard)
                                )

                                InfoRow(label: "Google Contacts", value: "\(backup.googleContactsCount)")

                                InfoRow(label: "Mac Contacts", value: "\(backup.macContactsCount)")

                                InfoRow(
                                    label: "Total Contacts",
                                    value: "\(backup.contactVersions.count)"
                                )

                                if let notes = backup.metadata.customNotes {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Notes")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        Text(notes)
                                            .font(.caption)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.appSurfaceTinted)
                            .cornerRadius(6)
                        }

                        // Details button
                        Button(action: { showBackupDetails = true }) {
                            HStack {
                                Image(systemName: AppIcon.statusInfo)
                                    .symbolRenderingMode(.hierarchical)
                                Text("View Full Details")
                                Spacer()
                                Image(systemName: AppIcon.disclosure)
                            }
                            .font(.subheadline)
                            .foregroundStyle(Color.appAccent)
                            .padding(12)
                            .background(Color.appSurfaceTinted)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens a detailed view of the backup contents.")

                        // What will happen
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What will happen")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            VStack(alignment: .leading, spacing: 8) {
                                StepRow(number: 1, text: "A new backup of current contacts will be created")

                                StepRow(number: 2, text: "All contacts will be updated to match this backup")

                                StepRow(number: 3, text: "Sync history will record this restoration")

                                StepRow(number: 4, text: "You can undo by restoring to another backup")
                            }
                        }
                    }
                    .padding(16)
                }

                Divider()

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { isPresented = false }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        isRestoring = true
                        onRestore()
                        // Simulate restore time
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isPresented = false
                        }
                    }) {
                        if isRestoring {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(12)
                        } else {
                            Text("Restore")
                                .frame(maxWidth: .infinity)
                                .padding(12)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRestoring)
                    .accessibilityHint("Replaces your current contacts with the contents of this backup.")
                }
                .padding(16)
                .background(Color.appSurfaceTinted)
            }
            .sheet(isPresented: $showBackupDetails) {
                BackupDetailsView(backup: backup)
            }
        }
    }
}

// MARK: - Supporting Views

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.semibold)
                .frame(width: 24, height: 24)
                .background(Color.appAccent)
                .foregroundStyle(Color.appTextInverse)
                .cornerRadius(4)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption)
                .lineLimit(3)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}

// MARK: - Backup Details View

struct BackupDetailsView: View {
    let backup: BackupSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Backup Summary")
                            .font(.headline)

                        VStack(spacing: 8) {
                            DetailRow(label: "ID", value: backup.id)
                            DetailRow(label: "Type", value: backup.type.rawValue)
                            DetailRow(label: "Created", value: backup.timestamp.formatted(date: .abbreviated, time: .standard))
                            DetailRow(label: "Google Contacts", value: "\(backup.googleContactsCount)")
                            DetailRow(label: "Mac Contacts", value: "\(backup.macContactsCount)")
                        }
                    }

                    Divider()

                    // Contacts list
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Contacts in Backup")
                                .font(.headline)

                            Spacer()

                            Text("\(backup.contactVersions.count)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(4)
                                .background(Color.appAccent)
                                .foregroundStyle(Color.appTextInverse)
                                .cornerRadius(4)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(backup.contactVersions.prefix(10)) { version in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(version.contactName)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)

                                        Text(version.source.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                    .background(Color.appSurfaceTinted)
                                    .cornerRadius(6)
                                }

                                if backup.contactVersions.count > 10 {
                                    VStack(alignment: .center, spacing: 4) {
                                        Text("+\(backup.contactVersions.count - 10)")
                                            .font(.caption)
                                            .fontWeight(.semibold)

                                        Text("more")
                                            .font(.caption2)
                                    }
                                    .padding(8)
                                    .background(Color.appAccent.opacity(0.10))
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }

                    Divider()

                    // Metadata
                    if let syncDirection = backup.metadata.syncDirection {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sync Configuration")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            DetailRow(label: "Direction", value: syncDirection)
                            if let mode = backup.metadata.syncMode {
                                DetailRow(label: "Mode", value: mode)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Backup Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Preview

#if DEBUG
struct RestoreBackupConfirmationView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleBackup = BackupSession(
            id: UUID().uuidString,
            timestamp: Date(),
            syncSessionId: nil,
            type: .postSyncBackup,
            googleContactsCount: 150,
            macContactsCount: 120,
            contactVersions: [],
            metadata: BackupMetadata(
                appVersion: "1.0.0",
                syncDirection: "2-way",
                syncMode: "manual",
                autoResolution: nil,
                customNotes: "Backup after sync"
            )
        )

        RestoreBackupConfirmationView(
            backup: sampleBackup,
            isPresented: .constant(true),
            onRestore: {}
        )
    }
}
#endif
