//
//  SyncHistoryView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - History Filter

private enum HistoryFilter: String, CaseIterable {
    case all      = "All"
    case success  = "Success"
    case warnings = "Warnings"
    case errors   = "Errors"
}

// MARK: - Sync History View

struct SyncHistoryView: View {
    @State private var allEvents: [SyncEvent] = []
    @State private var activeFilter: HistoryFilter = .all
    @State private var searchText = ""
    @State private var expandedIDs: Set<UUID> = []

    private var filteredEvents: [SyncEvent] {
        var events = allEvents
        if !searchText.isEmpty {
            events = events.filter {
                $0.action.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText) ||
                ($0.details ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        // Simple filter by action keyword (no separate success/error status on SyncEvent)
        switch activeFilter {
        case .all:      break
        case .success:  events = events.filter { !$0.action.lowercased().contains("error") && !$0.action.lowercased().contains("warn") }
        case .warnings: events = events.filter { $0.action.lowercased().contains("warn") }
        case .errors:   events = events.filter { $0.action.lowercased().contains("error") }
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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HistoryFilter.allCases, id: \.self) { filter in
                            filterChip(filter)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // Events list
            if groupedEvents.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No history found.")
                        .foregroundStyle(.secondary)
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
                        Text(event.action)
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

    private func filterChip(_ filter: HistoryFilter) -> some View {
        let selected = activeFilter == filter
        return Button(filter.rawValue) { activeFilter = filter }
            .buttonStyle(.plain)
            .font(.subheadline)
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selected ? Color("BrandIndigo") : Color.secondary.opacity(0.1))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: selected)
    }

    // MARK: - Helpers

    private func eventIcon(_ event: SyncEvent) -> String {
        let a = event.action.lowercased()
        if a.contains("error") { return "xmark.circle.fill" }
        if a.contains("warn")  { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func eventColor(_ event: SyncEvent) -> Color {
        let a = event.action.lowercased()
        if a.contains("error") { return .red }
        if a.contains("warn")  { return .orange }
        return .green
    }

    private func exportLog() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(SyncHistory.shared.events()),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let url = downloads.appendingPathComponent("contact_syncmate_history.json")
        try? data.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

#Preview {
    SyncHistoryView()
}
