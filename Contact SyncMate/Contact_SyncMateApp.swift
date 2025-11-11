//
//  Contact_SyncMateApp.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI
import AppKit

@main
struct Contact_SyncMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Settings window - use WindowGroup for better control
        WindowGroup(id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 600, height: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Add Settings command to app menu
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    // Open the settings window
                    if let url = URL(string: "contactsyncmate://settings") {
                        NSWorkspace.shared.open(url)
                    } else {
                        // Fallback: use notification
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - AppDelegate for Menu Bar
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for URL events (OAuth callback)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        
        // Listen for settings window open requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettingsWindow),
            name: .openSettingsWindow,
            object: nil
        )
        
        // Create the menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Contact SyncMate")
            button.action = #selector(menuBarIconClicked)
            button.target = self
        }
        
        // Hide the dock icon (menu bar only by default)
        // Users can toggle this in settings
        updateActivationPolicy()
        
        // Listen for activation policy changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateActivationPolicy),
            name: .activationPolicyChanged,
            object: nil
        )
    }
    
    @objc private func handleOpenSettingsWindow() {
        print("📍 handleOpenSettingsWindow() called")
        openSettingsWindowDirectly()
    }
    
    private func openSettingsWindowDirectly() {
        NSApp.activate(ignoringOtherApps: true)
        
        // Check if window already exists
        if let window = settingsWindow, window.isVisible {
            print("📍 Settings window already visible, bringing to front")
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        // Create new settings window
        print("📍 Creating new settings window")
        let appState = AppState()
        let contentView = SettingsView()
            .environmentObject(appState)
        
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        
        print("📍 Settings window created and shown")
    }
    
    @objc private func updateActivationPolicy() {
        if AppSettings.shared.attachToMenuBar {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
    
    @objc func menuBarIconClicked() {
        guard (statusItem?.button) != nil else { return }
        
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showMenu()
        }
    }
    
    private func showMenu() {
        let menu = NSMenu()
        let settings = AppSettings.shared
        
        // Google Account Status
        let googleStatus = GoogleOAuthManager.shared.isAuthenticated
        let googleEmail = GoogleOAuthManager.shared.userEmail
        
        if googleStatus, let email = googleEmail {
            let statusItem = NSMenuItem(title: "✓ Google: \(email)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        } else {
            let statusItem = NSMenuItem(title: "⚠️ Google Account Not Connected", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Primary Sync button (based on selected sync type)
        let syncTitle = getSyncButtonTitle(for: settings.selectedSyncType)
        let syncItem = NSMenuItem(title: syncTitle, action: #selector(performSync), keyEquivalent: "")
        // Disable sync if Google is not connected
        syncItem.isEnabled = googleStatus
        menu.addItem(syncItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Sync Type submenu (to change the sync type)
        let syncTypeItem = NSMenuItem(title: "Sync Type", action: nil, keyEquivalent: "")
        let syncTypeSubmenu = NSMenu()
        
        for syncType in SyncType.allCases {
            let item = NSMenuItem(title: syncType.displayName, action: #selector(changeSyncType(_:)), keyEquivalent: "")
            item.representedObject = syncType
            item.state = (syncType == settings.selectedSyncType) ? .on : .off
            syncTypeSubmenu.addItem(item)
        }
        
        syncTypeItem.submenu = syncTypeSubmenu
        menu.addItem(syncTypeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status & History
        menu.addItem(NSMenuItem(title: "View Sync Status", action: #selector(viewStatus), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sync History…", action: #selector(viewHistory), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        // Accounts
        let accountsItem = NSMenuItem(title: "Accounts to Sync", action: nil, keyEquivalent: "")
        let accountsSubmenu = NSMenu()
        accountsSubmenu.addItem(NSMenuItem(title: "Gmail Account…", action: #selector(configureGmail), keyEquivalent: ""))
        accountsSubmenu.addItem(NSMenuItem(title: "Mac Account…", action: #selector(configureMacAccount), keyEquivalent: ""))
        accountsItem.submenu = accountsSubmenu
        menu.addItem(accountsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings & Quit
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Contact SyncMate", action: #selector(quit), keyEquivalent: "q"))
        
        // Set targets for all menu items
        for item in menu.items {
            item.target = self
            if let submenu = item.submenu {
                for subitem in submenu.items {
                    subitem.target = self
                }
            }
        }
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
    
    // MARK: - Menu Actions
    
    @objc private func performSync() {
        let syncType = AppSettings.shared.selectedSyncType
        print("Performing sync: \(syncType.displayName)")
        
        switch syncType {
        case .twoWay:
            // TODO: Implement 2-way sync
            break
        case .googleToMac:
            // TODO: Implement Google → Mac sync
            break
        case .macToGoogle:
            // TODO: Implement Mac → Google sync
            break
        case .manual:
            // TODO: Show manual sync preview window
            break
        }
    }
    
    @objc private func changeSyncType(_ sender: NSMenuItem) {
        guard let syncType = sender.representedObject as? SyncType else { return }
        AppSettings.shared.selectedSyncType = syncType
        print("Changed sync type to: \(syncType.displayName)")
    }
    
    private func getSyncButtonTitle(for syncType: SyncType) -> String {
        switch syncType {
        case .twoWay:
            return "Sync Now (2-Way)"
        case .googleToMac:
            return "Sync Now (Google → Mac)"
        case .macToGoogle:
            return "Sync Now (Mac → Google)"
        case .manual:
            return "Manual Sync…"
        }
    }
    
    @objc private func viewStatus() {
        print("View Status triggered")
        // TODO: Show status window
    }
    
    @objc private func viewHistory() {
        print("View History triggered")
        // TODO: Show history window
    }
    
    @objc private func configureGmail() {
        print("Configure Gmail triggered")
        
        // Activate the app
        NSApp.activate(ignoringOtherApps: true)
        
        // Check if already signed in
        if GoogleOAuthManager.shared.isAuthenticated {
            // Already signed in, just open settings
            openSettings()
            
            // Navigate to Accounts tab after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .showAccountsSettings, object: nil)
            }
        } else {
            // Not signed in, trigger OAuth flow directly
            GoogleOAuthManager.shared.startSignInFromCurrentWindow()
            
            // After sign-in, open settings
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.openSettings()
                
                // Navigate to Accounts tab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .showAccountsSettings, object: nil)
                }
            }
        }
    }
    
    @objc private func configureMacAccount() {
        print("📍 Configure Mac Account triggered")
        
        // Activate the app and open Settings
        NSApp.activate(ignoringOtherApps: true)
        print("📍 App activated")
        
        openSettings()
        print("📍 Settings opened")
        
        // Post notification to switch to Accounts tab after a short delay
        // to ensure the Settings window has fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            print("📍 Posting showAccountsSettings notification")
            NotificationCenter.default.post(name: .showAccountsSettings, object: nil)
        }
    }
    
    @objc private func openSettings() {
        print("📍 openSettings() called")
        NSApp.activate(ignoringOtherApps: true)
        
        // Post notification to open settings window
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        
        // Also try to open window directly using environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Check if settings window already exists
            let settingsWindows = NSApp.windows.filter { window in
                // SettingsView has a frame of 600x500
                return window.contentView?.frame.width == 600 && 
                       window.contentView?.frame.height == 500
            }
            
            if let window = settingsWindows.first {
                print("📍 Found existing Settings window, bringing to front")
                window.makeKeyAndOrderFront(nil)
            } else {
                print("📍 Opening new Settings window")
                // Open the WindowGroup
                if #available(macOS 13.0, *) {
                    NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
                }
            }
        }
    }
    
    @objc private func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - URL Handling
    
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        // The URL will be handled by ASWebAuthenticationSession automatically
        // This is just a fallback to ensure the app receives the callback
        print("Received URL callback: \(url)")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showAccountsSettings = Notification.Name("showAccountsSettings")
    static let activationPolicyChanged = Notification.Name("activationPolicyChanged")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}
