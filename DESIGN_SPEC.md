# Contact SyncMate — Complete UX/UI & Workflow Design Spec
**Version 1.0 | Engineering Handoff Document**

---

## 1. HIGH-LEVEL OVERVIEW

Contact SyncMate is a **macOS menu bar utility** (no Dock icon by default) that provides 2-way sync between Google Contacts and Apple Contacts. The experience has three layers:

| Layer | Description |
|---|---|
| **Menu Bar** | Always-visible status icon + quick actions dropdown |
| **Main Window** | Sync dashboard, history, account management |
| **Settings Window** | Full configuration panel |

**Core UX Principle:** The user should never worry about data loss. Every destructive action has a preview, confirmation, and undo path.

---

## 2. FULL WORKFLOW ARCHITECTURE

### 2.1 First Launch Onboarding

```
App Launch (first time)
    │
    ▼
┌─────────────────────────────┐
│  SPLASH SCREEN              │
│  Infinity loop animation    │
│  "Setting up..."            │
│  Duration: 1.2s             │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  ONBOARDING STEP 1/4        │
│  "Welcome to Contact        │
│   SyncMate"                 │
│  App logo + tagline         │
│  [Get Started]              │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  ONBOARDING STEP 2/4        │
│  GOOGLE ACCOUNT             │
│  "Connect your Google       │
│   account"                  │
│  [Connect Google Account]   │
│        │                    │
│   ┌────▼────────────┐       │
│   │ OAuth Web Sheet │       │
│   │ accounts.google │       │
│   │ .com/oauth2/... │       │
│   │ ─────────────── │       │
│   │ ✓ Sign in       │       │
│   │ Grant Contacts  │       │
│   │ permission      │       │
│   └────┬────────────┘       │
│        │                    │
│   Success → token stored    │
│   in macOS Keychain         │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  ONBOARDING STEP 3/4        │
│  MAC CONTACTS ACCESS        │
│  "Allow access to your      │
│   Mac contacts"             │
│  [Allow Access]             │
│        │                    │
│   ┌────▼────────────┐       │
│   │ macOS system    │       │
│   │ permission      │       │
│   │ dialog          │       │
│   │ "ContactSync-   │       │
│   │  Mate wants to  │       │
│   │  access your    │       │
│   │  Contacts"      │       │
│   │ [Don't Allow]   │       │
│   │ [OK]            │       │
│   └────┬────────────┘       │
│        │                    │
│   Denied → Show guidance    │
│   to enable in System       │
│   Settings                  │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  ONBOARDING STEP 4/4        │
│  SYNC STRATEGY              │
│  "How would you like to     │
│   start?"                   │
│                             │
│  ○ Google → Mac             │
│    (Google is master)       │
│  ○ Mac → Google             │
│    (Mac is master)          │
│  ● 2-Way Sync               │
│    (Merge both)             │
│                             │
│  ⚠️ Tip: We recommend       │
│  manual first sync          │
│  to review changes          │
│                             │
│  [Start Initial Sync]       │
│  [Skip, I'll do it later]   │
└─────────────┬───────────────┘
              │
              ▼
         Main Window
```

---

### 2.2 Manual Sync Flow

```
User triggers sync
(menu bar or main window)
         │
         ▼
┌────────────────────┐
│ FETCHING           │
│ ∞ animation        │
│ "Fetching Google   │
│  contacts..."      │
│ "Fetching Mac      │
│  contacts..."      │
│ Progress bar       │
└──────┬─────────────┘
       │
       ▼
┌────────────────────┐     ┌──────────────────────┐
│ DIFF ENGINE        │────▶│ CONFLICT DETECTED?   │
│ Compute changes:   │     │                      │
│ - Adds             │     │ Same contact edited  │
│ - Updates          │     │ on both sides?       │
│ - Deletes          │     └──────────┬───────────┘
│ - Merges           │                │
│ - Conflicts        │          YES   │   NO
└──────┬─────────────┘                │    │
       │                              ▼    ▼
       │                    ┌─────────────────────┐
       │                    │ CONFLICT RESOLUTION │
       │                    │                     │
       │                    │ Side-by-side diff   │
       │                    │ Per-field:          │
       │                    │ [Use Google] [Mac]  │
       │                    │ [Skip] [Merge]      │
       │                    └──────────┬──────────┘
       │                               │
       ▼                               ▼
┌──────────────────────────────────────────────────┐
│ SYNC PREVIEW SCREEN                              │
│                                                  │
│  Summary bar:                                    │
│  ┌──────┬──────┬──────┬──────┬──────┐           │
│  │ +12  │ ~8   │ ×2   │ ⚠️3  │ 0    │           │
│  │ Add  │ Upd  │ Del  │ Conf │ Err  │           │
│  └──────┴──────┴──────┴──────┴──────┘           │
│                                                  │
│  Contact list (grouped by action type):          │
│  ┌──────────────────────────────────────┐        │
│  │ ▶ NEW (12)                           │        │
│  │   [→ Mac] John Smith (from Google)  │        │
│  │   [→ Ggl] Jane Doe (from Mac)       │        │
│  │ ▶ UPDATED (8)                        │        │
│  │   [⟷] Bob Jones - phone changed     │        │
│  │ ▶ DELETED (2)                        │        │
│  │   [✕] Old Contact (orphaned)         │        │
│  └──────────────────────────────────────┘        │
│                                                  │
│  Per-contact actions: [Skip] [View Diff] [Edit]  │
│                                                  │
│  [Cancel]              [Apply All Sync →]        │
└────────────────────────┬─────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────┐
│ APPLYING SYNC                          │
│ ∞ spinning                             │
│ "Applying 22 changes..."               │
│ ████████░░░░ 14/22                     │
└──────────────┬─────────────────────────┘
               │
        ┌──────┴──────┐
        │ Success?    │
        │             │
     YES│          NO │
        │             │
        ▼             ▼
┌────────────┐  ┌────────────────────────┐
│ COMPLETE   │  │ PARTIAL ERROR          │
│ ✅ 22 done │  │ ⚠️ 19 ok, 3 failed     │
│ Summary    │  │ Show failed contacts   │
│ [View Log] │  │ [Retry failed]         │
│ [Done]     │  │ [Skip & continue]      │
└────────────┘  └────────────────────────┘
```

