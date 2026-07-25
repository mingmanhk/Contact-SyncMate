//
//  AppButtonStyle.swift
//  Contact SyncMate
//
//  Custom button styles that draw the focus ring, hover background, and
//  pressed state — capabilities `.plain` strips off. Use these instead of
//  `.buttonStyle(.plain)` for menu rows, list rows, and link-styled buttons.
//

import SwiftUI

// MARK: - AppRowButtonStyle

/// A row-style button used in menu bar popovers and list rows.
/// Renders a hover background and a focus ring without altering label layout.
public struct AppRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(background(for: configuration))
            )
            .overlay(focusRing(for: configuration))
            .opacity(isEnabled ? 1.0 : 0.55)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.10), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func background(for cfg: Configuration) -> Color {
        if cfg.isPressed { return Color.accentColor.opacity(0.18) }
        if isHovered     { return Color.gray.opacity(0.12) }
        return .clear
    }

    @ViewBuilder
    private func focusRing(for cfg: Configuration) -> some View {
        // Native focus ring is restored by `.focusEffect(.automatic)` on macOS 14+;
        // for now we draw a subtle outline when pressed to ensure VO+keyboard
        // users see activation feedback.
        if cfg.isPressed {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        }
    }
}

public extension ButtonStyle where Self == AppRowButtonStyle {
    /// `.buttonStyle(.appRow)` — list-row style with hover + pressed states.
    static var appRow: AppRowButtonStyle { AppRowButtonStyle() }
}

// MARK: - AppDestructiveButtonStyle

/// A destructive bordered button that uses the `.appError` semantic colour.
public struct AppDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.appError)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.appError.opacity(configuration.isPressed ? 0.8 : 0.4),
                            lineWidth: 1)
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == AppDestructiveButtonStyle {
    /// `.buttonStyle(.appDestructive)` — bordered destructive style.
    static var appDestructive: AppDestructiveButtonStyle { AppDestructiveButtonStyle() }
}
