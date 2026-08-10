//
//  SyncSummaryBadges.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Sync Summary Badges Row

struct SyncSummaryBadges: View {
    let added: Int
    let updated: Int
    let deleted: Int
    let conflicts: Int

    var body: some View {
        // `String(localized:)` because the labels travel through a `String`
        // parameter — `Text(String)` renders verbatim and skips the catalog.
        HStack(spacing: 12) {
            badge(icon: AppIcon.added,    count: added,     color: .appSuccess, label: String(localized: "Added"))
            badge(icon: AppIcon.updated,  count: updated,   color: .appInfo,    label: String(localized: "Updated"))
            badge(icon: AppIcon.deleted,  count: deleted,   color: .appError,   label: String(localized: "Deleted"))
            badge(icon: AppIcon.conflict, count: conflicts, color: .appWarning, label: String(localized: "Conflicts"))
        }
    }

    @ViewBuilder
    private func badge(icon: String, count: Int, color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text("\(count)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.subheadline)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(count)")
    }
}

#Preview {
    SyncSummaryBadges(added: 12, updated: 8, deleted: 2, conflicts: 3)
        .padding()
}
