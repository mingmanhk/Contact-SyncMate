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
        HStack(spacing: 12) {
            badge(icon: "plus",           count: added,     color: .green,  label: "Added")
            badge(icon: "pencil",         count: updated,   color: .blue,   label: "Updated")
            badge(icon: "minus",          count: deleted,   color: .red,    label: "Deleted")
            badge(icon: "exclamationmark",count: conflicts, color: .orange, label: "Conflicts")
        }
    }

    @ViewBuilder
    private func badge(icon: String, count: Int, color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon + ".circle.fill")
                    .foregroundStyle(color)
                Text("\(count)")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    SyncSummaryBadges(added: 12, updated: 8, deleted: 2, conflicts: 3)
        .padding()
}
