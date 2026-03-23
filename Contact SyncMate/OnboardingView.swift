//
//  OnboardingView.swift
//  Contact SyncMate
//

import SwiftUI
import Contacts

// MARK: - Constants

private let kTotalSteps = 4

// MARK: - Onboarding View

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @StateObject private var settings = AppSettings.shared
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<kTotalSteps, id: \.self) { idx in
                    Circle()
                        .fill(idx <= currentStep ? Color("BrandIndigo") : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut, value: currentStep)
                }
            }
            .padding(.top, 24)

            // Step content
            TabView(selection: $currentStep) {
                OnboardingWelcomeStep()
                    .tag(0)

                OnboardingGoogleStep()
                    .tag(1)

                OnboardingMacPermissionStep()
                    .tag(2)

                OnboardingSyncStrategyStep()
                    .tag(3)
            }
            .tabViewStyle(.automatic)
            .animation(.easeInOut, value: currentStep)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < kTotalSteps - 1 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandIndigo"))
                } else {
                    Button("Get Started") {
                        settings.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandIndigo"))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Step 1: Welcome

private struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color("BrandIndigo").gradient)

            VStack(spacing: 8) {
                Text("Welcome to Contact SyncMate")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Keep your Google and Mac contacts in perfect sync — privately, on your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "arrow.triangle.2.circlepath", text: "2-way and 1-way sync modes")
                FeatureRow(icon: "eye",                        text: "Preview every change before applying")
                FeatureRow(icon: "clock.arrow.circlepath",     text: "Automatic background sync")
                FeatureRow(icon: "lock.shield",                text: "100% private — runs entirely on your Mac")
            }
            .padding(16)
            .background(Color("BrandIndigo").opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.primary)
    }
}

// MARK: - Step 2: Google Account

private struct OnboardingGoogleStep: View {
    @State private var isConnecting = false
    @ObservedObject private var oauth = GoogleOAuthManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.red.gradient)

            VStack(spacing: 8) {
                Text("Connect Google Account")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Sign in so Contact SyncMate can access your Google Contacts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if oauth.isAuthenticated, let email = oauth.userEmail {
                Label(email, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            } else {
                Button(isConnecting ? "Connecting…" : "Connect Google Account") {
                    isConnecting = true
                    GoogleOAuthManager.shared.startSignInFromCurrentWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isConnecting = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isConnecting)
            }

            Text("Your contacts stay on your device. No third-party servers are involved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 3: Mac Contacts Permission

private struct OnboardingMacPermissionStep: View {
    @State private var authStatus: CNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green.gradient)

            VStack(spacing: 8) {
                Text("Allow Contacts Access")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Contact SyncMate needs permission to read and write your Mac contacts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            switch authStatus {
            case .authorized:
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)

            case .denied, .restricted:
                VStack(spacing: 8) {
                    Label("Access denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Open System Settings → Privacy & Security → Contacts and enable Contact SyncMate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

            default:
                Button(isRequesting ? "Requesting…" : "Allow Access") {
                    isRequesting = true
                    CNContactStore().requestAccess(for: .contacts) { granted, _ in
                        DispatchQueue.main.async {
                            authStatus = granted ? .authorized : .denied
                            isRequesting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isRequesting)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        .onAppear {
            authStatus = CNContactStore.authorizationStatus(for: .contacts)
        }
    }
}

// MARK: - Step 4: Sync Strategy

private struct OnboardingSyncStrategyStep: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 72))
                .foregroundStyle(Color("BrandIndigo").gradient)

            VStack(spacing: 8) {
                Text("Choose Sync Strategy")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("How should contacts be synced between Google and Mac?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker("Sync direction", selection: $settings.autoSyncDirection) {
                Text("2-Way").tag(SyncDirection.twoWay)
                Text("Google → Mac").tag(SyncDirection.googleToMac)
                Text("Mac → Google").tag(SyncDirection.macToGoogle)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Text(settings.autoSyncDirection.strategySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - SyncDirection Helpers

private extension SyncDirection {
    var strategySummary: String {
        switch self {
        case .twoWay:      return "Changes on either side are merged and synced in both directions."
        case .googleToMac: return "Google Contacts are the master copy. Mac contacts are kept in sync."
        case .macToGoogle: return "Mac Contacts are the master copy. Google contacts are kept in sync."
        }
    }
}