---

### 2.3 Auto Sync Flow

```
Auto-sync timer fires
(or CNContactStoreDidChange notification)
         │
         ▼
┌───────────────────────────────┐
│ Pre-flight checks:            │
│ ✓ Network available?          │
│ ✓ OAuth token valid?          │
│ ✓ Not already syncing?        │
│ ✓ Battery > 20% (if set)?     │
└──────────────┬────────────────┘
               │ All pass
               ▼
┌───────────────────────────────┐
│ INCREMENTAL SYNC              │
│ Use Google sync tokens        │
│ Use CNContactStore change IDs │
│ Only process changed contacts │
└──────────────┬────────────────┘
               │
    ┌──────────▼──────────┐
    │ Conflicts found?    │
    │                     │
  NO│                  YES│
    │                     │
    ▼                     ▼
┌───────────┐    ┌─────────────────────────┐
│ Apply     │    │ Per setting:            │
│ silently  │    │                         │
│ → macOS   │    │ "Auto-resolve" ON:      │
│ notif:    │    │  Apply Google wins rule │
│ "3 contacts│   │                         │
│  synced"  │    │ "Auto-resolve" OFF:     │
└───────────┘    │  Pause auto-sync        │
                 │  Menu bar turns ⚠️      │
                 │  Notify user            │
                 │  "2 conflicts need      │
                 │   your review"          │
                 └─────────────────────────┘
```

---

### 2.4 Permission Recovery Flow

```
OAuth token expired or revoked
         │
         ▼
┌─────────────────────────────┐
│ SILENT REFRESH ATTEMPT      │
│ Use refresh token           │
└──────────┬──────────────────┘
           │
    ┌──────▼──────┐
    │  Success?   │
    │             │
 YES│          NO │
    │             │
    ▼             ▼
Continue    ┌─────────────────────────────┐
            │ REAUTH REQUIRED             │
            │                             │
            │ Menu bar icon: 🔴           │
            │ Tooltip: "Re-auth needed"   │
            │                             │
            │ Notification:               │
            │ "Google sign-in expired.    │
            │  Tap to reconnect."         │
            │                             │
            │ User taps → OAuth sheet     │
            │ opens inline                │
            └─────────────────────────────┘
```

---

## 3. SCREEN-BY-SCREEN UI WIREFRAMES

### 3.1 Menu Bar Dropdown

```
╔══════════════════════════════════╗
║  ∞  Contact SyncMate             ║  ← App icon + name
╠══════════════════════════════════╣
║  Status: ● Idle                  ║  ← Status dot (green/yellow/red)
║  Last synced: 2 min ago          ║
╠══════════════════════════════════╣
║  [  ⟳  Sync Now          ]       ║  ← Primary action
╠══════════════════════════════════╣
║  Google:  ✓ user@gmail.com       ║
║  Mac:     ✓ iCloud (247 contacts)║
╠══════════════════════════════════╣
║  Auto-sync: Every 30 min    ON ● ║
╠══════════════════════════════════╣
║  Open Dashboard...               ║
║  Sync History...                 ║
║  Preferences...                  ║
╠══════════════════════════════════╣
║  Quit Contact SyncMate           ║
╚══════════════════════════════════╝

States:
● Idle:    Green dot, "Last synced X ago"
● Syncing: Yellow dot + ∞ spin, "Syncing... 14/22"
● Error:   Red dot, "3 contacts need review"
● Offline: Gray dot, "No internet connection"
```

