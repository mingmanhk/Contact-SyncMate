//
//  AppIntents.swift
//  Contact SyncMate
//
//  Shortcuts / Automation integration (macOS 13+).
//
//  Exposes app actions to the Shortcuts app, Spotlight, and Siri:
//    • "Sync Contacts Now"  — runs a sync through the shared SyncCoordinator
//    • "Get Last Sync Status" — returns a text summary for use in workflows
//
//  Users can chain these into automations, e.g. "every morning at 9, sync
//  contacts and notify me with the result".
//

import AppIntents
import Foundation

// MARK: - Sync Now

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Contacts Now"
    static let description = IntentDescription(
        "Runs a contact sync between Google Contacts and Mac Contacts using your configured direction and settings.",
        categoryName: "Sync"
    )

    // Show the app's UI is not required — the sync runs in the background.
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinator = SyncCoordinator.shared

        guard !coordinator.isRunning else {
            return .result(dialog: "A sync is already in progress.")
        }
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return .result(dialog: "Google account is not connected. Open Contact SyncMate → Settings → Accounts to sign in.")
        }

        await coordinator.runSync()

        // Report the outcome from the coordinator's phase
        switch coordinator.phase {
        case .completed(let r):
            return .result(dialog: r.successful
                ? IntentDialog(stringLiteral: "Sync complete — \(r.summary).")
                : IntentDialog(stringLiteral: "Sync finished with \(r.errorCount) error(s)."))
        case .failed(let message):
            return .result(dialog: IntentDialog(stringLiteral: "Sync failed: \(message)"))
        default:
            return .result(dialog: "Sync finished.")
        }
    }
}

// MARK: - Last Sync Status

struct LastSyncStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Sync Status"
    static let description = IntentDescription(
        "Returns a summary of the most recent contact sync.",
        categoryName: "Sync"
    )

    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Read the most recent sync.complete / sync.failed history event —
        // survives app relaunches, unlike in-memory AppState.
        let events = SyncHistory.shared.events()
        let last = events.last {
            $0.action == "sync.complete" || $0.action == "sync.failed"
        }

        let summary: String
        if let last {
            let when = last.timestamp.formatted(date: .abbreviated, time: .shortened)
            let outcome = last.action == "sync.complete" ? "succeeded" : "failed"
            summary = "Last sync \(outcome) at \(when). \(last.details ?? "")"
        } else {
            summary = "No sync has run yet."
        }

        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - App Shortcuts (zero-setup phrases)

struct ContactSyncMateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync contacts with \(.applicationName)",
                "Run a sync in \(.applicationName)"
            ],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: LastSyncStatusIntent(),
            phrases: [
                "Get sync status from \(.applicationName)"
            ],
            shortTitle: "Sync Status",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
