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
    let backup: BackupSessionSummary
    @Binding var isPresented: Bool
    let onRestore: () -> Void
    @Binding var removeExtras: Bool

    @State private var isRestoring = false
    @State private var showBackupDetails = false

    var body: some View {
        // No NavigationView here.
        //
        // It used to wrap this whole dialog, and on macOS NavigationView is a
        // split view: inside a sheet with no size proposed to it, it collapsed to
        // a sliver showing nothing but two truncated buttons. There is no
        // navigation in this dialog to justify it. An explicit frame is what a
        // macOS sheet needs — the same approach SyncPreviewView uses.
        Group {
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
                        // Without this the restore is a merge, not a revert:
                        // anything added since the backup survives it, so a
                        // rollback cannot undo contacts a bad sync created —
                        // which is usually the whole reason for restoring.
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Delete contacts added since this backup",
                                   isOn: $removeExtras)
                                .toggleStyle(.checkbox)

                            Text(removeExtras
                                 ? "Both address books will match this backup exactly. Contacts created after it — including any a faulty sync added — will be deleted."
                                 : "Contacts created after this backup will be kept. Use this if you only want to recover changed or deleted contacts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(Color.appSurfaceTinted)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("A safety snapshot of the current state is taken first, so this restore can itself be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

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
                                InfoRow(label: String(localized: "Type"), value: backup.type.localizedDisplayName)

                                InfoRow(
                                    label: String(localized: "Created"),
                                    value: backup.timestamp.formatted(date: .abbreviated, time: .standard)
                                )

                                InfoRow(label: String(localized: "Google Contacts"), value: "\(backup.googleContactsCount)")

                                InfoRow(label: String(localized: "Mac Contacts"), value: "\(backup.macContactsCount)")

                                InfoRow(
                                    label: String(localized: "Total Contacts"),
                                    value: "\(backup.versionCount)"
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
                                StepRow(number: 1, text: String(localized: "A new backup of current contacts will be created"))

                                StepRow(number: 2, text: String(localized: "All contacts will be updated to match this backup"))

                                StepRow(number: 3, text: String(localized: "Sync history will record this restoration"))

                                StepRow(number: 4, text: String(localized: "You can undo by restoring to another backup"))
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
                        // Hand off and close. The old code showed a spinner for a
                        // hard-coded 2 seconds — "simulate restore time" — which
                        // had nothing to do with the actual restore and finished
                        // long before it did. The presenting view owns the real
                        // progress overlay and the success/failure alerts.
                        isRestoring = true
                        onRestore()
                        isPresented = false
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
        .frame(width: 560, height: 620)
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
    let backup: BackupSessionSummary
    @Environment(\.dismiss) var dismiss

    /// Contact names come from the session body, which the metadata-only index
    /// (#56) no longer keeps in memory — it loads from disk when this sheet
    /// opens, not before.
    @State private var contactVersions: [ContactVersion]?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Backup Summary")
                            .font(.headline)

                        VStack(spacing: 8) {
                            DetailRow(label: String(localized: "ID"), value: backup.id)
                            DetailRow(label: String(localized: "Type"), value: backup.type.localizedDisplayName)
                            DetailRow(label: String(localized: "Created"), value: backup.timestamp.formatted(date: .abbreviated, time: .standard))
                            DetailRow(label: String(localized: "Google Contacts"), value: "\(backup.googleContactsCount)")
                            DetailRow(label: String(localized: "Mac Contacts"), value: "\(backup.macContactsCount)")
                        }
                    }

                    Divider()

                    // Contacts list
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Contacts in Backup")
                                .font(.headline)

                            Spacer()

                            Text("\(backup.versionCount)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(4)
                                .background(Color.appAccent)
                                .foregroundStyle(Color.appTextInverse)
                                .cornerRadius(4)
                        }

                        if let contactVersions {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(contactVersions.prefix(10)) { version in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(version.contactName)
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .lineLimit(1)

                                            Text(version.source.localizedDisplayName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(8)
                                        .background(Color.appSurfaceTinted)
                                        .cornerRadius(6)
                                    }

                                    if contactVersions.count > 10 {
                                        VStack(alignment: .center, spacing: 4) {
                                            Text("+\(contactVersions.count - 10)")
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
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Divider()

                    // Metadata
                    if let syncDirection = backup.metadata.syncDirection {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sync Configuration")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            DetailRow(label: String(localized: "Direction"), value: syncDirection)
                            if let mode = backup.metadata.syncMode {
                                DetailRow(label: String(localized: "Mode"), value: mode)
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
        .task {
            // After the sheet renders, so a large session body does not delay
            // its appearance. A vanished file shows an empty list rather than
            // spinning forever.
            contactVersions = ContactBackupManager.shared
                .getBackupSession(id: backup.id)?.contactVersions ?? []
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

// MARK: - Localized display names

extension BackupSession.BackupType {
    /// User-facing name. The rawValue is a persistence token ("preSyncBackup")
    /// and must never be shown.
    var localizedDisplayName: String {
        switch self {
        case .preSyncBackup:  return String(localized: "Pre-sync backup")
        case .postSyncBackup: return String(localized: "Post-sync backup")
        case .manualBackup:   return String(localized: "Manual backup")
        case .autoBackup:     return String(localized: "Automatic backup")
        }
    }
}

extension ContactVersion.ContactSource {
    var localizedDisplayName: String {
        switch self {
        case .google: return String(localized: "Google")
        case .mac:    return String(localized: "Mac")
        case .merged: return String(localized: "Merged")
        }
    }
}

// MARK: - Preview

#if DEBUG
struct RestoreBackupConfirmationView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleBackup = BackupSessionSummary(
            id: UUID().uuidString,
            timestamp: Date(),
            syncSessionId: nil,
            type: .postSyncBackup,
            googleContactsCount: 150,
            macContactsCount: 120,
            versionCount: 0,
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
            onRestore: {},
            removeExtras: .constant(false)
        )
    }
}
#endif