---

### 3.2 Main Window — Sync Dashboard

```
┌──────────────────────────────────────────────────────────────────┐
│  ∞  Contact SyncMate              [?] Help   [⚙] Settings  [×]  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │  📧 GOOGLE           │    │  💻 MAC CONTACTS      │            │
│  │  user@gmail.com     │    │  iCloud Account     │             │
│  │  1,247 contacts     │    │  983 contacts       │             │
│  │  [Change Account]   │    │  [Change Account]   │             │
│  └─────────────────────┘    └─────────────────────┘             │
│                    ↕  Last sync: Today 2:34 PM  ↕               │
│                                                                  │
│  ╔════════════════════════════════════════════════╗              │
│  ║  SYNC STATUS                           ● Idle  ║              │
│  ║  ────────────────────────────────────────────  ║              │
│  ║  Everything is up to date              ✓       ║              │
│  ║  No conflicts pending                  ✓       ║              │
│  ╚════════════════════════════════════════════════╝              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  SYNC DIRECTION                                          │   │
│  │  ○ Google → Mac   ● 2-Way   ○ Mac → Google              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────┐            │
│  │  ⟳ SYNC NOW           [ Manual  ▼ ]             │            │
│  └─────────────────────────────────────────────────┘            │
│                                                                  │
│  RECENT ACTIVITY                            [View Full Log →]   │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ Today 2:34 PM  •  Synced 3 contacts  •  0 conflicts         │
│  ✓ Today 9:01 AM  •  Synced 1 contact   •  0 conflicts         │
│  ⚠ Yesterday      •  2 conflicts resolved                       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
  Window size: 700 × 520 (fixed, non-resizable for simplicity)
```

---

### 3.3 Sync Preview Screen

```
┌──────────────────────────────────────────────────────────────────┐
│  ← Back    Preview Sync Changes                     [?] Help    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────┬────────┬────────┬────────┬────────┐                 │
│  │  +14   │  ~8    │  ×2    │  ⚠️ 3  │  ✓ All │                 │
│  │  Add   │  Edit  │  Del   │  Conf  │  OK    │                 │
│  └────────┴────────┴────────┴────────┴────────┘                 │
│  [All] [+ Add] [~ Edit] [× Delete] [⚠ Conflicts]               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  ⚠ CONFLICTS (3)                              [Expand ▼]│   │
│  │  ─────────────────────────────────────────────────────  │   │
│  │  Bob Johnson   Phone changed on both sides              │   │
│  │  Google: +1 555-0101  |  Mac: +1 555-0199               │   │
│  │  [Use Google] [Use Mac] [Skip]     [View Diff ▶]        │   │
│  │                                                         │   │
│  │  Alice Chen    Company edited on both                   │   │
│  │  [Use Google] [Use Mac] [Skip]     [View Diff ▶]        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  + NEW CONTACTS (14)                          [Expand ▼]│   │
│  │  ─────────────────────────────────────────────────────  │   │
│  │  [→Mac] Carlos Mendez    (from Google)  [Skip] [View]  │   │
│  │  [→Mac] Sarah Williams   (from Google)  [Skip] [View]  │   │
│  │  [→Ggl] Hiroshi Tanaka   (from Mac)     [Skip] [View]  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ⚠️ 3 conflicts need your decision before proceeding.           │
│                                                                  │
│  [Cancel]                [Resolve All →]  [Apply 22 Changes →]  │
└──────────────────────────────────────────────────────────────────┘
```

---

### 3.4 Contact Diff View (Sheet)

```
┌────────────────────────────────────────────────────────┐
│  Contact Diff: Bob Johnson                       [×]   │
├────────────────────────────────────────────────────────┤
│                                                        │
│         GOOGLE                    MAC                  │
│  ┌─────────────────────┐  ┌────────────────────────┐  │
│  │ Bob Johnson         │  │ Bob Johnson            │  │
│  │ ─────────────────── │  │ ───────────────────    │  │
│  │ 📞 +1 555-0101      │  │ 📞 +1 555-0199         │  │
│  │ ── CONFLICT ──▲──── │  │ ── CONFLICT ──▲────    │  │
│  │ 📧 bob@co.com       │  │ 📧 bob@co.com          │  │
│  │ 🏢 Acme Corp        │  │ 🏢 Acme Corp           │  │
│  │ Updated: 2h ago     │  │ Updated: 5h ago        │  │
│  └─────────────────────┘  └────────────────────────┘  │
│                                                        │
│  Conflicting field: Phone                              │
│  ┌────────────────────────────────────────────────┐   │
│  │  ● Use Google version  (+1 555-0101)           │   │
│  │  ○ Use Mac version     (+1 555-0199)           │   │
│  │  ○ Keep both numbers                           │   │
│  │  ○ Skip this contact                           │   │
│  └────────────────────────────────────────────────┘   │
│                                                        │
│  [← Previous]    1 of 3 conflicts    [Next →]          │
│  [Cancel]                            [Apply Decision]  │
└────────────────────────────────────────────────────────┘
```

