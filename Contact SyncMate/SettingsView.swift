//
//  SettingsView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import Contacts

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var oauthManager = GoogleOAuthManager.shared
    @State private var selectedTab: Int = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Google Account Status Banner
            if oauthManager.isAuthenticated, let email = oauthManager.userEmail {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Google Account:")
                        .foregroundStyle(.secondary)
                    Text(email)
                        .fontWeight(.medium)
                    Spacer()
                    Button(action: {
                        selectedTab = 4 // Switch to Accounts tab
                    }) {
                        Text("Manage")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Google Account not connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: {
                        selectedTab = 4 // Switch to Accounts tab
                    }) {
                        Text("Connect")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            
            Divider()
            
            TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)
            
            CommonSyncSettingsView()
                .tabItem {
                    Label("Common Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(1)
            
            ManualSyncSettingsView()
                .tabItem {
                    Label("Manual Sync", systemImage: "hand.tap")
                }
                .tag(2)
            
            AutoSyncSettingsView()
                .tabItem {
                    Label("Auto Sync", systemImage: "clock.arrow.circlepath")
                }
                .tag(3)
            
            AccountsSettingsView()
                .tabItem {
                    Label("Accounts", systemImage: "person.2")
                }
                .tag(4)
            }
            .frame(width: 600, height: 500)
            .onReceive(NotificationCenter.default.publisher(for: .showAccountsSettings)) { _ in
                print("📍 Received showAccountsSettings notification")
                selectedTab = 4 // Switch to Accounts tab
            }
        }
        .onAppear {
            print("📍 SettingsView appeared")
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Sync Type") {
                Picker("Sync mode:", selection: $settings.selectedSyncType) {
                    ForEach(SyncType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.radioGroup)
                
                Text(settings.selectedSyncType.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Section("Appearance") {
                Toggle("Use black & white menu bar icon", isOn: $settings.useBlackWhiteIcon)
                    .help("Display a monochrome icon in the menu bar instead of colored")
                
                Toggle("Attach app to menu bar only", isOn: $settings.attachToMenuBar)
                    .help("When enabled, app won't appear in Dock")
                    .onChange(of: settings.attachToMenuBar) { _, newValue in
                        updateDockVisibility(hide: newValue)
                    }
            }
            
            Section("Language") {
                Picker("Interface language:", selection: $settings.selectedLanguage) {
                    Text("System Default").tag("system")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                }
                .help("Choose the language for the app interface")
            }
            
            Section("Data") {
                Button("Reset All Settings") {
                    settings.resetToDefaults()
                }
                .help("Reset all preferences to their default values")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private func updateDockVisibility(hide: Bool) {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        // Notify the app delegate about the change
        NotificationCenter.default.post(name: .activationPolicyChanged, object: nil)
    }
}

// MARK: - Common Sync Settings

struct CommonSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Basic Sync Options") {
                Toggle("Sync deleted contacts", isOn: $settings.syncDeletedContacts)
                    .help("When enabled, deleting a contact on one side will delete it on the other")
                
                Toggle("Sync photos", isOn: $settings.syncPhotos)
                    .help("Include contact photos in sync operations")
                
                Toggle("Sync postal country codes", isOn: $settings.syncPostalCountryCodes)
                    .help("Synchronize and normalize country codes for international addresses")
            }
            
            Section("Merge Behavior") {
                Toggle("Merge contacts during 2-way sync", isOn: $settings.mergeContacts2Way)
                    .help("Merge fields when contacts differ, rather than overwriting")
                
                Toggle("Merge contacts during 1-way sync", isOn: $settings.mergeContacts1Way)
                    .help("Merge fields during 1-way sync instead of full replacement")
            }
            
            Section("Performance") {
                Toggle("Batch Google updates", isOn: $settings.batchGoogleUpdates)
                    .help("Group updates into batches for faster sync (up to 100 per batch)")
            }
            
            Section("Filters") {
                Toggle("Filter sync by groups/labels", isOn: $settings.filterByGroups)
                    .help("Only sync contacts in selected Mac groups or Google labels")
                
                if settings.filterByGroups {
                    Button("Select Groups/Labels…") {
                        // TODO: Show group/label picker
                    }
                    .disabled(true) // TODO: Enable when implemented
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Manual Sync Settings

struct ManualSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Safety Features") {
                Toggle("Detect Google duplicates during sync", isOn: $settings.detectGoogleDuplicates)
                    .help("Identify and warn about duplicate contacts before syncing")
                
                Toggle("Confirm pending deletions", isOn: $settings.confirmPendingDeletions)
                    .help("Show confirmation dialog before deleting contacts")
            }
            
            Section("Advanced") {
                Toggle("Force update all contacts", isOn: $settings.forceUpdateAll)
                    .help("Update all contacts even if unchanged (slower, more API-intensive)")
                
                Toggle("Dry run mode", isOn: $settings.dryRunMode)
                    .help("Preview changes without actually writing them")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Auto Sync Settings

struct AutoSyncSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    private let intervalOptions: [(String, TimeInterval)] = [
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600),
        ("4 hours", 14400),
        ("Daily", 86400)
    ]
    
    var body: some View {
        Form {
            Section("Auto Sync") {
                Toggle("Enable automatic sync", isOn: $settings.autoSyncEnabled)
                    .help("Run sync automatically in the background")
                
                if settings.autoSyncEnabled {
                    Picker("Sync direction:", selection: $settings.autoSyncDirection) {
                        Text("2-Way Sync").tag(SyncDirection.twoWay)
                        Text("Google → Mac").tag(SyncDirection.googleToMac)
                        Text("Mac → Google").tag(SyncDirection.macToGoogle)
                    }
                    
                    Picker("Update interval:", selection: $settings.autoSyncInterval) {
                        ForEach(intervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                }
            }
            
            if settings.autoSyncEnabled {
                Section("Conditions (Optional)") {
                    Toggle("Only sync when on AC power", isOn: $settings.autoSyncOnlyOnPower)
                        .help("Skip auto sync when running on battery")
                    
                    Toggle("Only sync when on Wi-Fi", isOn: $settings.autoSyncOnlyOnWiFi)
                        .help("Skip auto sync on cellular or metered connections")
                    
                    Toggle("Only sync when idle", isOn: $settings.autoSyncOnlyWhenIdle)
                        .help("Skip auto sync when user is actively using the Mac")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Accounts Settings

struct AccountsSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState
    @StateObject private var googleConnector = GoogleContactsConnector()
    @StateObject private var oauthManager = GoogleOAuthManager.shared
    @StateObject private var googleExporter = GoogleContactsExporter()
    @StateObject private var macExporter = MacContactsExporter()
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var showMacAccountPicker = false
    @State private var contactCount: Int?
    @State private var isLoadingContactCount = false
    @State private var macContactCount: Int?
    @State private var isLoadingMacContactCount = false
    
    var body: some View {
        Form {
            Section("Google Account") {
                if let email = oauthManager.userEmail {
                    // Connected state
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connected")
                                .font(.headline)
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let count = contactCount {
                                Text("\(count) contacts")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if isLoadingContactCount {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.7)
                                    Text("Loading...")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        Button(action: refreshContactCount) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Refresh contact count")
                        .disabled(isLoadingContactCount)
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Button("Test Connection") {
                            testGoogleConnection()
                        }
                        .help("Verify connection to Google Contacts API")
                        
                        Button("Backup to CSV…") {
                            exportContactsToCSV()
                        }
                        .help("Export all Google contacts to a CSV file")
                        .disabled(googleExporter.isExporting || macExporter.isExporting)
                        
                        Button("Backup to Excel…") {
                            exportContactsToExcel()
                        }
                        .help("Export all Google contacts to an Excel file")
                        .disabled(googleExporter.isExporting || macExporter.isExporting)
                        
                        if googleExporter.isExporting {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(Int(googleExporter.exportProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button("Sign Out") {
                        signOutFromGoogle()
                    }
                    .foregroundStyle(.red)
                } else {
                    // Not connected state
                    HStack {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.orange)
                        Text("Not connected")
                    }
                    
                    Button("Sign In with Google…") {
                        signInToGoogle()
                    }
                    .disabled(isSigningIn)
                    
                    if isSigningIn {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Authenticating...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let error = signInError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                Text("Required for syncing contacts with Google Contacts. The People API provides access to read and write your contact list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Mac Contacts Account") {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac Contacts")
                            .font(.headline)
                        if appState.isMacContactsAuthorized {
                            Text("Access granted")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Access required")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    if appState.isMacContactsAuthorized {
                        Button(action: refreshMacContactCount) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Refresh contact count")
                        .disabled(isLoadingMacContactCount)
                    }
                }
                
                if let count = macContactCount {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .foregroundStyle(.secondary)
                        Text("\(count) contact\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if isLoadingMacContactCount {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Picker("Account mode:", selection: $settings.macAccountMode) {
                    ForEach(MacAccountMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .help(settings.macAccountMode.description)
                .onChange(of: settings.macAccountMode) { oldValue, newValue in
                    // Automatically show picker when user selects "Specific Account"
                    if newValue == .specific && oldValue != .specific {
                        // Small delay to allow the picker to render properly
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showMacAccountPicker = true
                        }
                    }
                    // Refresh count when mode changes
                    refreshMacContactCount()
                }
                
                Text(settings.macAccountMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                if settings.macAccountMode == .specific {
                    VStack(alignment: .leading, spacing: 8) {
                        if let identifier = settings.selectedMacAccountIdentifier,
                           let accountName = getAccountName(for: identifier) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text("Selected Account:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(accountName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                Spacer()
                                Button("Change") {
                                    showMacAccountPicker = true
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                                Text("No account selected")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Select Account…") {
                                    showMacAccountPicker = true
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    
                    .sheet(isPresented: $showMacAccountPicker) {
                        MacAccountPickerView(
                            selectedIdentifier: $settings.selectedMacAccountIdentifier,
                            isAuthorized: appState.isMacContactsAuthorized
                        )
                        .frame(minWidth: 500, minHeight: 400)
                    }
                }
                
                // Backup Actions for Mac Contacts
                if appState.isMacContactsAuthorized {
                    HStack(spacing: 12) {
                        Button("Backup to CSV…") {
                            exportMacContactsToCSV()
                        }
                        .help("Export Mac contacts to a CSV file")
                        .disabled(googleExporter.isExporting || macExporter.isExporting)
                        
                        Button("Backup to Excel…") {
                            exportMacContactsToExcel()
                        }
                        .help("Export Mac contacts to an Excel file")
                        .disabled(googleExporter.isExporting || macExporter.isExporting)
                        
                        if macExporter.isExporting {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(Int(macExporter.exportProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Text("Mac Contacts is used for syncing with Google Contacts. You can back up your selected account to CSV or Excel format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Permissions") {
                HStack {
                    Image(systemName: appState.isMacContactsAuthorized ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(appState.isMacContactsAuthorized ? .green : .orange)
                    Text("Mac Contacts Access")
                    
                    Spacer()
                    
                    if !appState.isMacContactsAuthorized {
                        Button("Grant Access") {
                            openSystemSettings()
                        }
                    }
                }
                
                Text("Contact SyncMate needs access to your Mac contacts to sync them")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Load contact count when view appears if connected
            if oauthManager.isAuthenticated {
                refreshContactCount()
            }
            if appState.isMacContactsAuthorized {
                refreshMacContactCount()
            }
        }
    }
    
    // MARK: - Google Account Functions
    
    private func refreshContactCount() {
        isLoadingContactCount = true
        Task {
            do {
                let contacts = try await googleConnector.fetchAllContacts()
                await MainActor.run {
                    contactCount = contacts.count
                    isLoadingContactCount = false
                }
            } catch {
                await MainActor.run {
                    contactCount = nil
                    isLoadingContactCount = false
                }
            }
        }
    }
    
    private func exportContactsToCSV() {
        Task {
            do {
                guard let fileURL = try await googleExporter.exportToCSV() else {
                    // User cancelled
                    return
                }
                
                // Get contact count for success message
                let contacts = try await googleConnector.fetchAllContacts()
                
                await MainActor.run {
                    googleExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run {
                    googleExporter.showExportErrorAlert(error)
                }
            }
        }
    }
    
    private func exportContactsToExcel() {
        Task {
            do {
                guard let fileURL = try await googleExporter.exportToExcel() else {
                    // User cancelled
                    return
                }
                
                // Get contact count for success message
                let contacts = try await googleConnector.fetchAllContacts()
                
                await MainActor.run {
                    googleExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run {
                    googleExporter.showExportErrorAlert(error)
                }
            }
        }
    }
    
    // MARK: - Mac Contacts Export Functions
    
    private func exportMacContactsToCSV() {
        Task {
            do {
                let containerID = getContainerIdentifierForExport()
                guard let fileURL = try await macExporter.exportToCSV(from: containerID) else {
                    // User cancelled
                    return
                }
                
                // Count contacts
                let connector = MacContactsConnector()
                let contacts = try connector.fetchAllContacts()
                
                await MainActor.run {
                    macExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run {
                    macExporter.showExportErrorAlert(error)
                }
            }
        }
    }
    
    private func exportMacContactsToExcel() {
        Task {
            do {
                let containerID = getContainerIdentifierForExport()
                guard let fileURL = try await macExporter.exportToExcel(from: containerID) else {
                    // User cancelled
                    return
                }
                
                // Count contacts
                let connector = MacContactsConnector()
                let contacts = try connector.fetchAllContacts()
                
                await MainActor.run {
                    macExporter.showExportSuccessAlert(fileURL: fileURL, contactCount: contacts.count)
                }
            } catch {
                await MainActor.run {
                    macExporter.showExportErrorAlert(error)
                }
            }
        }
    }
    
    private func getContainerIdentifierForExport() -> String? {
        // Return the selected container ID if in specific mode
        if settings.macAccountMode == .specific {
            return settings.selectedMacAccountIdentifier
        }
        return nil // Export all accounts
    }
    
    private func refreshMacContactCount() {
        guard appState.isMacContactsAuthorized else { return }
        
        isLoadingMacContactCount = true
        Task {
            do {
                let connector = MacContactsConnector()
                let contacts = try connector.fetchAllContacts()
                await MainActor.run {
                    macContactCount = contacts.count
                    isLoadingMacContactCount = false
                }
            } catch {
                await MainActor.run {
                    macContactCount = nil
                    isLoadingMacContactCount = false
                }
            }
        }
    }
    
    private func signInToGoogle() {
        isSigningIn = true
        signInError = nil

        Task { @MainActor in
            // Ensure the settings window is frontmost
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.makeKeyAndOrderFront(nil)
            }
            
            // Activate the app
            NSApp.activate(ignoringOtherApps: true)
            
            // Small delay to ensure window activation completes
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            
            // Start the OAuth flow using the shared manager to ensure proper presentation
            GoogleOAuthManager.shared.startSignInFromCurrentWindow()
            
            // Wait a short moment to allow the session to present; real completion is handled via state updates
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            
            // If already authenticated, update UI state
            if GoogleOAuthManager.shared.isAuthenticated {
                settings.googleAccountEmail = GoogleOAuthManager.shared.userEmail
                appState.isGoogleConnected = true
            }
            
            isSigningIn = false
        }
    }
    
    private func signOutFromGoogle() {
        googleConnector.signOut()
        settings.googleAccountEmail = nil
        appState.isGoogleConnected = false
    }
    
    private func testGoogleConnection() {
        Task {
            do {
                let contacts = try await googleConnector.fetchAllContacts()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Connection Successful"
                    alert.informativeText = "Successfully connected to Google Contacts!\n\nFound \(contacts.count) contacts."
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
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Helper Functions
    
    private func getAccountName(for identifier: String) -> String? {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }
        
        do {
            let containers = try store.containers(matching: nil)
            if let container = containers.first(where: { $0.identifier == identifier }) {
                return displayName(for: container)
            }
        } catch {
            return nil
        }
        return identifier // Fallback to identifier if not found
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

// MARK: - Mac Account Picker View

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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select a Contacts Account")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Choose which Mac Contacts account to use for syncing with Google")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            // Error or Authorization Message
            if !isAuthorized {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Contacts Access Required")
                            .font(.headline)
                        Text("Grant access to Mac Contacts to see available accounts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let error = error {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error Loading Accounts")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            // Accounts List
            if isLoading && isAuthorized {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading accounts...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if containers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Contacts Accounts Found")
                        .font(.headline)
                    Text("Your Mac doesn't have any contacts accounts configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(containers, id: \.identifier) { container in
                            AccountRowView(
                                container: container,
                                contactCount: containerContactCounts[container.identifier],
                                isSelected: selectedIdentifier == container.identifier,
                                action: {
                                    selectedIdentifier = container.identifier
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Divider()
            
            // Footer Buttons
            HStack {
                Text("\(containers.count) account\(containers.count == 1 ? "" : "s") available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Select") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIdentifier == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear(perform: loadContainers)
    }
    
    private func loadContainers() {
        let store = CNContactStore()
        
        // Check authorization status
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            fetchContainers(store: store)
        case .notDetermined:
            // Request access
            store.requestAccess(for: .contacts) { granted, error in
                DispatchQueue.main.async {
                    if granted {
                        fetchContainers(store: store)
                    } else {
                        self.error = error?.localizedDescription ?? "Access denied"
                        isLoading = false
                    }
                }
            }
        case .denied, .restricted:
            error = "Contacts access is not authorized. Enable it in System Settings → Privacy & Security → Contacts."
            isLoading = false
        @unknown default:
            error = "Unknown authorization status"
            isLoading = false
        }
    }
    
    private func fetchContainers(store: CNContactStore) {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetchedContainers = try store.containers(matching: nil)
                
                // Fetch contact counts for each container
                var counts: [String: Int] = [:]
                for container in fetchedContainers {
                    let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                    let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: [])
                    counts[container.identifier] = contacts.count
                }
                
                DispatchQueue.main.async {
                    self.containers = fetchedContainers
                    self.containerContactCounts = counts
                    self.isLoading = false
                    
                    if fetchedContainers.isEmpty {
                        self.error = "No Contacts accounts were found on this Mac"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "Failed to load accounts: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Account Row View

struct AccountRowView: View {
    let container: CNContainer
    let contactCount: Int?
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: icon(for: container.type))
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .blue)
                    .frame(width: 40, height: 40)
                    .background(isSelected ? Color.blue : Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Account Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: container))
                        .font(.headline)
                        .foregroundStyle(isSelected ? .primary : .primary)
                    
                    HStack(spacing: 8) {
                        Text(typeDescription(for: container.type))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if let count = contactCount {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("\(count) contact\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Show identifier for debugging/reference
                    Text(container.identifier)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                // Selection Indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle")
                        .font(.title2)
                        .foregroundStyle(.secondary.opacity(0.3))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.blue.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
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

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

