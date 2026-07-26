import Foundation
import Combine

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

    private let queue = DispatchQueue(label: "SyncHistory.queue", attributes: .concurrent)
    private var _events: [SyncEvent] = []
    private let maxEvents = 1000

    private init() {
        loadFromDisk()
        // Apply the retention window on startup so stale events from a
        // previous run are pruned even if the user never logs a new event.
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self._events = Self.prune(self._events,
                                      retentionDays: Self.retentionDays(),
                                      maxCount: self.maxEvents)
            self.saveToDisk()
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
            self.saveToDisk()
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
            self.saveToDisk()
        }
    }

    // MARK: - Disk Persistence

    private func appSupportURL() -> URL {
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let bundleID = Bundle.main.bundleIdentifier ?? "ContactSync"
            let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            if (try? dir.checkResourceIsReachable()) != true {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return fm.temporaryDirectory
    }

    /// True when running inside XCTest.
    ///
    /// The test bundle is injected into the app process, so tests share this
    /// singleton, its container, and its history file. A test run was therefore
    /// overwriting the user's real sync history — which destroyed the diagnostic
    /// log at exactly the moment it was needed to explain a failed sync.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private var historyFileURL: URL {
        let name = Self.isRunningTests ? "sync_history.tests.json" : "sync_history.json"
        return appSupportURL().appendingPathComponent(name)
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(_events)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            // Ignore disk errors to not disrupt app flow.
        }
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: historyFileURL)
            let loaded = try decoder.decode([SyncEvent].self, from: data)
            _events = loaded
        } catch {
            _events = []
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