---

### 3.5 Settings Window

```
┌──────────────────────────────────────────────────────────────────┐
│  Settings                                               [×]      │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────────────────────────┐ │
│  │  🔑 Accounts     │  │  ACCOUNTS                            │ │
│  │  🔄 Sync         │  │  ─────────────────────────────────   │ │
│  │  📋 Filters      │  │  Google Account                      │ │
│  │  🤝 Conflicts    │  │  user@gmail.com          [Sign Out]  │ │
│  │  🔔 Notifications│  │                          [Switch]    │ │
│  │  🖥 Appearance   │  │  ─────────────────────────────────   │ │
│  │  🛡 Privacy      │  │  Mac Account                         │ │
│  │  ℹ About        │  │  ● Auto (iCloud recommended)         │ │
│  └──────────────────┘  │  ○ iCloud                            │ │
│                        │  ○ On My Mac                         │ │
│                        │  ○ All accounts                      │ │
│                        └──────────────────────────────────────┘ │
│                                                                  │
│  [Restore Defaults]                               [Done]        │
└──────────────────────────────────────────────────────────────────┘

SYNC TAB:
┌──────────────────────────────────────────────────────────────────┐
│  SYNC MODE                                                       │
│  ● 2-Way  ○ Google → Mac  ○ Mac → Google                        │
│                                                                  │
│  AUTO SYNC                                                       │
│  Enable                                         [ON  ●]         │
│  Interval                                  [Every 30 min ▼]     │
│  Only on AC power                               [OFF ○]         │
│  Only when network available                    [ON  ●]         │
│                                                                  │
│  COMMON SETTINGS                                                 │
│  Sync deleted contacts                          [OFF ○]         │
│  Sync photos                                    [ON  ●]         │
│  Batch Google updates (100/batch)               [ON  ●]         │
│  Merge on 2-way conflict (default)              [ON  ●]         │
│                                                                  │
│  FIRST SYNC PROTECTION                                           │
│  Always preview before applying                 [ON  ●]         │
│  Confirm before deleting contacts               [ON  ●]         │
│  Maximum deletes per sync                     [ 50 contacts ▼]  │
└──────────────────────────────────────────────────────────────────┘
```

---

### 3.6 Sync History / Log

```
┌──────────────────────────────────────────────────────────────────┐
│  Sync History                                 [Export Log] [×]  │
├──────────────────────────────────────────────────────────────────┤
│  [All] [Success] [Warnings] [Errors]        🔍 Search...        │
│  ─────────────────────────────────────────────────────────────  │
│                                                                  │
│  ▼ Today — 2 sessions                                           │
│                                                                  │
│  ✓ 2:34 PM  2-Way  •  +3 added, ~1 updated  •  0 errors        │
│    └ Duration: 1.2s  •  API calls: 4  •  [View Details]         │
│                                                                  │
│  ✓ 9:01 AM  Auto   •  ~1 updated  •  0 errors                  │
│    └ Duration: 0.8s  •  API calls: 2  •  [View Details]         │
│                                                                  │
│  ▼ Yesterday — 1 session                                        │
│                                                                  │
│  ⚠ 4:15 PM  Manual  •  +5 added, 2 conflicts  •  0 errors      │
│    └ Conflicts resolved manually  •  [View Details]             │
│                                                                  │
│  ▼ March 20 — 1 session                                         │
│  ─────────────────────────────────────────────────────────────  │
│                                                                  │
│  [Load More]                                                     │
└──────────────────────────────────────────────────────────────────┘
```

---

### 3.7 Onboarding Screens

