//
//  SecurityScopedBookmark.swift
//  Contact SyncMate
//
//  App Sandbox support for user-selected folders.
//
//  Under the App Sandbox a plain file path granted through NSOpenPanel is only
//  valid for the lifetime of the process. To keep access across launches the
//  app must store a *security-scoped bookmark* and call
//  `startAccessingSecurityScopedResource()` before touching the folder.
//
//  Usage:
//      // once, when the user picks a folder:
//      SecurityScopedBookmark.save(url, forKey: .backupFolder)
//
//      // every time you need it:
//      guard let url = SecurityScopedBookmark.resolve(.backupFolder) else { … }
//      SecurityScopedBookmark.withAccess(to: .backupFolder) { folder in
//          // read / write inside `folder`
//      }
//

import Foundation
import os.log

public enum SecurityScopedBookmark {

    // MARK: - Keys

    public enum Key: String {
        /// Folder the user chose for backup snapshots.
        case backupFolder = "bookmark.backupFolder"
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ContactSyncMate",
                                    category: "Sandbox")

    // MARK: - Save

    /// Persist a security-scoped bookmark for a user-selected URL.
    /// Call this immediately after `NSOpenPanel` returns, while the URL is
    /// still "hot" from the user's grant.
    @discardableResult
    public static func save(_ url: URL, forKey key: Key) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key.rawValue)
            log.info("Saved security-scoped bookmark for \(key.rawValue, privacy: .public)")
            return true
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
            SyncHistory.shared.log(source: "Sandbox", action: "bookmark.saveFailed",
                                   details: error.localizedDescription)
            return false
        }
    }

    /// Forget a stored bookmark (e.g. user reset the backup location).
    public static func clear(_ key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }

    public static func exists(_ key: Key) -> Bool {
        UserDefaults.standard.data(forKey: key.rawValue) != nil
    }

    // MARK: - Resolve

    /// Resolve a stored bookmark back into a URL. Returns `nil` if no bookmark
    /// is stored or the folder can no longer be reached (moved / deleted).
    ///
    /// Note: the caller is responsible for balancing
    /// `startAccessingSecurityScopedResource()` / `stopAccessing…`. Prefer
    /// `withAccess(to:)` which does that automatically.
    public static func resolve(_ key: Key) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Folder moved — refresh the bookmark so the next launch works.
                log.notice("Bookmark for \(key.rawValue, privacy: .public) was stale; refreshing")
                _ = url.startAccessingSecurityScopedResource()
                save(url, forKey: key)
                url.stopAccessingSecurityScopedResource()
            }
            return url
        } catch {
            log.error("Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
            SyncHistory.shared.log(source: "Sandbox", action: "bookmark.resolveFailed",
                                   details: error.localizedDescription)
            return nil
        }
    }

    // MARK: - Scoped access

    /// Run `body` with sandbox access to the bookmarked folder held open,
    /// releasing it afterwards even if `body` throws.
    ///
    /// Returns `nil` when no valid bookmark exists, so callers can fall back
    /// to the app's own container.
    @discardableResult
    public static func withAccess<T>(to key: Key, _ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolve(key) else { return nil }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard didStart else {
            log.error("startAccessingSecurityScopedResource failed for \(key.rawValue, privacy: .public)")
            return nil
        }
        return try body(url)
    }
}
