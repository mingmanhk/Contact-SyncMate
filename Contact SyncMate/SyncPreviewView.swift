//
//  SyncPreviewView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Change Filter

private enum ChangeFilter: String, CaseIterable {
    case all      = "All"
    case add      = "Add"
    case update   = "Edit"
    case delete   = "Delete"
    case conflict = "Conflict"

    var action: SyncAction? {
        switch self {
        case .all:      return nil
        case .add:      return .add
        case .update:   return .update
        case .delete:   return .delete
        case .conflict: return .merge
        }
    }
}

// MARK: - Sync Preview View

struct SyncPreviewView: View {
    let session: SyncSession
    @Binding var isPresented: Bool

    @State private var activeFilter: ChangeFilter = .all
    @State private var skipped: Set<UUID> = []
    @State private var showingDiff: ContactChange? = nil

    private var filteredChanges: [ContactChange] {
        let base = session.contactChanges.filter { !skipped.contains($0.id) }
        guard let action = activeFilter.action else { return base }
        return base.filter { $0.action == action }
    }

    private var pendingCount: Int { session.contactChanges.filter { !skipped.contains($0.id) }.count }

    private var addedCount:    Int { session.contactChanges.filter { $0.action == .add    }.count }
    private var updatedCount:  Int { session.contactChanges.filter { $0.action == .update }.count }
    private var deletedCount:  Int { session.contactChanges.filter { $0.action == .delete }.count }
    private var conflictCount: Int { session.contactChanges.filter { $0.action == .merge  }.count }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Preview")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(pendingCount) change\(pendingCount == 1 ? "" : "s") pending")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Summary badges
            SyncSummaryBadges(
                added:     addedCount,
                updated:   updatedCount,
                deleted:   deletedCount,
                conflicts: conflictCount
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            // Filter bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChangeFilter.allCases, id: \.self) { filter in
                        FilterChip(title: filter.rawValue, isSelected: activeFilter == filter) {
                            activeFilter = filter
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 8)

            Divider()

            // Changes list
            if filteredChanges.isEmpty {
                Spacer()
                Text("No changes matching this filter.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredChanges) { change in
                    ContactChangeRow(
                        change: change,
                        onSkip: { skipped.insert(change.id) },
                        onViewDiff: { showingDiff = change }
                    )
                    .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { isPresented = false }

                Spacer()

                Button("Apply \(pendingCount) Change\(pendingCount == 1 ? "" : "s")") {
                    // TODO: feed into SyncEngine
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandIndigo"))
                .disabled(pendingCount == 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 520)
        .sheet(item: $showingDiff) { change in
            ContactDiffView(
                conflict: ContactConflict(from: change),
                isPresented: Binding(
                    get: { showingDiff != nil },
                    set: { if !$0 { showingDiff = nil } }
                )
            )
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color("BrandIndigo") : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
