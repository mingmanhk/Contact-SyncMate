//
//  GoogleOAuthManager.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import AuthenticationServices
import Security
import Combine
import AppKit

/// Manages Google OAuth 2.0 authentication flow
///
/// This manager handles all aspects of Google OAuth authentication including:
/// - Starting the OAuth flow with ASWebAuthenticationSession
/// - Handling callbacks and exchanging authorization codes for tokens
/// - Storing tokens securely in the keychain
/// - Refreshing expired tokens automatically
/// - Managing authentication state
///
/// ## Important Implementation Details
///
/// ### Menu Bar Mode Compatibility
/// The OAuth flow is designed to work even when the app is in menu bar only mode (`.accessory` activation policy).
/// The `startSignInFromCurrentWindow()` method temporarily switches to `.regular` mode during authentication
/// to ensure the browser window can be presented properly.
///
/// ### Window Presentation
/// The `presentationAnchor` method provides multiple fallback options for finding a valid window to present
/// the OAuth session, ensuring reliability across different app states.
///
/// ### Token Management
/// - Access tokens are automatically refreshed when they expire (with a 5-minute buffer)
/// - Refresh tokens are saved and reused across app launches
/// - All tokens are stored securely in the macOS keychain
///
/// ## Configuration Required
/// 1. Create `GoogleOAuthConfig.swift` with your Client ID, Client Secret, and Redirect URI
/// 2. Add the redirect URI scheme to `Info.plist` under `CFBundleURLSchemes`
/// 3. Configure the same redirect URI in Google Cloud Console
///
/// See `OAUTH_CONFIGURATION.md` for detailed setup instructions.
class GoogleOAuthManager: NSObject, ObservableObject {
    static let shared = GoogleOAuthManager()
    
    // MARK: - Google OAuth Configuration
    // Credentials are loaded from GoogleOAuthConfig.swift (kept in .gitignore)
    // Remember to update the URL Types scheme in your app's Info.plist
    // to match the redirect URI scheme, e.g. com.googleusercontent.apps.YOUR_CLIENT_ID
    private let config = GoogleOAuthConfig()
    private var clientId: String { config.clientId }
    private var clientSecret: String { config.clientSecret }
    private var redirectURI: String { config.redirectURI }
    
    // Scopes needed for Google People API
    private let scopes = [
        "https://www.googleapis.com/auth/contacts",
        "https://www.googleapis.com/auth/contacts.other.readonly",
        "https://www.googleapis.com/auth/userinfo.email"
    ]
    
    @Published var isAuthenticated = false
    @Published var userEmail: String?
    
    private var authSession: ASWebAuthenticationSession?
    
    // MARK: - Keychain Keys
    private let accessTokenKey = "GoogleAccessToken"
    private let refreshTokenKey = "GoogleRefreshToken"
    private let tokenExpiryKey = "GoogleTokenExpiry"
    
    override private init() {
        super.init()
        checkExistingAuth()
    }
    
    // MARK: - Authentication
    
    /// Check if we have valid stored credentials
    private func checkExistingAuth() {
        guard let _ = getAccessToken(),
              let expiry = getTokenExpiry() else {
            isAuthenticated = false
            return
        }
        
        // Check if token is still valid
        if expiry > Date() {
            isAuthenticated = true
            fetchUserEmail()
        } else if let refreshToken = getRefreshToken() {
            // Try to refresh the token
            Task {
                try? await refreshAccessToken(refreshToken: refreshToken)
            }
        }
    }
    
