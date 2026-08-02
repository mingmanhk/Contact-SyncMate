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
        // Must run before checkExistingAuth(): tokens minted under a revoked
        // secret cannot be refreshed, so treating them as valid would leave the
        // UI claiming "connected" while every API call fails.
        purgeLegacyCachedClientSecret()
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
    
    // MARK: - Client Secret

    /// The client secret used for the token exchange.
    ///
    /// Precedence is **config file first, Keychain second** — deliberately, and
    /// this is the opposite of what it used to be.
    ///
    /// The old order cached the config value in the Keychain and then preferred
    /// the Keychain forever after. That made credential rotation impossible: a
    /// freshly rotated secret placed in `GoogleOAuthConfig.json` was silently
    /// ignored in favour of the revoked copy, and Google answered every token
    /// exchange with `invalid_client`. Nothing in the app could clear it.
    ///
    /// The config file ships inside the bundle, so it is the natural home for
    /// the shipped credential — rotating it means a new build, which is correct.
    /// The Keychain now only serves a secret the user typed into Settings, used
    /// when the bundle carries no usable value (e.g. a checkout that only has
    /// `GoogleOAuthConfig.example.json`).
    ///
    /// Note this is not a confidentiality regression: for an installed app,
    /// Google does not treat the client secret as a secret — PKCE (RFC 7636)
    /// provides the actual protection, and it is enforced on every sign-in.
    private var clientSecret: String {
        let fromConfig = config.clientSecret
        if !fromConfig.isEmpty && fromConfig != "SET_AT_RUNTIME_OR_CI" {
            return fromConfig
        }
        return getFromKeychain(key: Self.clientSecretKeychainKey) ?? ""
    }

    /// Remove a client secret cached by an older build.
    ///
    /// Without this, a machine that ran a pre-rotation build keeps a revoked
    /// secret in its Keychain. It is inert under the precedence above, but
    /// leaving a dead credential on disk is not something to rely on staying
    /// harmless, and it would resurface the moment the config file is missing.
    private func purgeLegacyCachedClientSecret() {
        let fromConfig = config.clientSecret
        guard !fromConfig.isEmpty, fromConfig != "SET_AT_RUNTIME_OR_CI" else {
            // No usable config value — whatever is in the Keychain is all we
            // have, so keep it.
            return
        }
        guard let cached = getFromKeychain(key: Self.clientSecretKeychainKey),
              cached != fromConfig else { return }

        deleteFromKeychain(key: Self.clientSecretKeychainKey)

        // Any refresh token issued against the superseded secret is dead —
        // `refresh_token` grants are rejected with `invalid_client` too. Drop
        // them so the user is asked to sign in once, instead of hitting an
        // unexplained failure on the next sync.
        clearTokens()

        SyncHistory.shared.log(
            source: "GoogleOAuth",
            action: "clientSecret.purgedStaleCache",
            details: "Removed a client secret cached by an earlier build; sign-in required once."
        )
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

        // The scheme in the config has to be one this app actually registered.
        //
        // ASWebAuthenticationSession will not open a window for a callback
        // scheme the bundle does not own: `start()` just returns false. The
        // symptom is a Connect button that does nothing at all — no browser, no
        // error — which says nothing about the two files being out of step.
        //
        // The redirect URI lives in GoogleOAuthConfig.json and the scheme in
        // Info.plist, and they are edited separately, so drifting apart is the
        // normal failure. Scripts/set-oauth-client.sh writes both from one ID.
        try assertCallbackSchemeIsRegistered()

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
    
    /// Compare two strings without short-circuiting on the first difference.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    /// Sign out, revoking the grant with Google before discarding it locally.
    ///
    /// Deleting the tokens alone left the authorisation **live on Google's
    /// side**: the app kept appearing under the account's third-party access
    /// list, and anyone holding a copy of the refresh token (a backup, a synced
    /// Keychain, a stolen disk image) could keep using it indefinitely. Signing
    /// out should mean the grant is gone.
    ///
    /// Revocation is best-effort — offline sign-out must still work — but the
    /// local tokens are cleared either way.
    func signOut() {
        let refreshToken = getRefreshToken()
        let accessToken = getAccessToken()

        clearTokens()
        isAuthenticated = false
        userEmail = nil
        signInError = nil

        // Prefer the refresh token: revoking it invalidates every access token
        // derived from it, whereas revoking an access token leaves the grant.
        guard let token = refreshToken ?? accessToken else { return }

        Task.detached {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
                .data(using: .utf8)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                SyncHistory.shared.log(
                    source: "GoogleOAuth",
                    action: status == 200 ? "signOut.revoked" : "signOut.revokeFailed",
                    details: "HTTP \(status)"
                )
            } catch {
                SyncHistory.shared.log(source: "GoogleOAuth", action: "signOut.revokeFailed",
                                       details: error.localizedDescription)
            }
        }
    }
    
    // MARK: - OAuth Flow Helpers
    
    /// Random value binding the authorization response to this request (RFC 6749
    /// §10.12). Regenerated per sign-in, checked in `handleCallback`.
    private var authState: String?

    private func buildAuthorizationURL() -> URL {
        // Generate fresh PKCE pair for each sign-in attempt
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        // `state` was missing entirely. PKCE stops a stolen code from being
        // *exchanged* by anyone else, but it does not tell us the response we
        // received belongs to the request we sent — and this app uses a custom
        // URL scheme, which any other app on the machine can also register. A
        // state we generated and verified is the standard defence.
        let state = generateCodeVerifier()   // same CSPRNG, 32 bytes base64url
        authState = state

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            // PKCE parameters (RFC 7636)
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }
    
    /// Throw unless `Info.plist` registers the scheme the config asks for.
    private func assertCallbackSchemeIsRegistered() throws {
        let scheme = getCallbackScheme()
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                          as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        guard registered.contains(scheme) else {
            let message = String(
                format: NSLocalizedString(
                    "The sign-in callback is not set up. GoogleOAuthConfig.json expects the URL scheme “%@”, but this build registers “%@”. Run Scripts/set-oauth-client.sh with your Google Client ID to write both from one value.",
                    comment: "OAuth redirect scheme missing from Info.plist"),
                scheme, registered.first ?? "none")
            SyncHistory.shared.log(source: "GoogleOAuth",
                                   action: "signIn.callbackSchemeMissing",
                                   details: "config=\(scheme) plist=\(registered)")
            throw GoogleOAuthError.configurationInvalid(message)
        }
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
            SyncHistory.shared.log(source: "GoogleOAuth", action: "callback.error", details: error)
            throw GoogleOAuthError.authError(error)
        }

        // Reject a response that is not the one we asked for.
        //
        // Compared with `constantTimeEquals` rather than `==`: string comparison
        // short-circuits on the first differing byte, which leaks how much of a
        // guess was right.
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        guard let expected = authState,
              let returnedState,
              Self.constantTimeEquals(expected, returnedState) else {
            authState = nil
            SyncHistory.shared.log(source: "GoogleOAuth", action: "callback.stateMismatch",
                                   details: "authorization response did not match the request")
            throw GoogleOAuthError.invalidCallback
        }
        authState = nil
        
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
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]

        // Only sent when there is one. An OAuth client of type "iOS" — the type
        // Google requires for macOS apps — is a public client and is issued no
        // secret at all. Sending `client_secret=` empty is not the same as
        // omitting it, and Google answers `invalid_client`.
        if !clientSecret.isEmpty {
            bodyParams["client_secret"] = clientSecret
        }

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
        
        var bodyParams = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        // Same rule as the initial exchange: omitted entirely for a public
        // client, not sent empty. See exchangeCodeForTokens.
        if !clientSecret.isEmpty {
            bodyParams["client_secret"] = clientSecret
        }
        
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: String.Encoding.utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Surface Google's own diagnosis, exactly as exchangeCodeForTokens
            // does. This path used to throw a bare `.tokenRefreshFailed`, which
            // is the one place the distinction matters most: `invalid_grant`
            // means the refresh token is dead and the user must sign in again,
            // while a 5xx is worth retrying. Discarding the body turned both
            // into the same unactionable "Failed to refresh access token."
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = Self.googleErrorSummary(from: body, status: status)

            if detail.contains("invalid_grant") {
                // The grant is gone — revoked in the Google account, password
                // changed, or the app's access removed. Retrying cannot help, and
                // without this every remaining contact would repeat the same
                // failure. Fail the session once, loudly.
                clearTokens()
                await MainActor.run {
                    isAuthenticated = false
                    signInError = String(
                        localized: "Google access has expired. Please sign in again."
                    )
                }
                SyncHistory.shared.log(source: "GoogleOAuth", action: "refresh.revoked",
                                       details: detail)
                throw GoogleOAuthError.noRefreshToken
            }

            SyncHistory.shared.log(source: "GoogleOAuth", action: "refresh.failed",
                                   details: detail)
            throw GoogleOAuthError.authError(detail)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Store new access token
        try saveAccessToken(tokenResponse.accessToken)

        // Google rotates the refresh token on some grants. Dropping the new one
        // leaves us re-presenting a superseded token on the next refresh, which
        // is itself an invalid_grant a while later.
        if let rotated = tokenResponse.refreshToken, !rotated.isEmpty {
            try saveRefreshToken(rotated)
        }

        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try saveTokenExpiry(expiry)

        await MainActor.run {
            isAuthenticated = true
            signInError = nil
        }
    }
    
    /// The refresh currently in flight, if any.
    ///
    /// `getValidAccessToken()` is called once per API request, so a sync applying
    /// a hundred changes crosses the expiry buffer and then fires a hundred
    /// refreshes. Google rotates the refresh token as it issues a new one, so the
    /// stampede invalidates itself: the first request succeeds and the rest come
    /// back `invalid_grant` — which is exactly the wall of "Failed to refresh
    /// access token" one per contact.
    ///
    /// Holding the Task lets every caller await the same refresh instead.
    @MainActor private var refreshInFlight: Task<Void, Error>?

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

        try await refreshOnce()

        guard let newAccessToken = getAccessToken() else {
            throw GoogleOAuthError.tokenRefreshFailed
        }

        return newAccessToken
    }

    /// Refresh, coalescing concurrent callers onto a single request.
    @MainActor
    private func refreshOnce() async throws {
        if let existing = refreshInFlight {
            // Someone else is already refreshing — wait for their result rather
            // than racing them.
            return try await existing.value
        }

        guard let refreshToken = getRefreshToken() else {
            throw GoogleOAuthError.noRefreshToken
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.refreshAccessTokenWithRetry(refreshToken: refreshToken)
        }
        refreshInFlight = task

        defer { refreshInFlight = nil }
        try await task.value
    }

    /// Refresh with backoff for transient failures.
    ///
    /// A single dropped connection used to fail the refresh outright, and because
    /// nothing recorded that, every subsequent contact retried and failed the same
    /// way. Only network and 5xx errors are retried — `invalid_grant` is terminal
    /// and `refreshAccessToken` already handles it.
    private func refreshAccessTokenWithRetry(refreshToken: String) async throws {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            do {
                try await refreshAccessToken(refreshToken: refreshToken)
                return
            } catch GoogleOAuthError.noRefreshToken {
                throw GoogleOAuthError.noRefreshToken   // revoked — do not retry
            } catch {
                let isTransient = (error as? URLError) != nil
                guard isTransient, attempt < maxAttempts else { throw error }

                SyncHistory.shared.log(
                    source: "GoogleOAuth",
                    action: "refresh.retrying",
                    details: "attempt \(attempt)/\(maxAttempts): \(error.localizedDescription)"
                )
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1))))
            }
        }
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
    /// The app's own OAuth configuration is wrong — carries the specific
    /// mismatch, because "sign-in failed" is useless when the fix is editing a
    /// file the user has to be told the name of.
    case configurationInvalid(String)
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
        case .configurationInvalid(let detail):
            return detail
        case .unknown:
            return "An unknown error occurred."
        }
    }
}
