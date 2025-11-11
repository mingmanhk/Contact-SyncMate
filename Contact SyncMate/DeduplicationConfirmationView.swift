//
//  DeduplicationConfirmationView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import SwiftUI

/// View for confirming duplicate contact merges
struct DeduplicationConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    
    let duplicateGroups: [DuplicateGroup]
    let onDecisionsMade: ([UUID: DuplicateDecision]) -> Void
    
    @State private var decisions: [UUID: DuplicateDecision] = [:]
    @State private var rememberPatterns: Set<UUID> = []
    @State private var selectedGroupID: UUID?
    @State private var showingMergePreview: UUID?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                headerView
                
                Divider()
                
                // Groups list
                if duplicateGroups.isEmpty {
                    emptyStateView
                } else {
                    groupsList
                }
                
                Divider()
                
                // Action buttons
                actionButtons
            }
            .navigationTitle("Possible Duplicates")
            .sheet(item: $showingMergePreview) { groupID in
                if let group = duplicateGroups.first(where: { $0.id == groupID }) {
                    MergePreviewSheet(group: group)
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Possible Duplicates")
                        .font(.headline)
                    Text("\(duplicateGroups.count) group\(duplicateGroups.count == 1 ? "" : "s") found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            Text("These contacts appear to be the same person. Please confirm how to handle them.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("No Duplicates Found")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("All contacts appear to be unique.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var groupsList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(duplicateGroups) { group in
                    DuplicateGroupCard(
                        group: group,
                        decision: decisions[group.id],
                        rememberPattern: rememberPatterns.contains(group.id),
                        isSelected: selectedGroupID == group.id,
                        onDecisionChanged: { decision in
                            decisions[group.id] = decision
                        },
                        onRememberPatternToggled: {
                            if rememberPatterns.contains(group.id) {
                                rememberPatterns.remove(group.id)
                            } else {
                                rememberPatterns.insert(group.id)
                            }
                        },
                        onPreviewMerge: {
                            showingMergePreview = group.id
                        },
                        onSelect: {
                            selectedGroupID = group.id
                        }
                    )
                }
            }
            .padding()
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Text("\(decisionsMadeCount) of \(duplicateGroups.count) decided")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button("Apply Decisions") {
                onDecisionsMade(decisions)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(decisionsMadeCount == 0)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var decisionsMadeCount: Int {
        decisions.values.filter { $0 != .skip }.count
    }
}

// MARK: - Duplicate Group Card

struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let decision: DuplicateDecision?
    let rememberPattern: Bool
    let isSelected: Bool
    let onDecisionChanged: (DuplicateDecision) -> Void
    let onRememberPatternToggled: () -> Void
    let onPreviewMerge: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with score and type
            HStack {
                scoreIndicator
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.groupType.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(group.matchReason)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                Spacer()
                
                if group.shouldAutoMerge {
                    Label("Auto-merge", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Divider()
            
            // Contacts in group
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.contacts) { candidate in
                    ContactCandidateRow(candidate: candidate)
                }
            }
            
            Divider()
            
            // Decision buttons
            VStack(alignment: .leading, spacing: 8) {
                Text("Your decision:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    ForEach([DuplicateDecision.merge, .keepSeparate, .skip], id: \.self) { dec in
                        DecisionButton(
                            decision: dec,
                            isSelected: decision == dec,
                            action: { onDecisionChanged(dec) }
                        )
                    }
                }
                
                HStack {
                    Toggle("Remember this choice for similar matches", isOn: .init(
                        get: { rememberPattern },
                        set: { _ in onRememberPatternToggled() }
                    ))
                    .font(.caption)
                    .disabled(decision == nil)
                    
                    Spacer()
                    
                    if decision == .merge {
                        Button(action: onPreviewMerge) {
                            Label("Preview Merged Result", systemImage: "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onSelect()
        }
    }
    
    private var scoreIndicator: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 3)
                    .frame(width: 50, height: 50)
                
                Circle()
                    .trim(from: 0, to: CGFloat(group.matchScore) / 100.0)
                    .stroke(scoreColor, lineWidth: 3)
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                
                Text("\(group.matchScore)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(scoreColor)
            }
            
            Text("Match")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var scoreColor: Color {
        if group.matchScore >= 80 {
            return .green
        } else if group.matchScore >= 50 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Contact Candidate Row

struct ContactCandidateRow: View {
    let candidate: DuplicateCandidate
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.source == .google ? "g.circle.fill" : "desktopcomputer")
                .foregroundColor(candidate.source == .google ? .blue : .gray)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                
                if let email = candidate.primaryEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let phone = candidate.primaryPhone {
                    Text(phone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(candidate.source.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.2)))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.textBackgroundColor))
        )
    }
}

