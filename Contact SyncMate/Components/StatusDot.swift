//
//  StatusDot.swift
//  Contact SyncMate
//
//  A small, accessible status indicator. State is conveyed by:
//   • Colour (semantic token, dark-mode aware)
//   • SF Symbol (fallback for color-blind users via the convenience initialiser)
//   • Accessibility label & value (announced by VoiceOver as a single phrase)
//
//  Pulse animation is disabled when System Settings → Accessibility → Display →
//  Reduce Motion is enabled.
//

import SwiftUI

// MARK: - Sync Status

public enum SyncStatus: String {
    case idle
    case syncing
    case success
    case error

    /// Semantic colour token. Adapts to light/dark mode automatically.
    public var color: Color {
        switch self {
        case .idle:    return .appSuccess
        case .syncing: return .appWarning
        case .success: return .appSuccess
        case .error:   return .appError
        }
    }

    /// Human-readable status used as the accessibility label and visible
    /// label (e.g. in `MenuBarView.statusRow`).
    public var label: String {
        switch self {
        case .idle:    return "Up to date"
        case .syncing: return "Syncing"
        case .success: return "Sync complete"
        case .error:   return "Sync error"
        }
    }

    /// SF Symbol used by ancillary indicators (e.g., when paired with the dot
    /// for high-contrast / Differentiate-Without-Color users).
    public var iconName: String {
        switch self {
        case .idle:    return AppIcon.statusIdle
        case .syncing: return AppIcon.statusSyncing
        case .success: return AppIcon.statusSuccess
        case .error:   return AppIcon.statusError
        }
    }
}

// MARK: - StatusDot

/// A 10×10 coloured dot that pulses while syncing. Always paired with a
/// VoiceOver-friendly accessibility label so state is never colour-only.
public struct StatusDot: View {
    public let status: SyncStatus

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    public init(status: SyncStatus) {
        self.status = status
    }

    public var body: some View {
        Group {
            if differentiateWithoutColor {
                // High-contrast / colour-blind path: render the symbol so
                // state is conveyed by shape, not just hue.
                Image(systemName: status.iconName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.color)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 10, height: 10)
                    .shadow(color: status.color.opacity(0.6),
                            radius: shouldPulse ? 6 : 2)
                    .scaleEffect(shouldPulse ? 1.3 : 1.0)
                    .animation(pulseAnimation, value: pulse)
            }
        }
        .onAppear  { pulse = (status == .syncing && !reduceMotion) }
        .onChange(of: status)        { _, new in pulse = (new == .syncing && !reduceMotion) }
        .onChange(of: reduceMotion)  { _, rm  in pulse = (status == .syncing && !rm) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sync status"))
        .accessibilityValue(Text(status.label))
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Helpers

    private var shouldPulse: Bool { pulse && !reduceMotion }

    private var pulseAnimation: Animation? {
        guard shouldPulse else { return nil }
        return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }
}

// MARK: - Preview

#Preview("Light") {
    HStack(spacing: 16) {
        StatusDot(status: .idle)
        StatusDot(status: .syncing)
        StatusDot(status: .success)
        StatusDot(status: .error)
    }
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    HStack(spacing: 16) {
        StatusDot(status: .idle)
        StatusDot(status: .syncing)
        StatusDot(status: .success)
        StatusDot(status: .error)
    }
    .padding()
    .preferredColorScheme(.dark)
}
