//
//  AutoSyncScheduler.swift
//  Contact SyncMate
//
//  Manages the repeating auto-sync timer.
//
//  Responsibilities:
//    • Starts / stops a `DispatchSourceTimer` based on `AppSettings.autoSyncEnabled`
//    • Re-arms the timer whenever `autoSyncInterval` changes
//    • Publishes `AppState.nextScheduledSync` so the Settings → Auto Sync countdown
//      can display a live relative-time label
//    • Calls the injected `triggerSync` closure on each fire
//

import Foundation
import Combine

@MainActor
final class AutoSyncScheduler: ObservableObject {

    // MARK: - Dependencies

    private weak var appState: AppState?
    private let settings = AppSettings.shared

    /// Called each time the timer fires.  Inject actual sync logic from the call site.
    var triggerSync: (() async -> Void)?

    // MARK: - Private State

    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        observeSettings()

        // Arm immediately if auto-sync was already enabled when the app launched
        if settings.autoSyncEnabled {
            reschedule()
        }
    }

    // MARK: - Settings Observation

    private func observeSettings() {
        // React to the master toggle
        settings.$autoSyncEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.reschedule()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)

        // React to interval changes while auto-sync is on
        settings.$autoSyncInterval
            .dropFirst() // skip initial value (handled by autoSyncEnabled observer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.settings.autoSyncEnabled == true else { return }
                self?.reschedule()
            }
            .store(in: &cancellables)
    }

    // MARK: - Timer Management

    /// (Re)arm the timer using the current interval from settings.
    private func reschedule() {
        stop() // cancel any existing timer first

        let interval = max(60, settings.autoSyncInterval) // floor at 1 minute
        let fireDate = Date().addingTimeInterval(interval)
        appState?.nextScheduledSync = fireDate

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(10)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.triggerSync?()
                // Re-publish next fire date after each execution
                self?.appState?.nextScheduledSync = Date().addingTimeInterval(interval)
            }
        }
        source.resume()
        timer = source
    }

    /// Cancel the active timer and clear the next-sync display.
    private func stop() {
        timer?.cancel()
        timer = nil
        appState?.nextScheduledSync = nil
    }

    deinit {
        timer?.cancel()
    }
}