    /// Start OAuth flow
    func signIn() async throws {
        guard !getCallbackScheme().isEmpty,
              URL(string: redirectURI) != nil else {
            throw GoogleOAuthError.invalidCallback
        }
        
        let authURL = buildAuthorizationURL()
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: GoogleOAuthError.unknown)
                    return
                }
                
                var isResumed = false
                
                self.authSession = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: self.getCallbackScheme()
                ) { callbackURL, error in
                    guard !isResumed else { return }
                    
                    if let error = error {
                        isResumed = true
                        continuation.resume(throwing: GoogleOAuthError.authCancelled(error))
                        return
                    }
                    
                    guard let callbackURL = callbackURL else {
                        isResumed = true
                        continuation.resume(throwing: GoogleOAuthError.noCallbackURL)
                        return
                    }
                    
                    Task {
                        do {
                            try await self.handleCallback(url: callbackURL)
                            if !isResumed {
                                isResumed = true
                                continuation.resume()
                            }
                        } catch {
                            if !isResumed {
                                isResumed = true
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                
                self.authSession?.presentationContextProvider = self
                self.authSession?.prefersEphemeralWebBrowserSession = false
                
                if !self.authSession!.start() {
                    if !isResumed {
                        isResumed = true
                        continuation.resume(throwing: GoogleOAuthError.sessionStartFailed)
                    }
                }
            }
        }
    }
    
    @MainActor
    func startSignInFromCurrentWindow() {
        // Temporarily switch to regular activation policy for OAuth
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        
        // Ensure the app is properly activated before showing OAuth
        NSApp.activate(ignoringOtherApps: true)
        
        Task { [weak self] in
            do {
                try await self?.signIn()
                
                // Restore previous activation policy after OAuth completes
                await MainActor.run {
                    if previousPolicy == .accessory {
                        NSApp.setActivationPolicy(previousPolicy)
                    }
                }
            } catch {
                print("Google sign-in failed: \(error)")
                
                // Restore previous activation policy on error
                await MainActor.run {
                    if previousPolicy == .accessory {
                        NSApp.setActivationPolicy(previousPolicy)
                    }
                }
            }
        }
    }
    
    /// Sign out and clear tokens
    func signOut() {
        clearTokens()
        isAuthenticated = false
        userEmail = nil
    }
    
    // MARK: - OAuth Flow Helpers
    
    private func buildAuthorizationURL() -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }
    
    private func getCallbackScheme() -> String {
        // Extract scheme from redirect URI like: com.googleusercontent.apps.<CLIENT_ID>:/oauth2redirect
        let trimmed = redirectURI.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if let scheme = trimmed.components(separatedBy: ":").first, !scheme.isEmpty {
            return scheme
        }
        return ""
    }
    
    private func handleCallback(url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw GoogleOAuthError.invalidCallback
        }
        
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            print("Google OAuth error from callback: \(error)")
            throw GoogleOAuthError.authError(error)
        }
        
        // Extract authorization code
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw GoogleOAuthError.noAuthCode
        }
        
        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code)
    }
    
    private func exchangeCodeForTokens(code: String) async throws {
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: String.Encoding.utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleOAuthError.tokenExchangeFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        // Store tokens
        try saveAccessToken(tokenResponse.accessToken)
        if let refreshToken = tokenResponse.refreshToken {
            try saveRefreshToken(refreshToken)
        }
        
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try saveTokenExpiry(expiry)
        
        await MainActor.run {
            isAuthenticated = true
            userEmail = nil
        }
        
        // Fetch user email
        fetchUserEmail()
    }
    
    /// Refresh access token using refresh token
    func refreshAccessToken(refreshToken: String) async throws {
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: String.Encoding.utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleOAuthError.tokenRefreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        // Store new access token
        try saveAccessToken(tokenResponse.accessToken)
        
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try saveTokenExpiry(expiry)
        
        await MainActor.run {
            isAuthenticated = true
        }
    }
    
    /// Get valid access token (refreshing if needed)
    func getValidAccessToken() async throws -> String {
        guard let accessToken = getAccessToken(),
              let expiry = getTokenExpiry() else {
            throw GoogleOAuthError.notAuthenticated
        }
        
        // Check if token is still valid (with 5 minute buffer)
        if expiry > Date().addingTimeInterval(300) {
            return accessToken
        }
        
        // Token expired or about to expire, refresh it
        guard let refreshToken = getRefreshToken() else {
            throw GoogleOAuthError.noRefreshToken
        }
        
        try await refreshAccessToken(refreshToken: refreshToken)
        
        guard let newAccessToken = getAccessToken() else {
            throw GoogleOAuthError.tokenRefreshFailed
        }
        
        return newAccessToken
    }
    
    // MARK: - User Info
    
    private func fetchUserEmail() {
        Task {
            do {
                let token = try await getValidAccessToken()
                let url = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                let (data, _) = try await URLSession.shared.data(for: request)
                let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
                
                await MainActor.run {
                    self.userEmail = userInfo.email
                }
            } catch {
                print("Failed to fetch user email: \(error)")
            }
        }
    }
    
    // MARK: - Keychain Storage
    
    private func saveAccessToken(_ token: String) throws {
        try saveToKeychain(key: accessTokenKey, value: token)
    }
    
    private func getAccessToken() -> String? {
        return getFromKeychain(key: accessTokenKey)
    }
    
    private func saveRefreshToken(_ token: String) throws {
        try saveToKeychain(key: refreshTokenKey, value: token)
    }
    
    private func getRefreshToken() -> String? {
        return getFromKeychain(key: refreshTokenKey)
    }
    
    private func saveTokenExpiry(_ date: Date) throws {
        let timestamp = String(date.timeIntervalSince1970)
        try saveToKeychain(key: tokenExpiryKey, value: timestamp)
    }
    
    private func getTokenExpiry() -> Date? {
        guard let timestamp = getFromKeychain(key: tokenExpiryKey),
              let interval = TimeInterval(timestamp) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }
    
    private func clearTokens() {
        deleteFromKeychain(key: accessTokenKey)
        deleteFromKeychain(key: refreshTokenKey)
        deleteFromKeychain(key: tokenExpiryKey)
    }
    
    private func saveToKeychain(key: String, value: String) throws {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ContactSyncMate",
            kSecValueData as String: data
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GoogleOAuthError.keychainError(status)
        }
    }
    
    private func getFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ContactSyncMate",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ContactSyncMate"
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleOAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Ensure app is active
        NSApp.activate(ignoringOtherApps: true)
        
        // Try to find a valid window
        // 1. Key window
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        
        // 2. Main window
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        
        // 3. Any visible, on-screen window
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.isOnActiveSpace }) {
            return window
        }
        
        // 4. Settings window if it exists
        if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.identifier?.rawValue.contains("Settings") == true }) {
            settingsWindow.makeKeyAndOrderFront(nil)
            return settingsWindow
        }
        
        // 5. Any window at all
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            return window
        }
        
        // Last resort: create a temporary window
        // This should rarely happen, but provides a fallback
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

