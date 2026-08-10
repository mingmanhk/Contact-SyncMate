//
//  SyncFailuresView.swift
//  Contact SyncMate
//
//  The contacts the sync gave up on, and what to do about them.
//

import SwiftUI

/// Lists contacts that failed to write repeatedly and were set aside.
///
/// The point of this screen is that a failure has somewhere to go. Before it,
/// a contact that could not be written failed on every sync, forever: the error
/// appeared in the log, scrolled away, and came back next run. Nothing
/// accumulated, so there was never a moment where a user could look at the
/// problem as a whole and decide.
///
/// The three actions are deliberately the only ones. Retry, for when the cause
/// was outside the app — a read-only account made writable, a permission
/// granted. Ignore, for a contact that is simply not going to sync and should
/// stop being mentioned. Unlink, for the case this app can actually cause:
/// a mapping pointing at a record that no longer exists or was never writable,
/// where forgetting the pairing lets the next sync match afresh.
///
/// There is no "fix it automatically" button, because the failures collected
/// here are ones we could not interpret — mostly Cocoa 134092, which means the
/// save was refused without saying why. Guessing at a repair for an error we
/// cannot read is how the retry loop started.
struct SyncFailuresView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var failures: [SyncFailure] = []
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if failures.isEmpty {
                EmptyState(
                    icon: "checkmark.circle",
                    title: "No sync failures",
                    message: "Contacts that fail to save three times in a row are listed here so you can decide what to do with them."
                )
            } else {
                List {
                    ForEach(failures) { failure in
                        row(for: failure)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear(perform: reload)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Failures")
                    .font(.headline)
                Text("These contacts could not be saved and are no longer being retried.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func row(for failure: SyncFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: failure.ignored
                  ? "bell.slash" : "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(failure.ignored ? Color.secondary : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: failure.contactName.isEmpty
                     ? String(localized: "Unnamed contact")
                     : failure.contactName)
                    .font(.body)

                // The raw error, not a friendly paraphrase. These are mostly
                // Cocoa errors whose numbers are searchable; rewriting them as
                // "Something went wrong" would remove the only lead there is.
                Text(failure.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(verbatim: "\(failure.failureCount) × · \(failure.lastFailedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Button("Retry") {
                    SyncFailureStore.shared.retry(key: failure.id)
                    reload()
                }
                .buttonStyle(.borderless)

                if !failure.ignored {
                    Button("Ignore") {
                        SyncFailureStore.shared.ignore(key: failure.id)
                        reload()
                    }
                    .buttonStyle(.borderless)
                }

                // Only offered when there is a pairing to forget. A
                // Google-keyed failure has no Mac mapping to remove, and a
                // button that silently does nothing is worse than no button.
                if failure.id.hasPrefix("mac:") {
                    Button("Unlink") {
                        unlink(failure)
                    }
                    .buttonStyle(.borderless)
                    .help("Forget the pairing between this Mac contact and its Google contact, so the next sync matches it again from scratch.")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            // Built as a String and passed verbatim. A ternary of two
            // interpolated literals leaves SwiftUI to pick between the
            // `LocalizedStringKey` and `String` initialisers, and the key it
            // would build — count and plural baked into the lookup — is not a
            // string any translator can work with anyway.
            if !failures.isEmpty {
                Text(verbatim: "\(failures.count) set aside")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry All") {
                for failure in failures { SyncFailureStore.shared.retry(key: failure.id) }
                reload()
            }
            .disabled(failures.isEmpty)

            Button("Clear List", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(failures.isEmpty)
            .confirmationDialog(
                "Clear the failure list?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear List", role: .destructive) {
                    SyncFailureStore.shared.clearAll()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These contacts will be attempted again on the next sync. If the underlying problem has not been fixed, they will fail again and reappear here.")
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func reload() {
        failures = SyncFailureStore.shared.allFailures()
    }

    /// Forget the mapping, then stop tracking the failure.
    ///
    /// Order matters: dropping the mapping is the change that might make the
    /// next sync succeed, so clearing the failure first would set the contact
    /// loose with the same broken pairing still in place.
    private func unlink(_ failure: SyncFailure) {
        let macID = String(failure.id.dropFirst("mac:".count))
        ContactMappingStore.shared.deleteMapping(macContactIdentifier: macID)
        SyncFailureStore.shared.clearFailure(key: failure.id)
        SyncHistory.shared.log(
            source: "SyncFailures", action: "mapping.unlinked",
            details: "\(failure.contactName) — pairing removed at user request")
        reload()
    }
}
