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
        case .twoWay:      return "Both ways"
        case .googleToMac: return "Google → Mac"
        case .macToGoogle: return "Mac → Google"
        }
    }

    private var directionColor: Color {
        switch change.direction {
        case .twoWay:      return .purple
        case .googleToMac: return .red
        case .macToGoogle: return .blue
        }
    }

    private var isConflict: Bool { change.action == .merge }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon)
                .foregroundStyle(actionColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(change.contactName)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    // Direction badge
                    Text(directionLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(directionColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(directionColor.opacity(0.1))
                        .clipShape(Capsule())

                    if let firstChange = change.changes.first {
                        Text(firstChange)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Conflict badge — draws attention to rows needing review
            if isConflict {
                Text("Conflict")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appTextInverse)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appWarning)
                    .clipShape(Capsule())
            }

            if change.action != .skip {
                HStack(spacing: 6) {
                    Button("Skip") { onSkip() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)

                    Button("Details") { onViewDiff() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // Conflict rows get a subtle orange tint background
        .background(isConflict ? Color.appWarning.opacity(0.08) : Color.clear)
        .cornerRadius(6)
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
