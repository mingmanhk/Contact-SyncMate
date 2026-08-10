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
        case .add:    return .appSuccess
        case .update: return .appInfo
        case .delete: return .appError
        case .merge:  return .appWarning
        case .skip:   return .secondary
        }
    }

    /// Localized name of the action, used to lead the row's accessibility
    /// label so VoiceOver announces "Delete Jane Appleseed", not just the name.
    private var actionName: String {
        switch change.action {
        case .add:    return String(localized: "Add")
        case .update: return String(localized: "Update")
        case .delete: return String(localized: "Delete")
        case .merge:  return String(localized: "Merge")
        case .skip:   return String(localized: "Skip")
        }
    }

    private var directionLabel: String {
        switch change.direction {
        case .twoWay:      return String(localized: "Both ways")
        case .googleToMac: return String(localized: "Google → Mac")
        case .macToGoogle: return String(localized: "Mac → Google")
        }
    }

    private var directionColor: Color {
        switch change.direction {
        case .twoWay:      return .appBrand
        case .googleToMac: return .appSourceGoogle
        case .macToGoogle: return .appSourceApple
        }
    }

    private var isConflict: Bool { change.action == .merge }

    /// One phrase, action first: "Delete Jane Appleseed, Google → Mac".
    /// The action is the whole point of this screen — an unlabeled icon was
    /// the only thing distinguishing an addition from a deletion.
    private var accessibilityDescription: String {
        var parts = ["\(actionName) \(change.contactName)", directionLabel]
        if isConflict { parts.append(String(localized: "Conflict")) }
        if let firstChange = change.changes.first { parts.append(firstChange) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Informational part: combined into a single element whose label
            // leads with the action. The Skip/Details buttons stay outside so
            // they remain individually reachable (row is a `.contain` element).
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
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)

            Spacer()

            // Conflict badge — draws attention to rows needing review
            // (already part of the combined label above, so hidden from VO)
            if isConflict {
                Text("Conflict")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appTextInverse)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appWarning)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
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
        // Container: the combined info element and the Skip/Details buttons
        // stay reachable as separate children.
        .accessibilityElement(children: .contain)
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