```
SCREEN 1/4 — Welcome
┌──────────────────────────────────────────────────┐
│                                                  │
│         ┌─────────────────────┐                  │
│         │   [INFINITY LOGO]   │                  │
│         │   animated glow     │                  │
│         └─────────────────────┘                  │
│                                                  │
│         Contact SyncMate                         │
│         Keep Google & Mac contacts               │
│         in perfect harmony.                      │
│                                                  │
│         ● ○ ○ ○                                  │
│                                                  │
│                    [Get Started →]               │
│                                                  │
└──────────────────────────────────────────────────┘

SCREEN 2/4 — Google Account
┌──────────────────────────────────────────────────┐
│  ← Back                            2 of 4        │
│                                                  │
│         [ABSTRACT CLOUD ICON]                    │
│         (colorful, no Google logo)               │
│                                                  │
│         Connect Cloud Contacts                   │
│         Sign in to access your                   │
│         Google Contacts securely.                │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  🔒 We only request Contacts access.     │   │
│  │  Your credentials are stored in          │   │
│  │  macOS Keychain.                         │   │
│  └──────────────────────────────────────────┘   │
│                                                  │
│         [Connect Google Account →]               │
│         Skip for now                             │
│                                                  │
└──────────────────────────────────────────────────┘

SCREEN 3/4 — Mac Contacts
┌──────────────────────────────────────────────────┐
│  ← Back                            3 of 4        │
│                                                  │
│         [ABSTRACT ADDRESS BOOK ICON]             │
│         (silhouette, no Apple logo)              │
│                                                  │
│         Access Local Contacts                    │
│         Contact SyncMate needs                   │
│         read/write access to your               │
│         Mac Contacts.                            │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  A system dialog will appear.            │   │
│  │  Tap "OK" to allow access.               │   │
│  └──────────────────────────────────────────┘   │
│                                                  │
│         [Allow Access →]                         │
│                                                  │
└──────────────────────────────────────────────────┘

SCREEN 4/4 — Sync Strategy
┌──────────────────────────────────────────────────┐
│  ← Back                            4 of 4        │
│                                                  │
│         Choose your sync strategy                │
│                                                  │
│  ┌─────────────────────────────────────────┐    │
│  │  ○ Google is my master                  │    │
│  │    Update Mac from Google               │    │
│  ├─────────────────────────────────────────┤    │
│  │  ○ Mac is my master                     │    │
│  │    Update Google from Mac               │    │
│  ├─────────────────────────────────────────┤    │
│  │  ● Merge both                           │    │
│  │    Keep the best of both worlds         │    │
│  └─────────────────────────────────────────┘    │
│                                                  │
│  💡 For your first sync, we'll show you a        │
│  full preview before anything changes.           │
│                                                  │
│  [Start First Sync →]                            │
│  [I'll do this later]                            │
│                                                  │
└──────────────────────────────────────────────────┘
```

---

## 4. DESIGN SYSTEM

### 4.1 Color Tokens

```swift
// MARK: - Brand Colors
let syncMateIndigo    = Color(hex: "#5B6AF9")  // Primary brand
let syncMatePurple    = Color(hex: "#9B5CF5")  // Secondary brand
let syncMateGradient  = LinearGradient(        // Infinity logo gradient
    colors: [syncMateIndigo, syncMatePurple],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

// MARK: - Sync State Colors
let statusIdle        = Color(hex: "#30D158")  // Green — macOS system green
let statusSyncing     = Color(hex: "#FF9F0A")  // Amber — macOS system yellow
let statusError       = Color(hex: "#FF453A")  // Red — macOS system red
let statusOffline     = Color(hex: "#8E8E93")  // Gray — macOS system gray
let statusConflict    = Color(hex: "#FF9F0A")  // Amber — same as syncing

// MARK: - Surface Colors (respect dark mode)
let surfacePrimary    = Color(.windowBackgroundColor)
let surfaceSecondary  = Color(.controlBackgroundColor)
let surfaceTertiary   = Color(.underPageBackgroundColor)

// MARK: - Text (semantic)
let textPrimary       = Color(.labelColor)
let textSecondary     = Color(.secondaryLabelColor)
let textTertiary      = Color(.tertiaryLabelColor)

// MARK: - Tailwind-equivalent tokens
// --color-brand-500:  #5B6AF9
// --color-brand-600:  #4552E8
// --color-green-500:  #30D158
// --color-amber-500:  #FF9F0A
// --color-red-500:    #FF453A
// --color-gray-400:   #8E8E93
```

---

### 4.2 Typography

```
Font: SF Pro (system default — no custom fonts needed)

Title Large:    .largeTitle   34pt  Bold      — Onboarding headlines
Title 1:        .title        28pt  Bold      — Window titles
Title 2:        .title2       22pt  Regular   — Section headers
Title 3:        .title3       20pt  Regular   — Card headers
Headline:       .headline     17pt  Semibold  — Contact names, labels
Body:           .body         17pt  Regular   — Main content
Callout:        .callout      16pt  Regular   — Descriptions
Subheadline:    .subheadline  15pt  Regular   — Secondary info
Footnote:       .footnote     13pt  Regular   — Timestamps, meta
Caption:        .caption      12pt  Regular   — Hints, tooltips
Caption 2:      .caption2     11pt  Regular   — Badges, micro labels
```

---

### 4.3 Spacing System (4pt grid)

