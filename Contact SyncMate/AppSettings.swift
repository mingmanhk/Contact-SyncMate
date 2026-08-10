//
//  AppSettings.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import AppKit
// Required, not redundant: newer SDKs no longer have SwiftUI re-export Combine,
// so @Published's initialiser is unavailable without this.
import Combine

/// Centralized app settings using UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private init() {
        migrateLegacySyncType()
    }

    /// Carry a pre-split `selectedSyncType` over to the settings that replaced it.
    ///
    /// `SyncType` used to hold a direction and a mode in one value. Anyone who had
    /// chosen a direction tile has that raw value on disk, and it no longer
    /// decodes — the property initialiser would quietly fall back to `.manual`
    /// and drop their choice. This moves the direction to `autoSyncDirection`
    /// (where it is actually read) and sets the mode to `.automatic`, which is
    /// what those tiles meant.
    private func migrateLegacySyncType() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "selectedSyncType"),
              SyncType(rawValue: raw) == nil else { return }

        if let direction = SyncDirection(rawValue: raw) {
            autoSyncDirection = direction
        }
        selectedSyncType = .automatic

        SyncHistory.shared.log(
            source: "AppSettings", action: "settings.migratedSyncType",
            details: "'\(raw)' → mode=automatic, direction=\(autoSyncDirection.rawValue)"
        )
    }
    
    // MARK: - Common Sync Settings
    
    @Published var syncDeletedContacts: Bool = UserDefaults.standard.bool(forKey: "syncDeletedContacts") {
        didSet { UserDefaults.standard.set(syncDeletedContacts, forKey: "syncDeletedContacts") }
    }
    
    @Published var syncPhotos: Bool = UserDefaults.standard.object(forKey: "syncPhotos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncPhotos, forKey: "syncPhotos") }
    }
    
    @Published var filterByGroups: Bool = UserDefaults.standard.bool(forKey: "filterByGroups") {
        didSet { UserDefaults.standard.set(filterByGroups, forKey: "filterByGroups") }
    }
    
    @Published var selectedMacGroups: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "selectedMacGroups"),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }() {
        didSet {
            if let encoded = try? JSONEncoder().encode(selectedMacGroups) {
                UserDefaults.standard.set(encoded, forKey: "selectedMacGroups")
            }
        }
    }
    
    @Published var selectedGoogleLabels: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "selectedGoogleLabels"),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }() {
        didSet {
            if let encoded = try? JSONEncoder().encode(selectedGoogleLabels) {
                UserDefaults.standard.set(encoded, forKey: "selectedGoogleLabels")
            }
        }
    }
    
    // `mergeContacts2Way` used to live here, unread. It decided the same thing
    // as `defaultConflictResolution` — what happens when both sides changed — so
    // the two settings could disagree. It is now the `.mergeBoth` case there.
    
    @Published var mergeContacts1Way: Bool = UserDefaults.standard.bool(forKey: "mergeContacts1Way") {
        didSet { UserDefaults.standard.set(mergeContacts1Way, forKey: "mergeContacts1Way") }
    }
    
    @Published var syncPostalCountryCodes: Bool = UserDefaults.standard.object(forKey: "syncPostalCountryCodes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncPostalCountryCodes, forKey: "syncPostalCountryCodes") }
    }
    
    @Published var batchGoogleUpdates: Bool = UserDefaults.standard.object(forKey: "batchGoogleUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(batchGoogleUpdates, forKey: "batchGoogleUpdates") }
    }
    
    // MARK: - Manual Sync Settings
    
    @Published var detectGoogleDuplicates: Bool = UserDefaults.standard.object(forKey: "detectGoogleDuplicates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(detectGoogleDuplicates, forKey: "detectGoogleDuplicates") }
    }
    
    @Published var confirmPendingDeletions: Bool = UserDefaults.standard.object(forKey: "confirmPendingDeletions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(confirmPendingDeletions, forKey: "confirmPendingDeletions") }
    }
    
    @Published var forceUpdateAll: Bool = UserDefaults.standard.bool(forKey: "forceUpdateAll") {
        didSet { UserDefaults.standard.set(forceUpdateAll, forKey: "forceUpdateAll") }
    }
    
    @Published var dryRunMode: Bool = UserDefaults.standard.bool(forKey: "dryRunMode") {
        didSet { UserDefaults.standard.set(dryRunMode, forKey: "dryRunMode") }
    }
    
    // MARK: - Auto Sync Settings
    
    @Published var autoSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "autoSyncEnabled") {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "autoSyncEnabled") }
    }
    
    @Published var autoSyncDirection: SyncDirection = {
        guard let rawValue = UserDefaults.standard.string(forKey: "autoSyncDirection"),
              let direction = SyncDirection(rawValue: rawValue) else {
            return .twoWay
        }
        return direction
    }() {
        didSet { UserDefaults.standard.set(autoSyncDirection.rawValue, forKey: "autoSyncDirection") }
    }
    
    /// Default 4 hours.
    ///
    /// Address books change rarely, so a short interval mostly buys full fetches
    /// that find nothing. Going all the way to daily is the wrong trade though:
    /// a long window between syncs is exactly what lets both sides be edited
    /// before they reconcile, and every one of those becomes a conflict the user
    /// has to resolve. Four hours keeps the two copies close without polling.
    ///
    /// The user can pick anything from 5 minutes to daily in Settings → Auto Sync.
    @Published var autoSyncInterval: TimeInterval = UserDefaults.standard.object(forKey: "autoSyncInterval") as? TimeInterval ?? 14400 {
        didSet { UserDefaults.standard.set(autoSyncInterval, forKey: "autoSyncInterval") }
    }
    
    // Optional conditions
    @Published var autoSyncOnlyOnPower: Bool = UserDefaults.standard.bool(forKey: "autoSyncOnlyOnPower") {
        didSet { UserDefaults.standard.set(autoSyncOnlyOnPower, forKey: "autoSyncOnlyOnPower") }
    }
    
    @Published var autoSyncOnlyOnWiFi: Bool = UserDefaults.standard.bool(forKey: "autoSyncOnlyOnWiFi") {
        didSet { UserDefaults.standard.set(autoSyncOnlyOnWiFi, forKey: "autoSyncOnlyOnWiFi") }
    }
    
    @Published var autoSyncOnlyWhenIdle: Bool = UserDefaults.standard.bool(forKey: "autoSyncOnlyWhenIdle") {
        didSet { UserDefaults.standard.set(autoSyncOnlyWhenIdle, forKey: "autoSyncOnlyWhenIdle") }
    }
    
    // MARK: - AI Matching Settings

    @Published var aiMatchingEnabled: Bool = UserDefaults.standard.object(forKey: "aiMatchingEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiMatchingEnabled, forKey: "aiMatchingEnabled") }
    }

    /// Explicit user consent for the Cloud AI tier.
    ///
    /// AI matching is on by default, so that toggle is not consent to send
    /// anything anywhere. This flag is set only by the disclosure toggle in
    /// Settings → AI Matching, and the Anthropic call refuses to run while it
    /// is false — so the onboarding promise that contacts stay between this
    /// Mac and Google holds until the user explicitly reads and accepts the
    /// trade.
    @Published var aiCloudConsentGiven: Bool = UserDefaults.standard.object(forKey: "aiCloudConsentGiven") as? Bool ?? false {
        didSet { UserDefaults.standard.set(aiCloudConsentGiven, forKey: "aiCloudConsentGiven") }
    }

    /// Anthropic API key — stored in the macOS Keychain (not UserDefaults).
    /// On first launch after upgrade, any pre-existing key in UserDefaults is
    /// migrated into the Keychain and then removed from UserDefaults.
    @Published var anthropicAPIKey: String = AppSettings.loadAnthropicKey() {
        didSet {
            Self.keychain.setString(anthropicAPIKey,
                                    for: KeychainStore.Account.anthropicAPIKey)
        }
    }

    private static let keychain = KeychainStore()

    /// Load the Anthropic key from the Keychain, migrating any legacy
    /// UserDefaults value on first run.
    private static func loadAnthropicKey() -> String {
        let defaultsKey = "anthropicAPIKey"

        // Migration: if a legacy UserDefaults value exists, copy it into the
        // Keychain and clear the plaintext copy.
        if let legacy = UserDefaults.standard.string(forKey: defaultsKey),
           !legacy.isEmpty,
           keychain.string(for: KeychainStore.Account.anthropicAPIKey) == nil {
            keychain.setString(legacy, for: KeychainStore.Account.anthropicAPIKey)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }

        return keychain.string(for: KeychainStore.Account.anthropicAPIKey) ?? ""
    }

    /// Which Claude model the AI matching tier calls. Haiku is fast and
    /// cheap (recommended); Sonnet is more accurate for very ambiguous pairs.
    @Published var aiModel: AIModelChoice = {
        guard let raw = UserDefaults.standard.string(forKey: "aiModel"),
              let model = AIModelChoice(rawValue: raw) else { return .haiku }
        return model
    }() {
        didSet { UserDefaults.standard.set(aiModel.rawValue, forKey: "aiModel") }
    }

    /// Only call the Anthropic API for rule scores inside this range (default 30–79)
    @Published var aiAPIScoreRangeLow: Int = UserDefaults.standard.object(forKey: "aiAPIScoreRangeLow") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(aiAPIScoreRangeLow, forKey: "aiAPIScoreRangeLow") }
    }

    @Published var aiAPIScoreRangeHigh: Int = UserDefaults.standard.object(forKey: "aiAPIScoreRangeHigh") as? Int ?? 79 {
        didSet { UserDefaults.standard.set(aiAPIScoreRangeHigh, forKey: "aiAPIScoreRangeHigh") }
    }

    // MARK: - Notification Settings

    @Published var notifyOnSyncComplete: Bool = UserDefaults.standard.object(forKey: "notifyOnSyncComplete") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnSyncComplete, forKey: "notifyOnSyncComplete") }
    }

    @Published var notifyOnErrors: Bool = UserDefaults.standard.object(forKey: "notifyOnErrors") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnErrors, forKey: "notifyOnErrors") }
    }

    @Published var notifyOnConflicts: Bool = UserDefaults.standard.object(forKey: "notifyOnConflicts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnConflicts, forKey: "notifyOnConflicts") }
    }

    // MARK: - Field Sync Settings

    /// Notes-field sync requires the `com.apple.developer.contacts.notes`
    /// entitlement (granted by Apple). When the entitlement is not present
    /// this setting is **forced to `false`** regardless of stored value,
    /// because the API silently returns empty strings and drops writes on
    /// the floor. Attempting to enable it would mis-lead the user.
    ///
    /// To re-enable Notes sync in the future: obtain the entitlement, set
    /// `MacContactsConnector.notesFieldAvailable = true`, and this toggle
    /// will honour the stored value again.
    @Published var syncNotes: Bool = {
        guard MacContactsConnector.notesFieldAvailable else { return false }
        return UserDefaults.standard.object(forKey: "syncNotes") as? Bool ?? true
    }() {
        didSet {
            // Never write a stale `true` to disk if the entitlement is gone.
            let effective = MacContactsConnector.notesFieldAvailable ? syncNotes : false
            UserDefaults.standard.set(effective, forKey: "syncNotes")
        }
    }

    @Published var syncBirthday: Bool = UserDefaults.standard.object(forKey: "syncBirthday") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncBirthday, forKey: "syncBirthday") }
    }

    @Published var syncWebsites: Bool = UserDefaults.standard.object(forKey: "syncWebsites") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncWebsites, forKey: "syncWebsites") }
    }

    @Published var syncAddresses: Bool = UserDefaults.standard.object(forKey: "syncAddresses") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncAddresses, forKey: "syncAddresses") }
    }

    @Published var syncJobTitle: Bool = UserDefaults.standard.object(forKey: "syncJobTitle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncJobTitle, forKey: "syncJobTitle") }
    }

    // MARK: - Conflict Resolution

    @Published var defaultConflictResolution: ConflictResolutionDefault = {
        guard let raw = UserDefaults.standard.string(forKey: "defaultConflictResolution"),
              let value = ConflictResolutionDefault(rawValue: raw) else { return .alwaysAsk }
        return value
    }() {
        didSet { UserDefaults.standard.set(defaultConflictResolution.rawValue, forKey: "defaultConflictResolution") }
    }

    // MARK: - Other Settings
    
    @Published var selectedLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "system" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }
    
    @Published var useBlackWhiteIcon: Bool = UserDefaults.standard.bool(forKey: "useBlackWhiteIcon") {
        didSet { UserDefaults.standard.set(useBlackWhiteIcon, forKey: "useBlackWhiteIcon") }
    }

    @Published var attachToMenuBar: Bool = UserDefaults.standard.object(forKey: "attachToMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(attachToMenuBar, forKey: "attachToMenuBar") }
    }

    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: "launchAtLogin") {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    @Published var showSyncBadge: Bool = UserDefaults.standard.object(forKey: "showSyncBadge") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSyncBadge, forKey: "showSyncBadge") }
    }

    @Published var historyRetentionDays: Int = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }

    // MARK: - Confirmation Preferences
    //
    // Every potentially destructive action can either ask for confirmation
    // or run silently — the user chooses. Deletion confirmation
    // (`confirmPendingDeletions`) already exists in Manual Sync settings.

    /// Ask before starting a sync from the menu bar "Sync Now" button.
    /// Default OFF — Sync Now is an explicit user action already.
    @Published var confirmBeforeSyncNow: Bool = UserDefaults.standard.bool(forKey: "confirmBeforeSyncNow") {
        didSet { UserDefaults.standard.set(confirmBeforeSyncNow, forKey: "confirmBeforeSyncNow") }
    }

    // `confirmBeforeRestore` used to live here and was never read. It could not
    // be honoured either way: the restore sheet is not a yes/no prompt, it is
    // where the user decides whether to delete contacts added since the backup.
    // Skipping it would mean picking one of those outcomes for them silently.

    /// Allow high-confidence duplicate merges to apply WITHOUT asking.
    /// Default OFF — auto-merge only runs silently when the user opts in.
    @Published var allowSilentAutoMerge: Bool = UserDefaults.standard.bool(forKey: "allowSilentAutoMerge") {
        didSet { UserDefaults.standard.set(allowSilentAutoMerge, forKey: "allowSilentAutoMerge") }
    }

    // MARK: - Name Formatting (opt-in normalisation)

    /// Whether to apply the chosen name casing convention to contacts as
    /// they are written during sync. OFF by default — never rewrite user
    /// data without explicit opt-in.
    @Published var nameFormattingEnabled: Bool = UserDefaults.standard.bool(forKey: "nameFormattingEnabled") {
        didSet { UserDefaults.standard.set(nameFormattingEnabled, forKey: "nameFormattingEnabled") }
    }

    /// The casing convention to apply when `nameFormattingEnabled` is on.
    @Published var nameCasingConvention: NameCasingConvention = {
        guard let raw = UserDefaults.standard.string(forKey: "nameCasingConvention"),
              let convention = NameCasingConvention(rawValue: raw) else { return .titleCase }
        return convention
    }() {
        didSet { UserDefaults.standard.set(nameCasingConvention.rawValue, forKey: "nameCasingConvention") }
    }

    // MARK: - UI Customisation

    /// Appearance override: follow the system, or force light / dark.
    @Published var preferredAppearance: AppearanceMode = {
        guard let raw = UserDefaults.standard.string(forKey: "preferredAppearance"),
              let mode = AppearanceMode(rawValue: raw) else { return .system }
        return mode
    }() {
        didSet {
            UserDefaults.standard.set(preferredAppearance.rawValue, forKey: "preferredAppearance")
            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        }
    }

    /// User-selected accent colour. `.system` follows the macOS accent colour.
    @Published var accentColorChoice: AccentColorChoice = {
        guard let raw = UserDefaults.standard.string(forKey: "accentColorChoice"),
              let choice = AccentColorChoice(rawValue: raw) else { return .system }
        return choice
    }() {
        didSet { UserDefaults.standard.set(accentColorChoice.rawValue, forKey: "accentColorChoice") }
    }

    /// Menu bar popover section visibility — lets the user trim the popover
    /// down to just what they use.
    @Published var menuBarShowAccounts: Bool = UserDefaults.standard.object(forKey: "menuBarShowAccounts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarShowAccounts, forKey: "menuBarShowAccounts") }
    }

    @Published var menuBarShowAutoSyncToggle: Bool = UserDefaults.standard.object(forKey: "menuBarShowAutoSyncToggle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarShowAutoSyncToggle, forKey: "menuBarShowAutoSyncToggle") }
    }

    @Published var menuBarShowFeedbackBanner: Bool = UserDefaults.standard.object(forKey: "menuBarShowFeedbackBanner") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarShowFeedbackBanner, forKey: "menuBarShowFeedbackBanner") }
    }

    @Published var menuBarShowNavigationLinks: Bool = UserDefaults.standard.object(forKey: "menuBarShowNavigationLinks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarShowNavigationLinks, forKey: "menuBarShowNavigationLinks") }
    }

    // MARK: - Backup Settings

    /// Create a snapshot before every sync. Strongly recommended on by default.
    @Published var autoBackupEnabled: Bool = UserDefaults.standard.object(forKey: "autoBackupEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: "autoBackupEnabled") }
    }

    /// Maximum number of backup snapshots retained on disk. Older backups
    /// are pruned automatically once this limit is reached.
    @Published var maxBackupCount: Int = UserDefaults.standard.object(forKey: "maxBackupCount") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(maxBackupCount, forKey: "maxBackupCount") }
    }
    
    // MARK: - Account Settings
    
    @Published var googleAccountEmail: String? = UserDefaults.standard.string(forKey: "googleAccountEmail") {
        didSet { UserDefaults.standard.set(googleAccountEmail, forKey: "googleAccountEmail") }
    }
    
    @Published var macAccountMode: MacAccountMode = {
        guard let rawValue = UserDefaults.standard.string(forKey: "macAccountMode"),
              let mode = MacAccountMode(rawValue: rawValue) else {
            return .auto
        }
        return mode
    }() {
        didSet { UserDefaults.standard.set(macAccountMode.rawValue, forKey: "macAccountMode") }
    }
    
    @Published var selectedMacAccountIdentifier: String? = UserDefaults.standard.string(forKey: "selectedMacAccountIdentifier") {
        didSet { UserDefaults.standard.set(selectedMacAccountIdentifier, forKey: "selectedMacAccountIdentifier") }
    }
    
    // MARK: - Onboarding
    
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    
    @Published var hasCompletedInitialSync: Bool = UserDefaults.standard.bool(forKey: "hasCompletedInitialSync") {
        didSet { UserDefaults.standard.set(hasCompletedInitialSync, forKey: "hasCompletedInitialSync") }
    }
    
    // MARK: - Sync Type Selection
    
    @Published var selectedSyncType: SyncType = {
        guard let rawValue = UserDefaults.standard.string(forKey: "selectedSyncType"),
              let syncType = SyncType(rawValue: rawValue) else {
            return .manual // Default to manual for safety
        }
        return syncType
    }() {
        didSet { UserDefaults.standard.set(selectedSyncType.rawValue, forKey: "selectedSyncType") }
    }
    
    // MARK: - Helper Methods
    
    func resetToDefaults() {
        selectedSyncType = .manual

        syncDeletedContacts = false
        syncPhotos = true
        filterByGroups = false
        mergeContacts1Way = false
        syncPostalCountryCodes = true
        batchGoogleUpdates = true

        syncNotes = true
        syncBirthday = true
        syncWebsites = true
        syncAddresses = true
        syncJobTitle = true
        defaultConflictResolution = .alwaysAsk

        detectGoogleDuplicates = true
        confirmPendingDeletions = true
        forceUpdateAll = false
        dryRunMode = false

        autoSyncEnabled = false
        autoSyncDirection = .twoWay
        autoSyncInterval = 14400
        autoSyncOnlyOnPower = false
        autoSyncOnlyOnWiFi = false
        autoSyncOnlyWhenIdle = false

        aiMatchingEnabled = true
        aiAPIScoreRangeLow = 30
        aiAPIScoreRangeHigh = 79
        // Note: anthropicAPIKey is intentionally NOT reset here

        notifyOnSyncComplete = true
        notifyOnErrors = true
        notifyOnConflicts = true

        selectedLanguage = "system"
        useBlackWhiteIcon = false
        attachToMenuBar = true
        launchAtLogin = false
        showSyncBadge = true
        historyRetentionDays = 30

        autoBackupEnabled = true
        maxBackupCount = 30

        confirmBeforeSyncNow = false
        confirmPendingDeletions = true
        allowSilentAutoMerge = false

        nameFormattingEnabled = false
        nameCasingConvention = .titleCase

        preferredAppearance = .system
        accentColorChoice = .system
        menuBarShowAccounts = true
        menuBarShowAutoSyncToggle = true
        menuBarShowFeedbackBanner = true
        menuBarShowNavigationLinks = true
    }

    /// Return the app to a first-launch state.
    ///
    /// `resetToDefaults()` only resets preferences, which is not enough: the
    /// contact mappings, the sync log, the backups, the onboarding flag and the
    /// last-sync record all survive it, so the next run behaves like an
    /// established install rather than a new one.
    ///
    /// This deletes the backups too. That is the difference between "reset" and
    /// "reset except for the bit that remembers everything", and a button called
    /// Reset Everything should not quietly mean the second. It is irreversible —
    /// backups are the undo for every other operation in the app — so the
    /// confirmation that reaches it says so plainly.
    ///
    /// Never touches the user's actual contacts, on either side. Google sign-out
    /// is opt-in, since re-authorising is usually not what you want.
    func resetEverything(signOutGoogle: Bool = false) {
        resetToDefaults()

        ContactMappingStore.shared.deleteAllMappings()
        ContactBackupManager.shared.deleteAllBackups()
        DeduplicationDecisionStore.shared.clearAll()
        SyncFailureStore.shared.clearAll()
        SyncHistory.shared.clear()

        // Then remove the directory itself.
        //
        // Clearing each store through its own API leaves whatever nobody
        // remembered to list. That is not hypothetical: `dedup_decisions.json`
        // sat here through every "reset" in this app's life because no reset
        // path knew about it. Deleting the container is the version that cannot
        // silently miss a file a future store adds.
        Self.deleteApplicationSupportDirectory()

        hasCompletedOnboarding = false
        hasCompletedInitialSync = false
        if signOutGoogle { googleAccountEmail = nil }

        // `lastSyncDate` is persisted (AppState writes it to UserDefaults), so
        // it has to be removed here or a "reset" leaves the status line
        // reporting a sync whose every other trace has just been deleted.
        //
        // `lastSyncResult` and `nextScheduledSync` are in-memory only; the
        // caller clears those, since AppSettings has no access to AppState.
        UserDefaults.standard.removeObject(forKey: AppState.lastSyncDateKey)

        if signOutGoogle {
            GoogleOAuthManager.shared.signOut()
        }

        SyncHistory.shared.log(
            source: "AppSettings", action: "reset.everything",
            details: signOutGoogle
                ? "settings, mappings, backups, dedup decisions, history, Google sign-out"
                : "settings, mappings, backups, dedup decisions, history")
    }

    /// Everything the app has written under Application Support.
    ///
    /// `contact_mappings.json`, `sync_history.json`, `dedup_decisions.json` —
    /// and anything added later, which is the point of removing the directory
    /// rather than a list of filenames.
    private static func deleteApplicationSupportDirectory() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil, create: false)
        else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "ContactSync"
        let directory = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.removeItem(at: directory)
    }

    /// Remove the Keychain items and the saved folder grant as well.
    ///
    /// Separate from `resetEverything` because signing out is a different
    /// decision from starting over — but "erase everything about me" has to
    /// include the credentials, or it is not that.
    func eraseCredentialsAndGrants() {
        GoogleOAuthManager.shared.signOut()

        let keychain = Self.keychain
        for account in [KeychainStore.Account.anthropicAPIKey,
                        KeychainStore.Account.googleClientSecret,
                        "GoogleAccessToken", "GoogleRefreshToken",
                        "GoogleOAuthClientSecret"] {
            _ = keychain.delete(account: account)
        }

        SecurityScopedBookmark.clear(.backupFolder)
        anthropicAPIKey = ""
        googleAccountEmail = nil

        SyncHistory.shared.log(source: "AppSettings", action: "reset.credentialsErased",
                               details: "Keychain items and folder grant removed")
    }
}