// MARK: - Decision Button

struct DecisionButton: View {
    let decision: DuplicateDecision
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(decision.displayName)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? buttonColor : Color.gray.opacity(0.1))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
    
    private var buttonColor: Color {
        switch decision {
        case .merge: return .green
        case .keepSeparate: return .orange
        case .skip: return .gray
        }
    }
}

// MARK: - Merge Preview Sheet

struct MergePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: DuplicateGroup
    
    @State private var mergePreview: MergePreview?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if let preview = mergePreview {
                    VStack(alignment: .leading, spacing: 20) {
                        // Original contacts
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Original Contacts (\(preview.originalContacts.count))")
                                .font(.headline)
                            
                            ForEach(preview.originalContacts) { contact in
                                ContactDetailCard(contact: contact)
                            }
                        }
                        
                        Divider()
                        
                        // Merged result
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Merged Result")
                                    .font(.headline)
                                
                                if preview.hasConflicts {
                                    Label("\(preview.conflictCount) conflict\(preview.conflictCount == 1 ? "" : "s")",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            ContactDetailCard(contact: preview.mergedContact)
                        }
                        
                        if !preview.changes.isEmpty {
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Changes & Conflicts")
                                    .font(.headline)
                                
                                ForEach(preview.changes) { change in
                                    MergeChangeRow(change: change)
                                }
                            }
                        }
                    }
                    .padding()
                } else {
                    ProgressView("Generating preview...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Merge Preview")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                let deduplicator = ContactDeduplicator()
                mergePreview = deduplicator.generateMergePreview(for: group)
            }
        }
    }
}

struct ContactDetailCard: View {
    let contact: UnifiedContact
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contact.displayName)
                .font(.body)
                .fontWeight(.semibold)
            
            if let org = contact.organizationName {
                Label(org, systemImage: "building.2")
                    .font(.caption)
            }
            
            ForEach(contact.emailAddresses, id: \.value) { email in
                Label(email.value, systemImage: "envelope")
                    .font(.caption)
            }
            
            ForEach(contact.phoneNumbers, id: \.value) { phone in
                Label(phone.value, systemImage: "phone")
                    .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

struct MergeChangeRow: View {
    let change: MergeChange
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: change.isConflict ? "exclamationmark.circle.fill" : "arrow.right.circle")
                .foregroundColor(change.isConflict ? .orange : .blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(change.fieldName)
                    .font(.caption)
                    .fontWeight(.semibold)
                
                if change.isConflict {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Values found:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        ForEach(change.values, id: \.self) { value in
                            Text("• \(value)")
                                .font(.caption2)
                        }
                        
                        Text("Chosen: \(change.chosenValue)")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                } else {
                    Text(change.chosenValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(change.isConflict ? Color.orange.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Preview

#Preview("With Duplicates") {
    let contact1 = UnifiedContact(
        id: UUID(),
        givenName: "John",
        familyName: "Smith",
        emailAddresses: [.init(value: "john@company.com", label: "work")],
        phoneNumbers: [.init(value: "555-1234", label: "mobile")]
    )
    
    let contact2 = UnifiedContact(
        id: UUID(),
        givenName: "J.",
        familyName: "Smith",
        emailAddresses: [.init(value: "john@company.com", label: "work")],
        phoneNumbers: [.init(value: "555-1234", label: "work")]
    )
    
    let group = DuplicateGroup(
        contacts: [
            DuplicateCandidate(contact: contact1, source: .google),
            DuplicateCandidate(contact: contact2, source: .mac)
        ],
        matchScore: 85,
        matchReason: "Same email and similar names",
        groupType: .acrossSources
    )
    
    DeduplicationConfirmationView(
        duplicateGroups: [group],
        onDecisionsMade: { _ in }
    )
}

#Preview("Empty State") {
    DeduplicationConfirmationView(
        duplicateGroups: [],
        onDecisionsMade: { _ in }
    )
}
