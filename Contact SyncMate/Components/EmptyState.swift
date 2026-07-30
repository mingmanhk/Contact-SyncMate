//
//  EmptyState.swift
//  Contact SyncMate
//
//  The "there is nothing here yet" placeholder, in one place.
//

import SwiftUI

/// Placeholder shown when a list has no rows to draw.
///
/// This layout — icon, title, optional explanation — was hand-written five
/// times across the app, and the copies had drifted: three different icon
/// sizes, two different title fonts, one using `foregroundColor` where the
/// others used `foregroundStyle`, and inconsistent handling of whether the
/// placeholder centres in the available space or sits inline. None of that was
/// a decision; it was just five separate afternoons.
///
/// The distinction that *is* a decision is `fill`: a placeholder inside a card
/// should take its natural height, while one filling a whole pane should
/// centre. That is the only knob here.
struct EmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    /// Centre in all available space (a full pane) rather than sitting inline
    /// at natural height (inside a card).
    var fill: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
        .padding(.vertical, fill ? 0 : 32)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// A `String`-titled variant, for titles built at runtime.
///
/// `LocalizedStringKey` only auto-localises string *literals*, so an
/// interpolated title like the search-miss message has to come through as an
/// already-resolved `String` — passing it as a key would look up a phrase that
/// does not exist in the catalog and render the raw text unlocalised.
extension EmptyState {
    init(icon: String, verbatimTitle: String, message: LocalizedStringKey? = nil, fill: Bool = true) {
        self.init(icon: icon, title: LocalizedStringKey(verbatimTitle), message: message, fill: fill)
    }
}

#Preview("Fills the pane") {
    EmptyState(icon: "clock.arrow.circlepath",
               title: "No sync history yet",
               message: "Run your first sync to see activity here.")
        .frame(width: 380, height: 260)
}
