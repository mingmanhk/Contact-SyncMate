//
//  SettingsView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//  Modernised: April 2026 — adaptive layout, semantic colours, macOS HIG
//

import SwiftUI
import Contacts

// MARK: - Semantic Colour Palette

/// Thin facade over the project-wide design tokens defined in
/// `DesignSystem/Color+App.swift`. Kept here so existing call-sites (`Palette.success`)
/// continue to compile while delegating to the asset-catalog-backed accessors
/// that adapt to light / dark mode.
private enum Palette {
    static var background       : Color { .appBackground }
    static var cardBackground   : Color { .appSurface }
    static var separator        : Color { .appBorder }
    static var accent           : Color { .appAccent }
    static var primaryText      : Color { .appTextPrimary }
    static var secondaryText    : Color { .appTextSecondary }
    static var success          : Color { .appSuccess }
    static var warning          : Color { .appWarning }
    static var danger           : Color { .appError }
}

// `AdaptiveIcon` is now provided globally by `DesignSystem/AdaptiveIcon.swift`.
// The previous private duplicate has been removed.

// MARK: - Settings Section Enum

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general     = "General"
    case syncFields  = "Sync Fields"
    case manualSync  = "Manual Sync"
    case autoSync    = "Auto Sync"
    case aiMatching  = "AI Matching"
    case accounts    = "Accounts"
    case backups     = "Backups"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:    return "gear"
        case .syncFields: return "slider.horizontal.3"
        case .manualSync: return "hand.tap"
        case .autoSync:   return "clock.arrow.circlepath"
        case .aiMatching: return "sparkles"
        case .accounts:   return "person.2.circle"
        case .backups:    return "externaldrive"
        }
    }

    var group: SectionGroup {
        switch self {
        case .general:                    return .app
        case .syncFields, .manualSync, .autoSync: return .sync
        case .aiMatching:                 return .advanced
        case .accounts, .backups:         return .account
        }
    }

    enum SectionGroup: String {
        case app      = "App"
        case sync     = "Sync"
        case advanced = "Advanced"
        case account  = "Account"
    }
}

// MARK: - Settings View (Root)

struct SettingsView: View {
    @StateObject private var settings     = AppSettings.shared
    @StateObject private var oauthManager = GoogleOAuthManager.shared

    @State private var selectedSection: SettingsSection = .general

    // Groups in display order
    private let groups: [(SettingsSection.SectionGroup, [SettingsSection])] = [
        (.app,      [.general]),
        (.sync,     [.syncFields, .manualSync, .autoSync]),
        (.advanced, [.aiMatching]),
        (.account,  [.accounts, .backups])
    ]

