//
//  StatusDot.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Status Dot State

enum SyncStatus {
    case idle
    case syncing
    case error

    var color: Color {
        switch self {
        case .idle:    return .green
        case .syncing: return .orange
        case .error:   return .red
        }
    }

    var label: String {
        switch self {
        case .idle:    return "Idle"
        case .syncing: return "Syncing…"
        case .error:   return "Error"
        }
    }
}

// MARK: - StatusDot View

struct StatusDot: View {
    let status: SyncStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .shadow(color: status.color.opacity(0.6), radius: pulse ? 6 : 2)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .animation(
                status == .syncing
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear {
                if status == .syncing { pulse = true }
            }
            .onChange(of: status) { _, newStatus in
                pulse = newStatus == .syncing
            }
    }
}

#Preview {
    HStack(spacing: 16) {
        StatusDot(status: .idle)
        StatusDot(status: .syncing)
        StatusDot(status: .error)
    }
    .padding()
}
