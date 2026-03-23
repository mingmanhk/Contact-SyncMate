//
//  ContentView.swift
//  Contact SyncMate
//

import SwiftUI

/// Root view — shows OnboardingView until setup is complete, then DashboardView.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                DashboardView()
                    .environmentObject(appState)
            } else {
                // Placeholder while onboarding sheet is up
                ZStack {
                    Color.clear
                }
                .onAppear { showOnboarding = true }
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            // If user dismissed without completing, mark complete anyway
            // so they're not stuck. They can reconfigure in Settings.
            settings.hasCompletedOnboarding = true
        }) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
