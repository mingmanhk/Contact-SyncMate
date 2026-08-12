//
//  DeduplicationDecisionStore.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation
import Combine
import os

/// Persistent storage for user's duplicate resolution decisions
class DeduplicationDecisionStore: ObservableObject {

    static let shared = DeduplicationDecisionStore()

    /// Unified-log channel for persistence faults, following the
    /// SyncFailureStore pattern: a decision file that cannot be written means
    /// the user will be asked the same duplicate questions again, and a
    /// `print` buried that on a discarded stdout.
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ContactSyncMate",
        category: "persistence")
    
    private let fileURL: URL
    /// Where pattern-memory events are logged. `.shared` in production; tests
    /// point it at a temp-file history so dedup runs never write the user's
    /// real ledger (issue #106).
    private let history: SyncHistory
@Published private(set) var lastUpdated: Date = Date()
    private var patterns: [String: DuplicatePattern] = [:]
    private let queue = DispatchQueue(label: "DeduplicationDecisionStore.queue", attributes: .concurrent)

    private init() {
        // Set up storage location
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let bundleID = Bundle.main.bundleIdentifier ?? "ContactSync"
        let directory = (appSupport ?? fm.temporaryDirectory)
            .appendingPathComponent(bundleID, isDirectory: true)

        if (try? directory.checkResourceIsReachable()) != true {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        self.fileURL = directory.appendingPathComponent("dedup_decisions.json")
        self.history = SyncHistory.shared

        loadFromDisk()
    }

    /// Testability seam (issue #106): a store over a private directory, so
    /// tests never load or rewrite the user's real `dedup_decisions.json`, and
    /// pattern-memory logging lands in the injected (temp-file) history rather
    /// than the real one. Production always uses `shared`.
    init(directoryURL: URL, history: SyncHistory = .shared) {
        let fm = FileManager.default
        if (try? directoryURL.checkResourceIsReachable()) != true {
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        self.fileURL = directoryURL.appendingPathComponent("dedup_decisions.json")
        self.history = history
        loadFromDisk()
    }
    
    // MARK: - Public API
    
    /// Save a user's decision for a duplicate pattern
    func savePattern(pattern: String, decision: DuplicateDecision) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let patternRecord = DuplicatePattern(
                pattern: pattern,
                decision: decision
            )
            
            self.patterns[pattern] = patternRecord
            self.saveToDisk()
            
            self.history.log(
                source: "DeduplicationStore",
                action: "savePattern",
                details: "pattern=\(pattern), decision=\(decision.rawValue)"
            )
        }
    }
    
    /// Get saved decision for a pattern
    func getDecision(for pattern: String) -> DuplicateDecision? {
        var decision: DuplicateDecision?
        queue.sync {
            decision = patterns[pattern]?.decision
        }
        return decision
    }
    
    /// Get all saved patterns
    func getAllPatterns() -> [DuplicatePattern] {
        var allPatterns: [DuplicatePattern] = []
        queue.sync {
            allPatterns = Array(patterns.values)
        }
        return allPatterns.sorted { $0.createdAt > $1.createdAt }
    }
    
    /// Delete a saved pattern
    func deletePattern(_ pattern: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.patterns.removeValue(forKey: pattern)
            self.saveToDisk()
            
            self.history.log(
                source: "DeduplicationStore",
                action: "deletePattern",
                details: "pattern=\(pattern)"
            )
        }
    }
    
    /// Clear all saved patterns
    func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.patterns.removeAll()
            self.saveToDisk()
            
            self.history.log(
                source: "DeduplicationStore",
                action: "clearAll",
                details: nil
            )
        }
    }
    
    /// Get statistics about saved patterns
    func getStatistics() -> PatternStatistics {
        var stats = PatternStatistics()
        queue.sync {
            stats.totalPatterns = patterns.count
            stats.mergePatterns = patterns.values.filter { $0.decision == .merge }.count
            stats.keepSeparatePatterns = patterns.values.filter { $0.decision == .keepSeparate }.count
            stats.skipPatterns = patterns.values.filter { $0.decision == .skip }.count
        }
        return stats
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(Array(patterns.values))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // In-memory decisions still work for this launch; the fault line
            // and the history event are what stop the loss from being
            // invisible.
            Self.logger.fault("Could not persist deduplication decisions: \(error.localizedDescription, privacy: .public)")
            self.history.log(
                source: "DeduplicationStore",
                action: "persistence.failed",
                details: "Duplicate decisions could not be saved and will not survive a relaunch: \(error.localizedDescription)")
        }
    }
    
    private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            let data = try Data(contentsOf: fileURL)
            let loadedPatterns = try decoder.decode([DuplicatePattern].self, from: data)
            
            patterns = Dictionary(uniqueKeysWithValues: loadedPatterns.map { ($0.pattern, $0) })
            
            self.history.log(
                source: "DeduplicationStore",
                action: "loadFromDisk",
                details: "loaded \(patterns.count) patterns"
            )
        } catch {
            // File doesn't exist or is corrupted, start fresh
            patterns = [:]
        }
    }
}

// MARK: - Statistics

struct PatternStatistics {
    var totalPatterns: Int = 0
    var mergePatterns: Int = 0
    var keepSeparatePatterns: Int = 0
    var skipPatterns: Int = 0
    
    var summary: String {
        """
        Total saved patterns: \(totalPatterns)
        - Merge: \(mergePatterns)
        - Keep Separate: \(keepSeparatePatterns)
        - Skip: \(skipPatterns)
        """
    }
}
