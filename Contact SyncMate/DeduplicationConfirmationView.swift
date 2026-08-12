//
//  DeduplicationConfirmationView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/11/25.
//

import SwiftUI

// UUID conforms to Identifiable for sheet(item:) usage
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// View for confirming duplicate contact merges
struct DeduplicationConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    
    let duplicateGroups: [DuplicateGroup]
    /// Decisions per group, plus the groups whose "Remember this choice"
    /// toggle is on. The view collected the patterns all along but the old
    /// single-argument callback silently dropped them.
    let onDecisionsMade: ([UUID: DuplicateDecision], Set<UUID>) -> Void
    
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

                bulkActionBar

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
                    .foregroundStyle(Color.appWarning)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Possible Duplicates")
                        .font(.headline)
                    Text("\(duplicateGroups.count) group\(duplicateGroups.count == 1 ? "" : "s") found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Text("These contacts appear to be the same person. Please confirm how to handle them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Bulk actions

    /// Decide whole confidence tiers at once.
    ///
    /// Twenty-eight groups decided one card at a time is not review, it is
    /// data entry — and the app already knows which of them are not in doubt.
    /// So the two tiers it can answer for itself get a button each, and what
    /// remains is the 50–79 band, where the evidence genuinely is ambiguous and
    /// a person has to look.
    ///
    /// There is deliberately no "merge all 28". Merging is the one action here
    /// that destroys information — two contacts become one and the app has no
    /// unmerge — so a blanket grant over pairs the scorer itself is unsure
    /// about is the wrong shape of button, however convenient. The tiered
    /// versions give the same relief for everything that can be decided by
    /// rule, and stop where rules stop.
    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Button {
                decideAll(.merge, in: highConfidenceGroups)
            } label: {
                Label("Merge \(highConfidenceGroups.count) high-confidence",
                      systemImage: "arrow.triangle.merge")
            }
            .disabled(highConfidenceGroups.isEmpty)
            .help("Applies to groups scoring 80 or above — a shared phone number or email, not a name guess")

            Button {
                decideAll(.keepSeparate, in: lowConfidenceGroups)
            } label: {
                Label("Keep \(lowConfidenceGroups.count) separate", systemImage: "arrow.triangle.branch")
            }
            .disabled(lowConfidenceGroups.isEmpty)
            .help("Applies to groups scoring below 50 — too weak a match to merge on")

            Spacer()

            if needsAttentionCount > 0 {
                Text("\(needsAttentionCount) need your decision")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset") { decisions.removeAll() }
                .disabled(decisions.isEmpty)
                .help("Clear every decision made on this screen")
        }
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Groups the app is confident about: a shared phone or email, not a name.
    private var highConfidenceGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.shouldAutoMerge }
    }

    /// Too weak to merge on.
    private var lowConfidenceGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.shouldKeepSeparate }
    }

    /// The middle band — the ones no rule can settle.
    private var needsAttentionCount: Int {
        duplicateGroups.filter { $0.shouldPromptUser && decisions[$0.id] == nil }.count
    }

    /// Fill in a decision for groups that have none yet.
    ///
    /// Only the undecided ones. A bulk button that overwrote choices already
    /// made would silently undo careful work — someone who decided three cards
    /// by hand and then reached for "merge the easy ones" would lose all three
    /// without being told.
    private func decideAll(_ decision: DuplicateDecision, in groups: [DuplicateGroup]) {
        for group in groups where decisions[group.id] == nil {
            decisions[group.id] = decision
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.appSuccess)
            
            Text("No Duplicates Found")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("All contacts appear to be unique.")
                .font(.body)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            
            Button("Apply Decisions") {
                onDecisionsMade(decisions, rememberPatterns)
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
        // A real Button rather than `.onTapGesture`: selection is now
        // reachable via Tab / Full Keyboard Access and announced as a button
        // by VoiceOver. Inner controls (decision buttons, toggle) keep
        // handling their own clicks.
        Button(action: onSelect) {
            cardContent
        }
        .buttonStyle(.appRow)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with score and type
            HStack(alignment: .top) {
                scoreIndicator

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.groupType.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // AI source badge
                        if let source = group.aiSourceLabel {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                Text(source)
                                    .font(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                    }

                    Text(group.matchReason)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)

                    // AI score enhancement indicator
                    if let aiScore = group.aiEnhancedScore, aiScore != group.matchScore {
                        HStack(spacing: 4) {
                            Image(systemName: aiScore > group.matchScore ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(aiScore > group.matchScore ? Color.appSuccess : Color.appWarning)
                            Text("AI adjusted score: \(group.matchScore) → \(aiScore)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if group.shouldAutoMerge {
                        Label("Auto-merge", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appSuccess)
                    }

                    // AI suggested action badge
                    if let aiAction = group.aiMatchResult?.suggestedAction,
                       group.userDecision == nil {
                        HStack(spacing: 3) {
                            Image(systemName: "lightbulb.fill")
                                .font(.caption2)
                            Text("AI: \(aiAction.aiLabel)")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(aiActionColor(aiAction).opacity(0.12))
                        .foregroundStyle(aiActionColor(aiAction))
                        .clipShape(Capsule())
                    }
                }
            }
            
            Divider()
            
            // Contacts in group
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.contacts) { candidate in
                    ContactCandidateRow(candidate: candidate)
                }
            }
            
            // AI reasoning block (shown when AI analysis is available)
            if let ai = group.aiMatchResult, !ai.reasoning.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Analysis")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                        Text(ai.reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Signal chips
                        if !ai.matchSignals.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(ai.matchSignals) { signal in
                                        Text(signal.label)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                (signal.isPositive ? Color.appSuccess : Color.appWarning).opacity(0.12)
                                            )
                                            .foregroundStyle(signal.isPositive ? Color.appSuccess : Color.appWarning)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Decision buttons
            VStack(alignment: .leading, spacing: 8) {
                Text("Your decision:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
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
    }
    
    private var scoreIndicator: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 3)
                    .frame(width: 50, height: 50)

                Circle()
                    .trim(from: 0, to: CGFloat(group.effectiveScore) / 100.0)
                    .stroke(scoreColor, lineWidth: 3)
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: group.effectiveScore)

                Text("\(group.effectiveScore)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(scoreColor)
            }

            Text(group.hasAIAnalysis ? "AI Score" : "Match")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    private var scoreColor: Color {
        let score = group.effectiveScore
        if score >= 80 { return .appSuccess }
        if score >= 50 { return .appWarning }
        return .appError
    }

    private func aiActionColor(_ action: DuplicateDecision) -> Color {
        switch action {
        case .merge:        return .appSuccess
        case .keepSeparate: return .appWarning
        case .skip:         return .secondary
        }
    }
}

// MARK: - Contact Candidate Row

struct ContactCandidateRow: View {
    let candidate: DuplicateCandidate
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.source == .google ? "g.circle.fill" : "desktopcomputer")
                .foregroundStyle(candidate.source == .google ? Color.appSourceGoogle : Color.appSourceApple)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                
                if let email = candidate.primaryEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let phone = candidate.primaryPhone {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
    
    private var buttonColor: Color {
        switch decision {
        case .merge: return .appSuccess
        case .keepSeparate: return .appWarning
        case .skip: return .secondary
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
                                        .foregroundStyle(Color.appWarning)
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
                .foregroundStyle(change.isConflict ? Color.appWarning : Color.appInfo)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(change.fieldName)
                    .font(.caption)
                    .fontWeight(.semibold)
                
                if change.isConflict {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Values found:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        ForEach(change.values, id: \.self) { value in
                            Text("• \(value)")
                                .font(.caption2)
                        }
                        
                        Text("Chosen: \(change.chosenValue)")
                            .font(.caption2)
                            .foregroundStyle(Color.appSuccess)
                    }
                } else {
                    Text(change.chosenValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(change.isConflict ? Color.appWarning.opacity(0.10) : Color.appSurface)
        )
    }
}

// MARK: - Preview

#Preview("With Duplicates") {
    let contact1 = UnifiedContact(
        id: UUID(),
        givenName: "John",
        familyName: "Smith",
        phoneNumbers: [.init(value: "555-1234", label: "mobile")],
        emailAddresses: [.init(value: "john@company.com", label: "work")]
    )
    
    let contact2 = UnifiedContact(
        id: UUID(),
        givenName: "J.",
        familyName: "Smith",
        phoneNumbers: [.init(value: "555-1234", label: "work")],
        emailAddresses: [.init(value: "john@company.com", label: "work")]
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
        onDecisionsMade: { _, _ in }
    )
}

#Preview("Empty State") {
    DeduplicationConfirmationView(
        duplicateGroups: [],
        onDecisionsMade: { _, _ in }
    )
}
