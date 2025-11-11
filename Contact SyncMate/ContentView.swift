//
//  ContentView.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import SwiftUI

/// Main content view - primarily used for onboarding flow
/// The app mainly runs as a menu bar utility
struct ContentView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var showOnboarding = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Contact SyncMate")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Keep your Google and Mac contacts in perfect sync")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
                .padding(.vertical)
            
            if !settings.hasCompletedOnboarding {
                VStack(spacing: 12) {
                    Text("Welcome! Let's get you set up.")
                        .font(.headline)
                    
                    Button("Start Setup") {
                        showOnboarding = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                VStack(spacing: 12) {
                    Text("✓ Setup Complete")
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Text("Contact SyncMate is running in your menu bar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 16) {
                        Button("Open Settings") {
                            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                        }
                        
                        Button("Run Sync") {
                            // TODO: Trigger sync
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top)
                }
            }
            
            Spacer()
            
            Text("Look for the  icon in your menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @StateObject private var settings = AppSettings.shared
    @State private var currentStep = 0
    
    private let totalSteps = 5
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
            }
            .padding()
            
            // Content
            TabView(selection: $currentStep) {
                WelcomeStepView()
                    .tag(0)
                
                PermissionsStepView()
                    .tag(1)
                
                GoogleAccountStepView()
                    .tag(2)
                
                MacAccountStepView()
                    .tag(3)
                
                SyncStrategyStepView()
                    .tag(4)
            }
            .tabViewStyle(.automatic)
            
            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                }
                
                Spacer()
                
                if currentStep < totalSteps - 1 {
                    Button("Next") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        settings.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Onboarding Steps

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Welcome to Contact SyncMate")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Keep your Google Contacts and Mac Contacts in perfect sync")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 12) {
                Label("2-way and 1-way sync modes", systemImage: "arrow.triangle.2.circlepath")
                Label("Manual preview before syncing", systemImage: "eye")
                Label("Automatic background sync", systemImage: "clock.arrow.circlepath")
                Label("100% private - all sync runs locally", systemImage: "lock.shield")
            }
            .padding()
            .background(Color.accentColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding()
    }
}

struct PermissionsStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Contact SyncMate needs access to your Mac contacts")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("When prompted:")
                    .font(.headline)
                
                Text("1. Click \"OK\" to allow Contacts access")
                Text("2. If needed, open System Settings → Privacy & Security → Contacts")
                Text("3. Make sure Contact SyncMate is checked")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Button("Request Access") {
                // TODO: Request Contacts permission
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct GoogleAccountStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            Text("Connect Google")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Sign in to your Google account to sync contacts")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy Notice:")
                    .font(.headline)
                
                Text("• Your contacts stay on your device")
                Text("• Only Google and Mac can access your data")
                Text("• No third-party servers involved")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Button("Sign In with Google") {
                GoogleOAuthManager.shared.startSignInFromCurrentWindow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct MacAccountStepView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Mac Account")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Choose which Mac contacts to sync")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                ForEach(MacAccountMode.allCases, id: \.self) { mode in
                    Button(action: {
                        settings.macAccountMode = mode
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(mode.rawValue)
                                    .font(.headline)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.macAccountMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding()
                        .background(settings.macAccountMode == mode ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }
}

struct SyncStrategyStepView: View {
    @State private var selectedStrategy = SyncDirection.twoWay
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 60))
                .foregroundStyle(.purple)
            
            Text("Initial Sync Strategy")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("How should we handle your first sync?")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                StrategyButton(
                    title: "2-Way Sync",
                    description: "Merge and reconcile both Google and Mac",
                    icon: "arrow.left.arrow.right",
                    strategy: .twoWay,
                    selected: $selectedStrategy
                )
                
                StrategyButton(
                    title: "Google → Mac",
                    description: "Use Google as master, update Mac",
                    icon: "arrow.right",
                    strategy: .googleToMac,
                    selected: $selectedStrategy
                )
                
                StrategyButton(
                    title: "Mac → Google",
                    description: "Use Mac as master, update Google",
                    icon: "arrow.left",
                    strategy: .macToGoogle,
                    selected: $selectedStrategy
                )
            }
            
            Text("💡 Tip: Clean duplicates in Google Contacts first")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct StrategyButton: View {
    let title: String
    let description: String
    let icon: String
    let strategy: SyncDirection
    @Binding var selected: SyncDirection
    
    var body: some View {
        Button(action: {
            selected = strategy
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 30)
                
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if selected == strategy {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .background(selected == strategy ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
