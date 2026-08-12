import Foundation
import Combine
import os

/// `Sendable` because it is immutable value data — and it has to cross threads:
/// events are now logged from the Contacts write queue, not just the main actor.
public struct SyncEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let action: String
    public let details: String?

    public nonisolated init(id: UUID = UUID(), timestamp: Date = Date(), source: String, action: String, details: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.action = action
        self.details = details
    }
}

/// `@unchecked Sendable` because the invariant is enforced by `queue`, not by the
/// type system: every read goes through `queue.sync` and every mutation through a
/// barrier. The compiler cannot verify that discipline, but it is the reason this
/// type is safe to log to from any thread — which matters now that Contacts work
/// runs off the main actor and still needs to record what it did.
public final class SyncHistory: @unchecked Sendable {
    public nonisolated static let shared = SyncHistory()

    /// Posted after every mutation (log or clear), from the history queue.
    /// The History window refreshes on this instead of polling a timer —
    /// see `SyncHistoryViewModel`.
    public nonisolated static let didChangeNotification =
        Notification.Name("SyncHistory.didChange")

    private let queue = DispatchQueue(label: "SyncHistory.queue", attributes: .concurrent)
    // Guarded by `queue` (barrier writes, sync reads) — annotated so the
    // queue closures, which are nonisolated, may touch it.
    nonisolated(unsafe) private var _events: [SyncEvent] = []
    private let maxEvents = 1000

