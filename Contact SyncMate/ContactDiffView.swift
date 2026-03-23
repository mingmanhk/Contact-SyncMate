//
//  ContactDiffView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Contact Conflict Model

struct ContactConflict: Identifiable {
    let id: UUID
    let contactName: String
    let googleFields: [String: String]   // field → value
    let macFields:    [String: String]
    let conflictingFields: [String]
    var resolution: ConflictResolution

    init(id: UUID = UUID(),
         contactName: String,
         googleFields: [String: String],
         macFields: [String: String],
         conflictingFields: [String],
         resolution: ConflictResolution = .useGoogle) {
        self.id = id
        self.contactName = contactName
        self.googleFields = googleFields
        self.macFields = macFields
        self.conflictingFields = conflictingFields
        self.resolution = resolution
    }

    /// Bridge from a ContactChange (for preview sheet → diff sheet flow)
    init(from change: ContactChange) {
        self.id = change.id
        self.contactName = change.contactName
        var google: [String: String] = [:]
        var mac: [String: String] = [:]
        var conflicts: [String] = []
        for desc in change.changes {
            // Parse "Field: old → new" pattern
            let parts = desc.components(separatedBy: ": ")
            if parts.count >= 2 {
                let field = parts[0]
                let values = parts[1].components(separatedBy: " → ")
                mac[field]    = values.first ?? "-"
                google[field] = values.last  ?? "-"
                conflicts.append(field)
            }
        }
        self.googleFields = google
        self.macFields    = mac
        self.conflictingFields = conflicts
        self.resolution = .useGoogle
    }
}

enum ConflictResolution: String, CaseIterable {
    case useGoogle = "Use Google"
    case useMac    = "Use Mac"
    case keepBoth  = "Keep Both"
    case skip      = "Skip"
}

// MARK: - Contact Diff View

struct ContactDiffView: View {
    let conflict: ContactConflict
    @Binding var isPresented: Bool

    @State private var resolution: ConflictResolution
    @State private var conflicts: [ContactConflict]
    @State private var currentIndex: Int = 0

    init(conflict: ContactConflict, isPresented: Binding<Bool>) {
        self.conflict = conflict
        self._isPresented = isPresented
        self._resolution = State(initialValue: conflict.resolution)
        self._conflicts = State(initialValue: [conflict])
    }

    private var current: ContactConflict { conflicts[currentIndex] }

    private var allFields: [String] {
        let keys = Set(current.googleFields.keys).union(current.macFields.keys)
        return keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.contactName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(currentIndex + 1) of \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Column headers
            HStack(spacing: 0) {
                Text("Field")
                    .frame(width: 120, alignment: .leading)
                    .fontWeight(.semibold)
                Divider()
                HStack {
                    Image(systemName: "g.circle.fill").foregroundStyle(.red)
                    Text("Google")
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
                Divider()
                HStack {
                    Image(systemName: "desktopcomputer").foregroundStyle(.blue)
                    Text("Mac")
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Field rows
            List {
                ForEach(allFields, id: \.self) { field in
                    let isConflict = current.conflictingFields.contains(field)
                    HStack(spacing: 0) {
                        Text(field)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)

                        Divider()

                        Text(current.googleFields[field] ?? "—")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .foregroundStyle(isConflict ? Color.orange : .primary)

                        Divider()

                        Text(current.macFields[field] ?? "—")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .foregroundStyle(isConflict ? Color.orange : .primary)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
                    .background(isConflict ? Color.orange.opacity(0.06) : .clear)
                }
            }
            .listStyle(.plain)

            Divider()

            // Resolution picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolution")
                    .font(.headline)

                Picker("Resolution", selection: $resolution) {
                    ForEach(ConflictResolution.allCases, id: \.self) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Navigation + apply
            HStack {
                // Prev / Next
                HStack(spacing: 8) {
                    Button("← Prev") {
                        if currentIndex > 0 { currentIndex -= 1 }
                    }
                    .disabled(currentIndex == 0)

                    Button("Next →") {
                        if currentIndex < conflicts.count - 1 { currentIndex += 1 }
                    }
                    .disabled(currentIndex >= conflicts.count - 1)
                }

                Spacer()

                Button("Apply Decision") {
                    conflicts[currentIndex].resolution = resolution
                    if currentIndex < conflicts.count - 1 {
                        currentIndex += 1
                        resolution = conflicts[currentIndex].resolution
                    } else {
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandIndigo"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 600, height: 520)
    }
}