```
spacing-1:   4px   — Icon internal padding
spacing-2:   8px   — Dense list items
spacing-3:  12px   — Default list item padding
spacing-4:  16px   — Card internal padding
spacing-5:  20px   — Section gaps
spacing-6:  24px   — Major section padding
spacing-8:  32px   — Window padding
spacing-10: 40px   — Onboarding padding
spacing-12: 48px   — Large gaps

Corner Radii:
radius-sm:   6px   — Tags, badges
radius-md:  10px   — Buttons, inputs
radius-lg:  14px   — Cards
radius-xl:  20px   — Panels, sheets
radius-app: 10.5% of icon size — App icon (macOS standard)
```

---

### 4.4 Component Specs

#### Button Styles

```swift
// Primary Action Button
// Background: brand gradient
// Foreground: white
// Padding: 12×20
// Radius: 10
// Font: .headline
// Hover: scale(1.01) + shadow
// Press: scale(0.99)

Button("Sync Now") { }
    .buttonStyle(SyncMateButtonStyle(variant: .primary))

// Secondary Button
// Background: .controlBackgroundColor
// Foreground: .labelColor
// Border: 1pt .separatorColor
// Same sizing as primary

// Destructive Button
// Background: clear
// Foreground: .red
// Hover: .red.opacity(0.1) background

// Ghost/Link Button
// Background: clear
// Foreground: .accentColor
// Underline on hover
```

#### Toggle

```swift
// Use native macOS Toggle
// Label on left, toggle on right
// Section trailing spacing: 16pt
Toggle("Sync deleted contacts", isOn: $settings.syncDeletedContacts)
    .toggleStyle(.switch)
```

#### Status Dot

```swift
struct StatusDot: View {
    enum State { case idle, syncing, error, offline, conflict }
    let state: State
    // Size: 8×8pt
    // idle:     #30D158 solid
    // syncing:  #FF9F0A pulsing (opacity 1.0 → 0.4, 0.8s repeat)
    // error:    #FF453A solid
    // offline:  #8E8E93 solid
    // conflict: #FF9F0A solid
}
```

#### Sync Direction Segmented Control

```swift
Picker("Sync Direction", selection: $settings.syncDirection) {
    Text("← Mac").tag(SyncDirection.macToGoogle)
    Text("⟷ 2-Way").tag(SyncDirection.twoWay)
    Text("Google →").tag(SyncDirection.googleToMac)
}
.pickerStyle(.segmented)
```

#### Contact Row

```swift
// Height: 56pt
// Left:   Avatar (32pt circle, initials fallback)
// Center: Name (.headline) + subtitle (.caption, secondary)
// Right:  Direction badge + action chevron
// Separator: 0.5pt, .separatorColor, inset 48pt from left
// Hover:  .controlBackgroundColor background fill
```

#### Action Badge

```swift
// "→ Mac", "→ Google", "⟷", "⚠️ Conflict", "× Delete"
// Background: state-specific color at 0.15 opacity
// Foreground: state-specific color
// Font: .caption, semibold
// Padding: 4×8
// Radius: 6
```

---

### 4.5 Animations

```swift
// Infinity Logo Spin (syncing state)
// Rotation: 0° → 360°
// Duration: 2.0s
// Easing: .linear
// Repeat: .forever

// Status Pulse (syncing dot)
// Opacity: 1.0 → 0.4 → 1.0
// Duration: 0.8s
// Easing: .easeInOut
// Repeat: .forever

// Screen Transitions
// Type: .slide (onboarding forward/back)
// Duration: 0.25s

// Row Appear (preview list)
// Offset: Y+8 → 0
// Opacity: 0 → 1
// Duration: 0.2s
// Stagger: 30ms per row

// Success Checkmark
// Scale: 0.5 → 1.1 → 1.0
// Duration: 0.4s
// Easing: .spring(response: 0.4, dampingFraction: 0.6)
```

---

## 5. ICONOGRAPHY & ASSETS

### 5.1 Menu Bar Icons

```
Menu bar icon variants (all 22×22pt @1x, 44×44pt @2x):

● IDLE:
  Shape: Infinity (∞) loop
  Stroke: 2pt
  Color: [Monochrome] Adapts to menu bar appearance
  Light mode: #000000 at 85% opacity
  Dark mode:  #FFFFFF at 85% opacity

● SYNCING:
  Same shape, animated rotation
  OR: static with motion-blur effect on one side

● ERROR:
  Infinity + small overlay badge (9×9pt)
  Badge: Filled circle, #FF453A
  Content: "!" or "×"

● CONFLICT:
  Infinity + small overlay badge
  Badge: Filled circle, #FF9F0A
  Content: "!"

Export sizes:
  menubar.png        @1x = 22×22
  menubar@2x.png     @2x = 44×44
  menubar_sync.png   animated variant
  menubar_error.png
  menubar_conflict.png
```

### 5.2 App Icon

