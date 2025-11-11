import Foundation

public struct SyncEvent: Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let action: String
    public let details: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), source: String, action: String, details: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.action = action
        self.details = details
    }
}

public final class SyncHistory {
    public static let shared = SyncHistory()

    private let queue = DispatchQueue(label: "SyncHistory.queue", attributes: .concurrent)
    private var _events: [SyncEvent] = []
    private let maxEvents = 1000

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    @discardableResult
    public func log(source: String, action: String, details: String? = nil) -> SyncEvent {
        let event = SyncEvent(source: source, action: action, details: details)
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self._events.append(event)
            if self._events.count > self.maxEvents {
                self._events.removeFirst(self._events.count - self.maxEvents)
            }
            self.saveToDisk()
        }
        return event
    }

    public func events() -> [SyncEvent] {
        var snapshot: [SyncEvent] = []
        queue.sync {
            snapshot = self._events
        }
        return snapshot.sorted { $0.timestamp < $1.timestamp }
    }

    public func clear() {
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
            if ((try? dir.checkResourceIsReachable()) == nil) ?? true {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return fm.temporaryDirectory
    }

    private var historyFileURL: URL {
        appSupportURL().appendingPathComponent("sync_history.json")
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
