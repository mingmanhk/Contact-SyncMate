//
//  SyncProgressView.swift
//  Contact SyncMate
//

import SwiftUI

// MARK: - Full-Window Sync Progress View

struct SyncProgressView: View {
    let progress: SyncProgress?

    @State private var rotation: Double = 0

    private var stepText: String { progress?.currentStep ?? "Preparing…" }
    private var fraction: Double  { progress?.percentage ?? 0 }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated infinity symbol
            Image(systemName: "infinity")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Color("BrandIndigo").gradient)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            VStack(spacing: 8) {
                Text("Syncing Contacts")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(stepText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let progress {
                VStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)

                    Text("\(progress.completedItems) of \(progress.totalItems)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    SyncProgressView(progress: SyncProgress(
        currentStep: "Fetching Google contacts",
        completedItems: 42,
        totalItems: 120
    ))
    .frame(width: 400, height: 300)
}
