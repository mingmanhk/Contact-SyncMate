//
//  AutoSyncConditions.swift
//  Contact SyncMate
//
//  Evaluates the Settings → Auto Sync "Run Conditions" toggles.
//

import Foundation
import IOKit.ps
import Network
import CoreGraphics

/// Decides whether a scheduled sync may run right now.
///
/// The three toggles (AC power / Wi-Fi / idle) existed in Settings but nothing
/// consulted them: the only reader was `SyncEngine.checkAutoSyncConditions()`,
/// reachable solely from `runAutoSync()`, which has no callers. Automatic sync
/// actually runs through `AutoSyncScheduler → SyncCoordinator.runSync()`, which
/// checked nothing at all — so the app synced on battery, on a phone hotspot, and
/// while the user was typing.
///
/// That old check was also wrong on its own terms: it tested
/// `isLowPowerModeEnabled`, which is a user setting, not whether the Mac is
/// plugged in.
///
/// Conditions apply to *scheduled* syncs only. A sync the user asked for happens
/// regardless — they can see their own battery.
@MainActor
enum AutoSyncConditions {

    /// A condition that is not currently met, with text fit for the UI and log.
    struct Blocker {
        let reason: String
    }

    /// How long without user input counts as idle.
    ///
    /// Two minutes: long enough that a pause in typing does not qualify, short
    /// enough that stepping away for coffee does.
    private static let idleThreshold: TimeInterval = 120

    /// The first unmet condition, or nil when the sync may proceed.
    static func blocker() -> Blocker? {
        let settings = AppSettings.shared

        if settings.autoSyncOnlyOnPower, !isOnACPower() {
            return Blocker(reason: String(localized: "waiting for AC power"))
        }

        if settings.autoSyncOnlyOnWiFi, isNetworkExpensive() {
            return Blocker(reason: String(localized: "waiting for an unmetered network"))
        }

        if settings.autoSyncOnlyWhenIdle, !isUserIdle() {
            return Blocker(reason: String(localized: "waiting until the Mac is idle"))
        }

        return nil
    }

    // MARK: - Individual checks

    /// Whether the Mac is running on wall power.
    ///
    /// A desktop with no battery reports no power sources, which counts as AC —
    /// otherwise this condition would permanently block sync on a Mac mini.
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return true
        }

        if sources.isEmpty { return true }   // no battery — desktop Mac

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }

    /// Whether the current network is metered.
    ///
    /// Deliberately "not expensive/constrained" rather than "interface == wifi":
    /// Ethernet is not Wi-Fi but is certainly not metered, and blocking sync on a
    /// wired Mac would be absurd. `isExpensive` covers cellular and personal
    /// hotspots; `isConstrained` covers Low Data Mode.
    static func isNetworkExpensive() -> Bool {
        let path = pathMonitor.currentPath
        return path.isExpensive || path.isConstrained
    }

    /// Whether the user has been away from the keyboard and mouse.
    static func isUserIdle() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: .init(rawValue: ~0)!   // any input event
        )
        return idle >= idleThreshold
    }

    // MARK: - Network monitoring

    /// A single long-lived monitor. `NWPathMonitor` reports the current path only
    /// after it has started, so creating one per check would always read a stale
    /// or empty path.
    ///
    /// `nonisolated`: the monitor updates on its own background queue while
    /// `currentPath` is read from the MainActor — Apple documents that read as
    /// safe, and `NWPathMonitor` is `Sendable`, so no `unsafe` opt-out is
    /// needed; the annotation records the cross-isolation use as intended.
    nonisolated private static let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.victorlam.ContactSyncMate.path"))
        return monitor
    }()
}
