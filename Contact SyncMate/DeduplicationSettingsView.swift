//
//  DeduplicationSettingsView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import SwiftUI

/// Settings panel for deduplication configuration
struct DeduplicationSettingsView: View {
    @AppStorage("dedup.autoMergeEnabled") private var autoMergeEnabled = true
    @AppStorage("dedup.autoMergeThreshold") private var autoMergeThreshold = 80
    @AppStorage("dedup.confirmationThreshold") private var confirmationThreshold = 50
    @AppStorage("dedup.requireFirstSyncConfirmation") private var requireFirstSyncConfirmation = true
    @AppStorage("dedup.enablePatternMemory") private var enablePatternMemory = true
    @AppStorage("dedup.maxAutoMergeGroupSize") private var maxAutoMergeGroupSize = 3
    
    @StateObject private var decisionStore = DeduplicationDecisionStore.shared
    @State private var showingClearConfirmation = false
    @State private var patternStats: PatternStatistics?
    
    var body: some View {
        Form {
            Section("Automatic Merging") {
                Toggle("Enable auto-merge for high-confidence matches", isOn: $autoMergeEnabled)
                    .help("Automatically merge contacts with score ≥ \(autoMergeThreshold)")
                
                if autoMergeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-merge threshold:")
                            Spacer()
                            Text("\(autoMergeThreshold)")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(autoMergeThreshold) },
                            set: { autoMergeThreshold = Int($0) }
                        ), in: 70...95, step: 5)
                        
                        Text("Score must be ≥ \(autoMergeThreshold) for automatic merge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max group size for auto-merge:")
                            Spacer()
                            Text("\(maxAutoMergeGroupSize)")
                                .foregroundColor(.secondary)
                        }
                        
                        Stepper(value: $maxAutoMergeGroupSize, in: 2...5) {
                            EmptyView()
                        }
                        
                        Text("Groups with more than \(maxAutoMergeGroupSize) contacts always need confirmation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Toggle("Require confirmation on first sync", isOn: $requireFirstSyncConfirmation)
                    .help("Even high-confidence matches need manual confirmation on first sync")
            }
            
            Section("User Confirmation") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Confirmation threshold:")
                        Spacer()
                        Text("\(confirmationThreshold)")
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(confirmationThreshold) },
                        set: { confirmationThreshold = Int($0) }
                    ), in: 30...70, step: 5)
                    
                    Text("Contacts with score \(confirmationThreshold)-\(autoMergeThreshold-1) will prompt for confirmation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Toggle("Remember my decisions for similar matches", isOn: $enablePatternMemory)
                    .help("Learn from your choices to auto-apply decisions for similar duplicate patterns")
            }
            
            Section("Pattern Memory") {
                if let stats = patternStats {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Total saved patterns", value: "\(stats.totalPatterns)")
                        LabeledContent("Auto-merge patterns", value: "\(stats.mergePatterns)")
                        LabeledContent("Keep separate patterns", value: "\(stats.keepSeparatePatterns)")
                        LabeledContent("Skip patterns", value: "\(stats.skipPatterns)")
                    }
                } else {
                    Text("Loading statistics...")
                        .foregroundColor(.secondary)
                }
                
                Button("Clear All Saved Patterns") {
                    showingClearConfirmation = true
                }
                .disabled(patternStats?.totalPatterns == 0)
            }
            
            Section("Detection Sensitivity") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Score Ranges")
                        .font(.headline)
                    
                    ScoreRangeIndicator(
                        range: "\(autoMergeThreshold)–100",
                        label: "Auto-merge",
                        color: .green
                    )
                    
                    ScoreRangeIndicator(
                        range: "\(confirmationThreshold)–\(autoMergeThreshold-1)",
                        label: "Ask for confirmation",
                        color: .orange
                    )
                    
                    ScoreRangeIndicator(
                        range: "0–\(confirmationThreshold-1)",
                        label: "Keep separate",
                        color: .gray
                    )
                }
            }
            
            Section("Help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How scoring works")
                        .font(.headline)
                    
                    ScoringRuleRow(icon: "envelope.fill", rule: "Same email address", points: "+60")
                    ScoringRuleRow(icon: "phone.fill", rule: "Same phone number", points: "+60")
                    ScoringRuleRow(icon: "person.fill", rule: "Exact name match", points: "+30")
                    ScoringRuleRow(icon: "person.2.fill", rule: "Similar names", points: "+20")
                    ScoringRuleRow(icon: "building.2.fill", rule: "Same organization", points: "+10")
                    ScoringRuleRow(icon: "location.fill", rule: "Same address", points: "+10")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Deduplication Settings")
        .task {
            loadStatistics()
        }
        .alert("Clear All Saved Patterns?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearPatterns()
            }
        } message: {
            Text("This will remove all saved duplicate resolution patterns. You'll be asked to confirm duplicates again.")
        }
    }
    
    private func loadStatistics() {
        patternStats = decisionStore.getStatistics()
    }
    
    private func clearPatterns() {
        decisionStore.clearAll()
        loadStatistics()
    }
}

// MARK: - Subviews

struct ScoreRangeIndicator: View {
    let range: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            
            Text(range)
                .font(.system(.body, design: .monospaced))
                .frame(width: 70, alignment: .leading)
            
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}

struct ScoringRuleRow: View {
    let icon: String
    let rule: String
    let points: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            Text(rule)
                .font(.caption)
            
            Spacer()
            
            Text(points)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Configuration Extension

extension ContactDeduplicator.Configuration {
    
    /// Create configuration from user defaults
    static func fromUserDefaults() -> ContactDeduplicator.Configuration {
        var config = Configuration()
        
        config.autoMergeThreshold = UserDefaults.standard.integer(forKey: "dedup.autoMergeThreshold")
        if config.autoMergeThreshold == 0 {
            config.autoMergeThreshold = 80  // Default
        }
        
        config.confirmationThreshold = UserDefaults.standard.integer(forKey: "dedup.confirmationThreshold")
        if config.confirmationThreshold == 0 {
            config.confirmationThreshold = 50  // Default
        }
        
        config.maxAutoMergeGroupSize = UserDefaults.standard.integer(forKey: "dedup.maxAutoMergeGroupSize")
        if config.maxAutoMergeGroupSize == 0 {
            config.maxAutoMergeGroupSize = 3  // Default
        }
        
        config.requireConfirmationOnFirstSync = UserDefaults.standard.bool(forKey: "dedup.requireFirstSyncConfirmation")
        config.enablePatternMemory = UserDefaults.standard.bool(forKey: "dedup.enablePatternMemory")
        
        return config
    }
    
    /// Save configuration to user defaults
    func saveToUserDefaults() {
        UserDefaults.standard.set(autoMergeThreshold, forKey: "dedup.autoMergeThreshold")
        UserDefaults.standard.set(confirmationThreshold, forKey: "dedup.confirmationThreshold")
        UserDefaults.standard.set(maxAutoMergeGroupSize, forKey: "dedup.maxAutoMergeGroupSize")
        UserDefaults.standard.set(requireConfirmationOnFirstSync, forKey: "dedup.requireFirstSyncConfirmation")
        UserDefaults.standard.set(enablePatternMemory, forKey: "dedup.enablePatternMemory")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DeduplicationSettingsView()
    }
    .frame(width: 600, height: 800)
}
