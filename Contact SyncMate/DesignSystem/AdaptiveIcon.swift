//
//  AdaptiveIcon.swift
//  Contact SyncMate
//
//  Shared icon component. Renders SF Symbols with hierarchical rendering mode
//  and a semantic colour token, guaranteeing visibility in both light and
//  dark mode and consistent treatment across every screen.
//
//  Use this instead of `Image(systemName:)` whenever an icon participates in
//  layout (status indicators, account rows, list rows, badges).
//

import SwiftUI

// MARK: - AdaptiveIcon

/// An SF Symbol rendered with hierarchical mode + semantic colour.
public struct AdaptiveIcon: View {
    public let systemName: String
    public var color: Color
    public var size: CGFloat
    public var weight: Font.Weight

    /// Designated initialiser.
    /// - Parameters:
    ///   - systemName: The SF Symbol name (e.g. `"checkmark.circle.fill"`).
    ///   - color: Semantic colour token. Defaults to `.appTextPrimary`.
    ///   - size: Glyph point size. The hit area is slightly larger.
    ///   - weight: Symbol weight; defaults to `.regular`.
    public init(systemName: String,
                color: Color = .appTextPrimary,
                size: CGFloat = 16,
                weight: Font.Weight = .regular) {
        self.systemName = systemName
        self.color = color
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .font(.system(size: size, weight: weight))
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true) // Decorative by default; callers add labels at row level.
    }
}

// MARK: - View modifier convenience

public extension View {
    /// Apply standard hierarchical icon styling + semantic colour to any
    /// `Image(systemName:)`. Equivalent to building an `AdaptiveIcon` but
    /// allowed inside `Label`.
    func iconStyle(_ color: Color = .appTextPrimary,
                   weight: Font.Weight = .regular) -> some View {
        self.symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .fontWeight(weight)
    }
}

// MARK: - AppIcon registry

/// Typed registry of every SF Symbol used in the app. Adding a new icon
/// requires extending this enum, which keeps drift in check and gives us a
/// single place to update if Apple renames or deprecates a symbol.
public enum AppIcon {
    // Status
    public static let statusIdle           = "person.2.circle"
    public static let statusSyncing        = "arrow.triangle.2.circlepath"
    public static let statusSuccess        = "checkmark.circle.fill"
    public static let statusError          = "xmark.circle.fill"
    public static let statusWarning        = "exclamationmark.triangle.fill"
    public static let statusInfo           = "info.circle"

    // Sources
    public static let sourceGoogle         = "g.circle.fill"
    public static let sourceApple          = "desktopcomputer"

    // Navigation / chrome
    public static let dashboard            = "gauge.with.dots.needle.33percent"
    public static let history              = "clock"
    public static let settings             = "gearshape"
    public static let autoSync             = "clock.arrow.circlepath"
    public static let manualSync           = "hand.tap"
    public static let quit                 = "power"

    // Actions
    public static let restore              = "arrow.uturn.backward"
    public static let disclosure           = "chevron.right"
    public static let refresh              = "arrow.clockwise"

    // Diff / counts
    public static let added                = "plus.circle.fill"
    public static let updated              = "pencil.circle.fill"
    public static let deleted              = "minus.circle.fill"
    public static let conflict             = "exclamationmark.circle.fill"
}
