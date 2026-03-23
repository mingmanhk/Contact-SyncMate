//
//  ContactChangeRow.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Contact Change Row

struct ContactChangeRow: View {
    let change: ContactChange
    let onSkip: () -> Void
    let onViewDiff: () -> Void

    private var actionIcon: String {
        switch change.action {
        case .add:    return "plus.circle.fill"
        case .update: return "pencil.circle.fill"
        case .delete: return "minus.circle.fill"
        case .merge:  return "arrow.triangle.merge"
        case .skip:   return "xmark.circle.fill"
        }
    }

    private var actionColor: Color {
        switch change.action {
        case .add:    return .green
        case .update: return .blue
        case .delete: return .red
        case .merge:  return .orange
        case .skip:   return .secondary
        }
    }

    private var directionLabel: String {
        switch change.direction {
        case .twoWay:      return "↔"
        case .googleToMac: return "G→M"
        case .macToGoogle: return "M→G"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon)
                .foregroundStyle(actionColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.contactName)
                    .fontWeight(.medium)
                if let firstChange = change.changes.first {
                    Text(firstChange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(directionLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())

            if change.action != .skip {
                HStack(spacing: 8) {
                    Button("Skip") { onSkip() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Diff") { onViewDiff() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let sample = ContactChange(
        contactName: "Jane Appleseed",
        action: .update,
        direction: .googleToMac,
        changes: ["Phone: +1 555 1234 → +1 555 5678"]
    )
    ContactChangeRow(change: sample, onSkip: {}, onViewDiff: {})
        .padding()
}
