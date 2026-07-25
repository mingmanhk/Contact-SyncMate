# Contact SyncMate

> A macOS menu bar app that keeps **Google Contacts** and **Apple Contacts** (iCloud / On My Mac / Exchange / CardDAV) in sync — privately, locally, with full preview, automatic backups, and AI-assisted duplicate detection.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)]()
[![Language](https://img.shields.io/badge/language-Swift%205.9-orange.svg)]()
[![License](https://img.shields.io/badge/license-Proprietary-lightgrey.svg)]()

---

## Table of Contents

1. [Features](#features)
2. [Architecture overview](#architecture-overview)
3. [Sync engine overview](#sync-engine-overview)
4. [Setup](#setup)
5. [Build](#build)
6. [Permissions required](#permissions-required)
7. [Configuration](#configuration)
8. [Screenshots (described)](#screenshots-described)
9. [Known limitations](#known-limitations)
10. [Future improvements](#future-improvements)
11. [Troubleshooting](#troubleshooting)
12. [Project structure](#project-structure)

---

## Features

- **Two-way sync** — Google ↔ Apple Contacts in either direction or both.
- **Manual sync with preview** — see every add / update / delete / merge before it runs; override per contact.
- **Auto sync** — background sync at configurable intervals (5 min … daily) with optional run-conditions (on power, on Wi-Fi, when idle).
- **Field-level control** — opt in/out of photos, notes, birthday, addresses, websites, job title.
- **Conflict resolution** — Always Ask, Prefer Google, or Prefer Mac, with a per-contact override sheet.
- **Duplicate detection** — local NLP (nicknames, initials, transposed names, phonetic surname matching, plus-aliases) plus optional Anthropic AI escalation for borderline scores.
- **Automatic snapshots** — pre-sync and post-sync backups stored locally; restore any prior state from Settings → Backups.
- **Accessibility-first UI** — semantic colour tokens, hierarchical SF Symbols, VoiceOver labels, `accessibilityReduceMotion` and `accessibilityDifferentiateWithoutColor` honoured.
- **Privacy-first** — no backend; OAuth tokens, API keys, and contact data never leave your Mac (except the People API calls to Google).

---

## Architecture overview

Contact SyncMate is a single-process macOS app composed of four layers:

```
┌─────────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                            │
│   MenuBarView · DashboardView · SettingsView (sidebar)      │
│   OnboardingView · SyncPreviewView · BackupComparisonView   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Coordinators / View models                                 │
│   SyncCoordinator (@MainActor singleton)                    │
│   AppState (ObservableObject)                               │
│   AppSettings (UserDefaults + Keychain facade)              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Domain services                                            │
│   SyncEngine · DeduplicationCoordinator · AIContactMatcher  │
│   ContactBackupManager · SyncHistory · AutoSyncScheduler    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Connectors / storage                                       │
│   GoogleContactsConnector (People API + OAuth + Keychain)   │
│   MacContactsConnector (CNContactStore)                     │
│   ContactMappingStore (JSON on disk)                        │
│   KeychainStore                                             │
└─────────────────────────────────────────────────────────────┘
```

### Single sync execution path

Every sync — whether triggered by the **Sync Now** button, **Auto Sync timer**, or any other code path — flows through `SyncCoordinator.runSync()`. This guarantees that:

- `AppState.isSyncing`, the menu bar icon, the dashboard banner, and the popover progress bar all stay in sync.
- Two syncs cannot run concurrently (the coordinator's `isRunning` guard).
- Errors are translated to user-friendly messages in one place (`SyncCoordinator.friendlyMessage`).

### Design system

A small `DesignSystem/` module defines the project-wide vocabulary used by every view:

- `Color+App.swift` — semantic colour tokens (`.appSuccess`, `.appWarning`, `.appError`, `.appInfo`, `.appAccent`, `.appBrand`, `.appSourceGoogle`, `.appSourceApple`, `.appSurface`, `.appSurfaceTinted`, `.appBorder`, `.appText{Primary,Secondary,Tertiary,Inverse}`). Every token is backed by an asset-catalog colour set with light + dark variants.
- `AdaptiveIcon.swift` — `AdaptiveIcon` view + `AppIcon` typed registry of every SF Symbol the app uses. All icons use `.symbolRenderingMode(.hierarchical)` for guaranteed visibility in both modes.
- `AppButtonStyle.swift` — `.appRow` (hover/pressed/focus feedback) and `.appDestructive` button styles.
- `KeychainStore.swift` — wrapper for storing user secrets in the macOS Keychain.

**Rule:** views never use `Color.red`, `Color.green`, `Color.blue`, etc. directly — always reach for a semantic token.

---

## Sync engine overview

```
┌──────────────────┐    ┌─────────────────┐
│  Google People   │    │ Apple Contacts  │
│       API        │    │ (CNContactStore)│
└────────┬─────────┘    └────────┬────────┘
         │ fetch                  │ fetch
         ▼                        ▼
   GoogleContact           CNContact
         │                        │
         └────────┬───────────────┘
                  ▼
           UnifiedContact          ← canonical in-memory model
                  │
                  ▼
        ContactMappingStore        ← persistent ID linkage
                  │
                  ▼
              SyncEngine
        ┌─────┬──┴──┬─────┬─────┐
        ▼     ▼     ▼     ▼     ▼
       diff  dedup  conflict  backup  history
                  │
                  ▼
            SyncSession  ← list of ContactChange (add/update/delete/merge/skip)
                  │
                  ▼
   user preview / per-contact override (manual sync only)
                  │
                  ▼
           apply via connectors
                  │
                  ▼
         post-sync snapshot + history log
```

### Field-level sync

Every contact field can be opted out individually (Settings → Sync Fields). The engine consults `AppSettings` in two places:

- `compareFields(...)` — fields the user has opted out of are not considered when computing the diff.
- `applyFieldFilters(...)` — opt-out fields are zeroed on the unified contact before being written, so a contact that already had data on the target side is left untouched.

### Conflict resolution

When the same contact differs on both sides, the engine consults `AppSettings.defaultConflictResolution`:

- **Always Ask** — the contact ends up in the preview screen with `.userOverride` left for the user to set.
- **Prefer Google** — Google value wins automatically.
- **Prefer Mac** — Mac value wins automatically.

Per-contact overrides set in the preview screen always trump the default.

### Deduplication

A two-tier system handles duplicates:

1. **Local NLP (always on)** — exact email/phone match, normalised name match, nickname expansion, phonetic surname (Soundex), transposed-name matching, plus-alias email handling.
2. **AI escalation (optional)** — if an Anthropic API key is configured, contact pairs whose rule score lands inside `[aiAPIScoreRangeLow, aiAPIScoreRangeHigh]` (default 30–79) are escalated to Claude Haiku for a final judgement. High-confidence and offline cases skip the API entirely.

Auto-merge is gated on three checks: score ≥ 80, group size ≤ 3, no critical-field conflicts.

### Backups

Two snapshots are taken around every sync (when `autoBackupEnabled` is on, which it is by default):

- **Pre-sync** — full Google + Mac state immediately before any changes.
- **Post-sync** — full Google + Mac state after the sync completes.

Both are linked to the sync session via `syncSessionId`. Restore is available from Settings → Backups; it performs an **additive** restore (upserts every contact in the snapshot) without deleting contacts that were created after the snapshot — by design, to avoid destructive surprises.

---

## Setup

### Prerequisites

- macOS 13 (Ventura) or later
- Xcode 15 or later
- A Google Cloud project with:
  - **Google People API** enabled
  - An OAuth 2.0 **Client ID for macOS** (or a desktop app type)
- *(Optional)* An Anthropic API key for the AI duplicate-matching tier — get one at [console.anthropic.com](https://console.anthropic.com)

### 1. Clone the repository

```bash
git clone https://github.com/your-org/contact-syncmate.git
cd contact-syncmate
```

### 2. Provide your Google OAuth credentials

```bash
cp "Contact SyncMate/GoogleOAuthConfig.example.json" \
   "Contact SyncMate/GoogleOAuthConfig.json"
```

Edit `GoogleOAuthConfig.json`:

```json
{
  "clientId": "YOUR_CLIENT_ID.apps.googleusercontent.com",
  "redirectURI": "com.googleusercontent.apps.YOUR_CLIENT_ID:/oauth2redirect",
  "clientSecret": "SET_AT_RUNTIME_OR_CI"
}
```

`GoogleOAuthConfig.json` is **gitignored**. The client ID is public and safe to embed; the client secret is migrated into the macOS Keychain on first launch.

### 3. Update `Info.plist`'s URL scheme

Replace the placeholder URL scheme in `Info.plist > CFBundleURLTypes > CFBundleURLSchemes` with:

```
com.googleusercontent.apps.YOUR_CLIENT_ID
```

This is the reverse-DNS of your client ID and must match the `redirectURI` in step 2.

---

## Build

```bash
open "Contact SyncMate.xcodeproj"
```

Build and run with **⌘R**. The first launch will show the onboarding sheet — connect Google, grant Contacts access, choose a sync direction, and run a dry-run preview.

### Pre-commit secret check

The repo ships with `Scripts/check-secrets.sh`. Wire it into your pre-commit hook to guarantee no API keys land in git:

```bash
ln -s ../../Scripts/check-secrets.sh .git/hooks/pre-commit
```

---

## Permissions required

Contact SyncMate requests the minimum necessary permissions:

| Permission | Why | Where requested |
|---|---|---|
| **Contacts** (`NSContactsUsageDescription`) | Read & write Apple Contacts. | First launch — and re-grantable from Settings → Accounts → Permissions. If denied, the app deep-links to System Settings → Privacy → Contacts. |
| **Network — Outbound** (`com.apple.security.network.client`) | OAuth + Google People API. | Granted by entitlement; no runtime prompt. |
| **Personal Information / Address Book** (entitlement) | Required for `CNContactStore` write access on macOS. | Granted by entitlement. |
| **Keychain** (`keychain-access-groups`) | Store OAuth tokens, OAuth client secret, and Anthropic API key. | Granted by entitlement; no runtime prompt. |
| ~~Notes field~~ (`com.apple.developer.contacts.notes`) | Would enable Contacts `note` field sync. **Not currently requested** — Apple denied the entitlement. Notes sync is disabled at runtime; all other fields sync normally. Re-enable by getting the entitlement approved and setting `MacContactsConnector.notesFieldAvailable = true`. | — |

Contact SyncMate runs **outside the App Sandbox** in the current configuration. To submit to the Mac App Store, add `com.apple.security.app-sandbox` to the entitlements file and audit network/file access.

---

## Configuration

All preferences are exposed in **Settings** (⌘,) and persisted to `UserDefaults`, except secrets which live in the Keychain.

| Tab | Highlights |
|---|---|
| **General** | Sync mode, launch at login, monochrome menu bar icon, dock visibility, notifications, language, history retention, reset-to-defaults |
| **Sync Fields** | Per-field opt-out (photos, notes, birthday, websites, addresses, job title), default conflict resolution, merge behaviour, country-code normalisation, batched updates, group/label filtering |
| **Manual Sync** | Detect-duplicates toggle, confirm-pending-deletions, force-update-all, dry-run mode |
| **Auto Sync** | Enable, direction, interval (5 min / 15 min / 30 min / 1 h / 4 h / daily), run-conditions (AC power / Wi-Fi only / idle only) |
| **AI Matching** | Enable, Anthropic API key (Keychain-backed, with show/hide & test button), call-sensitivity range slider (default 30–79) |
| **Accounts** | Google sign-in/out, contact count, test connection, CSV/Excel export, Mac account mode (auto / all / specific), per-account picker with contact counts |
| **Backups** | Last backup, total backups, storage used, manual backup, location chooser, recent backup files (reveal in Finder), automatic backups toggle, max-backup-count stepper |

---

## Screenshots (described)

> Screenshots are not included in this repo. Each visual is described below so the surface can be verified against the description after a build.

1. **Menu bar popover (light mode)** — 280-pt wide. Top: green pulse dot + "Up to date" / "Synced 2 hours ago". A divider, then a borderless **Sync Now** primary button. Account rows for Google (red `g.circle.fill`) and Mac (blue desktop) with right-aligned 6-pt connection dots. Auto-sync toggle row. Three menu links (Open Dashboard, Sync History, Preferences) with hover backgrounds. Bottom: red **Quit Contact SyncMate** with ⌘Q shortcut.
2. **Menu bar popover (dark mode)** — same layout; backgrounds adapt; `BrandIndigo` and `Accent` colour sets shift to their dark variants; the green pulse dot uses the `StatusSuccess` dark variant (slightly desaturated).
3. **Settings — Accounts tab** — sidebar on the left grouped into App / Sync / Advanced / Account; right pane shows the Google account banner at the top (with email + count), then a Google section with status row, Test Connection / Backup to CSV / Backup to Excel / Sign Out, then a Mac Contacts section with account-mode picker and the same actions, then a Permissions section with Grant Access CTA when needed.
4. **Settings — AI Matching tab** — overview card with `sparkles` icon, enable toggle, a list of the eight on-device NLP signals, an Anthropic API key text field with show/hide eye button, a Test API Key button, and a two-thumb sensitivity slider for the API call range.
5. **Sync preview** — list of contact changes grouped by action; each row shows direction (Google → Mac / Mac → Google), the field changes, and a per-row override picker (Add / Update / Skip / Force Google / Force Mac).
6. **Backup comparison** — side-by-side diff of a contact between the current state and a chosen backup; field-level highlighting in `appWarning` for changed lines.
7. **Onboarding** — four-step sheet: Welcome → Connect Google → Grant Contacts → Choose direction. Now resizable and only marks setup complete when the user reaches the final step.

---

## Known limitations

- **Notes field is not synced.** The Contacts `note` field is gated by `com.apple.developer.contacts.notes`, a special-access entitlement that Apple must approve. Contact SyncMate ships without it; the Notes toggle in Settings → Sync Fields is disabled and forced off. Every other field syncs normally. Once Apple approves the entitlement, re-add the key to `Contact SyncMate.entitlements` and set `MacContactsConnector.notesFieldAvailable = true`.
- **Rollback is additive only.** Restoring a backup re-creates and updates contacts but does not delete contacts that were added after the snapshot. To do a destructive rollback, manually remove the new contacts before restoring.
- **Group / label filtering UI** is gated behind `Settings → Sync Fields → Filter by Groups`; the picker UI ships in a future update.
- **Sync between two Google accounts** is on the roadmap.
- **Field-level rules** ("always trust Google for company") are global today (Sync Fields tab); per-field source preferences are roadmap.
- **CLI** is not yet shipped.
- **App Sandbox** is currently disabled. Direct distribution only; not yet submitted to the Mac App Store.
- **Hardcoded Google API key** in `GoogleAPIConfig.swift` should be rotated and externalised before public distribution. (Public client IDs are safe; this is a separate API key for non-OAuth People API metadata calls.)
- **History pruning** uses a hard cap (1000 events) rather than the `historyRetentionDays` setting; the latter is exposed in UI but not yet enforced.

---

## Future improvements

- Two-Google-account sync (Google A ↔ Google B via Mac mapping).
- Per-field source rules ("always trust Google for company & title"; "always keep Mac photos").
- Multiple sync profiles ("Personal" / "Work").
- Notification Center integration ("Synced 120 contacts (3 updated, 1 deleted)").
- Command-line interface for power users / CI.
- Smart duplicate resolver UI (side-by-side merge editor with field-level confidence).
- Time-window history retention (honour `historyRetentionDays`).
- Mac App Store distribution (sandbox + entitlement audit).

---

## Troubleshooting

### Google sign-in immediately fails

- Confirm `GoogleOAuthConfig.json` is in the bundle and `clientId` is correct.
- Confirm the URL scheme in `Info.plist > CFBundleURLTypes > CFBundleURLSchemes` matches your reverse-domain client ID.
- Check **Settings → Accounts → Google → Sign In** for an inline error message.
- Look at the Console log for `OAuth callback` events.

### Contact SyncMate cannot see my contacts

- **System Settings → Privacy & Security → Contacts** — make sure Contact SyncMate is toggled on.
- Quit and relaunch — `CNContactStore` authorization is checked at launch and on `applicationDidBecomeActive`.
- If you have multiple accounts (iCloud + On My Mac + Exchange), set **Settings → Accounts → Mac Contacts → Account mode** to **Specific** and pick the right container.

### Auto-sync isn't running

- **Settings → Auto Sync → Enable automatic sync** must be on.
- Check the run-conditions — if "Only on AC power" is on and you're on battery, sync is skipped (you'll see a `skipped` event in **Sync History**).
- Confirm both accounts are connected (the menu bar popover shows green dots).

### "Sync already in progress" error

- A sync is genuinely running (manual or auto). Wait for it to finish.
- If the icon shows the spinner indefinitely, something has hung — quit and relaunch. The next launch will reset `SyncCoordinator.phase` to `.idle`.

### AI matching does nothing

- Enter a valid Anthropic API key in **Settings → AI Matching → Cloud AI Tier**. Click **Test API Key** to verify.
- Adjust the sensitivity slider — by default the API is only called for borderline matches (rule score 30–79). Wider range = more API calls = higher accuracy and cost.
- If you have no key configured, only the on-device NLP signals run (still effective for most cases).

### Restore from backup didn't delete a contact I expected

- Restore is **additive** by design (see [Known limitations](#known-limitations)). To remove the contact, delete it manually then restore.

### Where are my backups stored?

- Default: `~/Documents/Contact SyncMate Backups/`
- Custom: whatever you chose in **Settings → Backups → Backup Location → Change Location…**
- Click **Open in Finder** in that section to reveal the folder.

### Anthropic API key disappeared after upgrade

The key migrated automatically from `UserDefaults` to the macOS Keychain on first launch after upgrade. If migration failed (Keychain locked, etc.), re-paste the key in **Settings → AI Matching → Cloud AI Tier**.

---

## Project structure

```
Contact SyncMate/
├── Contact SyncMate.xcodeproj/
├── Contact SyncMate/
│   ├── Contact_SyncMateApp.swift          # @main, AppDelegate, status item, scheduler wiring
│   ├── ContentView.swift                  # Root: onboarding gate → DashboardView
│   ├── AppState.swift                     # @Published global state (auth, sync, last result)
│   ├── AppSettings.swift                  # UserDefaults + Keychain facade
│   │
│   ├── DesignSystem/                      # Project-wide vocabulary
│   │   ├── Color+App.swift                #   • semantic colour tokens
│   │   ├── AdaptiveIcon.swift             #   • SF Symbol component + AppIcon registry
│   │   ├── AppButtonStyle.swift           #   • .appRow / .appDestructive
│   │   └── KeychainStore.swift            #   • secrets storage
│   │
│   ├── Components/                        # Small reusable views
│   │   ├── StatusDot.swift                #   • accessible pulse indicator
│   │   ├── SyncSummaryBadges.swift        #   • +N / ~N / -N / !N counters
│   │   ├── SyncProgressView.swift
│   │   └── ContactChangeRow.swift
│   │
│   ├── Coordinators / view layer
│   │   ├── SyncCoordinator.swift          # the single sync execution path
│   │   ├── DashboardView.swift
│   │   ├── MenuBarView.swift              # 280pt menu bar popover
│   │   ├── SettingsView.swift             # NavigationSplitView with 7 tabs
│   │   ├── OnboardingView.swift
│   │   ├── SyncPreviewView.swift / ContactDiffView.swift
│   │   ├── SyncHistoryView.swift / SyncHistoryAndBackupView.swift
│   │   ├── BackupComparisonView.swift / RestoreBackupDialog.swift
│   │   └── DeduplicationSettingsView.swift / DeduplicationConfirmationView.swift
│   │
│   ├── Domain / engine
│   │   ├── SyncEngine.swift                       # diff + apply + ContactMappingStore
│   │   ├── SyncTypes.swift / UnifiedContact.swift
│   │   ├── ContactNormalizer.swift                # email/phone/name normalisation
│   │   ├── SyncEngineDeduplicationIntegration.swift
│   │   ├── SyncBackupIntegration.swift            # rollback path
│   │   ├── ContactBackupManager.swift             # snapshot store
│   │   ├── SyncHistory.swift / SyncHistoryViewModel.swift
│   │   ├── AutoSyncScheduler.swift                # DispatchSource timer
│   │   ├── ContactDeduplicator.swift / AIContactMatcher.swift
│   │   ├── DeduplicationCoordinator.swift / DeduplicationModels.swift
│   │   └── DeduplicationDecisionStore.swift / DeduplicationScoringReference.swift
│   │
│   ├── Connectors
│   │   ├── GoogleContactsConnector.swift          # People API client
│   │   ├── GoogleOAuthManager.swift               # ASWebAuthenticationSession + Keychain
│   │   ├── GoogleOAuthConfig.swift                # JSON loader
│   │   ├── GoogleAPIConfig.swift                  # API key (rotate before public release)
│   │   ├── GoogleContactsExporter.swift           # CSV / Excel export
│   │   ├── MacContactsConnector.swift             # CNContactStore
│   │   └── MacContactsExporter.swift
│   │
│   ├── Assets.xcassets/                   # Asset catalog (colour sets + app icons)
│   ├── Info.plist / *.entitlements
│   ├── PRIVACY_POLICY.md / TERMS_OF_SERVICE.md / CHANGELOG.md
│   └── GoogleOAuthConfig.example.json     # template — copy to GoogleOAuthConfig.json
│
├── ContactSyncMateTests/
│   ├── ContactSyncMateTests.swift
│   └── SyncEngineDiffTests.swift
│
├── Scripts/
│   └── check-secrets.sh                   # pre-commit guard for API keys
│
└── README.md
```

---

## Privacy

Contact SyncMate runs **entirely on your Mac**. There is no Contact SyncMate server, no telemetry, and no third-party analytics. The only network calls are:

- **Google People API** — to read and write your Google Contacts (after you sign in).
- **Anthropic API** — only if you provide an API key and only for borderline duplicate matches.

OAuth tokens, the OAuth client secret, and the Anthropic API key are stored in the macOS Keychain. Backups are stored in plain `.json` files under `~/Documents/Contact SyncMate Backups/` (or your chosen folder). See `PRIVACY_POLICY.md` for the full text.

---

## License

Proprietary. © Victor Lam. All rights reserved.
