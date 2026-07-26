//
//  AppSettings.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import AppKit
import Combine

/// Centralized app settings using UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private init() {
        // Private initializer to ensure singleton
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
    
    @Published var mergeContacts2Way: Bool = UserDefaults.standard.object(forKey: "mergeContacts2Way") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mergeContacts2Way, forKey: "mergeContacts2Way") }
    }
    
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
    
    @Published var autoSyncInterval: TimeInterval = UserDefaults.standard.object(forKey: "autoSyncInterval") as? TimeInterval ?? 900 {
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

    /// Ask before restoring a backup. Default ON — restore rewrites contacts.
    @Published var confirmBeforeRestore: Bool = UserDefaults.standard.object(forKey: "confirmBeforeRestore") as? Bool ?? true {
        didSet { UserDefaults.standard.set(confirmBeforeRestore, forKey: "confirmBeforeRestore") }
    }

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
        mergeContacts2Way = true
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
        autoSyncInterval = 900
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
        confirmBeforeRestore = true
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

enum SyncType: String, CaseIterable, Codable {
    case twoWay = "twoWay"
    case googleToMac = "googleToMac"
    case macToGoogle = "macToGoogle"
    case manual = "manual"
    
    var displayName: String {
        switch self {
        case .twoWay:
            return String(localized: "2-Way Sync")
        case .googleToMac:
            return String(localized: "Google → Mac")
        case .macToGoogle:
            return String(localized: "Mac → Google")
        case .manual:
            return String(localized: "Manual Sync…")
        }
    }

    var description: String {
        switch self {
        case .twoWay:
            return String(localized: "Sync changes in both directions automatically")
        case .googleToMac:
            return String(localized: "Google contacts are the master, changes sync to Mac only")
        case .macToGoogle:
            return String(localized: "Mac contacts are the master, changes sync to Google only")
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

    var displayName: String {
        switch self {
        case .alwaysAsk:    return "Always Ask"
        case .preferGoogle: return "Prefer Google"
        case .preferMac:    return "Prefer Mac"
        }
    }

    var description: String {
        switch self {
        case .alwaysAsk:    return "Show the conflict review sheet each time"
        case .preferGoogle: return "Silently keep the Google value when fields differ"
        case .preferMac:    return "Silently keep the Mac value when fields differ"
        }
    }

    var icon: String {
        switch self {
        case .alwaysAsk:    return "questionmark.circle"
        case .preferGoogle: return "g.circle.fill"
        case .preferMac:    return "desktopcomputer"
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
