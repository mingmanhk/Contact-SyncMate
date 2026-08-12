//
//  DashboardView.swift
//  Contact SyncMate
//

import SwiftUI
import Contacts
import Combine

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var oauth = GoogleOAuthManager.shared

    // Shared coordinator — single source of truth for sync state
    @StateObject private var sync = SyncCoordinator.shared

    @State private var showSyncPreview = false
    @State private var showHistoryView = false
    @State private var recentEvents: [SyncEvent] = []

    // Dedup confirmation (picked up from sync.dedupAwaitingConfirmation).
    // The coordinator is held here for the sheet's lifetime because it owns
    // the scan result on display and executes the user's decisions.
    @State private var showDedupConfirmation = false
    @State private var dedupCoordinator: DeduplicationCoordinator?

    // Sync feedback (derived from sync.phase — see onChange below)
    @State private var syncResultBanner: SyncResultBanner?
    @State private var showClearHistoryConfirmation = false
    @State private var syncErrorMessage: String?

    // MARK: Computed helpers

    private var syncStatus: SyncStatus {
        switch sync.phase {
        case .preparing, .syncing:           return .syncing
        case .failed:                        return .error
        case .completed(let r):              return r.successful ? .success : .error
        default:
            if let result = appState.lastSyncResult, !result.successful { return .error }
            return .idle
        }
    }

    private var lastSyncLabel: String {
        guard let date = appState.lastSyncDate else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var canSync: Bool {
        !sync.phase.isActive && oauth.isAuthenticated && appState.isMacContactsAuthorized
    }

    private var syncButtonTooltip: String {
        if sync.phase.isActive { return "Sync is already in progress" }
        if !oauth.isAuthenticated { return "Connect your Google account first" }
        if !appState.isMacContactsAuthorized { return "Grant Mac Contacts access first" }
        return "Start syncing contacts now"
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Result banner (success/error)
                    if let banner = syncResultBanner {
                        resultBannerView(banner)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let error = syncErrorMessage {
                        errorBannerView(error)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Prerequisite warnings
                    if !oauth.isAuthenticated || !appState.isMacContactsAuthorized {
                        prerequisiteWarning
                    }

                    // Account cards
                    accountCardsSection

                    // Sync direction
                    syncDirectionSection

                    // Sync Now button + progress
                    syncNowSection

                    // Recent activity
                    recentActivitySection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Sync Now also lives in the toolbar so it stays reachable when the
        // user has scrolled down to Recent Activity — the primary action of a
        // window should never scroll out of view (HIG).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    triggerSync()
                } label: {
                    Label(sync.phase.isActive ? sync.phase.label : "Sync Now",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canSync)
                // No keyboardShortcut here: the app's Sync menu already owns
                // ⌘R, and binding it twice makes the shortcut ambiguous.
                .help(syncButtonTooltip)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: syncResultBanner != nil)
        .animation(.easeInOut(duration: 0.25), value: syncErrorMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: appState.isSyncing)
        .sheet(isPresented: $showSyncPreview, onDismiss: {
            // A dedup confirmation published in the same run waits behind the
            // review sheet — two sheets cannot present in one transaction, and
            // the review is the primary flow. Pick it up now that the review
            // is out of the way.
            presentDedupConfirmationIfPending()
        }) {
            if let session = appState.currentSyncSession {
                SyncPreviewView(session: session, isPresented: $showSyncPreview) { reviewed in
                    applyReviewedSession(reviewed)
                }
            }
        }
        .sheet(isPresented: $showDedupConfirmation, onDismiss: {
            dedupCoordinator = nil
        }) {
            if let coordinator = dedupCoordinator {
                coordinator.presentConfirmationUI()
            }
        }
        .sheet(isPresented: $showHistoryView) {
            SyncHistoryAndBackupView(isSheet: true)
        }
        .confirmationDialog("Delete all sync events?",
                            isPresented: $showClearHistoryConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All Events", role: .destructive) {
                SyncHistory.shared.clear()
                recentEvents = []
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the recorded activity log only. Your backups and contacts are not affected.")
        }
        // Review mode reaches here from any entry point — menu bar, Settings or
        // the Dashboard button — because they all run through SyncCoordinator.
        .onChange(of: sync.sessionAwaitingReview?.id) { _, id in
            guard id != nil, let session = sync.sessionAwaitingReview else { return }
            appState.currentSyncSession = session
            showSyncPreview = true
            sync.sessionAwaitingReview = nil
        }
        // Same publish/present contract as sessionAwaitingReview: the scan's
        // coordinator was a discarded local in runSync, so the confirmation
        // sheet had no presenter and the "needs review" notification pointed
        // nowhere.
        .onChange(of: sync.dedupAwaitingConfirmation.map { ObjectIdentifier($0) }) { _, id in
            guard id != nil else { return }
            presentDedupConfirmationIfPending()
        }
        .onAppear {
            recentEvents = Self.interestingEvents(from: SyncHistory.shared.events())
            // Give the coordinator a handle to AppState so it can update isSyncing etc.
            sync.appState = appState
            // A session published before this window existed: onChange never
            // fires for it, so a menu-bar sync's review used to be orphaned
            // until the next run replaced it. Pick it up on appearance.
            if let session = sync.sessionAwaitingReview {
                appState.currentSyncSession = session
                showSyncPreview = true
                sync.sessionAwaitingReview = nil
            }
            // A dedup confirmation published before this window existed —
            // a menu-bar run, or a scheduled run whose notification the user
            // just clicked. Deferred behind the review sheet if one opened.
            presentDedupConfirmationIfPending()
        }
        // Drive banners from the coordinator's phase
        // The engine reports progress per contact, which makes it the natural
        // clock for streaming the list — no timer to own, and nothing polls
        // while idle.
        .onChange(of: sync.progress) { _, _ in
            guard sync.phase.isActive else { return }
            recentEvents = Self.interestingEvents(from: SyncHistory.shared.events())
        }
        .onChange(of: sync.phase) { _, phase in
            switch phase {
            case .completed(let r):
                withAnimation {
                    syncErrorMessage = nil
                    syncResultBanner = SyncResultBanner(
                        icon: r.successful
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill",
                        color: r.successful ? .appSuccess : .appWarning,
                        title: r.successful ? "Sync Completed" : "Sync Completed with Errors",
                        // One line, because the banner is one line. The
                        // multi-line `summary` was truncated to "…21" here,
                        // which told the user nothing except that a number
                        // ending in 21 existed.
                        detail: r.summary
                    )
                }
                recentEvents = Self.interestingEvents(from: SyncHistory.shared.events())
            case .failed(let msg):
                withAnimation {
                    syncResultBanner = nil
                    syncErrorMessage = msg
                }
            case .preparing, .syncing:
                withAnimation {
                    syncResultBanner = nil
                    syncErrorMessage = nil
                }
                // Show the writes as they land. Refreshing only on completion
                // meant the most informative moment — a long sync in flight —
                // was the one showing "No sync history yet".
                recentEvents = Self.interestingEvents(from: SyncHistory.shared.events())
            case .idle:
                break
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Contact SyncMate")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            // Last-sync result pill
            if let result = appState.lastSyncResult, !appState.isSyncing {
                lastSyncResultPill(result)
            }

            HStack(spacing: 6) {
                StatusDot(status: syncStatus)
                Text(appState.isSyncing ? "Syncing…" : lastSyncLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Preferences")
            .help("Open Preferences")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func lastSyncResultPill(_ result: SyncResult) -> some View {
        HStack(spacing: 10) {
            if result.added > 0 {
                Label("\(result.added)", systemImage: "plus")
                    .foregroundStyle(Color.appSuccess)
            }
            if result.updated > 0 {
                Label("\(result.updated)", systemImage: "pencil")
                    .foregroundStyle(Color.appInfo)
            }
            if result.deleted > 0 {
                Label("\(result.deleted)", systemImage: "minus")
                    .foregroundStyle(Color.appError)
            }
            if result.added == 0 && result.updated == 0 && result.deleted == 0 {
                Text("No changes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }

    // MARK: - Prerequisite Warning

    private var prerequisiteWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Setup Required", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appWarning)

            if !oauth.isAuthenticated {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(Color.appError)
                        .font(.caption)
                    Text("Google account not connected — open Settings → Accounts to sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !appState.isMacContactsAuthorized {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(Color.appError)
                        .font(.caption)
                    Text("Mac Contacts access not granted — open Settings → Accounts to authorize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Open Accounts Settings") {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appWarning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appWarning.opacity(0.3)))
    }

    // MARK: - Account Cards

    private var accountCardsSection: some View {
        HStack(spacing: 16) {
            accountCard(
                icon: "person.crop.circle.fill",
                iconColor: .appSourceGoogle,
                title: String(localized: "Google Account"),
                detail: oauth.isAuthenticated
                    ? (oauth.userEmail ?? String(localized: "Connected"))
                    : String(localized: "Not connected"),
                isConnected: oauth.isAuthenticated
            )
            // Re-consenting is the fix for a permission that was not granted,
            // and the only way to do it was a Sign Out button in a Settings
            // section the user has to know to look in. Put it where the account
            // is shown and the failure is read.
            .contextMenu {
                if oauth.isAuthenticated {
                    Button("Reconnect (re-approve permissions)") {
                        oauth.signOut()
                        GoogleOAuthManager.shared.startSignInFromCurrentWindow()
                    }
                    Button("Sign Out", role: .destructive) { oauth.signOut() }
                }
            }

            accountCard(
                icon: "desktopcomputer",
                iconColor: .appSourceApple,
                title: String(localized: "Mac Contacts"),
                detail: CNContactStore.authorizationStatus(for: .contacts) == .authorized
                    ? settings.macAccountMode.localizedDisplayName
                    : String(localized: "No access"),
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
                    .foregroundStyle(isConnected ? Color.secondary : Color.appError)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(isConnected ? Color.appSuccess : Color.appError)
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
            HStack {
                Text("Sync Direction")
                    .font(.headline)
                Spacer()
                Text("Applied on next sync")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Picker("Sync direction", selection: $settings.autoSyncDirection) {
                Text("2-Way").tag(SyncDirection.twoWay)
                Text("Google → Mac").tag(SyncDirection.googleToMac)
                Text("Mac → Google").tag(SyncDirection.macToGoogle)
            }
            .pickerStyle(.segmented)

            Text(settings.autoSyncDirection.directionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .animation(.easeInOut(duration: 0.2), value: settings.autoSyncDirection)
        }
    }

    // MARK: - Sync Now

    private var syncNowSection: some View {
        VStack(spacing: 12) {
            // Phase-aware progress block (visible during active sync)
            if sync.phase.isActive {
                VStack(spacing: 6) {
                    ProgressView(value: sync.progress)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: sync.progress)

                    HStack {
                        Text(sync.stepLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(sync.phase.label)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Button("Cancel") { sync.cancelSync() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Stop the sync at the next contact")
                    }
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Sync Now button ───────────────────────────────────────
            Button {
                triggerSync()
            } label: {
                HStack(spacing: 8) {
                    if sync.phase.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(sync.phase.isActive ? sync.phase.label : "Sync Now")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .controlSize(.large)
            .disabled(!canSync)
            .help(syncButtonTooltip)

            // Quick status line below the button
            if case .completed(let r) = sync.phase {
                Label(r.summary, systemImage: r.successful ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(r.successful ? Color.appSuccess : Color.appWarning)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sync.phase.isActive)
    }

    private var buttonTint: Color {
        switch sync.phase {
        case .failed:       return .appError
        case .completed(let r): return r.successful ? .appSuccess : .appWarning
        default:            return .accentColor
        }
    }

    // MARK: - Result / Error Banners

    private func resultBannerView(_ banner: SyncResultBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.icon)
                .foregroundStyle(banner.color)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(banner.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation { syncResultBanner = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(12)
        .background(banner.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(banner.color.opacity(0.2)))
    }

    private func errorBannerView(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appError)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Failed")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            Button {
                withAnimation { syncErrorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(12)
        .background(Color.appError.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appError.opacity(0.3)))
    }

    // MARK: - Recent Activity

    /// Actions worth showing on the dashboard: per-contact changes, sync
    /// outcomes, restores. Filters out internal plumbing noise
    /// (fetchAllContacts.begin, timer logs, container discovery, …) so the
    /// user sees WHAT the app did to their contacts.
    static func interestingEvents(from all: [SyncEvent], limit: Int = 8) -> [SyncEvent] {
        let interesting: (SyncEvent) -> Bool = { e in
            e.action.hasPrefix("change.") ||
            e.action.hasPrefix("sync.") ||
            e.action.hasPrefix("restore") ||
            e.action.hasPrefix("rollback") ||
            e.action == "userDecision"
        }
        return Array(all.filter(interesting).suffix(limit).reversed())
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Changes")
                    .font(.headline)
                Spacer()
                if !recentEvents.isEmpty {
                    Button("Clear") { showClearHistoryConfirmation = true }
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                        .help("Delete all recorded sync events. Backups and contacts are not affected.")

                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                Button("View History & Backups") {
                    showHistoryView = true
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }

            if recentEvents.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath",
                           title: "No sync history yet",
                           message: "Run your first sync to see activity here.",
                           fill: false)
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
        let icon = eventIcon(for: event.action)
        return HStack(spacing: 12) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .font(.body)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(friendlyLabel(for: event.action))
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let detail = event.details, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Failures carry the API payload that says what actually
                        // went wrong, and one line of it is never the useful
                        // part — "API error (403): {…" tells you nothing.
                        .lineLimit(isFailure(event.action) ? 6 : 1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background)
        // Right-click → Copy. Reading an error off a screenshot and retyping it
        // is how detail gets lost, and the detail is the whole message here.
        .contextMenu {
            Button("Copy") { copyToPasteboard(Self.plainText(event)) }
            Button("Copy All Recent Changes") {
                // `map { Self.plainText($0) }`, not `map(Self.plainText)`. The
                // second form makes a function *value*, which has no enclosing
                // context to inherit isolation from — a compile error under
                // default MainActor isolation. The closure inherits this one.
                copyToPasteboard(recentEvents.map { Self.plainText($0) }.joined(separator: "\n"))
            }
        }
        .help(event.details ?? friendlyLabel(for: event.action))
    }

    private func isFailure(_ action: String) -> Bool {
        let lowered = action.lowercased()
        return lowered.contains("fail") || lowered.contains("error")
    }

    /// One log line, in the shape you would want pasted into a bug report.
    ///
    /// `nonisolated` so it can be called from the context menu's escaping
    /// closure without the enclosing view's isolation. It reads only `let`
    /// properties of a `Sendable` struct, which is the case where that is
    /// actually true rather than merely convenient.
    private nonisolated static func plainText(_ event: SyncEvent) -> String {
        let stamp = event.timestamp.formatted(date: .abbreviated, time: .standard)
        let detail = event.details.map { " — \($0)" } ?? ""
        return "[\(stamp)] \(event.source) \(event.action)\(detail)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Sync Action

    private func triggerSync() {
        withAnimation {
            syncResultBanner = nil
            syncErrorMessage = nil
        }

        // Through the coordinator for every mode — including manual review.
        // The old private-engine preview path here diverged from the shared
        // pipeline: phase stayed idle (menu-bar icon disagreed with this
        // window), Cancel and the watchdog didn't apply, the dedup scan was
        // skipped, and a scheduled run could start mid-preview. runSync's
        // review path publishes sessionAwaitingReview, which this view
        // presents via onChange/onAppear.
        Task { await sync.runSync() }
    }

    /// Take ownership of a published dedup confirmation, unless a review
    /// sheet is (or is about to be) on screen — then it stays published and
    /// the review sheet's onDismiss picks it up.
    ///
    /// Both orderings of the two onChange handlers are covered: if this runs
    /// first the session is still awaiting pickup (`sessionAwaitingReview`
    /// non-nil); if the session handler ran first the preview is already
    /// showing (`showSyncPreview`).
    private func presentDedupConfirmationIfPending() {
        guard !showSyncPreview,
              sync.sessionAwaitingReview == nil,
              !showDedupConfirmation,
              let coordinator = sync.dedupAwaitingConfirmation else { return }
        dedupCoordinator = coordinator
        showDedupConfirmation = true
        sync.dedupAwaitingConfirmation = nil
    }

    /// Apply a session the user reviewed in the preview sheet.
    ///
    /// The Apply button used to be a TODO that just closed the sheet, so manual
    /// mode showed the user exactly what it was going to do and then did nothing.
    private func applyReviewedSession(_ session: SyncSession) {
        // Through the coordinator, not around it. Building a SyncEngine here
        // meant nothing was subscribed to its progress, so the header read
        // "Syncing…" while the progress bar and the live event list — both of
        // which watch SyncCoordinator.phase — showed nothing at all.
        //
        // The result banner still appears: the .onChange(of: sync.phase) handler
        // above builds it from the completed phase, the same as for every other
        // sync. This method no longer needs its own copy of that either.
        Task { await sync.applyReviewed(session) }
    }

    // MARK: - Error Handling (used only by the manual-preview path)

    private func handleSyncError(_ error: Error) {
        let friendly = SyncCoordinator.friendlyMessage(for: error)
        withAnimation { syncErrorMessage = friendly }
        SyncHistory.shared.log(source: "Dashboard", action: "sync.error",
                               details: "\(friendly) — \(error.localizedDescription)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            withAnimation { self.syncErrorMessage = nil }
        }
        recentEvents = Array(SyncHistory.shared.events().suffix(5).reversed())
    }

    // friendlyErrorMessage lived here — 62 lines that had drifted from
    // SyncCoordinator.friendlyMessage(for:), which is what handleSyncError
    // actually calls.

    // formatResultSummary went with it; SyncResult.summary is used instead.

    // MARK: - Event Helpers

    private func friendlyLabel(for action: String) -> String {
        switch action {
        case "sync.complete":           return "Sync completed"
        case "sync.failed":             return "Sync failed"
        case "sync.start", "scanForDuplicates.start": return "Sync started"
        case "sync.preview":            return "Sync preview prepared"
        case "sync.error":              return "Sync failed"
        case "change.add":              return "Contact added"
        case "change.update":           return "Contact updated"
        case "change.delete":           return "Contact deleted"
        case "change.merge":            return "Contacts merged"
        case "change.failed":           return "Change failed"
        case "restore.success", "rollback.success":  return "Backup restored"
        case "restore.partial", "rollback.partial":  return "Backup partially restored"
        case "add":                     return "Contact added"
        case "update":                  return "Contact updated"
        case "delete":                  return "Contact deleted"
        case "merge.deferred":          return "Conflict flagged for review"
        case "autoMerge":               return "Duplicates auto-merged"
        case "userMerge":               return "Duplicates merged"
        case "keepSeparate":            return "Contacts kept separate"
        case "skippedDuplicatesNotification": return "Duplicates skipped (auto-sync)"
        case "createMappingFromMerge":  return "Contact mapping created"
        case "clearPatterns":           return "Saved patterns cleared"
        default:
            return action
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private func eventIcon(for action: String) -> (name: String, color: Color) {
        if action.contains("error") || action.contains("Error") {
            return ("xmark.circle.fill", .appError)
        }
        switch action {
        case "sync.complete":         return (AppIcon.statusSuccess, .appSuccess)
        case "sync.failed":           return (AppIcon.statusError, .appError)
        case "sync.start", "scanForDuplicates.start": return (AppIcon.statusSyncing, Color.appAccent)
        case "sync.preview":          return ("eye.circle.fill", .appInfo)
        case "change.add", "add":     return (AppIcon.added, .appSuccess)
        case "change.update", "update": return (AppIcon.updated, .appInfo)
        case "change.delete", "delete": return (AppIcon.deleted, .appError)
        case "change.merge":          return ("arrow.triangle.merge", .appBrand)
        case "change.failed":         return (AppIcon.statusWarning, .appWarning)
        case "restore.success", "rollback.success": return (AppIcon.restore, .appSuccess)
        case "restore.partial", "rollback.partial": return (AppIcon.restore, .appWarning)
        case "merge.deferred":        return (AppIcon.statusWarning, .appWarning)
        case "autoMerge", "userMerge": return ("arrow.triangle.merge", .appBrand)
        default:                      return ("clock.fill", .secondary)
        }
    }
}

// MARK: - Sync Result Banner Model

struct SyncResultBanner: Equatable {
    let icon: String
    let color: Color
    let title: String
    let detail: String
}

// MARK: - SyncDirection helpers (Dashboard)

private extension SyncDirection {
    var directionDescription: String {
        switch self {
        case .twoWay:
            return "Changes on either side are merged — additions, edits and deletions flow in both directions."
        case .googleToMac:
            return "Google Contacts are the master copy. Changes in Google overwrite Mac; Mac-only changes are ignored."
        case .macToGoogle:
            return "Mac Contacts are the master copy. Changes on Mac overwrite Google; Google-only changes are ignored."
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
