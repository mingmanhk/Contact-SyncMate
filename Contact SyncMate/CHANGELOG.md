# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.1] - 2026-08-11

The first release audited end-to-end. Three full audit cycles
([`docs/AUDIT.md`](../docs/AUDIT.md), [`docs/AUDIT-CYCLE3.md`](../docs/AUDIT-CYCLE3.md))
reviewed the sync engine, connectors, persistence, UI, and policies; everything
below is the user-facing result.

### Added
- **Photo sync that actually works** — contact photos now sync Google → Mac,
  with change detection so unchanged photos are not rewritten every run.
- **Cancellable syncs** — a running sync can be stopped mid-flight; changes
  already applied are recorded in history and remain reversible via backups.
- **Full Chinese localization** — the entire UI is available in Simplified and
  Traditional Chinese alongside English.
- **Crash diagnostics** — failures during a sync are captured with enough
  context to diagnose them, surfaced in a dedicated Sync Failures view with
  plain-language explanations, and reported honestly in the sync summary.
- **Privacy manifest** — the app bundle ships `PrivacyInfo.xcprivacy`
  declaring its required-reason API usage and that no data is collected and
  no tracking occurs.
- **Continuous integration** — every push and pull request builds the app and
  runs the full test suite on GitHub Actions.
- **Group / label filtered sync** — restrict a sync to selected Mac groups or
  Google labels via the group picker.

### Changed
- **Safety gates for merges and deletions** — deletions never propagate unless
  explicitly enabled, and each one is confirmed individually; automatic merges
  are limited to small, unambiguous groups with no critical field conflicts,
  and the app no longer asks about merges that are not actually in doubt.
- **Offline resilience** — network drops and transient Google API errors are
  retried with backoff instead of failing the run; contacts that genuinely
  cannot be written are set aside and reported rather than retried forever.
- **Honest policies** — the privacy policy, terms, and App Store copy were
  rewritten to state exactly what the app does: no backend, no telemetry,
  unencrypted local backups disclosed, and the optional Anthropic AI tier
  gated behind the user's own API key *plus* an explicit consent toggle.

### Fixed
- Duplicate contacts no longer appear after repeated syncs; edits made on the
  Mac side are no longer dropped during two-way merges; backups no longer race
  a running sync.

## [0.x] - development scaffolding (historical)

Pre-1.1 working notes, retained for archaeology. Some details below describe
intermediate states that later changed.

### Runtime Wiring & Integration
- **`AutoSyncScheduler.swift`** *(new file)* — `@MainActor` class that owns the repeating `DispatchSourceTimer` for auto-sync. Observes `AppSettings.autoSyncEnabled` and `autoSyncInterval` via Combine; re-arms the timer whenever either changes. Publishes the next fire date to `AppState.nextScheduledSync` so the Settings → Auto Sync tab countdown shows a live relative-time label.
- **`Contact_SyncMateApp.swift`** — `AppDelegate` gains `setupAutoSyncScheduler()` (wires `AutoSyncScheduler` with a `triggerSync` closure ready for the real `SyncEngine`) and `setupLaunchAtLogin()` which registers/unregisters `SMAppService.mainApp` on macOS 13+ whenever the `launchAtLogin` preference changes, with a fallback comment for the LoginItem helper bundle path on macOS 12.
- **`DeduplicationCoordinator.swift`** — Removed the stored `private let deduplicator`; replaced with `makeDeduplicator()` which builds a fresh `ContactDeduplicator` from the live `AppSettings` singleton on each scan. AI matching is now controlled end-to-end by the user's Settings → AI Matching tab without requiring an app restart.
- **`ContactDeduplicator.Configuration`** — Added `aiScoreRangeLow: Int` and `aiScoreRangeHigh: Int` properties (default 30/79). Added `withScoreRange(low:high:)` builder method so the coordinator can propagate the user-configured API call window.
- **`AIContactMatcher.analyzeMatch`** — Accepts `scoreRangeLow`/`scoreRangeHigh` parameters (defaulting to 30/79) so the API escalation window is configurable rather than hardcoded. Fixed a variable-shadowing bug where the outer `key` (cache key) and the API-key parameter used the same name.
- **`SyncEngine.diffFields`** — Now respects per-field toggles from Settings → Common Sync → Fields to Sync: `syncJobTitle`, `syncNotes`, `syncBirthday`, `syncAddresses`, `syncWebsites`. Also added previously-missing diff checks for postal addresses and website URLs.
- **`SyncEngine.applyFieldSettings(to:)`** *(new private method)* — Strips disabled fields from a `UnifiedContact` before it is written to either side. Called by both `performAdd` and `performUpdate` so the user's field exclusions are enforced at write time, not just at diff time.
- **`SyncEngine.compute2WayChanges`** — Conflict handling now branches on `settings.defaultConflictResolution`: `alwaysAsk` creates a `.merge` change as before; `preferGoogle` auto-resolves to a `googleToMac` update; `preferMac` auto-resolves to a `macToGoogle` update.

