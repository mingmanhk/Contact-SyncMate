//
//  Surfaces.swift
//  Contact SyncMate
//
//  The two recurring container shapes, named.
//

import SwiftUI

/// Corner radii used for containers.
///
/// Not an aesthetic preference — a vocabulary. The app had grown four radii
/// (6, 8, 10, 12) applied by whichever number was in the developer's head that
/// afternoon, so two adjacent panels could round differently for no reason.
/// Two named sizes cover every real case: a small inline control, and a card.
enum SurfaceRadius {
    /// Search fields, inline pills, anything sitting inside a card.
    static let control: CGFloat = 8
    /// A card or panel that groups content.
    static let card: CGFloat = 10
}

extension View {
    /// Card chrome: padding, a tinted background, and rounded corners.
    ///
    /// This was written out longhand at eleven call sites, and the copies had
    /// drifted apart — `Color.appSurfaceTinted` at some, the literal
    /// `Color.secondary.opacity(0.1)` at others, with radii of 6, 8 and 10 for
    /// what is visually the same container. The literal is the one that was
    /// wrong: it ignores the app's palette and so does not follow the accent
    /// and appearance settings the rest of the UI honours.
    ///
    /// - Parameter padding: `nil` leaves padding to the caller, for cases where
    ///   the content already pads itself (a `List`, for instance).
    func cardSurface(padding: CGFloat? = 12,
                     radius: CGFloat = SurfaceRadius.card) -> some View {
        self
            .padding(padding.map { EdgeInsets(top: $0, leading: $0, bottom: $0, trailing: $0) }
                     ?? EdgeInsets())
            .background(Color.appSurfaceTinted)
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    /// Chrome for an inline control — a search field, a filter pill.
    ///
    /// Same treatment as `cardSurface` with the tighter radius and padding that
    /// small controls want, so the difference between "card" and "control" is
    /// stated rather than encoded in a magic number at each site.
    func controlSurface(horizontal: CGFloat = 10, vertical: CGFloat = 6) -> some View {
        self
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(Color.appSurfaceTinted)
            .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.control))
    }
}

/// A titled section heading, optionally with a trailing action.
///
/// The pattern — `Text(...).font(.headline)`, `Spacer()`, sometimes a link
/// button — appeared in six files with three different fonts (`.headline`,
/// `.subheadline` bold, `.title3`) for headings at the same level.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        SectionHeader("Recent Changes")

        // `verbatim:` so preview copy does not land in the string catalog as a
        // key translators have to deal with.
        Text(verbatim: "Search contacts")
            .controlSurface()

        VStack(alignment: .leading) {
            Text(verbatim: "A card groups related content.")
        }
        .cardSurface()
    }
    .padding()
    .frame(width: 360)
}