```
Shape: macOS rounded square (superellipse)
       Use NSApplication standard 10.5% corner radius

Layers (back to front):
1. Background: brand gradient (indigo → purple, 135°)
2. Abstract contact cards: 2 overlapping card silhouettes
   - White, 80% opacity
   - Left card: slight tilt -8°
   - Right card: slight tilt +8°
3. Infinity loop: centered, white, stroke 4pt (scales with size)
   - Subtle glow: white 40% opacity, blur 12pt

Export sizes:
  AppIcon.appiconset/
  ├── 16.png      (16×16)
  ├── 32.png      (32×32)
  ├── 64.png      (64×64)
  ├── 128.png     (128×128)
  ├── 256.png     (256×256)
  ├── 512.png     (512×512)
  └── 1024.png    (1024×1024 — App Store)
```

### 5.3 Sync State Illustrations (for empty/loading states)

```
EMPTY STATE (no contacts yet):
  Two abstract person silhouettes, faded
  Small infinity below them
  Caption: "Connect your accounts to get started"

SYNCING STATE (full-window):
  Infinity loop, large (120pt), animated rotation
  Pulsing glow
  Caption: "Syncing contacts..."

SUCCESS STATE:
  Large checkmark (animated spring-in)
  Green glow
  Caption: "All synced!"

ERROR STATE:
  Infinity with break/gap in the loop
  Red tint
  Caption: "Something went wrong"

NO INTERNET STATE:
  Infinity + wifi slash icon
  Gray tint
  Caption: "No internet connection"
```

---

## 6. SYNC LOGIC & ERROR HANDLING SPEC

### 6.1 Diff Algorithm

```
INPUT:
  googleContacts: [UnifiedContact]  — from Google People API
  macContacts:    [UnifiedContact]  — from CNContactStore
  mappingDB:      [ContactMapping]  — local DB: googleId ↔ macId

PROCESS:
  1. Build lookup maps by ID
  2. For each Google contact:
     a. If in mappingDB → find Mac counterpart
        - Compare fields → classify as UNCHANGED / UPDATED / CONFLICT
     b. If not in mappingDB:
        - Fuzzy match by (name + email/phone) → potential MERGE candidate
        - If no match → classify as ADD_TO_MAC
  3. For each Mac contact:
     a. If in mappingDB → already processed in step 2
     b. If not in mappingDB and no fuzzy match → classify as ADD_TO_GOOGLE
  4. For contacts in mappingDB but missing from one side → classify as DELETED

OUTPUT:
  SyncPlan {
    adds:      [ContactChange]
    updates:   [ContactChange]
    deletes:   [ContactChange]   — gated by settings.syncDeletedContacts
    conflicts: [ContactConflict]
    merges:    [ContactMerge]
  }
```

### 6.2 Conflict Resolution Rules

```
AUTOMATIC RESOLUTION (when autoResolveConflicts = true):
  Rule 1: More recently modified wins
  Rule 2: If same timestamp → Google wins (configurable)
  Rule 3: If field-level conflict → apply per-field rules (future)

MANUAL RESOLUTION:
  User sees diff view, picks per-conflict

FIELD-LEVEL MERGE (future v2):
  "Always trust Google for: company, title"
  "Always trust Mac for: photos, notes"
```

### 6.3 Safety Gates

```
GATE 1: Max deletes
  If deletes > settings.maxDeletesPerSync:
  → Pause, show warning
  → "X contacts will be deleted. Continue?"

GATE 2: First sync protection
  If no mapping DB entries exist:
  → Force manual preview, no auto-apply

GATE 3: Large batch warning
  If total changes > 100:
  → "This sync will affect 142 contacts. Review?"

GATE 4: Google API rate limiting
  People API: 90 req/user/sec, 10 req/sec
  → Batch updates: 100 contacts per batch request
  → Retry with exponential backoff on 429

GATE 5: Token expiry
  OAuth access token: 1 hour TTL
  Refresh token: indefinite (until revoked)
  → Silent refresh before any API call
  → If refresh fails → stop sync, notify user
```

### 6.4 Error States & Recovery

```
ERROR                    | DISPLAYED AS          | RECOVERY ACTION
─────────────────────────┼───────────────────────┼──────────────────────
OAuth expired            | 🔴 menu bar            | Tap → re-auth sheet
No internet              | Gray menu bar          | Auto-retry on reconnect
Contacts permission lost | ⚠️ banner in dashboard | [Open System Settings]
API rate limit (429)     | ⏳ "Paused, retrying"  | Auto-retry in 30s
Partial sync failure     | ⚠️ n failed            | [Retry Failed] button
Contact write error      | Per-row error icon     | [Skip] or [Retry]
Merge conflict           | ⚠️ badge count         | User resolves manually
Google API error (5xx)   | Toast notification     | Auto-retry ×3, then alert
```

