//
//  SyncNotifier.swift
//  Contact SyncMate
//
//  Posts macOS user notifications when a sync completes or fails, honouring
//  the user's notification preferences (Settings → General → Notifications).
//
//  This is what tells the user "the sync you didn't watch has finished" —
//  previously the notification toggles existed but nothing fired them.
//

import Foundation
import UserNotifications

@MainActor
enum SyncNotifier {

    private static var authorizationRequested = false

    /// Ask for notification permission once per launch (no-op if already
    /// granted or denied — macOS handles repeat calls gracefully).
    static func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Notify that a sync finished. Chooses success or error styling based
    /// on the result and the user's per-event preferences.
    static func notifySyncCompleted(added: Int, updated: Int, deleted: Int, errorCount: Int) {
        let settings = AppSettings.shared

        if errorCount > 0 {
            guard settings.notifyOnErrors else { return }
            post(
                title: "Sync completed with errors",
                body: "Added \(added), updated \(updated), deleted \(deleted) — \(errorCount) error\(errorCount == 1 ? "" : "s"). Open Sync History for details."
            )
        } else {
            guard settings.notifyOnSyncComplete else { return }
            let changes = added + updated + deleted
            post(
                title: "Contacts synced",
                body: changes == 0
                    ? "Everything already in sync."
                    : "Added \(added), updated \(updated), deleted \(deleted)."
            )
        }
    }

    /// Notify that a sync failed outright.
    static func notifySyncFailed(message: String) {
        guard AppSettings.shared.notifyOnErrors else { return }
        post(title: "Sync failed", body: message)
    }

    /// Notify that duplicate conflicts are waiting for review.
    static func notifyConflictsNeedReview(count: Int) {
        guard AppSettings.shared.notifyOnConflicts, count > 0 else { return }
        post(
            title: "Duplicates need review",
            body: "\(count) potential duplicate group\(count == 1 ? "" : "s") await your decision."
        )
    }

    // MARK: - Internals

    private static func post(title: String, body: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
