import Foundation

/// Configuration for Google API key (non-OAuth use cases)
///
/// IMPORTANT: Consider keeping this file out of version control or replacing
/// with a secure injection mechanism for production builds.
struct GoogleAPIConfig {
    /// API Key for Google services that accept API keys
    /// Provided by user. Replace if rotating keys.
    let apiKey: String = "AIzaSyAnXZ--26iMrwg1qtEeV31XUWuFa-c43lI"
}
