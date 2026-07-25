//
//  ContentView.swift
//  Contact SyncMate
//

import SwiftUI

/// Root view — shows OnboardingView until setup is complete, then DashboardView.
///
/// Onboarding is **only** marked complete when the user reaches the final
/// step inside `OnboardingView` (which sets `hasCompletedOnboarding = true`
/// before dismissing). If the user closes the sheet early, we keep showing
/// the onboarding gate next time the dashboard is opened — they are not
/// silently advanced past setup.
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
                OnboardingPlaceholderView { showOnboarding = true }
                    .onAppear { showOnboarding = true }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            // No `onDismiss` mutation: completion is the sheet's
            // responsibility, not the parent's.
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(appState)
        }
        // User-selected accent colour (Settings → General → Theme).
        .tint(settings.accentColorChoice.tint)
    }
}

/// Shown behind the onboarding sheet so the user can re-open it if they
/// dismiss the sheet without completing setup.
private struct OnboardingPlaceholderView: View {
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("Finish setting up Contact SyncMate")
                .font(.title3.weight(.semibold))

            Text("Connect your Google account and grant Contacts access to start syncing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Resume Setup", action: onResume)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
