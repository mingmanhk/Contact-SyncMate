//
//  GoogleOAuthManager.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
import AuthenticationServices
import Security
import CryptoKit
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
    // Client ID is loaded from GoogleOAuthConfig (public, safe to embed).
    // Client secret is stored in the macOS Keychain (never in plain-text files).
    private let config = GoogleOAuthConfig()
    private var clientId: String { config.clientId }
    private var redirectURI: String { config.redirectURI }

    // PKCE (Proof Key for Code Exchange) — industry standard per RFC 7636 / OAuth 2.1
    private var codeVerifier: String?

    // Keychain key for the client secret
    private static let clientSecretKeychainKey = "GoogleOAuthClientSecret"
    
    // Scopes needed for Google People API.
    //
    // Deliberately minimal — every scope here must be justified during OAuth
    // verification, and each sensitive scope lengthens review.
    //   • contacts        — required: two-way sync needs read AND write.
    //   • userinfo.email  — required: shows which account is connected in the UI.
    //
    // Removed: contacts.other.readonly ("Other contacts" auto-collected by
    // Gmail). It was requested but never read by any code path, and it is a
    // sensitive scope, so asking for it was pure liability.
    private let scopes = [
        "https://www.googleapis.com/auth/contacts",
        "https://www.googleapis.com/auth/userinfo.email"
    ]
    
    @Published var isAuthenticated = false
    @Published var userEmail: String?

    /// Human-readable reason the last sign-in attempt failed, or `nil` if the
    /// last attempt succeeded / none has been made. Shown in Accounts and in
    /// Onboarding so a failed bind is never silent.
    @Published var signInError: String?


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
    
    // MARK: - Client Secret (Keychain-backed)

    /// Retrieve the client secret from the Keychain.
    /// On first launch the secret is migrated from GoogleOAuthConfig.json into the
    /// Keychain and then the JSON value is no longer needed.
    private var clientSecret: String {
        // Try Keychain first
        if let stored = getFromKeychain(key: Self.clientSecretKeychainKey) {
            return stored
        }
        // Fall back to config file for first-run migration
        let fromConfig = config.clientSecret
        if !fromConfig.isEmpty && fromConfig != "SET_AT_RUNTIME_OR_CI" {
            try? saveToKeychain(key: Self.clientSecretKeychainKey, value: fromConfig)
            return fromConfig
        }
        return ""
    }

    /// Turn Google's JSON error payload into one readable line.
    /// Never echoes the request body, so no secret can leak into a log or the UI.
    static func googleErrorSummary(from body: String, status: Int) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "HTTP \(status)"
        }
        let code = json["error"] as? String ?? "HTTP \(status)"
        if let description = json["error_description"] as? String, !description.isEmpty {
            return "\(code): \(description)"
        }
        return code
    }

    /// Manually store a client secret in the Keychain (e.g. from Settings UI).
    func setClientSecret(_ secret: String) throws {
        try saveToKeychain(key: Self.clientSecretKeychainKey, value: secret)
    }

    // MARK: - PKCE Helpers (RFC 7636)

    /// Generate a cryptographically random code verifier (43–128 chars, URL-safe).
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Derive the S256 code challenge from a code verifier.
    private func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Sign In

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
                
                guard let session = self.authSession else {
                    if !isResumed {
                        isResumed = true
                        continuation.resume(throwing: GoogleOAuthError.sessionStartFailed)
                    }
                    return
                }
                if !session.start() {
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
        // Switch to regular activation policy so the OAuth browser sheet
        // has a window to anchor to.  We intentionally do NOT restore
        // .accessory afterwards — that would hide the app and make it
        // look like a crash.  The user's activation-policy preference
        // is applied the next time updateActivationPolicy() runs (e.g.
        // when a window is closed or the setting is toggled).
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }

        // Ensure the app is properly activated before showing OAuth
        NSApp.activate(ignoringOtherApps: true)

        signInError = nil

        Task { [weak self] in
            do {
                try await self?.signIn()
                await MainActor.run { self?.signInError = nil }
                SyncHistory.shared.log(source: "GoogleOAuth", action: "signIn.succeeded", details: "")
            } catch {
                // A silent failure here is what made this bug so hard to see:
                // the consent screen completes, then nothing happens. Publish
                // the reason so Accounts and Onboarding can both show it.
                let message = error.localizedDescription
                await MainActor.run { self?.signInError = message }
                SyncHistory.shared.log(source: "GoogleOAuth",
                                       action: "signIn.failed",
                                       details: message)
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
        // Generate fresh PKCE pair for each sign-in attempt
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            // PKCE parameters (RFC 7636)
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
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

        var bodyParams = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]

        // Include PKCE code_verifier (RFC 7636)
        if let verifier = codeVerifier {
            bodyParams["code_verifier"] = verifier
        }
        
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: String.Encoding.utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Surface Google's own diagnosis. `invalid_client` means the client
            // secret is wrong or missing; `redirect_uri_mismatch` means the URI
            // registered in Cloud Console does not match `redirectURI`. Guessing
            // between those without the payload wastes hours.
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = Self.googleErrorSummary(from: body, status: status)
            throw GoogleOAuthError.tokenExchangeFailed(detail)
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
    /// Carries Google's own error payload (e.g. `invalid_client`,
    /// `redirect_uri_mismatch`). Without it the user sees a generic failure
    /// and has nothing actionable to go on.
    case tokenExchangeFailed(String)
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
        case .tokenExchangeFailed(let detail):
            return detail.isEmpty
                ? "Failed to exchange code for tokens."
                : "Failed to exchange code for tokens — \(detail)"
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
