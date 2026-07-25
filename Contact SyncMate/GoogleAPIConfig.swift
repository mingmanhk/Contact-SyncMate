import Foundation

/// Configuration for the Google API key (non-OAuth use cases).
///
/// SECURITY: The key is loaded at runtime from `GoogleOAuthConfig.json`
/// (gitignored) — never hardcode it in source. Add an `"apiKey"` entry to
/// that JSON:
///
///     { "clientId": "…", "redirectURI": "…", "apiKey": "AIza…" }
///
/// If the entry is absent the key is empty and API-key-based calls are
/// skipped gracefully (OAuth-based calls are unaffected).
struct GoogleAPIConfig {
    /// API key for Google services that accept API keys. Empty when not
    /// configured.
    let apiKey: String = {
        if let url = Bundle.main.url(forResource: "GoogleOAuthConfig", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let key = json["apiKey"], !key.isEmpty {
            return key
        }
        return ""
    }()
}