    var body: some View {
        NavigationSplitView {
            // ── Sidebar ───────────────────────────────────────────────
            sidebarList
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            // ── Detail panel ─────────────────────────────────────────
            VStack(spacing: 0) {
                accountBanner
                Divider()
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        // User-selected accent colour (General → Theme). nil = system accent.
        .tint(settings.accentColorChoice.tint)
        .onReceive(NotificationCenter.default.publisher(for: .showAccountsSettings)) { _ in
            selectedSection = .accounts
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $selectedSection) {
            ForEach(groups, id: \.0.rawValue) { group, sections in
                Section(group.rawValue) {
                    ForEach(sections) { section in
                        sidebarRow(section)
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.rawValue)
                .font(.subheadline)
        } icon: {
            Image(systemName: section.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor(for: section))
                .frame(width: 20)
        }
        .padding(.vertical, 1)
        // Highlight Accounts row if not connected
        .overlay(alignment: .trailing) {
            if section == .accounts && !oauthManager.isAuthenticated {
                Circle()
                    .fill(Palette.warning)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 4)
            }
        }
    }

    private func iconColor(for section: SettingsSection) -> Color {
        // All non-status sidebar icons use the neutral primary text colour
        // (which adapts automatically). Only the Accounts row reflects state
        // (success when connected, warning when not).
        switch section {
        case .accounts:
            return oauthManager.isAuthenticated ? .appSuccess : .appWarning
        default:
            return .appTextSecondary
        }
    }

    // MARK: Account Banner

    @ViewBuilder
    private var accountBanner: some View {
        HStack(spacing: 10) {
            if oauthManager.isAuthenticated {
                AdaptiveIcon(systemName: "checkmark.circle.fill", color: Palette.success)
                Text("Google Account:")
                    .foregroundStyle(Palette.secondaryText)
                if let email = oauthManager.userEmail {
                    Text(email)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Connected")
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.success)
                }
                Spacer()
                Button("Manage") { selectedSection = .accounts }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                AdaptiveIcon(systemName: "exclamationmark.triangle.fill", color: Palette.warning)
                Text("Google Account not connected")
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Connect") { selectedSection = .accounts }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            oauthManager.isAuthenticated
                ? Palette.success.opacity(0.08)
                : Palette.warning.opacity(0.08)
        )
    }

    // MARK: Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:    GeneralSettingsView()
        case .syncFields: CommonSyncSettingsView()
        case .manualSync: ManualSyncSettingsView()
        case .autoSync:   AutoSyncSettingsView()
        case .aiMatching: AIMatchingSettingsView()
        case .accounts:   AccountsSettingsView()
        case .backups:    BackupAndRecoverySettingsView()
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - General Settings
// ═══════════════════════════════════════════════════════════════════════

struct GeneralSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var sync = SyncCoordinator.shared
    @EnvironmentObject private var appState: AppState
    @State private var showingResetConfirmation = false
    @State private var pendingLanguageRelaunch = false
    @State private var recentChanges: [SyncEvent] = []
    @State private var isLogExpanded = false

    /// Sync Mode used to be selectable here with no way to act on the choice —
    /// picking "Manual Sync…" set a preference and then left the user with
    /// nothing to press. This puts the state and the action next to the setting
    /// that governs them.
    private var canSync: Bool {
        appState.isGoogleConnected
            && appState.isMacContactsAuthorized
            && !sync.isRunning
    }

    /// The last handful of contact-level writes, newest first.
    ///
    /// Cached in `@State` rather than computed in the body: `SyncHistory.events()`
    /// takes a lock and copies the whole event array, and SwiftUI re-evaluates a
    /// body far more often than this data changes. Refreshed on appear and when a
    /// sync finishes — the only two moments it can differ.
    private static func loadRecentChanges() -> [SyncEvent] {
        SyncHistory.shared.events()
            .reversed()
            // `change.*` is the namespace SyncEngine uses for actual mutations,
            // so lifecycle noise like `sync.start` never crowds out the thing
            // the user wants to see.
            .filter { $0.action.lowercased().hasPrefix("change.") }
            // 20, not 5: the list only renders inside the expanded disclosure, and
            // when a sync is going wrong you need enough rows to see the pattern
            // rather than the last handful.
            .prefix(20)
            .map { $0 }
    }

    /// The expandable body — shared by the running and idle states so the log
    /// looks identical whether you open it mid-sync or afterwards.
    @ViewBuilder
    private var changeLogList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if recentChanges.isEmpty {
                Text("No changes yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(recentChanges) { event in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: changeIcon(for: event.action))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(changeTint(for: event.action))
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.details ?? event.action)
                            .font(.caption)
                            // Failures carry the reason, and a truncated reason is
                            // useless — that is the whole point of opening this.
                            .lineLimit(isFailure(event.action) ? 3 : 1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        if isFailure(event.action) {
                            Text(friendlyActionLabel(event.action))
                                .font(.caption2)
                                .foregroundStyle(Color.appError)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            Button("View History & Backups") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(.top, 2)
    }

    private func isFailure(_ action: String) -> Bool {
        let lowered = action.lowercased()
        return lowered.contains("fail") || lowered.contains("error")
    }

    private func friendlyActionLabel(_ action: String) -> String {
        switch action.lowercased() {
        case "change.failed": return String(localized: "Change failed")
        default:              return action
        }
    }

    private var failureCount: Int {
        recentChanges.filter { isFailure($0.action) }.count
    }

    private func changeIcon(for action: String) -> String {
        switch action.lowercased() {
        case let a where a.contains("add"):    return "plus.circle.fill"
        case let a where a.contains("update"): return "pencil.circle.fill"
        case let a where a.contains("delete"): return "minus.circle.fill"
        case let a where a.contains("merge"):  return "arrow.triangle.merge"
        case let a where a.contains("fail"):   return "xmark.circle.fill"
        default:                                return "circle.fill"
        }
    }

    private func changeTint(for action: String) -> Color {
        switch action.lowercased() {
        case let a where a.contains("fail"):   return Color.appError
        case let a where a.contains("delete"): return Color.appWarning
        case let a where a.contains("add"):    return Color.appSuccess
        default:                                return Color.appInfo
        }
    }

    private var statusIcon: String {
        guard appState.lastSyncDate != nil else { return "clock" }
        guard let result = appState.lastSyncResult else { return AppIcon.statusSuccess }
        return result.successful ? AppIcon.statusSuccess : "exclamationmark.triangle.fill"
    }

    private var statusTint: Color {
        guard let result = appState.lastSyncResult else { return .secondary }
        return result.successful ? Color.appSuccess : Color.appWarning
    }

    private var lastSyncSummary: String {
        guard let date = appState.lastSyncDate else { return "Never synced" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let when = relative.localizedString(for: date, relativeTo: Date())
        guard let result = appState.lastSyncResult else { return "Last synced \(when)" }
        return result.successful
            ? "Last synced \(when)"
            : "Last sync finished with errors \(when)"
    }

    var body: some View {
        Form {
            // ── Sync Status ────────────────────────────────────────────
            Section {
                if sync.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: sync.progress)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(sync.stepLabel.isEmpty ? sync.phase.label : sync.stepLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(sync.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }

                        // A percentage says how far along it is but nothing about
                        // what it is doing to your address book. Expanding streams
                        // the per-contact writes as they land, so a failing sync is
                        // visible while it runs instead of only afterwards.
                        DisclosureGroup(isExpanded: $isLogExpanded) {
                            changeLogList
                        } label: {
                            Text("Details")
                                .font(.caption)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        Label {
                            Text(lastSyncSummary)
                        } icon: {
                            Image(systemName: statusIcon)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(statusTint)
                        }

                        Spacer()

                        Button(settings.selectedSyncType == .manual ? "Review…" : "Sync Now") {
                            // Same single execution path as the menu bar and
                            // Dashboard — never a second copy of sync logic.
                            Task { await SyncCoordinator.shared.runSync() }
                        }
                        .disabled(!canSync)
                        .help(canSync
                              ? "Run a sync now using the mode selected below"
                              : "Connect a Google account and grant Contacts access first")
                    }

                    // "Last synced 5 minutes ago" says nothing about what moved.
                    if !recentChanges.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $isLogExpanded) {
                            changeLogList
                        } label: {
                            HStack(spacing: 6) {
                                Text("Recent Changes")
                                    .font(.caption)
                                if failureCount > 0 {
                                    // Surfaced on the collapsed row: a sync that
                                    // "completed" while every write failed should
                                    // not look identical to one that worked.
                                    Text("\(failureCount) failed")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.appError.opacity(0.15))
                                        .foregroundStyle(Color.appError)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Sync Status", systemImage: "clock.arrow.circlepath")
            }

            // ── Sync Mode ──────────────────────────────────────────────
            Section {
                ForEach(SyncType.allCases, id: \.self) { type in
                    SelectableRow(
                        icon: syncTypeIcon(type),
                        title: type.displayName,
                        subtitle: type.description,
                        isSelected: settings.selectedSyncType == type
                    ) {
                        settings.selectedSyncType = type
                    }
                }
            } header: {
                Label("Sync Mode", systemImage: "arrow.triangle.2.circlepath")
            }

            // ── Appearance ─────────────────────────────────────────────
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .help("Start Contact SyncMate automatically when you log in")
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }

                Toggle("Keep app in menu bar only", isOn: $settings.attachToMenuBar)
                    .help("When enabled, Contact SyncMate won't appear in the Dock")
                    .onChange(of: settings.attachToMenuBar) { _, newValue in
                        updateDockVisibility(hide: newValue)
                    }

                Toggle("Use monochrome menu bar icon", isOn: $settings.useBlackWhiteIcon)
                    .help("Display a monochrome icon in the menu bar")

                Toggle("Show pending-changes badge on icon", isOn: $settings.showSyncBadge)
                    .help("Display a badge count on the menu bar icon for pending changes")
            } header: {
                Label("Appearance", systemImage: "paintbrush")
            }

            // ── Notifications ──────────────────────────────────────────
            Section {
                Toggle("Sync completed", isOn: $settings.notifyOnSyncComplete)
                    .help("Notify when a sync finishes successfully")
                Toggle("Sync errors", isOn: $settings.notifyOnErrors)
                    .help("Notify when a sync fails")
                Toggle("Conflicts need review", isOn: $settings.notifyOnConflicts)
                    .help("Notify when conflicts need your attention")
            } header: {
                Label("Notifications", systemImage: "bell")
            } footer: {
                Button("Open Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // ── Appearance Customisation ───────────────────────────────
            Section {
                Picker("Appearance", selection: $settings.preferredAppearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                    }
                }
                .help("Follow the system, or force light / dark mode for Contact SyncMate only")

                Picker("Accent colour", selection: $settings.accentColorChoice) {
                    ForEach(AccentColorChoice.allCases) { choice in
                        HStack {
                            if let tint = choice.tint {
                                Circle().fill(tint).frame(width: 10, height: 10)
                            } else {
                                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                            }
                            Text(choice.displayName)
                        }
                        .tag(choice)
                    }
                }
                .help("Tint for buttons and highlights. System follows your macOS accent colour.")
            } header: {
                Label("Theme", systemImage: "paintpalette")
            }

            // ── Menu Bar Customisation ─────────────────────────────────
            Section {
                Toggle("Show account status rows", isOn: $settings.menuBarShowAccounts)
                    .help("Google and Mac account rows in the menu bar popover")
                Toggle("Show auto-sync toggle", isOn: $settings.menuBarShowAutoSyncToggle)
                    .help("Quick auto-sync on/off switch in the popover")
                Toggle("Show sync result banner", isOn: $settings.menuBarShowFeedbackBanner)
                    .help("Success/failure banner after each sync")
                Toggle("Show navigation shortcuts", isOn: $settings.menuBarShowNavigationLinks)
                    .help("Dashboard / History / Preferences links in the popover")
            } header: {
                Label("Menu Bar Popover", systemImage: "menubar.rectangle")
            } footer: {
                Text("Trim the menu bar popover down to just what you use. Sync Now and Quit are always shown.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            // ── Confirmations ──────────────────────────────────────────
            Section {
                Toggle("Ask before Sync Now", isOn: $settings.confirmBeforeSyncNow)
                    .help("Show a confirmation dialog when clicking Sync Now")
                Toggle("Ask before restoring a backup", isOn: $settings.confirmBeforeRestore)
                    .help("Show a confirmation dialog before a restore rewrites contacts")
                Toggle("Ask before deleting contacts", isOn: $settings.confirmPendingDeletions)
                    .help("Show pending deletions for review before they are applied")
                Toggle("Allow silent auto-merge of duplicates", isOn: $settings.allowSilentAutoMerge)
                    .help("Apply high-confidence duplicate merges without asking. Off = always review.")
            } header: {
                Label("Confirmations", systemImage: "checkmark.shield")
            } footer: {
                Text("Choose which actions ask for confirmation. Safer defaults are pre-selected; skip confirmations you find repetitive.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            // ── Language ───────────────────────────────────────────────
            Section {
                Picker("Interface language", selection: $settings.selectedLanguage) {
                    Text("System Default").tag("system")
                    Text(verbatim: "English").tag("en")
                    // `verbatim:` so a language's own name is never itself
                    // translated — 繁體中文 must read 繁體中文 in every locale.
                    Text(verbatim: "繁體中文").tag("zh-Hant")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                }
                .onChange(of: settings.selectedLanguage) { _, newValue in
                    // macOS resolves the localization table when the bundle
                    // loads, so the running view tree cannot be re-bound in
                    // place — see LanguageManager for why swizzling is worse.
                    if LanguageManager.shared.apply(newValue) {
                        pendingLanguageRelaunch = true
                    }
                }

                Text("The interface language changes after the app restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Language", systemImage: "globe")
            }

            // ── Data & History ─────────────────────────────────────────
            Section {
                Picker("Keep history for", selection: $settings.historyRetentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .help("Events older than this are removed automatically")

                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset All Settings to Defaults…", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(Palette.danger)
                }
                .confirmationDialog(
                    "Reset all settings?",
                    isPresented: $showingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset Settings", role: .destructive) { settings.resetToDefaults() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All preferences will return to defaults. Your Google account connection will not be affected.")
                }
            } header: {
                Label("Data & History", systemImage: "internaldrive")
            }
        }
        .formStyle(.grouped)
        .onAppear { recentChanges = Self.loadRecentChanges() }
        .onChange(of: sync.phase) { _, phase in
            if case .completed = phase { recentChanges = Self.loadRecentChanges() }
        }
        // `sync.progress` ticks per contact, which makes it the natural clock for
        // streaming the log — no timer to own, and nothing polls while idle.
        // Guarded on `isLogExpanded` so a collapsed section costs nothing.
        .onChange(of: sync.progress) { _, _ in
            guard isLogExpanded, sync.isRunning else { return }
            recentChanges = Self.loadRecentChanges()
        }
        .onChange(of: isLogExpanded) { _, expanded in
            if expanded { recentChanges = Self.loadRecentChanges() }
        }
        .alert("Restart to change the language?", isPresented: $pendingLanguageRelaunch) {
            Button("Restart Now") { LanguageManager.shared.relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Contact SyncMate needs to restart before the interface appears in the language you picked. Your settings are already saved. A sync in progress will be interrupted.")
        }
    }

    // MARK: Helpers

    private func syncTypeIcon(_ type: SyncType) -> String {
        switch type {
        case .twoWay:      return "arrow.triangle.2.circlepath"
        case .googleToMac: return "arrow.down.circle"
        case .macToGoogle: return "arrow.up.circle"
        case .manual:      return "hand.tap"
        }
    }

    private func updateDockVisibility(hide: Bool) {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        NotificationCenter.default.post(name: .activationPolicyChanged, object: nil)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        _ = enabled // SMAppService wired in AppDelegate
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Common Sync Settings
// ═══════════════════════════════════════════════════════════════════════

struct CommonSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            // ── Fields to Sync ─────────────────────────────────────────
            Section {
                FieldToggleRow(icon: "camera.fill",       label: "Photos",          help: "Include contact photos",          binding: $settings.syncPhotos)

                // Notes requires the com.apple.developer.contacts.notes
                // entitlement. When absent the toggle is disabled and forced
                // off — the underlying CNContactStore API returns empty
                // strings and silently drops writes.
                FieldToggleRow(icon: "note.text",          label: "Notes",           help: "Include the notes field",         binding: $settings.syncNotes)
                    .disabled(!MacContactsConnector.notesFieldAvailable)
                    .opacity(MacContactsConnector.notesFieldAvailable ? 1.0 : 0.55)

                FieldToggleRow(icon: "gift",               label: "Birthday",        help: "Include birthday dates",          binding: $settings.syncBirthday)
                FieldToggleRow(icon: "link",               label: "Websites",        help: "Include website URLs",            binding: $settings.syncWebsites)
                FieldToggleRow(icon: "mappin.and.ellipse", label: "Addresses",       help: "Include postal addresses",        binding: $settings.syncAddresses)
                FieldToggleRow(icon: "briefcase",          label: "Job Title & Org", help: "Include job title and organisation", binding: $settings.syncJobTitle)
            } header: {
                Label("Fields to Sync", systemImage: "list.bullet.clipboard")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deselected fields are left untouched on both sides during every sync.")
                    if !MacContactsConnector.notesFieldAvailable {
                        Label {
                            Text("Notes sync is unavailable in this build — Apple restricts the Contacts note field to apps with an approved entitlement.")
                        } icon: {
                            Image(systemName: AppIcon.statusInfo)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.appInfo)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
            }

            // ── Name Formatting (opt-in) ───────────────────────────────
            Section {
                Toggle(isOn: $settings.nameFormattingEnabled) {
                    Label("Normalise name formatting during sync", systemImage: "textformat")
                }
                .help("Apply a consistent casing convention to names as they are written")

                if settings.nameFormattingEnabled {
                    Picker("Convention", selection: $settings.nameCasingConvention) {
                        ForEach(NameCasingConvention.allCases) { convention in
                            Text(convention.displayName).tag(convention)
                        }
                    }

                    HStack(spacing: 6) {
                        AdaptiveIcon(systemName: "eye", color: Palette.secondaryText, size: 12)
                        Text(settings.nameCasingConvention.example)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .monospaced()
                    }
                }
            } header: {
                Label("Name Formatting", systemImage: "character.cursor.ibeam")
            } footer: {
                Text("Off by default — your names are never rewritten unless you opt in. Chinese, Japanese, and Korean names are always left unchanged. Title Case handles \"van der Berg\", \"McDonald\", and \"O'Brien\" correctly.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            // ── Conflict Resolution ────────────────────────────────────
            Section {
                ForEach(ConflictResolutionDefault.allCases, id: \.self) { option in
                    SelectableRow(
                        icon: option.icon,
                        title: option.displayName,
                        subtitle: option.description,
                        isSelected: settings.defaultConflictResolution == option
                    ) {
                        settings.defaultConflictResolution = option
                    }
                }
            } header: {
                Label("Default Conflict Resolution", systemImage: "arrow.triangle.branch")
            } footer: {
                Text("Per-contact overrides are always available in the Sync Preview.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            // ── Merge Behaviour ────────────────────────────────────────
            Section {
                Toggle("Merge during 2-way sync", isOn: $settings.mergeContacts2Way)
                    .help("Combine fields from both sides rather than overwriting")
                Toggle("Merge during 1-way sync", isOn: $settings.mergeContacts1Way)
                    .help("Merge fields during 1-way sync instead of full replacement")
                Toggle("Sync deleted contacts", isOn: $settings.syncDeletedContacts)
                    .help("Propagate deletions across sides")
                Toggle("Normalise postal country codes", isOn: $settings.syncPostalCountryCodes)
                    .help("Standardise country codes in postal addresses during sync")
            } header: {
                Label("Merge Behaviour", systemImage: "arrow.triangle.merge")
            }

            // ── Performance ────────────────────────────────────────────
            Section {
                Toggle("Batch Google API updates", isOn: $settings.batchGoogleUpdates)
                    .help("Send up to 100 changes per API call for faster sync")
            } header: {
                Label("Performance", systemImage: "gauge.high")
            }

            // ── Filters ────────────────────────────────────────────────
            Section {
                Toggle("Filter sync by groups / labels", isOn: $settings.filterByGroups)
                    .help("Only sync contacts that belong to selected groups or labels")

                if settings.filterByGroups {
                    GroupFilterPickerView()
                        .padding(.top, 4)
                }
            } header: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .formStyle(.grouped)
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Manual Sync Settings
// ═══════════════════════════════════════════════════════════════════════

struct ManualSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.detectGoogleDuplicates) {
                    Label("Detect duplicates before sync", systemImage: "person.2.badge.gearshape")
                }
                .help("Scan for duplicate contacts before changes are applied")

                Toggle(isOn: $settings.confirmPendingDeletions) {
                    Label("Confirm pending deletions", systemImage: "trash.badge.clock")
                }
                .help("Show a confirmation sheet for contacts that will be deleted")
            } header: {
                Label("Safety", systemImage: "checkmark.shield")
            } footer: {
                Text("These safeguards are recommended. Disabling them speeds up sync but increases the risk of data loss.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            Section {
                Toggle(isOn: $settings.forceUpdateAll) {
                    Label("Force update all contacts", systemImage: "arrow.clockwise.circle")
                }
                .help("Write every contact even if it appears unchanged")

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $settings.dryRunMode) {
                        Label("Dry run mode", systemImage: "eye.circle")
                    }
                    .help("Preview what would change without writing anything")

                    if settings.dryRunMode {
                        Label("Dry run is active — no changes will be saved.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.warning)
                            .padding(.leading, 24)
                    }
                }
            } header: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
            } footer: {
                Text("Force update is useful after fixing data corruption. Dry run is useful for auditing what a sync will do.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .formStyle(.grouped)
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Auto Sync Settings
// ═══════════════════════════════════════════════════════════════════════

struct AutoSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @EnvironmentObject private var appState: AppState

    private let intervalOptions: [(String, TimeInterval)] = [
        ("Every 5 minutes",  300),
        ("Every 15 minutes", 900),
        ("Every 30 minutes", 1800),
        ("Every hour",       3600),
        ("Every 4 hours",    14400),
        ("Once a day",       86400)
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.autoSyncEnabled) {
                    Label("Enable automatic sync", systemImage: "clock.arrow.circlepath")
                }
                .help("Run sync automatically in the background")

                if settings.autoSyncEnabled {
                    Picker("Direction", selection: $settings.autoSyncDirection) {
                        Label("2-Way Sync",   systemImage: "arrow.triangle.2.circlepath").tag(SyncDirection.twoWay)
                        Label("Google → Mac",  systemImage: "arrow.down.circle").tag(SyncDirection.googleToMac)
                        Label("Mac → Google",  systemImage: "arrow.up.circle").tag(SyncDirection.macToGoogle)
                    }

                    Picker("Interval", selection: $settings.autoSyncInterval) {
                        ForEach(intervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }

                    HStack(spacing: 6) {
                        AdaptiveIcon(systemName: "clock", color: Palette.secondaryText, size: 12)
                        if let next = appState.nextScheduledSync {
                            (Text("Next sync ").foregroundStyle(Palette.secondaryText)
                             + Text(next, style: .relative).fontWeight(.medium))
                        } else {
                            Text("Next sync will run after current interval elapses.")
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            } header: {
                Label("Schedule", systemImage: "calendar.badge.clock")
            }

            if settings.autoSyncEnabled {
                Section {
                    Toggle(isOn: $settings.autoSyncOnlyOnPower) {
                        Label("Only when on AC power", systemImage: "bolt.fill")
                    }
                    .help("Skip auto sync when running on battery")

                    Toggle(isOn: $settings.autoSyncOnlyOnWiFi) {
                        Label("Only when on Wi-Fi", systemImage: "wifi")
                    }
                    .help("Skip auto sync on cellular or metered connections")

                    Toggle(isOn: $settings.autoSyncOnlyWhenIdle) {
                        Label("Only when Mac is idle", systemImage: "zzz")
                    }
                    .help("Skip auto sync while you're actively using your Mac")
                } header: {
                    Label("Run Conditions", systemImage: "checklist")
                } footer: {
                    Group {
                        if settings.autoSyncOnlyOnPower || settings.autoSyncOnlyOnWiFi || settings.autoSyncOnlyWhenIdle {
                            Text("Auto sync will be skipped when any active condition is not met.")
                        } else {
                            Text("No conditions set — auto sync will run unconditionally at the chosen interval.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.2), value: settings.autoSyncEnabled)
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - AI Matching Settings
// ═══════════════════════════════════════════════════════════════════════

struct AIMatchingSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var isTestingKey = false
    @State private var keyTestResult: KeyTestResult?
    @State private var showAPIKey = false

    enum KeyTestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            // ── Overview ───────────────────────────────────────────────
            Section {
                HStack(alignment: .top, spacing: 12) {
                    AdaptiveIcon(systemName: "sparkles", color: Palette.accent, size: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI-Powered Matching")
                            .font(.headline)
                        Text("Catch duplicates that rule-based scoring misses — nicknames, name initials, transposed names, phonetic variants, and phone-number format differences.")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)

                Toggle(isOn: $settings.aiMatchingEnabled) {
                    Label("Enable AI matching", systemImage: "brain")
                }
                .help("Run the AI matching pipeline during duplicate detection")
            } header: {
                Label("AI Matching", systemImage: "sparkles")
            }

            // ── Local NLP Signals ──────────────────────────────────────
            if settings.aiMatchingEnabled {
                Section {
                    AISignalRow(icon: "person.text.rectangle",  label: "Nickname variants",         detail: "Bob ↔ Robert, Liz ↔ Elizabeth")
                    AISignalRow(icon: "character.cursor.ibeam", label: "Name initial abbreviation", detail: "J. Smith ↔ John Smith")
                    AISignalRow(icon: "arrow.left.arrow.right", label: "Transposed name order",      detail: "Wei Li ↔ Li Wei")
                    AISignalRow(icon: "waveform",               label: "Phonetic surname matching",  detail: "Schmidt ↔ Schmitt via Soundex")
                    AISignalRow(icon: "phone",                  label: "Phone suffix matching",      detail: "Local vs. international format")
                    AISignalRow(icon: "envelope",               label: "Email plus-alias detection", detail: "john+work@ ≈ john@")
                    AISignalRow(icon: "textformat.abc",         label: "Compound name handling",     detail: "Liwei Zhang ↔ Li Wei Zhang")
                    AISignalRow(icon: "person.crop.rectangle",  label: "Stored nickname field",      detail: "Uses the contact's own Nickname field")
                } header: {
                    Label("Local NLP Signals (always active)", systemImage: "cpu")
                } footer: {
                    Text("These run instantly on-device with no network access required.")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }

                // ── Cloud AI — everything API-related lives in ONE section:
                //    key → model → test → sensitivity, top to bottom.
                Section {
                    // 1. API key
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anthropic API Key")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            Group {
                                if showAPIKey {
                                    TextField("sk-ant-…", text: $settings.anthropicAPIKey)
                                } else {
                                    SecureField("sk-ant-…", text: $settings.anthropicAPIKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                            Button {
                                showAPIKey.toggle()
                            } label: {
                                AdaptiveIcon(systemName: showAPIKey ? "eye.slash" : "eye", size: 14)
                            }
                            .buttonStyle(.borderless)
                            .help(showAPIKey ? "Hide API key" : "Show API key")
                        }

                        Text("Get a key at console.anthropic.com — stored securely in the macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }

                    // 2. Model choice — always visible so users can see
                    //    what's available before entering a key.
                    Picker("Model", selection: $settings.aiModel) {
                        ForEach(AIModelChoice.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(settings.anthropicAPIKey.isEmpty)
                    .help("Which Claude model analyses borderline duplicate pairs")

                    // 3. Key test
                    if !settings.anthropicAPIKey.isEmpty {
                        HStack(spacing: 10) {
                            Button("Test API Key") { testAPIKey() }
                                .disabled(isTestingKey)

                            if isTestingKey {
                                ProgressView().controlSize(.small)
                            }

                            if let result = keyTestResult {
                                switch result {
                                case .success(let msg):
                                    Label(msg, systemImage: AppIcon.statusSuccess)
                                        .foregroundStyle(Palette.success)
                                        .font(.caption)
                                case .failure(let msg):
                                    Label(msg, systemImage: AppIcon.statusError)
                                        .foregroundStyle(Palette.danger)
                                        .font(.caption)
                                }
                            }
                        }

                        // 4. Sensitivity — same section, directly below the
                        //    model it configures.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Call API for rule scores in range: \(settings.aiAPIScoreRangeLow) – \(settings.aiAPIScoreRangeHigh)")
                                .font(.subheadline)

                            HStack(spacing: 6) {
                                Text("\(settings.aiAPIScoreRangeLow)")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(Palette.secondaryText)
                                    .frame(width: 28, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.aiAPIScoreRangeLow) },
                                        set: { settings.aiAPIScoreRangeLow = Int($0) }
                                    ),
                                    in: 10...60, step: 5
                                )
                                Text("\(settings.aiAPIScoreRangeHigh)")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(Palette.secondaryText)
                                    .frame(width: 28, alignment: .trailing)
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.aiAPIScoreRangeHigh) },
                                        set: { settings.aiAPIScoreRangeHigh = Int($0) }
                                    ),
                                    in: 60...95, step: 5
                                )
                            }

                            Text("Wider range = more API calls and higher accuracy; narrower = fewer calls and lower cost.")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .padding(.top, 4)
                    }
                } header: {
                    Label("Cloud AI (Anthropic API)", systemImage: "cloud")
                } footer: {
                    Group {
                        if settings.anthropicAPIKey.isEmpty {
                            Text("Optional. Without a key, only the on-device NLP signals above are used — still effective for most duplicates. With a key, borderline matches (rule score \(settings.aiAPIScoreRangeLow)–\(settings.aiAPIScoreRangeHigh)) are escalated to the selected Claude model.")
                        } else {
                            Text("The cloud tier is called only for ambiguous pairs — never for high-confidence matches or when you're offline.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.2), value: settings.aiMatchingEnabled)
    }

    // MARK: API Test

    private func testAPIKey() {
        isTestingKey = true
        keyTestResult = nil
        Task {
            do {
                guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw URLError(.badURL) }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 10
                req.setValue("application/json",            forHTTPHeaderField: "Content-Type")
                req.setValue(settings.anthropicAPIKey,       forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01",                   forHTTPHeaderField: "anthropic-version")
                let body: [String: Any] = [
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 10,
                    "messages": [["role": "user", "content": "Hi"]]
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    isTestingKey = false
                    keyTestResult = (200...299).contains(status) ? .success("Key valid") : .failure("HTTP \(status)")
                }
            } catch {
                await MainActor.run {
                    isTestingKey = false
                    keyTestResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Accounts Settings
// ═══════════════════════════════════════════════════════════════════════

struct AccountsSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState
    @StateObject private var googleConnector = GoogleContactsConnector()
    @StateObject private var oauthManager = GoogleOAuthManager.shared

    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var contactCount: Int?
    @State private var isLoadingContactCount = false
    @State private var macContactCount: Int?
    @State private var isLoadingMacContactCount = false
    @State private var showMacAccountPicker = false

    /// Cached display name for the selected Mac account. Loaded off-main —
    /// calling CNContactStore synchronously during body evaluation caused a
    /// priority-inversion hang risk (main thread waiting on contactsd XPC).
    @State private var selectedAccountName: String?

    var body: some View {
        Form {
            // ── Google Account ──────────────────────────────────────────
            Section {
                // Status row
                HStack(spacing: 12) {
                    accountIcon(
                        systemName: oauthManager.isAuthenticated ? "checkmark.circle.fill" : "xmark.circle",
                        color: oauthManager.isAuthenticated ? Palette.success : Palette.warning
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(oauthManager.isAuthenticated ? "Connected" : "Not connected")
                            .font(.headline)

                        if let email = oauthManager.userEmail {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if let count = contactCount {
                            Text("\(count) contacts")
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryText)
                        } else if isLoadingContactCount {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini).scaleEffect(0.7)
                                Text("Loading…")
                                    .font(.caption2)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }

                    Spacer()

                    if oauthManager.isAuthenticated {
                        Button { refreshContactCount() } label: {
                            AdaptiveIcon(systemName: "arrow.clockwise", size: 13)
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh contact count")
                        .disabled(isLoadingContactCount)
                    }
                }

                // Actions — exports live in the Backups tab (single home for
                // everything backup-related).
                if oauthManager.isAuthenticated {
                    HStack(spacing: 10) {
                        Button("Test Connection") { testGoogleConnection() }
                            .help("Verify connection to Google Contacts API")

                        Button("Sign Out") { signOutFromGoogle() }
                            .foregroundStyle(Palette.danger)
                    }
                } else {
                    Button("Sign In with Google…") { signInToGoogle() }
                        .disabled(isSigningIn)

                    if isSigningIn {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Authenticating…")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }

                    if let error = signInError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Required for syncing contacts with Google Contacts via the People API.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            } header: {
                Label("Google Account", systemImage: "g.circle")
            }

            // ── Mac Contacts ────────────────────────────────────────────
            Section {
                HStack(spacing: 12) {
                    accountIcon(
                        systemName: AppIcon.sourceApple,
                        color: .appSourceApple
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac Contacts")
                            .font(.headline)
                        Text(appState.isMacContactsAuthorized ? "Access granted" : "Access required")
                            .font(.caption)
                            .foregroundStyle(appState.isMacContactsAuthorized ? Palette.success : Palette.warning)
                    }

                    Spacer()

                    if appState.isMacContactsAuthorized {
                        if let count = macContactCount {
                            Text("\(count) contact\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        } else if isLoadingMacContactCount {
                            ProgressView().controlSize(.mini)
                        }

                        Button { refreshMacContactCount() } label: {
                            AdaptiveIcon(systemName: "arrow.clockwise", size: 13)
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh contact count")
                        .disabled(isLoadingMacContactCount)
                    }
                }

                Picker("Account mode:", selection: $settings.macAccountMode) {
                    ForEach(MacAccountMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .help(settings.macAccountMode.description)
                .onChange(of: settings.macAccountMode) { oldValue, newValue in
                    if newValue == .specific && oldValue != .specific {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showMacAccountPicker = true
                        }
                    }
                    refreshMacContactCount()
                }

                Text(settings.macAccountMode.description)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.macAccountMode == .specific {
                    specificAccountRow
                        .sheet(isPresented: $showMacAccountPicker) {
                            MacAccountPickerView(
                                selectedIdentifier: $settings.selectedMacAccountIdentifier,
                                isAuthorized: appState.isMacContactsAuthorized
                            )
                            .frame(minWidth: 500, minHeight: 400)
                        }
                }

                if appState.isMacContactsAuthorized {
                    Button("Test Connection") { testMacContactsConnection() }
                        .help("Verify access to Mac Contacts")
                }
            } header: {
                Label("Mac Contacts", systemImage: "person.crop.circle")
            }

            // ── Permissions ─────────────────────────────────────────────
            Section {
                HStack(spacing: 10) {
                    AdaptiveIcon(
                        systemName: appState.isMacContactsAuthorized ? "checkmark.circle.fill" : "xmark.circle",
                        color: appState.isMacContactsAuthorized ? Palette.success : Palette.warning,
                        size: 16
                    )
                    Text("Mac Contacts Access")
                    Spacer()
                    if !appState.isMacContactsAuthorized {
                        Button("Grant Access") { requestContactsAccess() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(Palette.success)
                    }
                }

                Text("Contact SyncMate needs access to your Mac contacts to sync them.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            } header: {
                Label("Permissions", systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if oauthManager.isAuthenticated { refreshContactCount() }
            if appState.isMacContactsAuthorized { refreshMacContactCount() }
            refreshSelectedAccountName()
        }
        .onChange(of: settings.selectedMacAccountIdentifier) {
            refreshSelectedAccountName()
        }
        .onChange(of: oauthManager.isAuthenticated) {
            // Reactively sync app-wide state whenever OAuth status changes
            if oauthManager.isAuthenticated {
                settings.googleAccountEmail = oauthManager.userEmail
                appState.isGoogleConnected = true
                refreshContactCount()
            } else {
                settings.googleAccountEmail = nil
                appState.isGoogleConnected = false
                contactCount = nil
            }
        }
        .onChange(of: oauthManager.userEmail) {
            // Keep stored email in sync if it arrives after isAuthenticated
            if oauthManager.isAuthenticated {
                settings.googleAccountEmail = oauthManager.userEmail
            }
        }
    }

    // MARK: - Specific Account Row

    @ViewBuilder
    private var specificAccountRow: some View {
        if settings.selectedMacAccountIdentifier != nil,
           let accountName = selectedAccountName {
            HStack(spacing: 10) {
                AdaptiveIcon(systemName: "checkmark.circle.fill", color: Palette.success, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected Account:")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                    Text(accountName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Spacer()
                Button("Change") { showMacAccountPicker = true }
                    .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Palette.success.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(spacing: 10) {
                AdaptiveIcon(systemName: "exclamationmark.circle", color: Palette.warning, size: 14)
                Text("No account selected")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Select Account…") { showMacAccountPicker = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(8)
            .background(Palette.warning.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Account Icon

    private func accountIcon(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .font(.title2)
            .frame(width: 32, height: 32)
    }

    // MARK: - Actions

    private func refreshContactCount() {
        isLoadingContactCount = true
        Task {
            do {
                let contacts = try await googleConnector.fetchAllContacts()
                await MainActor.run { contactCount = contacts.count; isLoadingContactCount = false }
            } catch {
                await MainActor.run { contactCount = nil; isLoadingContactCount = false }
            }
        }
    }

    private func refreshMacContactCount() {
        guard appState.isMacContactsAuthorized else { return }
        isLoadingMacContactCount = true
        // Task.detached: CNContactStore calls are synchronous XPC to contactsd
        // (background QoS). Running them on the main actor causes a
        // priority-inversion hang risk — always hop off main first.
        Task.detached(priority: .userInitiated) {
            do {
                let contacts = try MacContactsConnector.fetchAllContactsOffMain()
                await MainActor.run { macContactCount = contacts.count; isLoadingMacContactCount = false }
            } catch {
                await MainActor.run { macContactCount = nil; isLoadingMacContactCount = false }
            }
        }
    }

    private func signInToGoogle() {
        isSigningIn = true
        signInError = nil
        Task { @MainActor in
            // Ensure the app is frontmost so the OAuth browser sheet has an anchor
            if NSApp.activationPolicy() == .accessory {
                NSApp.setActivationPolicy(.regular)
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 100_000_000)

            do {
                // Await the full OAuth flow (browser → token exchange → user info)
                try await oauthManager.signIn()
                // Sign-in succeeded — update app state
                settings.googleAccountEmail = oauthManager.userEmail
                appState.isGoogleConnected = true
            } catch {
                signInError = error.localizedDescription
                print("Google sign-in failed: \(error)")
            }
            isSigningIn = false
        }
    }

    private func signOutFromGoogle() {
        googleConnector.signOut()
        settings.googleAccountEmail = nil
        appState.isGoogleConnected = false
    }

    private func testMacContactsConnection() {
        Task.detached(priority: .userInitiated) {
            do {
                let contacts = try MacContactsConnector.fetchAllContactsOffMain()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Connection Successful"
                    alert.informativeText = "Mac Contacts is accessible. Found \(contacts.count) contacts."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Connection Failed"
                    alert.informativeText = "Could not access Mac Contacts: \(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func testGoogleConnection() {
        Task {
            do {
                let contacts = try await googleConnector.fetchAllContacts()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Connection Successful"
                    alert.informativeText = "Found \(contacts.count) contacts."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Connection Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // CSV / Excel exports moved to the Backups tab — single home for all
    // backup and export functionality.

    private func requestContactsAccess() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            // First time: triggers the system permission dialog
            let store = MacContactsConnector.shared
            store.requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async {
                    appState.isMacContactsAuthorized = granted
                    if granted { refreshMacContactCount() }
                }
            }
        case .denied, .restricted:
            // Already denied: open System Settings so user can toggle it
            openSystemSettings()
        case .authorized:
            appState.isMacContactsAuthorized = true
        @unknown default:
            openSystemSettings()
        }
    }

    private func openSystemSettings() {
        // macOS 14+ uses the new System Settings URL scheme
        let urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts"
        let fallback = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Resolve the selected container's display name OFF the main thread.
    /// CNContactStore access goes over XPC to contactsd at background QoS;
    /// blocking the main thread on it is a hang risk (priority inversion).
    private func refreshSelectedAccountName() {
        guard let identifier = settings.selectedMacAccountIdentifier,
              CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            selectedAccountName = nil
            return
        }
        Task.detached(priority: .utility) {
            let store = MacContactsConnector.shared
            let name: String?
            do {
                let containers = try store.containers(matching: nil)
                if let container = containers.first(where: { $0.identifier == identifier }) {
                    name = await displayName(for: container)
                } else {
                    name = identifier
                }
            } catch {
                name = nil
            }
            await MainActor.run { selectedAccountName = name }
        }
    }

    private func displayName(for container: CNContainer) -> String {
        switch container.type {
        case .local: return "On My Mac"
        case .exchange: return "Exchange: \(container.name)"
        case .cardDAV: return container.name.isEmpty ? "CardDAV" : container.name
        case .unassigned: return container.name.isEmpty ? "Contacts" : container.name
        @unknown default: return container.name.isEmpty ? "Contacts" : container.name
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Mac Account Picker View
// ═══════════════════════════════════════════════════════════════════════

struct MacAccountPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIdentifier: String?
    let isAuthorized: Bool

    @State private var containers: [CNContainer] = []
    @State private var containerContactCounts: [String: Int] = [:]
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Select a Contacts Account")
                    .font(.title2).fontWeight(.bold)
                Text("Choose which Mac Contacts account to use for syncing with Google")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }

            Divider()

            if !isAuthorized {
                StatusBanner(icon: "exclamationmark.triangle.fill", color: Palette.warning,
                             title: "Contacts Access Required",
                             message: "Grant access to Mac Contacts to see available accounts") {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let error {
                StatusBanner(icon: "xmark.circle.fill", color: Palette.danger,
                             title: "Error Loading Accounts", message: error)
            }

            if isLoading && isAuthorized {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading accounts…").foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if containers.isEmpty && isAuthorized {
                Spacer()
                VStack(spacing: 12) {
                    AdaptiveIcon(systemName: "folder.badge.questionmark", size: 40)
                    Text("No Contacts Accounts Found").font(.headline)
                    Text("Your Mac doesn't have any contacts accounts configured")
                        .font(.caption).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(containers, id: \.identifier) { container in
                            AccountRowView(
                                container: container,
                                contactCount: containerContactCounts[container.identifier],
                                isSelected: selectedIdentifier == container.identifier,
                                action: { selectedIdentifier = container.identifier }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            HStack {
                Text("\(containers.count) account\(containers.count == 1 ? "" : "s") available")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Select") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIdentifier == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear(perform: loadContainers)
    }

    private func loadContainers() {
        let store = MacContactsConnector.shared
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            fetchContainers(store: store)
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, err in
                DispatchQueue.main.async {
                    if granted { fetchContainers(store: store) }
                    else { error = err?.localizedDescription ?? "Access denied"; isLoading = false }
                }
            }
        case .denied, .restricted:
            error = "Contacts access not authorised. Enable it in System Settings → Privacy & Security → Contacts."
            isLoading = false
        @unknown default:
            error = "Unknown authorisation status"
            isLoading = false
        }
    }

    private func fetchContainers(store: CNContactStore) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try store.containers(matching: nil)
                var counts: [String: Int] = [:]
                for c in fetched {
                    let predicate = CNContact.predicateForContactsInContainer(withIdentifier: c.identifier)
                    let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: [])
                    counts[c.identifier] = contacts.count
                }
                DispatchQueue.main.async {
                    containers = fetched; containerContactCounts = counts; isLoading = false
                    if fetched.isEmpty { error = "No contacts accounts found on this Mac" }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "Failed to load accounts: \(error.localizedDescription)"; isLoading = false
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Account Row View
// ═══════════════════════════════════════════════════════════════════════

struct AccountRowView: View {
    let container: CNContainer
    let contactCount: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon(for: container.type))
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.appTextInverse : Color.appAccent)
                    .frame(width: 40, height: 40)
                    .background(isSelected ? Color.appAccent : Color.appAccent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(for: container))
                        .font(.headline)
                        .foregroundStyle(Palette.primaryText)

                    HStack(spacing: 6) {
                        Text(typeDescription(for: container.type))
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                        if let count = contactCount {
                            Text("·").foregroundStyle(Palette.secondaryText)
                            Text("\(count) contact\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }

                Spacer()

                Image(systemName: isSelected ? AppIcon.statusSuccess : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.appSuccess : Color.appTextTertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.appAccent.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.appAccent : Color.appBorder, lineWidth: isSelected ? 2 : 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        }
        .buttonStyle(.plain)
    }

    private func displayName(for container: CNContainer) -> String {
        switch container.type {
        case .local: return "On My Mac"
        case .exchange: return container.name.isEmpty ? "Exchange Account" : container.name
        case .cardDAV: return container.name.isEmpty ? "CardDAV Account" : container.name
        case .unassigned: return container.name.isEmpty ? "Contacts" : container.name
        @unknown default: return container.name.isEmpty ? "Contacts Account" : container.name
        }
    }

    private func typeDescription(for type: CNContainerType) -> String {
        switch type {
        case .local: return "Local"
        case .exchange: return "Exchange"
        case .cardDAV: return "CardDAV (iCloud, etc.)"
        case .unassigned: return "Default"
        @unknown default: return "Unknown"
        }
    }

    private func icon(for type: CNContainerType) -> String {
        switch type {
        case .local: return "internaldrive"
        case .exchange: return "envelope.badge"
        case .cardDAV: return "cloud"
        case .unassigned: return "person.crop.circle"
        @unknown default: return "questionmark.circle"
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Backup & Recovery Settings
// ═══════════════════════════════════════════════════════════════════════

struct BackupAndRecoverySettingsView: View {
    @ObservedObject private var backupManager = ContactBackupManager.shared
    @StateObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState
    @StateObject private var googleExporter = GoogleContactsExporter()
    @StateObject private var macExporter = MacContactsExporter()
    @State private var isCreatingManualBackup = false
    @State private var backupResult: BackupResult?
    @State private var backupFiles: [(name: String, url: URL, size: Int64, date: Date)] = []

    private enum BackupResult {
        case success(count: Int)
        case error(String)
    }

    var body: some View {
        Form {
            // ── Status Overview ─────────────────────────────────────────
            Section {
                HStack {
                    Text("Last Backup")
                    Spacer()
                    if let lastBackup = backupManager.lastBackupDate {
                        Text(lastBackup.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(Palette.secondaryText)
                    } else {
                        Text("Never")
                            .foregroundStyle(Palette.warning)
                    }
                }

                HStack {
                    Text("Total Backups")
                    Spacer()
                    Text("\(backupManager.backupCount)")
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.secondaryText)
                }

                HStack {
                    Text("Storage Used")
                    Spacer()
                    Text(formatBytes(backupManager.totalBackupSize))
                        .foregroundStyle(Palette.secondaryText)
                }
            } header: {
                Label("Backup Status", systemImage: "externaldrive")
            }

            // ── Create Backup ───────────────────────────────────────────
            Section {
                Button { createManualBackup() } label: {
                    HStack(spacing: 8) {
                        if isCreatingManualBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "externaldrive.badge.plus")
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text(isCreatingManualBackup ? "Backing Up…" : "Create Backup Now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreatingManualBackup)

                // Result banner
                if let result = backupResult {
                    HStack(spacing: 8) {
                        switch result {
                        case .success(let count):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.success)
                            Text("Backed up \(count) contacts successfully")
                                .font(.caption)
                                .foregroundStyle(Palette.success)
                        case .error(let msg):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.danger)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(Palette.danger)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Manual Backup", systemImage: "hand.tap")
            }

            // ── Export to File (moved here from Accounts) ───────────────
            Section {
                if GoogleOAuthManager.shared.isAuthenticated {
                    HStack(spacing: 10) {
                        Label("Google Contacts", systemImage: AppIcon.sourceGoogle)
                            .iconStyle(.appSourceGoogle)
                        Spacer()
                        Button("CSV…")   { exportGoogle(excel: false) }
                            .disabled(googleExporter.isExporting)
                        Button("Excel…") { exportGoogle(excel: true) }
                            .disabled(googleExporter.isExporting)
                        if googleExporter.isExporting {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Text("Sign in to Google (Accounts tab) to export Google contacts.")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }

                if appState.isMacContactsAuthorized {
                    HStack(spacing: 10) {
                        Label("Mac Contacts", systemImage: AppIcon.sourceApple)
                            .iconStyle(.appSourceApple)
                        Spacer()
                        Button("CSV…")   { exportMac(excel: false) }
                            .disabled(macExporter.isExporting)
                        Button("Excel…") { exportMac(excel: true) }
                            .disabled(macExporter.isExporting)
                        if macExporter.isExporting {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Text("Grant Contacts access (Accounts tab) to export Mac contacts.")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            } header: {
                Label("Export to File", systemImage: "square.and.arrow.up")
            } footer: {
                Text("One-off spreadsheet exports for archiving or importing elsewhere. Snapshots above are the app's own restore format.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            // ── Backup Location ─────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(backupManager.backupDirectoryDisplayPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(backupManager.backupDirectory)
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    .help("Reveal backup folder in Finder")

                    Button {
                        backupManager.chooseBackupDirectory()
                        refreshBackupFiles()
                    } label: {
                        Label("Change Location…", systemImage: "folder.badge.gearshape")
                    }
                    .help("Choose a different folder for backups")

                    if backupManager.hasCustomBackupFolder {
                        Button {
                            backupManager.resetBackupDirectoryToDefault()
                            refreshBackupFiles()
                        } label: {
                            Label("Reset to Default", systemImage: AppIcon.restore)
                        }
                        .help("Return to the app's default backup folder")
                    }
                }
            } header: {
                Label("Backup Location", systemImage: "folder")
            }

            // ── Recent Backups ──────────────────────────────────────────
            Section {
                if backupFiles.isEmpty {
                    HStack {
                        Image(systemName: "tray")
                            .foregroundStyle(Palette.secondaryText)
                        Text("No backup files yet")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(backupFiles.prefix(10), id: \.url) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.appInfo)
                                .font(.caption)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(formatBytes(file.size)) • \(file.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(Palette.secondaryText)
                            }

                            Spacer()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                    }

                    if backupFiles.count > 10 {
                        Text("and \(backupFiles.count - 10) more…")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            } header: {
                HStack {
                    Label("Recent Backup Files", systemImage: "clock")
                    Spacer()
                    Button { refreshBackupFiles() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // ── Automation ──────────────────────────────────────────────
            Section {
                Toggle("Automatic Backups", isOn: $settings.autoBackupEnabled)
                    .help("Automatically create a snapshot before every sync")
                Text("Creates a safety backup before every sync operation. Recommended.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)

                Stepper(
                    value: $settings.maxBackupCount,
                    in: 5...200,
                    step: 5
                ) {
                    HStack {
                        Text("Keep at most")
                        Spacer()
                        Text("\(settings.maxBackupCount) backups")
                            .foregroundStyle(Palette.secondaryText)
                            .monospacedDigit()
                    }
                }
                .help("Older backups are pruned automatically once this limit is reached")
            } header: {
                Label("Automation", systemImage: "clock.arrow.circlepath")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshBackupFiles() }
    }

    private func createManualBackup() {
        isCreatingManualBackup = true
        backupResult = nil
        // Detached: Mac Contacts fetch is synchronous XPC — keep off main.
        Task.detached(priority: .userInitiated) {
            do {
                // Fetch actual contacts from Mac Contacts (if authorized)
                var macContacts: [UnifiedContact] = []
                if await appState.isMacContactsAuthorized {
                    // The CNContactStore work stays off main; the mapping hops
                    // back because ContactMapper is main-actor isolated.
                    let cnContacts = try MacContactsConnector.fetchAllContactsOffMain()
                    macContacts = await MainActor.run {
                        cnContacts.map { ContactMapper.toUnified(from: $0) }
                    }
                }

                // Fetch Google contacts (if authenticated)
                var googleContacts: [UnifiedContact] = []
                if await GoogleOAuthManager.shared.isAuthenticated {
                    let connector = await GoogleContactsConnector()
                    let gContacts = try await connector.fetchAllContacts()
                    googleContacts = await MainActor.run {
                        gContacts.map { ContactMapper.toUnified(from: $0) }
                    }
                }

                let totalCount = googleContacts.count + macContacts.count

                _ = try await backupManager.createManualBackup(
                    googleContacts: googleContacts,
                    macContacts: macContacts,
                    customNotes: "Manual backup from Settings — \(totalCount) contacts"
                )

                await MainActor.run {
                    backupResult = .success(count: totalCount)
                    isCreatingManualBackup = false
                    refreshBackupFiles()
                }
            } catch {
                await MainActor.run {
                    backupResult = .error(error.localizedDescription)
                    isCreatingManualBackup = false
                }
            }
        }
    }

    private func refreshBackupFiles() {
        backupFiles = backupManager.listBackupFiles()
    }

    // MARK: - Spreadsheet exports (moved from Accounts tab)

    private func exportGoogle(excel: Bool) {
        Task {
            do {
                let fileURL = excel
                    ? try await googleExporter.exportToExcel()
                    : try await googleExporter.exportToCSV()
                guard let fileURL else { return }
                let contacts = try await GoogleContactsConnector().fetchAllContacts()
                await MainActor.run {
                    googleExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run { googleExporter.showExportErrorAlert(error) }
            }
        }
    }

    private func exportMac(excel: Bool) {
        Task.detached(priority: .userInitiated) {
            do {
                let containerID = await settings.macAccountMode == .specific
                    ? settings.selectedMacAccountIdentifier : nil
                let fileURL = excel
                    ? try await macExporter.exportToExcel(from: containerID)
                    : try await macExporter.exportToCSV(from: containerID)
                guard let fileURL else { return }
                let contacts = try MacContactsConnector.fetchAllContactsOffMain()
                await MainActor.run {
                    macExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run { macExporter.showExportErrorAlert(error) }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Reusable Components
// ═══════════════════════════════════════════════════════════════════════

/// A tappable row with icon, title, subtitle, and selection checkmark.
private struct SelectableRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AdaptiveIcon(
                systemName: icon,
                color: isSelected ? Palette.accent : Palette.secondaryText,
                size: 15
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isSelected {
                AdaptiveIcon(systemName: "checkmark.circle.fill", color: Palette.accent, size: 16)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Toggle row with an SF Symbol icon.
private struct FieldToggleRow: View {
    let icon: String
    let label: String
    let help: String
    @Binding var binding: Bool

    var body: some View {
        Toggle(isOn: $binding) {
            Label(label, systemImage: icon)
        }
        .help(help)
    }
}

/// Row showing an AI-matching signal with icon, label, and detail text.
private struct AISignalRow: View {
    let icon: String
    let label: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AdaptiveIcon(systemName: icon, color: Palette.accent, size: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A coloured banner with icon, title, message and optional trailing action.
private struct StatusBanner<Actions: View>: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    var actions: (() -> Actions)?

    init(icon: String, color: Color, title: String, message: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon; self.color = color; self.title = title
        self.message = message; self.actions = actions
    }

    init(icon: String, color: Color, title: String, message: String) where Actions == EmptyView {
        self.icon = icon; self.color = color; self.title = title
        self.message = message; self.actions = nil
    }

    var body: some View {
        HStack(spacing: 12) {
            AdaptiveIcon(systemName: icon, color: color, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.caption).foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actions { actions() }
        }
        .padding()
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Preview
// ═══════════════════════════════════════════════════════════════════════

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
