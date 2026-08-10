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

    /// Chip title. The rawValue stays an identifier; `Text(rawValue)` would
    /// ship the English word in every locale.
    var localizedTitle: String {
        switch self {
        case .all:      return String(localized: "All")
        case .add:      return String(localized: "Add")
        case .update:   return String(localized: "Edit")
        case .delete:   return String(localized: "Delete")
        case .conflict: return String(localized: "Conflict")
        }
    }

    /// Empty-list message per filter. Written out per case instead of
    /// interpolating a lowercased rawValue, which no translator can reorder.
    var emptyStateText: String {
        switch self {
        case .all:      return String(localized: "All changes skipped")
        case .add:      return String(localized: "No additions pending")
        case .update:   return String(localized: "No edits pending")
        case .delete:   return String(localized: "No deletions pending")
        case .conflict: return String(localized: "No conflicts pending")
        }
    }
}

// MARK: - Sync Preview View

struct SyncPreviewView: View {
    let session: SyncSession
    @Binding var isPresented: Bool
    /// Applies the reviewed session. Supplied by the presenter so this view does
    /// not own a SyncEngine.
    var onApply: ((SyncSession) -> Void)? = nil

    @State private var activeFilter: ChangeFilter = .all
    @State private var skipped: Set<UUID> = []
    @State private var showingDiff: ContactChange? = nil

    private var filteredChanges: [ContactChange] {
        let base = session.contactChanges.filter { !skipped.contains($0.id) }
        guard let action = activeFilter.action else { return base }
        if action == .merge { return base.filter { Self.needsReview($0) } }
        return base.filter { $0.action == action }
    }

    /// A merge the app has not already decided.
    ///
    /// The conflicts chip used to count every merge, so a first sync between
    /// two populated address books reported ~200 "conflicts" — almost all of
    /// them contacts matched on a shared email address, where there is nothing
    /// to decide. A number that large reads as a wall, and a wall gets clicked
    /// through. Counting only the matches that genuinely need a person makes
    /// the number small enough to be worth reading.
    ///
    /// Always called as `filter { Self.needsReview($0) }`, never
    /// `filter(Self.needsReview)`. The second form makes a function *value*,
    /// which has no enclosing context to inherit isolation from and so fails to
    /// compile under this project's default MainActor isolation. A non-escaping
    /// closure inherits the view's isolation and costs nothing.
    static func needsReview(_ change: ContactChange) -> Bool {
        change.action == .merge && change.userOverride == nil
    }

    private var pendingCount:  Int { session.contactChanges.filter { !skipped.contains($0.id) }.count }
    private var addedCount:    Int { session.contactChanges.filter { $0.action == .add    }.count }
    private var updatedCount:  Int { session.contactChanges.filter { $0.action == .update }.count }
    private var deletedCount:  Int { session.contactChanges.filter { $0.action == .delete }.count }
    private var conflictCount: Int { session.contactChanges.filter { Self.needsReview($0) }.count }

    /// The session as the user left it: rows they unchecked become explicit
    /// skips, and the whole session is marked reviewed.
    ///
    /// `userReviewed` is what releases held-back deletions — the point of the
    /// "Ask before deleting contacts" setting is that a human saw this list.
    private func reviewedSession() -> SyncSession {
        var reviewed = session
        reviewed.userReviewed = true
        reviewed.contactChanges = session.contactChanges.map { change in
            guard skipped.contains(change.id) else { return change }
            var skippedChange = change
            skippedChange.userOverride = .skip
            return skippedChange
        }
        return reviewed
    }

    private func count(for filter: ChangeFilter) -> Int {
        let base = session.contactChanges.filter { !skipped.contains($0.id) }
        switch filter {
        case .all:      return base.count
        case .add:      return base.filter { $0.action == .add    }.count
        case .update:   return base.filter { $0.action == .update }.count
        case .delete:   return base.filter { $0.action == .delete }.count
        case .conflict: return base.filter { Self.needsReview($0) }.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Preview")
                        .font(.title2)
                        .fontWeight(.semibold)
                    // Catalog plural rule ("%lld changes pending"), not a
                    // hand-rolled English "s".
                    Text("\(pendingCount) changes pending")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // No Cancel here. The footer already has one, next to Apply,
                // which is where a sheet's decision belongs — two identical
                // buttons on one screen make you stop and work out whether they
                // differ. Escape still closes the sheet; that shortcut moved to
                // the footer button rather than being dropped.
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

            // Filter bar — includes per-filter counts so users know what to expect
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChangeFilter.allCases, id: \.self) { filter in
                        let n = count(for: filter)
                        FilterChip(
                            title: filter.localizedTitle,
                            count: filter == .all ? nil : n,
                            isSelected: activeFilter == filter,
                            isDisabled: n == 0 && filter != .all
                        ) {
                            if n > 0 || filter == .all { activeFilter = filter }
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
                VStack(spacing: 8) {
                    Image(systemName: activeFilter == .all ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(activeFilter.emptyStateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if activeFilter != .all {
                        Text("Switch to \"All\" to see other pending changes.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
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
            VStack(spacing: 8) {
                // Conflict warning banner
                if conflictCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: AppIcon.statusWarning)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.appWarning)
                        Text("\(conflictCount) conflicts need review — tap Details on each highlighted row.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                }

                HStack {
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.escape)

                    Spacer()

                    if skipped.count > 0 {
                        Text("\(skipped.count) skipped")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 4)
                    }

                    Button {
                        onApply?(reviewedSession())
                        isPresented = false
                    } label: {
                        if pendingCount == 0 {
                            Label("Nothing to Apply", systemImage: "checkmark")
                        } else {
                            Label("Apply \(pendingCount) Changes", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(pendingCount == 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
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
    var count: Int? = nil
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let n = count {
                    Text("\(n)")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.appTextInverse.opacity(0.25) : Color.appSurfaceTinted)
                        .clipShape(Capsule())
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundStyle(isDisabled ? Color.appTextTertiary : (isSelected ? Color.appTextInverse : Color.primary))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
