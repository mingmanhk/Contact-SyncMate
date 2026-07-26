//
//  SyncHistoryView.swift
//  Contact SyncMate
//

import SwiftUI
import UniformTypeIdentifiers  // UTType.json for the export panel
import Combine

// MARK: - History Filter

/// Three buckets, not four. "Success" and "Warnings" split the log along a line
/// nobody actually searches on — the real questions are "what did it do to my
/// contacts?" and "what went wrong?".
private extension String {
    /// "cnContactStoreDidChange" → "Cn Contact Store Did Change".
    ///
    /// Only used for action identifiers with no explicit label — a readable
    /// fallback, not a substitute for translating the ones users actually see.
    func splitCamelCaseWords() -> String {
        var out = ""
        for (index, character) in enumerated() {
            if index > 0, character.isUppercase, !out.hasSuffix(" ") {
                out.append(" ")
            }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

private enum HistoryFilter: String, CaseIterable {
    case all     = "All"
    case changes = "Changes"
    case errors  = "Errors"

    /// `Text(someString)` is not localized — `LocalizedStringKey` is only
    /// inferred for string *literals*, so feeding it `rawValue` shipped the
    /// English segment labels regardless of the chosen language.
    var localizedTitle: String {
        switch self {
        case .all:     return String(localized: "All")
        case .changes: return String(localized: "Changes")
        case .errors:  return String(localized: "Errors")
        }
    }
}

// MARK: - Sync History View

struct SyncHistoryView: View {
    @State private var allEvents: [SyncEvent] = []
    @State private var activeFilter: HistoryFilter = .all
    @State private var searchText = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var exportError: String?

    private var filteredEvents: [SyncEvent] {
        var events = allEvents
        if !searchText.isEmpty {
            let q = searchText
            events = events.filter {
                friendlyLabel(for: $0.action).localizedCaseInsensitiveContains(q) ||
                $0.action.localizedCaseInsensitiveContains(q) ||
                $0.source.localizedCaseInsensitiveContains(q) ||
                ($0.details ?? "").localizedCaseInsensitiveContains(q)
            }
        }
        switch activeFilter {
        case .all:
            break
        case .changes:
            // Only entries that actually mutated a contact — SyncEngine logs
            // those under the `change.*` namespace, plus the merge decisions
            // the user made by hand.
            events = events.filter {
                let action = $0.action.lowercased()
                return action.hasPrefix("change.")
                    || ["add", "update", "delete", "automerge", "usermerge", "keepseparate"]
                        .contains(action)
            }
        case .errors:
            events = events.filter {
                let action = $0.action.lowercased()
                return action.contains("error")
                    || action.contains("fail")
                    || action.contains("warn")
            }
        }
        return events.reversed()
    }

    private var groupedEvents: [(String, [SyncEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filteredEvents) { event -> String in
            if cal.isDateInToday(event.timestamp)     { return "Today" }
            if cal.isDateInYesterday(event.timestamp) { return "Yesterday" }
            let f = DateFormatter()
            f.dateStyle = .medium
            return f.string(from: event.timestamp)
        }
        // Sort groups: Today first, Yesterday second, rest by date descending
        let order = ["Today", "Yesterday"]
        let sorted = grouped.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a > b // date strings sort descending
        }
        return sorted.compactMap { key in
            guard let events = grouped[key] else { return nil }
            return (key, events)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Sync History")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Export Log") { exportLog() }
                    .buttonStyle(.bordered)
                    .alert("Couldn't export the log",
                           isPresented: .constant(exportError != nil)) {
                        Button("OK") { exportError = nil }
                    } message: {
                        Text(exportError ?? "")
                    }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            // Search + filter
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search history", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Segmented control rather than custom chips: three mutually
                // exclusive views of one list is exactly what NSSegmentedControl
                // is for, and it picks up keyboard focus and VoiceOver for free.
                Picker("Filter history", selection: $activeFilter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { filter in
                        Text(filter.localizedTitle).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Filter history")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // Events list
            if groupedEvents.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No sync history yet" : "No results for \"\(searchText)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if searchText.isEmpty {
                        Text("Run your first sync to see activity here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(groupedEvents, id: \.0) { (group, events) in
                        Section(group) {
                            ForEach(events) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear { allEvents = SyncHistory.shared.events() }
    }

    // MARK: - Row

    private func eventRow(_ event: SyncEvent) -> some View {
        let isExpanded = expandedIDs.contains(event.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedIDs.remove(event.id) }
                    else          { expandedIDs.insert(event.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: eventIcon(event))
                        .foregroundStyle(eventColor(event))
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(friendlyLabel(for: event.action))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(event.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(event.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let detail = event.details {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Filter Chip

    // MARK: - Helpers

    private func friendlyLabel(for action: String) -> String {
        switch action {
        case "sync.complete":                       return String(localized: "Sync completed")
        case "sync.start", "scanForDuplicates.start": return String(localized: "Sync started")
        case "add", "change.add":                   return String(localized: "Contact added")
        case "update", "change.update":             return String(localized: "Contact updated")
        case "delete", "change.delete":             return String(localized: "Contact deleted")
        case "change.merge":                        return String(localized: "Contacts merged")
        case "change.failed":                       return String(localized: "Change failed")
        case "merge.deferred":                      return String(localized: "Conflict flagged for review")
        case "autoMerge":                           return String(localized: "Duplicates auto-merged")
        case "userMerge":                           return String(localized: "Duplicates merged")
        case "keepSeparate":                        return String(localized: "Contacts kept separate")
        case "skippedDuplicatesNotification":       return String(localized: "Duplicates skipped (auto-sync)")
        case "createMappingFromMerge":              return String(localized: "Contact mapping created")
        case "clearPatterns":                       return String(localized: "Saved patterns cleared")
        case "preSyncBackup.failed",
             "postSyncBackup.failed":               return String(localized: "Backup failed")
        case "request.retrying":                    return String(localized: "Retrying after rate limit")
        case "cnContactStoreDidChange":             return String(localized: "Mac contacts changed")
        default:
            // The old fallback ran `.capitalized` over a dotted identifier, which
            // turned "cnContactStoreDidChange" into "Cncontactstoredidchange" —
            // unreadable in any language. Split on case boundaries instead and
            // leave it in the development language rather than mangling it.
            return action
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .splitCamelCaseWords()
        }
    }

    private func eventIcon(_ event: SyncEvent) -> String {
        let a = event.action
        if a.contains("error") || a.contains("Error") { return "xmark.circle.fill" }
        if a.contains("warn")  || a.contains("Warn")  { return "exclamationmark.triangle.fill" }
        switch a {
        case "sync.complete":          return "checkmark.circle.fill"
        case "sync.start", "scanForDuplicates.start": return "arrow.triangle.2.circlepath"
        case "add":                    return "plus.circle.fill"
        case "update":                 return "pencil.circle.fill"
        case "delete":                 return "minus.circle.fill"
        case "merge.deferred":         return "exclamationmark.triangle.fill"
        case "autoMerge", "userMerge": return "arrow.triangle.merge"
        case "keepSeparate":           return "xmark.circle"
        default:                       return "clock.fill"
        }
    }

    private func eventColor(_ event: SyncEvent) -> Color {
        let a = event.action
        if a.contains("error") || a.contains("Error") { return .red }
        if a.contains("warn")  || a.contains("Warn")  { return .orange }
        switch a {
        case "sync.complete":          return .green
        case "sync.start", "scanForDuplicates.start": return Color.accentColor
        case "add":                    return .green
        case "update":                 return .blue
        case "delete":                 return .red
        case "merge.deferred":         return .orange
        case "autoMerge", "userMerge": return .purple
        default:                       return .secondary
        }
    }

    /// Export the history as JSON to a location the user picks.
    ///
    /// The previous implementation wrote to
    /// `FileManager.urls(for: .downloadsDirectory)` and swallowed every failure
    /// with `guard … else { return }` and `try?`. Under App Sandbox that path
    /// resolves to the *container's* Downloads folder, and writing to the real
    /// one needs `files.downloads.read-write`, which this app deliberately does
    /// not request. So the button silently did nothing.
    ///
    /// `NSSavePanel` is the sandbox-correct route: the user's choice carries an
    /// implicit grant via `files.user-selected.read-write`, which we do hold.
    private func exportLog() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(SyncHistory.shared.events())
        } catch {
            exportError = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Log")
        panel.nameFieldStringValue = "contact-syncmate-history.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
            SyncHistory.shared.log(source: "SyncHistoryView",
                                   action: "exportLog.failed",
                                   details: error.localizedDescription)
        }
    }
}

#Preview {
    SyncHistoryView()
}
