//
//  MenuBarView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Menu Bar Popover View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var oauth  = GoogleOAuthManager.shared
    @ObservedObject private var sync   = SyncCoordinator.shared

    let onOpenDashboard:  () -> Void
    let onOpenHistory:    () -> Void
    let onOpenPreferences:() -> Void

    // MARK: Computed

    private var syncStatus: SyncStatus {
        switch sync.phase {
        case .preparing, .syncing:  return .syncing
        case .failed:               return .error
        case .completed(let r):     return r.successful ? .success : .error
        default:
            if let result = appState.lastSyncResult, !result.successful { return .error }
            return .idle
        }
    }

    // Inline feedback derived from the coordinator — no extra @State needed.
    // `String(localized:)` throughout: these used to be plain literals, which
    // `Text(String)` renders verbatim, so the banner never localized.
    private var syncFeedback: (message: String, isFailure: Bool)? {
        switch sync.phase {
        case .completed(let r):
            return r.successful
                ? (String.localized("Done: %@", r.summary), false)
                : (String(localized: "Completed with errors"), true)
        case .failed(let msg):
            return (String.localized("Failed: %@", msg), true)
        default:
            return nil
        }
    }

    private var statusLabel: String {
        if appState.isSyncing { return String(localized: "Sync in progress…") }
        guard let date = appState.lastSyncDate else { return String(localized: "Never synced") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return String.localized("Synced %@", f.localizedString(for: date, relativeTo: Date()))
    }

    private var autoSyncIntervalLabel: String {
        let interval = settings.autoSyncInterval
        if interval < 60 { return String.localized("every %llds", Int(interval)) }
        let minutes = Int(interval / 60)
        if minutes < 60 { return String.localized("every %lld min", minutes) }
        let hours = minutes / 60
        return String.localized("every %lldh", hours)
    }

    private var canSync: Bool {
        !sync.phase.isActive && oauth.isAuthenticated && appState.isMacContactsAuthorized
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

            // Sync feedback banner (driven by SyncCoordinator.phase)
            if settings.menuBarShowFeedbackBanner, let feedback = syncFeedback {
                HStack(spacing: 6) {
                    Image(systemName: feedback.isFailure ? AppIcon.statusError : AppIcon.statusSuccess)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(feedback.isFailure ? Color.appError : Color.appSuccess)
                        .font(.caption)
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))

                Divider()
            }

            // Sync Now + progress
            VStack(spacing: 6) {
                if sync.phase.isActive {
                    VStack(spacing: 4) {
                        ProgressView(value: sync.progress)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(sync.stepLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            // Item counter: "12 / 240"
                            if let p = appState.syncProgress, p.totalItems > 0 {
                                Text("\(p.completedItems) / \(p.totalItems)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sync progress")
                    .accessibilityValue(Text("\(Int(sync.progress * 100)) percent"))

                    // Outside the combined element above, so VoiceOver reaches
                    // it as its own control.
                    Button("Cancel") { sync.cancelSync() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Stop the sync at the next contact")
                }

                syncNowButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.2), value: sync.phase.isActive)

            Divider()

            // Account rows (hideable via Settings → General → Menu Bar)
            if settings.menuBarShowAccounts {
            VStack(spacing: 0) {
                accountRow(
                    icon: AppIcon.sourceGoogle,
                    iconColor: .appSourceGoogle,
                    label: oauth.isAuthenticated
                        ? (oauth.userEmail ?? String(localized: "Google"))
                        : String(localized: "Not connected"),
                    caption: String(localized: "Google Account"),
                    isConnected: oauth.isAuthenticated
                )

                Divider().padding(.leading, 44)

                accountRow(
                    icon: AppIcon.sourceApple,
                    iconColor: .appSourceApple,
                    label: settings.macAccountMode.localizedDisplayName,
                    caption: String(localized: "Mac Contacts"),
                    isConnected: appState.isMacContactsAuthorized
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
            } // end menuBarShowAccounts

            // Auto-sync toggle (hideable)
            if settings.menuBarShowAutoSyncToggle {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Auto-sync", systemImage: AppIcon.autoSync)
                        .font(.subheadline)
                    if settings.autoSyncEnabled {
                        if let next = appState.nextScheduledSync {
                            // Live countdown: "Next sync in 12 min"
                            (Text("Next sync ") + Text(next, style: .relative))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Runs \(autoSyncIntervalLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Off — turn on for background sync")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Real title (hidden visually) so VoiceOver announces
                // "Auto-sync" rather than an unnamed switch.
                Toggle("Auto-sync", isOn: $settings.autoSyncEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.2), value: settings.autoSyncEnabled)

            Divider()
            } // end menuBarShowAutoSyncToggle

            // Navigation links (hideable)
            if settings.menuBarShowNavigationLinks {
            VStack(spacing: 0) {
                menuLink(icon: AppIcon.dashboard, title: "Open Dashboard") {
                    onOpenDashboard()
                }
                menuLink(icon: AppIcon.history, title: "Sync History") {
                    onOpenHistory()
                }
                menuLink(icon: AppIcon.settings, title: "Preferences") {
                    onOpenPreferences()
                }
            }

            Divider()
            } // end menuBarShowNavigationLinks

            // Quit
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit Contact SyncMate", systemImage: AppIcon.quit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(Color.appError)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityHint("Closes Contact SyncMate.")
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.25), value: sync.phase.label)
        // User-selected accent colour (Settings → General → Appearance).
        // `.tint(nil)` follows the system accent.
        .tint(settings.accentColorChoice.tint)
    }

    // MARK: - Sub-views

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatusDot(status: syncStatus)

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

    @State private var showSyncConfirmation = false

    private var syncNowButton: some View {
        Button {
            if settings.confirmBeforeSyncNow {
                showSyncConfirmation = true
            } else {
                Task { await sync.runSync() }
            }
        } label: {
            HStack(spacing: 6) {
                if sync.phase.isActive {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                if sync.phase.isActive {
                    Text(verbatim: sync.phase.label)
                } else {
                    Text("Sync Now")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSync)
        .help(canSync ? "Start syncing contacts" : "Connect both accounts to sync")
        .confirmationDialog(
            "Start sync now?",
            isPresented: $showSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sync Now") { Task { await sync.runSync() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Direction: \(settings.autoSyncDirection.rawValue). You can turn off this confirmation in Settings → General → Confirmations.")
        }
    }

    private func accountRow(icon: String, iconColor: Color, label: String, caption: String, isConnected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Circle()
                .fill(isConnected ? Color.appSuccess : Color.appError)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(label)")
        .accessibilityValue(isConnected ? "Connected" : "Not connected")
    }

    // `LocalizedStringKey`, not `String`: `Text(String)` renders verbatim, so
    // these titles ignored their existing catalog translations.
    private func menuLink(icon: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.subheadline)
        }
        .buttonStyle(.appRow)
        .padding(.horizontal, 8)
    }

}

// MARK: - Localized display names

extension MacAccountMode {
    /// User-facing name. The rawValue is a persistence token and must not be
    /// shown: `Text(rawValue)` renders the English text verbatim in every locale.
    var localizedDisplayName: String {
        switch self {
        case .auto:     return String(localized: "Auto (Recommended)")
        case .all:      return String(localized: "All Accounts")
        case .specific: return String(localized: "Specific Account")
        }
    }
}
// MenuBarView sync action delegated entirely to SyncCoordinator.shared — see syncNowButton.

#Preview {
    MenuBarView(
        onOpenDashboard: {},
        onOpenHistory: {},
        onOpenPreferences: {}
    )
    .environmentObject(AppState())
}
