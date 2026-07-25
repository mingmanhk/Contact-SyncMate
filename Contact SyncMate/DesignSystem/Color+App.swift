//
//  Color+App.swift
//  Contact SyncMate
//
//  Centralised semantic colour tokens — the single source of truth for every
//  hue used in the UI. All colours adapt automatically to light / dark mode
//  via the asset catalog (`Assets.xcassets/<TokenName>.colorset`).
//
//  Rule: views must NEVER use `Color.red`, `Color.green`, `Color.blue`,
//  `Color.orange`, `Color.yellow`, `Color.purple`, `Color.brown` directly.
//  Use the semantic accessor (e.g. `Color.appError`) instead.
//
//  If a token is missing from the asset catalog, the accessor falls back to
//  the closest system colour so the build never breaks during incremental
//  rollout.
//

import SwiftUI

// MARK: - Semantic colour tokens

public extension Color {

    // ── Brand ───────────────────────────────────────────────────────────────

    /// Primary brand colour. Backed by `BrandIndigo.colorset`.
    static var appBrand: Color { Color("BrandIndigo", bundle: .main) }

    /// Accent colour (used for CTAs, selected states, focus rings).
    /// Backed by `AccentColor.colorset` (the project's accent colour set).
    static var appAccent: Color { .accentColor }

    // ── Status (success / warning / error / info) ───────────────────────────

    /// Success / "everything is OK" colour. Replaces hard-coded `.green`.
    static var appSuccess: Color {
        Color("StatusSuccess", bundle: .main, fallback: .green)
    }

    /// Warning / "needs attention" colour. Replaces `.orange` and `.yellow`.
    static var appWarning: Color {
        Color("StatusWarning", bundle: .main, fallback: .orange)
    }

    /// Error / destructive colour. Replaces `.red` for danger states.
    static var appError: Color {
        Color("StatusError", bundle: .main, fallback: .red)
    }

    /// Informational colour (used for info pills, neutral hints). Replaces `.blue`.
    static var appInfo: Color {
        Color("StatusInfo", bundle: .main, fallback: .blue)
    }

    // ── Source identity (Google / Apple) ────────────────────────────────────

    /// Google source colour. Use only for Google brand badges (`g.circle.fill`).
    static var appSourceGoogle: Color {
        Color("SourceGoogle", bundle: .main, fallback: .red)
    }

    /// Apple / Mac source colour. Use only for Mac brand badges.
    static var appSourceApple: Color {
        Color("SourceApple", bundle: .main, fallback: .blue)
    }

    // ── Surfaces ────────────────────────────────────────────────────────────

    /// Primary window background. Always prefer this over a literal colour.
    static var appBackground: Color { Color(nsColor: .windowBackgroundColor) }

    /// Card / sheet / form background.
    static var appSurface: Color { Color(nsColor: .controlBackgroundColor) }

    /// Tinted surface (replaces ad-hoc `Color.secondary.opacity(0.08–0.12)`).
    static var appSurfaceTinted: Color {
        Color("SurfaceTinted", bundle: .main, fallback: .secondary.opacity(0.10))
    }

    // ── Borders / dividers ──────────────────────────────────────────────────

    /// Hairline divider colour.
    static var appBorder: Color { Color(nsColor: .separatorColor) }

    /// Emphasised border (selected card outline, focus ring backdrop).
    static var appBorderEmphasized: Color { .accentColor }

    // ── Text ────────────────────────────────────────────────────────────────

    /// Body text colour. Equivalent to `.primary`.
    static var appTextPrimary: Color { .primary }

    /// Muted text colour. Equivalent to `.secondary`.
    static var appTextSecondary: Color { .secondary }

    /// De-emphasised caption text.
    static var appTextTertiary: Color { Color(nsColor: .tertiaryLabelColor) }

    /// Inverse text — for use on tinted backgrounds (`.appAccent`, `.appError`).
    static var appTextInverse: Color { Color(nsColor: .alternateSelectedControlTextColor) }
}

// MARK: - Internal initialiser with asset-fallback

private extension Color {
    /// Loads a named asset; if the asset is missing, returns the supplied
    /// fallback. Lets us roll out the asset catalog incrementally without
    /// breaking the build.
    init(_ name: String, bundle: Bundle?, fallback: Color) {
        if NSColor(named: name, bundle: bundle) != nil {
            self = Color(name, bundle: bundle)
        } else {
            self = fallback
        }
    }
}