    /// Unified-log channel for persistence faults. `.fault`, not `.error`:
    /// a history that cannot be written is the diagnostic ledger failing at
    /// its one job, and it must be visible in Console when nothing else is.
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ContactSyncMate",
        category: "persistence")

    /// Set once a disk write fails or Application Support is unreachable.
    /// Logging keeps working — in memory — but it will not survive a
    /// relaunch, and callers can surface that instead of pretending otherwise.
    nonisolated(unsafe) private var _persistenceDegraded = false

    public nonisolated var persistenceDegraded: Bool {
        queue.sync { _persistenceDegraded }
    }

    /// `persistenceURL` exists for tests (issue #92): the shared instance
    /// persists into the app container, and hosted tests share that container —
    /// so tests running against `shared` write through to the user's real
    /// history file. Mirrors `ContactMappingStore.init(persistenceURL:)`.
    /// Production always uses `shared` with the default path.
    init(persistenceURL: URL? = nil) {
        self.customFileURL = persistenceURL
        loadFromDisk()
        // Apply the retention window on startup so stale events from a
        // previous run are pruned even if the user never logs a new event.
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let pruned = Self.prune(self._events,
                                    retentionDays: Self.retentionDays(),
                                    maxCount: self.maxEvents)
            // Rewrite the file only when pruning actually removed something —
            // an unconditional save here rewrote the full log on every launch.
            if pruned.count != self._events.count {
                self._events = pruned
                self.scheduleSave()
            }
        }
    }

    // MARK: - Retention

    /// Reads Settings → General → "Keep history for". `0` means forever.
    static func retentionDays() -> Int {
        UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30
    }

    /// Pure pruning function — trims by age first (retentionDays; 0 = keep
    /// all ages), then by count (keep the most recent `maxCount`).
    /// Static and side-effect-free so it is directly unit-testable.
    static func prune(_ events: [SyncEvent], retentionDays: Int, maxCount: Int) -> [SyncEvent] {
        var result = events
        if retentionDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day,
                                               value: -retentionDays,
                                               to: Date()) ?? .distantPast
            result = result.filter { $0.timestamp >= cutoff }
        }
        if result.count > maxCount {
            result.removeFirst(result.count - maxCount)
        }
        return result
    }

    // MARK: - Public API

    @discardableResult
    public nonisolated func log(source: String, action: String, details: String? = nil) -> SyncEvent {
        let event = SyncEvent(source: source, action: action, details: details)
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self._events.append(event)
            self._events = Self.prune(self._events,
                                      retentionDays: Self.retentionDays(),
                                      maxCount: self.maxEvents)
            self.scheduleSave()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return event
    }

    public nonisolated func events() -> [SyncEvent] {
        var snapshot: [SyncEvent] = []
        queue.sync {
            snapshot = self._events
        }
        return snapshot.sorted { $0.timestamp < $1.timestamp }
    }

    /// Discard every recorded event.
    ///
    /// Barriered on the same queue as `log`, so a clear cannot interleave with a
    /// concurrent append. Writes through to disk immediately — otherwise a crash
    /// before the next log call would resurrect what the user just cleared.
    public nonisolated func clear() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self._events.removeAll()
            // Write-through, not debounced: a crash before the next log call
            // must not resurrect what the user just cleared.
            self.pendingSave?.cancel()
            self.pendingSave = nil
            self.saveToDisk()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Write any coalesced events out now.
    ///
    /// Termination handling calls this so the last second of a run is not lost
    /// to the debounce. Wiring it into `applicationWillTerminate` is tracked
    /// separately; this is the hook it needs.
    public nonisolated func flush() {
        queue.sync(flags: .barrier) {
            guard pendingSave != nil else { return }
            pendingSave?.cancel()
            pendingSave = nil
            saveToDisk()
        }
    }

    // MARK: - Disk Persistence

    /// Coalescing window for disk writes. A 1000-change sync logs thousands of
    /// events, and rewriting the full ≤1000-event file per line was hundreds
    /// of megabytes of write amplification. One write a second is
    /// indistinguishable in durability — `clear()` and `flush()` still write
    /// through immediately.
    nonisolated private static let saveDebounce: TimeInterval = 1.0
    nonisolated(unsafe) private var pendingSave: DispatchWorkItem?

    /// Callers already hold the barrier.
    nonisolated private func scheduleSave() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.saveToDisk()
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Note that persistence is degraded: shout to the unified log every time,
    /// and record one — exactly one — history event about it. The guard is the
    /// recursion break: the event itself schedules a save, that save fails,
    /// and without the flag each failure would mint another event forever.
    ///
    /// Callers hold the barrier (or run before any concurrency, in `init`).
    nonisolated private func noteDegraded(_ reason: String) {
        Self.logger.fault("Sync history persistence degraded: \(reason, privacy: .public)")
        guard !_persistenceDegraded else { return }
        _persistenceDegraded = true
        _events.append(SyncEvent(source: "SyncHistory",
                                 action: "persistence.degraded",
                                 details: reason))
    }

    nonisolated private func appSupportURL() -> URL {
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let bundleID = Bundle.main.bundleIdentifier ?? "ContactSync"
            let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            if (try? dir.checkResourceIsReachable()) != true {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        // temporaryDirectory is purged by the OS — falling back silently made
        // the ledger quietly ephemeral. Fall back, but on the record.
        noteDegraded("Application Support is unreachable; history is falling back "
                   + "to the temporary directory and will not survive cleanup")
        return fm.temporaryDirectory
    }

    /// True when running inside XCTest.
    ///
    /// The test bundle is injected into the app process, so tests share this
    /// singleton, its container, and its history file. A test run was therefore
    /// overwriting the user's real sync history — which destroyed the diagnostic
    /// log at exactly the moment it was needed to explain a failed sync.
    nonisolated private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Set only by the test seam; `nil` means the default container path.
    nonisolated private let customFileURL: URL?

    nonisolated private var historyFileURL: URL {
        if let customFileURL { return customFileURL }
        let name = Self.isRunningTests ? "sync_history.tests.json" : "sync_history.json"
        return appSupportURL().appendingPathComponent(name)
    }

    nonisolated private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(_events)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            // The audit trail failing is exactly what must not fail silently.
            // In-memory logging keeps working; the flag and the fault line say
            // the record is no longer durable.
            noteDegraded("could not write \(historyFileURL.lastPathComponent): "
                       + error.localizedDescription)
        }
    }

    nonisolated private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: historyFileURL)
            let loaded = try decoder.decode([SyncEvent].self, from: data)
            _events = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run — nothing recorded yet.
            _events = []
        } catch {
            _events = []
            Self.logger.fault("Sync history could not be read — starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }
}

public enum SyncHistoryFormatters {
    public static func contactSummary(id: String?, name: String?) -> String {
        switch (id, name) {
        case let (id?, name?):
            return "Contact(id:\(id), name:\(name))"
        case let (id?, nil):
            return "Contact(id:\(id))"
        case let (nil, name?):
            return "Contact(name:\(name))"
        default:
            return "Contact(unknown)"
        }
    }
}
