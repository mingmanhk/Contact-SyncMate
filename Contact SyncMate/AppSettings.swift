//
//  AppSettings.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
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
        // Reset all settings to their default values
        selectedSyncType = .manual
        
        syncDeletedContacts = false
        syncPhotos = true
        filterByGroups = false
        mergeContacts2Way = true
        mergeContacts1Way = false
        syncPostalCountryCodes = true
        batchGoogleUpdates = true
        
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
        
        selectedLanguage = "system"
        useBlackWhiteIcon = false
        attachToMenuBar = true
    }
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
            return "2-Way Sync"
        case .googleToMac:
            return "Google → Mac"
        case .macToGoogle:
            return "Mac → Google"
        case .manual:
            return "Manual Sync…"
        }
    }
    
    var description: String {
        switch self {
        case .twoWay:
            return "Sync changes in both directions automatically"
        case .googleToMac:
            return "Google contacts are the master, changes sync to Mac only"
        case .macToGoogle:
            return "Mac contacts are the master, changes sync to Google only"
        case .manual:
            return "Preview and approve each change before syncing"
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