// MARK: - UI Customisation Enums

/// Light / dark / follow-system appearance override.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    /// These return plain `String`, not `LocalizedStringKey`, so SwiftUI cannot
    /// localize them automatically the way it does a `Text("…")` literal — the
    /// lookup has to be explicit.
    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// The NSAppearance to apply app-wide. `nil` = follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// User-selectable accent colour. `.system` follows the macOS accent colour
/// preference; other cases apply a fixed tint via `.tint(...)` at each
/// window root.
enum AccentColorChoice: String, CaseIterable, Identifiable {
    case system = "system"
    case indigo = "indigo"
    case teal   = "teal"
    case green  = "green"
    case orange = "orange"
    case pink   = "pink"
    case graphite = "graphite"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:   return String(localized: "System")
        case .indigo:   return String(localized: "Indigo")
        case .teal:     return String(localized: "Teal")
        case .green:    return String(localized: "Green")
        case .orange:   return String(localized: "Orange")
        case .pink:     return String(localized: "Pink")
        case .graphite: return String(localized: "Graphite")
        }
    }

    /// The tint to apply, or `nil` to follow the system accent colour.
    /// Fixed choices deliberately use the standard macOS accent palette
    /// hues, which have well-tested light/dark behaviour.
    var tint: Color? {
        switch self {
        case .system:   return nil
        case .indigo:   return Color(nsColor: .systemIndigo)
        case .teal:     return Color(nsColor: .systemTeal)
        case .green:    return Color(nsColor: .systemGreen)
        case .orange:   return Color(nsColor: .systemOrange)
        case .pink:     return Color(nsColor: .systemPink)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }
}

