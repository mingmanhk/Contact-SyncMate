//
//  Contact_SyncMateApp.swift
//  Contact SyncMate
//

import SwiftUI
import AppKit
import Combine

@main
struct Contact_SyncMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window
        WindowGroup(id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .frame(width: 600, height: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // Single shared AppState for the whole app
    let appState = AppState()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // Managed windows
    private var dashboardWindow:  NSWindow?
    private var historyWindow:    NSWindow?
    private var settingsWindow:   NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // OAuth URL handling
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Settings notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettingsWindow),
            name: .openSettingsWindow,
            object: nil
        )

        // Activation policy
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateActivationPolicy),
            name: .activationPolicyChanged,
            object: nil
        )

        setupStatusItem()
        setupPopover()
        updateActivationPolicy()

        // Show onboarding on first launch (via dashboard/content window)
        if !AppSettings.shared.hasCompletedOnboarding {
            openDashboard()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon()
        statusItem?.button?.action = #selector(menuBarIconClicked)
        statusItem?.button?.target = self

        // Keep icon in sync with sync state
        appState.$isSyncing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateStatusItemIcon() {
        let name: String
        if appState.isSyncing {
            name = "arrow.triangle.2.circlepath"
        } else if let result = appState.lastSyncResult, !result.successful {
            name = "exclamationmark.circle"
        } else {
            name = "person.2.circle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name,
                                            accessibilityDescription: "Contact SyncMate")
    }

    // MARK: - Popover

    private func setupPopover() {
        let menuBarView = MenuBarView(
            onOpenDashboard:   { [weak self] in self?.openDashboard()  },
            onOpenHistory:     { [weak self] in self?.openHistory()    },
            onOpenPreferences: { [weak self] in self?.openSettings()   }
        )
        .environmentObject(appState)

        let controller = NSHostingController(rootView: menuBarView)
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.contentSize = NSSize(width: 280, height: 440)
        pop.behavior = .transient
        self.popover = pop
    }

    @objc private func menuBarIconClicked() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Window Management

    @objc func openDashboard() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = dashboardWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ContentView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: controller)
        window.title = "Contact SyncMate"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.minSize = NSSize(width: 640, height: 480)
        window.center()
        window.isReleasedWhenClosed = false
        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func openHistory() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: SyncHistoryView())
        let window = NSWindow(contentViewController: controller)
        window.title = "Sync History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func handleOpenSettingsWindow() {
        openSettings()
    }

    func openSettings() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Activation Policy

    @objc private func updateActivationPolicy() {
        NSApp.setActivationPolicy(AppSettings.shared.attachToMenuBar ? .accessory : .regular)
    }

    // MARK: - URL Handling

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        print("Received OAuth callback: \(url)")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showAccountsSettings  = Notification.Name("showAccountsSettings")
    static let activationPolicyChanged = Notification.Name("activationPolicyChanged")
    static let openSettingsWindow    = Notification.Name("openSettingsWindow")
}
