//
//  DeduplicationCoordinator.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import Foundation
import SwiftUI
import Combine

/// Coordinates deduplication workflow with the sync engine
@MainActor
class DeduplicationCoordinator: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    
    
    @Published var isScanning = false
    @Published var scanResult: DeduplicationResult?
    @Published var showingConfirmationSheet = false
    
    private let deduplicator: ContactDeduplicator
    private let decisionStore: DeduplicationDecisionStore
    private let history = SyncHistory.shared
    
    init(deduplicator: ContactDeduplicator = ContactDeduplicator(),
         decisionStore: DeduplicationDecisionStore = .shared) {
        self.deduplicator = deduplicator
        self.decisionStore = decisionStore
    }
    
    // MARK: - Public API
    
    /// Scan for duplicates before sync
    func scanForDuplicates(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        existingMappings: [ContactMapping],
        autoApplyIfSafe: Bool = false
    ) async -> DeduplicationResult {
        
        isScanning = true
        defer { isScanning = false }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "scanForDuplicates.start",
            details: "google=\(googleContacts.count), mac=\(macContacts.count)"
        )
        
        let result = await deduplicator.detectDuplicates(
            googleContacts: googleContacts,
            macContacts: macContacts,
            existingMappings: existingMappings
        )
        
        scanResult = result
        
        // If there are groups needing confirmation, show the sheet
        if result.needsUserConfirmation {
            showingConfirmationSheet = true
        }
        
        // Auto-apply safe merges if enabled
        if autoApplyIfSafe {
            let safeGroups = result.duplicateGroups.filter { group in
                deduplicator.isSafeToAutoMerge(group)
            }
            
            for group in safeGroups {
                await applySafeMerge(group: group)
            }
        }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "scanForDuplicates.end",
            details: result.stats.summary
        )
        
        return result
    }
    
    /// Apply user decisions from the confirmation UI
    func applyUserDecisions(
        _ decisions: [UUID: DuplicateDecision],
        rememberPatterns: Set<UUID> = []
    ) async {
        
        guard let result = scanResult else { return }
        
        history.log(
            source: "DeduplicationCoordinator",
            action: "applyUserDecisions",
            details: "\(decisions.count) decisions"
        )
        
        for (groupID, decision) in decisions {
            guard let group = result.duplicateGroups.first(where: { $0.id == groupID }) else {
                continue
            }
            
            // Record the decision
            let rememberPattern = rememberPatterns.contains(groupID)
            deduplicator.recordUserDecision(decision, for: group, rememberPattern: rememberPattern)
            
            // Execute the decision
            switch decision {
            case .merge:
                await executeMerge(group: group)
                
            case .keepSeparate:
                await markAsKeepSeparate(group: group)
                
            case .skip:
                // Do nothing, just skip this group
                break
            }
        }
    }
    
    /// Present confirmation UI
    func presentConfirmationUI() -> some View {
        DeduplicationConfirmationView(
            duplicateGroups: scanResult?.groupsNeedingConfirmation ?? [],
            onDecisionsMade: { decisions in
                Task {
                    await self.applyUserDecisions(decisions)
                }
            }
        )
    }
    
    // MARK: - Private Helpers
    
    /// Apply a safe auto-merge
    private func applySafeMerge(group: DuplicateGroup) async {
        history.log(
            source: "DeduplicationCoordinator",
            action: "autoMerge",
            details: "group=\(group.id), score=\(group.matchScore)"
        )
        
        // TODO: Implement actual merge logic with ContactMapper and connectors
        // This is where you would:
        // 1. Merge the contacts using UnifiedContact.merging(with:)
        // 2. Update both Google and Mac sides
        // 3. Create a ContactMapping entry
        // 4. Delete the duplicates
    }
    
    /// Execute user-confirmed merge
    private func executeMerge(group: DuplicateGroup) async {
        history.log(
            source: "DeduplicationCoordinator",
            action: "userMerge",
            details: "group=\(group.id), contacts=\(group.contacts.count)"
        )
        
        // TODO: Implement merge execution
        // Same as applySafeMerge but triggered by user
    }
    
    /// Mark contacts as intentionally separate
    private func markAsKeepSeparate(group: DuplicateGroup) async {
        history.log(
            source: "DeduplicationCoordinator",
            action: "keepSeparate",
            details: "group=\(group.id)"
        )
        
        // TODO: Store a record that these contacts should NOT be merged
        // This prevents future scans from flagging them again
    }
    
    // MARK: - Statistics & History
    
    /// Get deduplication statistics
    func getStatistics() -> PatternStatistics {
        return decisionStore.getStatistics()
    }
    
    /// Clear all saved patterns
    func clearSavedPatterns() {
        decisionStore.clearAll()
        history.log(
            source: "DeduplicationCoordinator",
            action: "clearPatterns",
            details: nil
        )
    }
}

// MARK: - Sync Engine Integration

extension DeduplicationCoordinator {
    
    /// Check if sync should proceed or wait for dedup confirmation
    func shouldProceedWithSync(result: DeduplicationResult, mode: SyncMode) -> Bool {
        switch mode {
        case .manual:
            // Manual sync: always wait for user confirmation if duplicates found
            return !result.needsUserConfirmation
            
        case .automatic:
            // Auto sync: skip duplicates and log notification
            if result.needsUserConfirmation {
                sendNotification(duplicateCount: result.groupsNeedingConfirmation.count)
                return false
            }
            return true
        }
    }
    
    /// Send system notification about skipped duplicates in auto mode
    private func sendNotification(duplicateCount: Int) {
        // TODO: Implement macOS notification
        // Use UserNotifications framework to alert user that duplicates were skipped
        history.log(
            source: "DeduplicationCoordinator",
            action: "skippedDuplicatesNotification",
            details: "count=\(duplicateCount)"
        )
    }
}

// MARK: - Supporting Types

enum SyncMode {
    case manual
    case automatic
}

// MARK: - View Extension

extension View {
    /// Present deduplication confirmation sheet
    func deduplicationConfirmation(
        isPresented: Binding<Bool>,
        coordinator: DeduplicationCoordinator
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            coordinator.presentConfirmationUI()
        }
    }
}