### Added
- Deduplication workflow coordinator (`DeduplicationCoordinator`) scaffolding with scan, decision application, and sync gating.
- Privacy Policy page (`PRIVACY_POLICY.md`).
- Terms of Service page (`TERMS_OF_SERVICE.md`).
- README updates with Legal section linking to policy documents.

### Changed
- Improved logging hooks via `SyncHistory` for deduplication steps and notifications.

### UX / UI Improvements
- **`MenuBarView`**: Fixed broken Sync Now button (was using an empty `systemImage` with a raw Unicode arrow). Now uses `arrow.triangle.2.circlepath` SF Symbol with a `.rotate` symbolEffect while syncing. Status text uses natural relative units ("Synced 2 minutes ago"). Auto-sync row shows a "Runs every X min" subtitle when enabled.
- **`DashboardView`**: Added Settings gear button in toolbar. Added a last-sync result stats pill showing added/updated/deleted counts. Activity feed now shows friendly event labels and per-event icons with semantic colours instead of raw action strings. Direction picker has a description subtitle and an "Applied on next sync" hint. Better empty state for the activity feed.
- **`SyncPreviewView`**: Filter chips now show per-filter counts ("Add 5", "Delete 2", etc.) and are visually disabled (40% opacity) when empty. Contextual empty state icon and message per active filter. Conflict warning banner in the footer when conflicts exist. Apply button shows a checkmark icon and reads "Nothing to Apply" when the change count is zero.
- **`OnboardingView`**: Animated progress bar replacing static dots. "Step X of 4" counter. "Skip setup" button visible on steps 1–3. Back button uses a chevron SF Symbol. Next/Continue button uses a right-side icon via a custom `RightIconLabelStyle`. Strategy step shows a rich animated description card.
- **`ContactChangeRow`**: Direction labels expanded ("Google → Mac", "Mac → Google", "Both ways") and colour-coded. Direction badge moved under the contact name. Conflict rows show an orange "Conflict" capsule badge and a subtle orange background tint. "Diff" renamed to "Details"; Skip button styled secondary.
- **`StatusDot`**: Label text updated: "Idle" → "Up to date", "Error" → "Sync error".
- **`SyncHistoryView`**: History rows now display friendly human-readable labels ("Sync completed", "Contact added", etc.) instead of raw internal action strings. `eventIcon` and `eventColor` helpers expanded with per-action-type icons and semantic colours. Empty state is contextual — distinct message and icon for no history vs. no search results. Search also matches on the friendly label.
- **`ContactDiffView`**: Navigation buttons replaced from plain text "← Prev" / "Next →" to bordered SF Symbol chevron buttons consistent with the rest of the app.
- **`DeduplicationConfirmationView`**: Replaced all deprecated `.foregroundColor()` calls with `.foregroundStyle()` throughout.
- **`SettingsView`**: Removed debug `print("📍 …")` statements left over from development.

### AI-Powered Matching & Deduplication
- **`AIContactMatcher.swift`** *(new file)* — Actor-based AI matching layer that runs two tiers:
  - **Tier 1 – Local NLP (always active, instant, offline)**: Extends the rule-based scorer with 8 new signals: nickname/common-name variants (200+ name groups, e.g. Bob ↔ Robert, Liz ↔ Elizabeth), first-name initial abbreviation (J. Smith ↔ John Smith), transposed name order (Wei Li ↔ Li Wei), Soundex phonetic surname matching (Schmidt ↔ Schmitt), phone-number suffix matching (handles local vs. international format differences), email plus-alias detection (john+work@ ≈ john@), compound/split name handling (Liwei ↔ Li Wei), and the contact's own stored Nickname field.
  - **Tier 2 – Anthropic Claude (optional, cloud)**: For borderline pairs whose rule score falls in a configurable range (default 30–79), calls `claude-haiku` with a structured prompt to return a 0–100 confidence score, a human-readable reasoning string, and a suggested action (merge / keep separate / review). Falls back silently to local NLP on any network error. Results cached per contact-pair for the lifetime of the process.
- **`ContactDeduplicator.swift`** — Integrated AI matcher into both `detectDuplicatesWithinSource` and `detectDuplicatesAcrossSources`. Pre-filter threshold is lowered by 20 points when AI is enabled so borderline pairs reach the AI tier before being discarded. `DuplicateGroup` now stores `aiEnhancedScore` and `aiMatchResult`. `Configuration` gains `aiMatchingEnabled` and `anthropicAPIKey`.
- **`DeduplicationModels.swift`** — `DuplicateGroup` gains `aiEnhancedScore: Int?`, `aiMatchResult: AIMatchResult?`, `effectiveScore` (best available score), `hasAIAnalysis`, and `aiSourceLabel`. `MatchScoreBreakdown` gains `aiBonus` and `totalScoreWithAI`. `DuplicateDecision` gains `aiLabel` for badge display.
- **`DeduplicationConfirmationView.swift`** — `DuplicateGroupCard` updated to surface AI analysis: sparkle-branded source badge ("Local NLP" / "Claude AI"), score-adjustment indicator (e.g. "AI adjusted score: 45 → 72"), a collapsible AI reasoning block with scrollable signal chips per signal, and an AI-suggested action badge (lightbulb icon). Score ring and label now use `effectiveScore` and reads "AI Score" vs "Match" accordingly.
- **`AppSettings.swift`** — Added `aiMatchingEnabled`, `anthropicAPIKey`, `aiAPIScoreRangeLow`, `aiAPIScoreRangeHigh` properties.
- **`SettingsView.swift`** — New **AI Matching** tab (tag 4, before Accounts) with: a feature overview card, an on/off master toggle, a read-only list of all local NLP signals with icons and example values, an API key field (show/hide toggle) with a "Test API Key" button that fires a real validation request, and a sensitivity slider pair for the API call score window. Accounts tab renumbered to tag 5.