extension Notification.Name {
    static let appearanceModeChanged = Notification.Name("appearanceModeChanged")
}

// MARK: - Supporting Enums

/// Whether Sync Now applies changes directly or shows them for review first.
///
/// This used to carry `twoWay` / `googleToMac` / `macToGoogle` alongside
/// `manual`, which conflated *direction* with *mode*. Direction already lived in
/// `autoSyncDirection`, and that is the value every sync path actually read — so
/// the three direction tiles in Settings changed nothing but a button label. A
/// user who picked "Google → Mac" there and left the direction picker on 2-Way
/// got a two-way sync.
///
/// Legacy raw values are migrated in `AppSettings.migrateLegacySyncType()`.
enum SyncType: String, CaseIterable, Codable {
    /// Apply the computed changes without stopping.
    case automatic = "automatic"
    /// Show the changes and wait for the user to approve them.
    case manual = "manual"

    var displayName: String {
        switch self {
        case .automatic:
            return String(localized: "Apply Changes Directly")
        case .manual:
            return String(localized: "Review Before Applying")
        }
    }

    var description: String {
        switch self {
        case .automatic:
            return String(localized: "Sync Now applies every change immediately")
        case .manual:
            return String(localized: "Preview and approve each change before syncing")
        }
    }
}

extension SyncDirection: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "twoWay": self = .twoWay
        case "googleToMac": self = .googleToMac
        case "macToGoogle": self = .macToGoogle
        default: return nil
        }
    }
    
    public var rawValue: String {
        switch self {
        case .twoWay: return "twoWay"
        case .googleToMac: return "googleToMac"
        case .macToGoogle: return "macToGoogle"
        }
    }
}

