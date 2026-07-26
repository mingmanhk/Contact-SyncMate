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
            // Top bar: step counter + Skip
            HStack {
                Text("Step \(currentStep + 1) of \(kTotalSteps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if currentStep < kTotalSteps - 1 {
                    Button("Skip setup") {
                        settings.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * (Double(currentStep + 1) / Double(kTotalSteps)), height: 4)
                        .animation(.spring(response: 0.4), value: currentStep)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 32)
            .padding(.bottom, 4)

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
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { currentStep -= 1 }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if currentStep < kTotalSteps - 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { currentStep += 1 }
                    } label: {
                        Label("Continue", systemImage: "chevron.right")
                            .labelStyle(RightIconLabelStyle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                } else {
                    Button {
                        settings.hasCompletedOnboarding = true
                        isPresented = false
                    } label: {
                        Label("Get Started", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - Label style helper (icon on the right)
private struct RightIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Step 1: Welcome

private struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor.gradient)

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
            .background(Color.accentColor.opacity(0.08))
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
                Label(email, systemImage: AppIcon.statusSuccess)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appSuccess)
                    .fontWeight(.medium)
            } else {
                Button(isConnecting ? "Connecting…" : "Connect Google Account") {
                    isConnecting = true
                    GoogleOAuthManager.shared.startSignInFromCurrentWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isConnecting = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appSourceGoogle)
                .disabled(isConnecting)
            }

            // A failed bind used to be completely silent here: the consent
            // screen closed and the button simply went back to its idle state.
            if !oauth.isAuthenticated, let failure = oauth.signInError {
                Label(failure, systemImage: AppIcon.statusError)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appError)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .textSelection(.enabled)
                    .accessibilityLabel("Sign-in failed: \(failure)")
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
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 72))
                .foregroundStyle(Color.appSuccess.gradient)

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
                Label("Access granted", systemImage: AppIcon.statusSuccess)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appSuccess)
                    .fontWeight(.medium)

            case .denied, .restricted:
                VStack(spacing: 8) {
                    Label("Access denied", systemImage: AppIcon.statusError)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appError)
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
                .tint(Color.appAccent)
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
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor.gradient)

            VStack(spacing: 6) {
                Text("Choose Your Sync Direction")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("You can always change this later in Preferences.")
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
            .frame(maxWidth: 380)

            // Rich description card for selected direction
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: settings.autoSyncDirection.strategyIcon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.autoSyncDirection.strategyTitle)
                        .fontWeight(.semibold)
                    Text(settings.autoSyncDirection.strategySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: 380, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.2), value: settings.autoSyncDirection)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - SyncDirection Helpers (Onboarding)

private extension SyncDirection {
    var strategyTitle: String {
        switch self {
        case .twoWay:      return "2-Way Sync (Recommended)"
        case .googleToMac: return "Google is the master"
        case .macToGoogle: return "Mac is the master"
        }
    }

    var strategyIcon: String {
        switch self {
        case .twoWay:      return "arrow.triangle.2.circlepath"
        case .googleToMac: return "arrow.right.circle.fill"
        case .macToGoogle: return "arrow.left.circle.fill"
        }
    }

    var strategySummary: String {
        switch self {
        case .twoWay:
            return "Additions, edits and deletions on either side are merged and kept in sync. Best for most people."
        case .googleToMac:
            return "Google Contacts are the source of truth. Changes you make in Google flow to Mac; Mac-only changes are not propagated back."
        case .macToGoogle:
            return "Mac Contacts are the source of truth. Changes you make on Mac flow to Google; Google-only changes are not propagated back."
        }
    }
}