### Settings Enhancements
- **General tab** — Sync Mode section replaced plain radio picker with a tappable card-style list showing icon, name, and description inline. Appearance gains "Launch at login" and "Show pending-changes badge" toggles. New Notifications section lets users independently toggle alerts for sync completion, errors, and conflicts (with a deep-link button to System Settings → Notifications). Data & History section now includes a history retention duration picker (7/14/30/90 days or Forever). Reset All Settings now uses a `.confirmationDialog` to prevent accidental resets.
- **Common Sync tab** — New "Fields to Sync" section lets users independently enable/disable Photos, Notes, Birthday, Websites, Addresses, and Job Title/Org on a per-field basis. New "Default Conflict Resolution" section replaces the implicit always-ask behaviour with an explicit choice (Always Ask / Prefer Google / Prefer Mac) shown as a card list with icons and descriptions. Merge Behaviour and Filters sections retain all prior controls.
- **Manual Sync tab** — Safety and Advanced sections polished with SF Symbol labels per toggle. Dry run mode now shows an inline orange warning banner when active. Help text updated to be more descriptive for both sections.
- **Auto Sync tab** — Picker labels updated to natural language ("Every 15 minutes", "Once a day"). A "Next sync in X" row below the interval picker shows a live countdown using `Text(date, style: .relative)` sourced from `AppState.nextScheduledSync`. Conditions section has SF Symbol labels per condition and a contextual footer explaining whether conditions are active. The whole tab animates in/out with `autoSyncEnabled`.
- **`AppSettings`** — Added 12 new persisted properties: `notifyOnSyncComplete`, `notifyOnErrors`, `notifyOnConflicts`, `syncNotes`, `syncBirthday`, `syncWebsites`, `syncAddresses`, `syncJobTitle`, `defaultConflictResolution`, `launchAtLogin`, `showSyncBadge`, `historyRetentionDays`. Added `ConflictResolutionDefault` enum with display name, description, and icon.
- **`AppState`** — Added `nextScheduledSync: Date?` published property for the Auto Sync tab countdown.

### Fixed
- **`runAutoSync` session mode bug** (`SyncEngine.swift`): Auto-sync sessions were being created with `mode: .manual` because `runAutoSync` reused `prepareManualSync` which hard-codes that mode. Added `session.mode = .automatic` override so `SyncResult` and history correctly reflect the run type.
- **`DeduplicationCoordinator` SwiftUI reactivity bug** (`DeduplicationCoordinator.swift`): Manually declaring `let objectWillChange = ObservableObjectPublisher()` bypasses the Swift compiler's automatic `@Published` synthesis, silently breaking all UI updates driven by `isScanning`, `scanResult`, and `showingConfirmationSheet`. Removed the redundant declaration.
- **Dead-code allocation in `performUpdate`** (`SyncEngine.swift`): `ContactMapper.toGoogle(from:)` was called and its result immediately overwritten on the next line with `GoogleContact(id: gID)`. Removed the unused first call; intent is now clear.
- **Misplaced `import Contacts`** (`SyncEngineDeduplicationIntegration.swift`): The import statement appeared before the file header comment. Moved it to its correct position after the header.

### Known Issues
- ~~Build error: `'SyncMode' is ambiguous for type lookup in this context` and `Invalid redeclaration of 'SyncMode'`.~~ **Resolved** — `enum SyncMode` has exactly one declaration in `SyncTypes.swift`. The local copy in `DeduplicationCoordinator.swift` was removed (see comment on line 228) and the build error no longer exists. This CHANGELOG entry was stale.

## [0.1.0] - 2025-11-11
### Added
- Initial repository setup for Contact SyncMate.
- Core types for deduplication results and decision handling (placeholders/stubs where applicable).

[Unreleased]: https://github.com/mingmanhk/Contact-SyncMate/compare/v1.1...HEAD
[1.1]: https://github.com/mingmanhk/Contact-SyncMate/compare/v0.1.0...v1.1
[0.1.0]: https://github.com/mingmanhk/Contact-SyncMate/releases/tag/v0.1.0