/// Claude model used by the cloud AI matching tier.
enum AIModelChoice: String, CaseIterable, Identifiable {
    case haiku  = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-5"
    case opus   = "claude-opus-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku:  return "Claude Haiku — fast, low cost (recommended)"
        case .sonnet: return "Claude Sonnet — balanced accuracy & cost"
        case .opus:   return "Claude Opus — highest accuracy, highest cost"
        }
    }
}

enum ConflictResolutionDefault: String, CaseIterable {
    case alwaysAsk  = "alwaysAsk"
    case preferGoogle = "preferGoogle"
    case preferMac    = "preferMac"
    /// Combine both sides: each side keeps its own values and gains whatever the
    /// other has that it is missing.
    ///
    /// Absorbed from the separate "Merge during 2-way sync" toggle, which was a
    /// second control over this same decision and was never read. Two settings
    /// that answer the same question can disagree; one enum cannot.
    case mergeBoth = "mergeBoth"

    var displayName: String {
        switch self {
        case .alwaysAsk:    return "Always Ask"
        case .preferGoogle: return "Prefer Google"
        case .preferMac:    return "Prefer Mac"
        case .mergeBoth:    return "Merge Both"
        }
    }

    var description: String {
        switch self {
        case .alwaysAsk:    return "Show the conflict review sheet each time"
        case .preferGoogle: return "Silently keep the Google value when fields differ"
        case .preferMac:    return "Silently keep the Mac value when fields differ"
        case .mergeBoth:    return "Combine both sides — neither loses a field the other has"
        }
    }

    var icon: String {
        switch self {
        case .alwaysAsk:    return "questionmark.circle"
        case .preferGoogle: return "g.circle.fill"
        case .preferMac:    return "desktopcomputer"
        case .mergeBoth:    return "arrow.triangle.merge"
        }
    }
}

enum MacAccountMode: String, CaseIterable {
    case auto = "Auto (Recommended)"
    case all = "All Accounts"
    case specific = "Specific Account"
    
    var description: String {
        switch self {
        case .auto:
            return "Automatically use iCloud if available, otherwise On My Mac"
        case .all:
            return "Sync with all Mac contact accounts (excluding read-only)"
        case .specific:
            return "Choose a specific contact account"
        }
    }
}