---

## 7. ASSET LIST FOR ENGINEERING HANDOFF

### 7.1 Images (to be created)

```
Assets.xcassets/
├── AppIcon.appiconset/          ← App icon all sizes
├── MenuBarIdle.imageset/        ← Monochrome ∞ (template image)
├── MenuBarSyncing.imageset/     ← Animated or alternate frame
├── MenuBarError.imageset/       ← ∞ + red badge
├── MenuBarConflict.imageset/    ← ∞ + amber badge
├── OnboardingWelcome.imageset/  ← Splash illustration
├── OnboardingGoogle.imageset/   ← Cloud silhouette
├── OnboardingMac.imageset/      ← Address book silhouette
├── EmptyState.imageset/         ← No contacts yet
├── SuccessCheckmark.imageset/   ← Animated success
└── ErrorState.imageset/         ← Broken sync illustration
```

### 7.2 SF Symbols Used

```swift
// Used throughout the app (no custom icons needed for these):
"person.2.circle.fill"        // App placeholder icon
"arrow.triangle.2.circlepath" // Sync action
"checkmark.circle.fill"       // Success states
"exclamationmark.triangle"    // Warning
"xmark.circle.fill"           // Error / dismiss
"gear"                        // Settings
"clock.arrow.circlepath"      // History
"wifi.slash"                  // No network
"lock.shield"                 // Privacy / security
"arrow.up.arrow.down"         // 2-way sync direction
"arrow.right.circle"          // Google → Mac
"arrow.left.circle"           // Mac → Google
"eye"                         // Preview
"pencil"                      // Edit
"trash"                       // Delete
"square.and.arrow.up"         // Export
"questionmark.circle"         // Help
"infinity"                    // Brand/sync motif
```

### 7.3 Localization Keys (initial set)

```
onboarding.welcome.title        = "Welcome to Contact SyncMate"
onboarding.welcome.subtitle     = "Keep Google & Mac contacts in perfect harmony."
onboarding.google.title         = "Connect Cloud Contacts"
onboarding.mac.title            = "Access Local Contacts"
onboarding.strategy.title       = "Choose your sync strategy"
sync.status.idle                = "Everything is up to date"
sync.status.syncing             = "Syncing contacts..."
sync.status.error               = "Sync error — tap for details"
sync.status.conflict            = "%d contacts need your review"
sync.preview.title              = "Preview Sync Changes"
sync.preview.apply              = "Apply %d Changes"
sync.complete.title             = "Sync Complete"
sync.complete.summary           = "+%d added, ~%d updated, ×%d deleted"
settings.title                  = "Settings"
error.oauth.expired             = "Google sign-in expired. Tap to reconnect."
error.noInternet                = "No internet connection."
error.contactsPermission        = "Contact access denied. Open System Settings."
```

---

## 8. RECOMMENDATIONS FOR FUTURE ENHANCEMENTS

### v1.1 — Polish
- [ ] Animated menu bar icon (spinning ∞ during sync)
- [ ] Touch Bar support (if still relevant)
- [ ] Keyboard shortcuts for all primary actions
- [ ] VoiceOver full accessibility pass

### v1.2 — Power Features
- [ ] **Field-level sync rules** ("Always trust Google for company")
- [ ] **Rollback / Undo last sync** (snapshot before each sync)
- [ ] **Dry run mode** (compute diff, never write)
- [ ] **CLI interface** (`contactsyncmate sync --mode=2way`)

### v2.0 — Advanced
- [ ] **Multiple sync profiles** (Personal: iCloud ↔ Gmail, Work: On My Mac ↔ Workspace)
- [ ] **Google ↔ Google sync** (two Google accounts via Mac as intermediary)
- [ ] **Smart duplicate resolver** (fuzzy match UI, side-by-side merge)
- [ ] **Notification Center integration** ("Synced 3 contacts in background")
- [ ] **Export/import** (CSV, VCF with mapping preservation)
- [ ] **iCloud Sharing** (share selected contacts group)

---

## 9. ACCESSIBILITY CHECKLIST

```
□ All interactive elements have accessibilityLabel
□ Status dots have accessibilityValue ("Idle", "Syncing", "Error")
□ Color is never the only differentiator (icons + text accompany all states)
□ Minimum tap target: 44×44pt
□ VoiceOver focus order is logical (top-left to bottom-right)
□ Dynamic Type supported up to .accessibility3
□ Reduce Motion: no spinning animations, use crossfade instead
□ High Contrast: increase separator and border opacity
□ Keyboard navigation: Tab order covers all interactive elements
□ Esc closes all sheets and modals
```

---

*Document version: 1.0 | Last updated: March 2026 | Author: Claude (AI Design Partner)*
