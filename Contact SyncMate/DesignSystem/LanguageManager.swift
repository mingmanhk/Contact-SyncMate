import Foundation
import SwiftUI
import AppKit

/// Applies the user's interface-language choice.
///
/// ## Why this needs a relaunch
///
/// macOS resolves a bundle's localization **once**, when the bundle is first
/// loaded. `Bundle.main.localizedString(...)` — which every SwiftUI
/// `LocalizedStringKey` ultimately calls — reads a table chosen at that moment
/// from `AppleLanguages`. Writing a new value mid-session changes what the *next*
/// launch resolves, not the strings already bound into the running view tree.
///
/// The alternative is swizzling `Bundle.main` to return a per-language bundle on
/// every lookup. That works, but it silently breaks anything reading
/// `Locale.current` (date and number formatting, collation in the deduplicator,
/// `RelativeDateTimeFormatter` in Sync Status) because those follow the process
/// locale, not the swizzled bundle. The result is a half-translated app with
/// English dates — worse than asking for a relaunch.
///
/// So: persist the choice, offer to relaunch, and let the next launch resolve
/// everything consistently.
/// Not an `ObservableObject`: nothing observes it. The language choice lives in
/// `AppSettings.selectedLanguage`, and the only visible effect happens on the
/// next launch, so there is no state here for a view to track.
@MainActor
final class LanguageManager {

    static let shared = LanguageManager()

    /// The key AppKit/Foundation read at bundle-load time.
    private static let appleLanguagesKey = "AppleLanguages"

    /// `"system"` means "don't override" — remove the key so macOS falls back to
    /// the user's System Settings language order.
    static let systemValue = "system"

    private init() {}

    /// Push `selectedLanguage` into `AppleLanguages`.
    ///
    /// Returns `true` when the effective language actually changed, i.e. when a
    /// relaunch is required for the UI to match the new choice.
    @discardableResult
    func apply(_ selection: String) -> Bool {
        let defaults = UserDefaults.standard
        let existing = defaults.stringArray(forKey: Self.appleLanguagesKey)

        if selection == Self.systemValue {
            guard existing != nil else { return false }
            defaults.removeObject(forKey: Self.appleLanguagesKey)
            return true
        }

        // Keep the rest of the user's preferred order as a fallback chain, so a
        // string missing from the chosen language degrades to their next
        // preference rather than straight to the development language.
        let remainder = (existing ?? Locale.preferredLanguages).filter { $0 != selection }
        let newOrder = [selection] + remainder
        guard existing?.first != selection else { return false }

        defaults.set(newOrder, forKey: Self.appleLanguagesKey)
        return true
    }

    /// Re-apply the stored preference at launch.
    ///
    /// Needed because `resetToDefaults()` and a fresh install both leave
    /// `AppleLanguages` out of sync with `selectedLanguage`.
    func applyStoredSelectionAtLaunch() {
        apply(AppSettings.shared.selectedLanguage)
    }

    /// Relaunch the app so the new localization takes effect.
    ///
    /// `NSApp.terminate` plus a detached `open` is the only approach that works
    /// under App Sandbox — `execv` on our own bundle is blocked, and
    /// `NSWorkspace.openApplication` from inside a terminating process races the
    /// exit and intermittently does nothing.
    func relaunch() {
        let path = Bundle.main.bundleURL.path

        // The wait has to happen in a *child* process. Scheduling it on one of
        // our own queues cannot work: NSApp.terminate tears this process down,
        // and the pending block dies with it — so the app would quit and never
        // come back.
        //
        // No `-n`: the child sleeps until we have exited, so a plain `open`
        // starts a fresh instance. Passing -n would instead risk two live
        // instances (and therefore two status items and two auto-sync timers)
        // in the case where our termination gets cancelled.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", path]

        do {
            try task.run()
        } catch {
            // Relaunching failed, so quitting would strand the user with no app
            // and no explanation. Better to stay open and let them quit by hand.
            SyncHistory.shared.log(
                source: "LanguageManager",
                action: "relaunch.failed",
                details: error.localizedDescription
            )
            return
        }

        NSApp.terminate(nil)
    }

    /// Display name for a selection tag, shown in its own language.
    static func displayName(for tag: String) -> String {
        switch tag {
        case systemValue: return String(localized: "System Default")
        case "en":        return "English"
        case "zh-Hans":   return "简体中文"
        case "zh-Hant":   return "繁體中文"
        default:          return tag
        }
    }
}

// MARK: - Localization helper

extension String {
    /// Look up a localized string from the String Catalog.
    ///
    /// SwiftUI localizes `Text("…")` automatically, but plain `String` values —
    /// enum `displayName`s, `NSMenu` item titles, notification bodies — do not
    /// go through `LocalizedStringKey`, so they need an explicit lookup.
    init(localized key: String, comment: String = "") {
        self = NSLocalizedString(key, comment: comment)
    }

    /// Localized string with positional arguments, e.g. `"Synced %lld contacts"`.
    static func localized(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
