//
//  SyncFailureStore.swift
//  Contact SyncMate
//
//  Remembers which contacts keep failing, so the sync stops retrying them.
//

import Foundation
import os

/// A contact that has failed to write repeatedly.
///
/// `nonisolated` because it crosses actors: written by the sync engine off the
/// main actor, read by SwiftUI on it. The project builds with default MainActor
/// isolation, so an unannotated struct would be main-actor isolated and this
/// would not compile at the write site.
nonisolated struct SyncFailure: Identifiable, Codable, Equatable, Sendable {
    /// Stable key: the Mac identifier when there is one, otherwise the Google
    /// resource name. Contacts that have neither cannot be tracked or retried.
    let id: String
    var contactName: String
    var reason: String
    var failureCount: Int
    var lastFailedAt: Date
    /// Set when the user chooses to stop being told about this one.
    var ignored: Bool = false
}

/// Persistent record of contacts the sync could not write.
///
/// Without this, a contact that cannot be written is retried on every sync
/// forever: the same failures scroll past each run, the log fills with them,
/// and nothing accumulates into a list anyone can act on. Three strikes and the
/// contact is set aside — the sync stops attempting it and it appears in
/// Settings → Sync Failures, where it can be retried, ignored, or unlinked.
///
/// Deliberately not automatic repair. These failures are Cocoa 134092 and
/// friends, which can mean a read-only account, a linked record, or a
/// permissions problem — retrying harder is what produced the loop. Setting the
/// contact aside and naming it is the honest response to an error we cannot
/// interpret.
///
/// `nonisolated` on the type: the sync engine records failures from a
/// background context and Settings reads them on the main actor. Under this
/// project's default MainActor isolation an unannotated class is main-actor
/// isolated, which would make every call site from the engine a compile error.
/// The dictionary is guarded by its own queue, which is what `@unchecked
/// Sendable` is asserting.
nonisolated final class SyncFailureStore: @unchecked Sendable {
    static let shared = SyncFailureStore()

    /// Attempts before a contact is set aside.
    ///
    /// Three, not one: a single failure is often transient — a rate limit, a
    /// token refresh landing mid-write, contactsd busy. Three consecutive
    /// failures across separate syncs is a pattern.
    static let attemptsBeforeSkipping = 3

    private let queue = DispatchQueue(label: "com.victorlam.ContactSyncMate.failures",
                                      attributes: .concurrent)
    private var failures: [String: SyncFailure] = [:]

    /// Unified-log channel for persistence faults. The failure ledger failing
    /// to persist is itself a failure worth recording somewhere durable —
    /// without it, forgotten entries mean the sync silently retries contacts
    /// it had already set aside.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ContactSyncMate",
        category: "persistence")

    /// One fault per launch about the temp-directory fallback, not one per save.
    private var warnedTemporaryFallback = false

    private init() { load() }

    // MARK: - Recording

    /// Note that a write failed. Returns the running count for this contact.
    @discardableResult
    func recordFailure(key: String, name: String, reason: String) -> Int {
        // Return types spelled out on every multi-statement barrier closure.
        // `DispatchQueue.sync` is generic over its result and Swift does not
        // infer that through a closure with control flow in it.
        queue.sync(flags: .barrier) { () -> Int in
            var entry = failures[key] ?? SyncFailure(
                id: key, contactName: name, reason: reason,
                failureCount: 0, lastFailedAt: Date())
            entry.contactName = name
            entry.reason = reason
            entry.failureCount += 1
            entry.lastFailedAt = Date()
            failures[key] = entry
            save()
            return entry.failureCount
        }
    }

    /// A write succeeded — forget the history, so a contact that recovers is not
    /// held against its past.
    func clearFailure(key: String) {
        queue.sync(flags: .barrier) { () -> Void in
            guard failures[key] != nil else { return }
            failures.removeValue(forKey: key)
            save()
        }
    }

    /// Whether the sync should stop attempting this contact.
    func shouldSkip(key: String) -> Bool {
        queue.sync { () -> Bool in
            guard let entry = failures[key] else { return false }
            return entry.ignored || entry.failureCount >= Self.attemptsBeforeSkipping
        }
    }

    // MARK: - User actions

    func allFailures() -> [SyncFailure] {
        queue.sync { () -> [SyncFailure] in
            failures.values.sorted { $0.lastFailedAt > $1.lastFailedAt }
        }
    }

    /// Try this contact again on the next sync.
    func retry(key: String) { clearFailure(key: key) }

    /// Stop attempting and stop reporting it.
    func ignore(key: String) {
        queue.sync(flags: .barrier) { () -> Void in
            failures[key]?.ignored = true
            save()
        }
    }

    func clearAll() {
        queue.sync(flags: .barrier) { () -> Void in
            failures.removeAll()
            save()
        }
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true) {
            base = appSupport
        } else {
            // temporaryDirectory is purged by the OS, so a ledger that lands
            // there is quietly ephemeral — say so instead of hiding it.
            if !warnedTemporaryFallback {
                warnedTemporaryFallback = true
                Self.logger.fault("Application Support is unreachable; sync failures are falling back to the temporary directory")
            }
            base = fm.temporaryDirectory
        }
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "ContactSync", isDirectory: true)
        if (try? dir.checkResourceIsReachable()) != true {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("sync_failures.json")
    }

    /// Callers already hold the barrier.
    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(failures.values))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // In-memory state still works for this launch; the fault line is
            // what stops the loss from being invisible.
            Self.logger.fault("Could not persist sync failures: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run — nothing recorded yet.
            return
        } catch {
            Self.logger.fault("Could not read sync failures: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            let list = try JSONDecoder().decode([SyncFailure].self, from: data)
            failures = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        } catch {
            Self.logger.fault("Sync failures file is unreadable — starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }
}