// MARK: - Models

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct UserInfo: Codable {
    let email: String
    let verifiedEmail: Bool?
    let name: String?
    let givenName: String?
    let familyName: String?
    let picture: String?
    
    enum CodingKeys: String, CodingKey {
        case email
        case verifiedEmail = "verified_email"
        case name
        case givenName = "given_name"
        case familyName = "family_name"
        case picture
    }
}

// MARK: - Errors

enum GoogleOAuthError: LocalizedError {
    case notAuthenticated
    case authCancelled(Error)
    case sessionStartFailed
    case noCallbackURL
    case invalidCallback
    case authError(String)
    case noAuthCode
    case tokenExchangeFailed
    case tokenRefreshFailed
    case noRefreshToken
    case keychainError(OSStatus)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please sign in first."
        case .authCancelled(let error):
            return "Authentication cancelled: \(error.localizedDescription)"
        case .sessionStartFailed:
            return "Failed to start authentication session."
        case .noCallbackURL:
            return "No callback URL received."
        case .invalidCallback:
            return "Invalid callback URL format."
        case .authError(let error):
            return "Authentication error: \(error)"
        case .noAuthCode:
            return "No authorization code received."
        case .tokenExchangeFailed:
            return "Failed to exchange code for tokens."
        case .tokenRefreshFailed:
            return "Failed to refresh access token."
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .unknown:
            return "An unknown error occurred."
        }
    }
}
