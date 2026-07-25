//
//  Contact_SyncMateApp.swift
//  Contact SyncMate
//

import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct Contact_SyncMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window
        WindowGroup(id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .frame(minWidth: 720, idealWidth: 780,
                       minHeight: 520, idealHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
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

    // Auto-sync scheduler — owns the repeating timer
    private var autoSyncScheduler: AutoSyncScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // OAuth callback is handled directly inside `ASWebAuthenticationSession`
        // by `GoogleOAuthManager.signIn()` — there is no need for a separate
        // AppleEvent URL handler. The legacy handler that previously lived
        // here only `print()`d the callback URL and was dead code.

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
        setupLaunchAtLogin()
        setupAutoSyncScheduler()
        setupAppearanceOverride()

        // Show onboarding on first launch (via dashboard/content window)
        if !AppSettings.shared.hasCompletedOnboarding {
            openDashboard()
        }
    }

    // MARK: - Auto-Sync Scheduler

    private func setupAutoSyncScheduler() {
        let scheduler = AutoSyncScheduler(appState: appState)
        scheduler.triggerSync = { [weak self] in
            guard let self else { return }

            // Single execution path: route through the shared SyncCoordinator
            // so that AppState.isSyncing, the menu bar icon, and history all
            // stay consistent regardless of whether the sync was triggered
            // by the user (Sync Now) or by the auto-sync timer.
            await MainActor.run {
                guard SyncCoordinator.shared.phase.isActive == false else {
                    SyncHistory.shared.log(source: "AutoSyncScheduler", action: "skipped",
                                           details: "sync already in progress")
                    return
                }
                guard self.appState.isGoogleConnected, self.appState.isMacContactsAuthorized else {
                    SyncHistory.shared.log(source: "AutoSyncScheduler", action: "skipped",
                                           details: "accounts not connected")
                    return
                }
                SyncHistory.shared.log(
                    source: "AutoSyncScheduler",
                    action: "timerFired",
                    details: "interval=\(AppSettings.shared.autoSyncInterval)s"
                )
                Task { await SyncCoordinator.shared.runSync() }
            }
        }
        autoSyncScheduler = scheduler
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Wire coordinator to appState BEFORE first icon draw
        SyncCoordinator.shared.appState = appState

        updateStatusItemIcon()
        statusItem?.button?.action = #selector(menuBarIconClicked)
        statusItem?.button?.target = self

        // React to SyncCoordinator phase changes (syncing, error, completed, idle)
        SyncCoordinator.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)

        // Live progress percentage in the menu bar during a sync
        SyncCoordinator.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)

        // Also react to lastSyncResult so the error badge persists after phase resets
        appState.$lastSyncResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateStatusItemIcon() {
        let coordinator = SyncCoordinator.shared
        let phase = coordinator.phase
        let symbolName: String
        var title = ""   // text shown next to the icon (progress % during sync)

        switch phase {
        case .preparing:
            symbolName = "arrow.triangle.2.circlepath"
            title = " …"
        case .syncing(let fraction):
            symbolName = "arrow.triangle.2.circlepath"
            title = " \(Int(fraction * 100))%"
        case .failed:
            symbolName = "exclamationmark.circle.fill"
        case .completed(let r) where !r.successful:
            symbolName = "exclamationmark.triangle.fill"
        default:
            // Idle / post-success — show persistent error badge if last result had errors
            if let result = appState.lastSyncResult, !result.successful {
                symbolName = "exclamationmark.circle"
            } else {
                symbolName = "person.2.circle"
            }
        }

        let image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "Contact SyncMate — \(phase.label)")
        image?.isTemplate = true  // Adapts to light/dark menu bar automatically

        guard let button = statusItem?.button else { return }
        button.image = image
        button.imagePosition = .imageLeft
        // Small monospaced-digit font so "42%" doesn't jiggle as it counts
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.title = title

        // Hover tooltip so the icon is identifiable among other status items
        button.toolTip = "Contact SyncMate — \(phase.label). Click to open."
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
        // Resizable is required: SettingsView's NavigationSplitView needs
        // minWidth 720 (sidebar + detail Form). A fixed 600-pt window
        // clipped the detail pane on the right.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 620))
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Launch at Login (SMAppService, macOS 13+)

    /// Call once at startup to sync the SMAppService registration status with the stored
    /// `launchAtLogin` preference, and then observe future changes.
    private func setupLaunchAtLogin() {
        // Sync the current setting → system on cold start
        applyLaunchAtLogin(AppSettings.shared.launchAtLogin)

        // Observe future toggle changes
        AppSettings.shared.$launchAtLogin
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.applyLaunchAtLogin(enabled)
            }
            .store(in: &cancellables)
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enable {
                    if service.status != .enabled { try service.register() }
                } else {
                    if service.status == .enabled { try service.unregister() }
                }
            } catch {
                SyncHistory.shared.log(
                    source: "LaunchAtLogin",
                    action: enable ? "register.failed" : "unregister.failed",
                    details: error.localizedDescription
                )
            }
        }
        // macOS 12 and earlier: requires a LoginItems helper bundle target.
        // SMLoginItemSetEnabled can be used there if that target is added.
    }

    // MARK: - Appearance Override (user customisation)

    /// Applies the user's light/dark/system preference app-wide and keeps
    /// following changes made in Settings → General → Appearance.
    private func setupAppearanceOverride() {
        applyAppearanceOverride()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyAppearanceOverride),
            name: .appearanceModeChanged,
            object: nil
        )
    }

    @objc private func applyAppearanceOverride() {
        NSApp.appearance = AppSettings.shared.preferredAppearance.nsAppearance
    }

    // MARK: - Activation Policy

    @objc private func updateActivationPolicy() {
        if AppSettings.shared.attachToMenuBar {
            // Only switch to .accessory if no visible windows are open.
            // Otherwise the app appears to "crash" / vanish while the
            // user is still interacting with it.
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.level == .normal }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // OAuth URL handling intentionally removed — see comment in
    // `applicationDidFinishLaunching`. ASWebAuthenticationSession handles
    // the callback inside `GoogleOAuthManager`.
}

// MARK: - Notifications

extension Notification.Name {
    static let showAccountsSettings  = Notification.Name("showAccountsSettings")
    static let activationPolicyChanged = Notification.Name("activationPolicyChanged")
    static let openSettingsWindow    = Notification.Name("openSettingsWindow")
}
