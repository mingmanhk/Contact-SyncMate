# App Store Connect — submission copy

Everything App Store Connect asks for, ready to paste. Field names match the
console. Character limits are Apple's; counts shown are for the text below.

---

## 1. App Information

| Field | Value |
|---|---|
| **Name** (30 max) | `Contact SyncMate` — 16 |
| **Subtitle** (30 max) | `Google ↔ Apple Contacts sync` — 29 |
| **Bundle ID** | `com.victorlam.ContactSyncMate` |
| **Primary category** | Utilities |
| **Secondary category** | Productivity |
| **Content rights** | Does not contain, show, or access third-party content |
| **Age rating** | 4+ (no objectionable content) |
| **Price** | Free |

> **Subtitle alternatives** if you want a different emphasis:
> - `Two-way contact sync, privately` — 30
> - `Contact sync, on your own Mac` — 29

---

## 2. Promotional text (170 max)

Editable without a new build — use it for release news.

```
Two-way sync between Google Contacts and Apple Contacts, on your Mac. Preview
every change, undo any sync. Optional AI matching sends nothing until you turn
it on.
```
*163 characters*

---

## 3. Description (4,000 max)

```
Contact SyncMate keeps your Google Contacts and your Apple Contacts matching
each other — in both directions, on a schedule you choose, with every change
shown to you before it is written.

Everything runs on your Mac. There is no Contact SyncMate account and no
server — and unless you enable optional AI matching, no way for anyone but you
to see your contacts.

It reconciles rather than overwrites: it remembers which Google contact
matches which Mac contact, moves only what genuinely changed since the last
run, merges field-level differences, and recognises the same person under
different spellings — so a second sync updates instead of duplicating.


TWO-WAY SYNC, OR ONE-WAY

• Two-way — changes flow both directions, with field-level merge when both
  sides changed
• Google → Mac — Google is the source of truth
• Mac → Google — the reverse
• Manual — preview and approve every single change first


SEE EVERY CHANGE BEFORE IT HAPPENS

Every add, update, deletion, and merge is listed with the exact fields
affected. Override any individual change, or use dry-run mode to compute
everything and write nothing.

Deletions never propagate unless you switch that on, and each one is confirmed
separately.


UNDO ANY SYNC

A snapshot is taken automatically before and after every sync. Roll back an
entire session, or restore one contact to any earlier version in the
side-by-side version browser.

A change log records what happened to every contact, in which direction, and
which fields were touched.


CATCHES DUPLICATES OTHERS MISS

Matching runs on your Mac and understands:
• Nicknames — Bob and Robert, Liz and Elizabeth
• Initials — J. Smith and John Smith
• Transposed names — Wei Li and Li Wei
• Phonetic surnames — Schmidt and Schmitt
• Phone formats — +1 415 555 0100 and 555-0100
• Email aliases — john+work@ and john@

High-confidence matches are merged only when the group is small and no critical
field conflicts. Anything ambiguous goes to you. Decisions are remembered, so a
pair you keep separate is never raised again.

Optionally, bring your own Anthropic API key to have borderline pairs
adjudicated by Claude. Off by default — nothing is sent until you also switch
on the consent toggle. When active, only the two records being compared are
sent — never your address book.


BUILT FOR macOS

• Menu bar app with live sync progress; optional Dock icon
• Notifications when a sync finishes, fails, or needs your review
• Shortcuts and Siri actions for automation
• Spotlight search across past syncs
• Background sync on your schedule — optionally only on AC power, on Wi-Fi,
  or when your Mac is idle
• Light, dark, or system appearance; seven accent colours
• Full keyboard navigation, VoiceOver, Reduce Motion, and Differentiate Without
  Color support


CHOOSE WHAT SYNCS

Photos, birthdays, addresses, websites, job titles and organisations can each be
turned on or off. Restrict sync to selected Mac groups or Google labels.
Optionally normalise name capitalisation — correct for "van der Berg",
"McDonald" and "O'Brien", never applied to Chinese, Japanese, or Korean names.

Export either address book to CSV or Excel whenever you want an archive.


PRIVACY

• All processing happens on your Mac unless you enable optional AI matching
• No server operated by the developer receives your contacts — there isn't one
• No analytics, no telemetry, no advertising, no data sale
• Sign-in tokens are stored in the macOS Keychain
• Revoke access any time from the app or your Google Account settings
• The source code is public and auditable

Contact SyncMate's use of information received from Google APIs adheres to the
Google API Services User Data Policy, including the Limited Use requirements.


REQUIREMENTS

macOS 14 Sonoma or later, and a Google account.

The Contacts note field is not synced — Apple restricts it to apps holding a
special entitlement, so that setting is disabled rather than failing silently.
Every other field syncs normally.
```
*3,984 characters — within the 4,000 limit.*

---

## 4. Keywords (100 max, comma-separated, no spaces after commas)

```
contacts,sync,google,gmail,icloud,address book,duplicate,merge,backup,vcard,crm,people,two-way
```
*98 characters*

Notes:
- Do **not** repeat words already in the app name or subtitle — Apple indexes those separately.
- `vcard` is included because users search it even though the app doesn't import `.vcf`; the description does not claim vCard support.

---

## 5. Support & marketing URLs

| Field | Value |
|---|---|
| **Support URL** (required) | `https://github.com/mingmanhk/Contact-SyncMate/issues` |
| **Marketing URL** (optional) | `https://mingmanhk.github.io/Contact-SyncMate/` |
| **Privacy Policy URL** (required) | `https://mingmanhk.github.io/Contact-SyncMate/privacy.html` |

---

## 6. App Privacy — nutrition labels

App Store Connect → App Privacy. Answer exactly as below.

### Does this app collect data?

> **No — "Data Not Collected"**

This is a deliberate decision, not an oversight, and this section is the
review-ready defence for it.

Apple's App Privacy definition of *collect* has two parts: data must be
transmitted **off-device**, *and* it must be retained **longer than necessary
to service the request in real time**. Data that leaves the device but is used
only to service the current request and not kept is explicitly excluded from
the label. Both of the app's transmissions fall inside that exclusion:

- **Google People API** — the sync itself. Contact records move between the
  user's Mac and the user's *own* Google account, which the user signed into
  and can revoke at any time. Each request is serviced in real time; nothing
  is retained anywhere the developer controls, because the developer controls
  nothing — there is no backend, no analytics SDK, no crash reporter.
- **Anthropic API** — optional AI duplicate matching. Off by default, and
  stays off until the user supplies their *own* API key **and** switches on a
  separate explicit consent toggle. When active, only the fields of the two
  records being compared are sent, solely for the real-time comparison; the
  verdict comes back and the exchange is over. The relationship is between
  the user and Anthropic under the user's key — the developer receives
  nothing, retains nothing, and could not access the data if it wanted to.

The binary says the same thing: the bundled privacy manifest
(`PrivacyInfo.xcprivacy`) declares `NSPrivacyCollectedDataTypes` as an empty
array and `NSPrivacyTracking = false`, so the label, the manifest, and the
actual network behaviour are consistent — the combination App Review checks.

**If App Review disagrees:** do not argue past one rejection. The prepared
revision is to declare **Contacts** as collected, **Data Not Linked to You**,
purpose **App Functionality**, marked **optional** — reflecting the AI tier's
transmission to Anthropic under the most conservative reading. Everything else
stays "Not Collected", and tracking stays "No" either way. Update only the
label in App Store Connect; no build change is needed.

### If the questionnaire forces itemisation

Some flows still walk you through categories. Answer:

| Data type | Collected? | If asked |
|---|:--:|---|
| Contacts | **No** | Data is exchanged only between the user's device and their own Google account. Not collected by the developer. |
| Contact Info (name, email) | **No** | The signed-in account address is displayed locally only. |
| Identifiers | **No** | No advertising ID, no device ID, no user ID. |
| Usage Data | **No** | No analytics or telemetry of any kind. |
| Diagnostics | **No** | No crash reporting SDK. |
| Location, Financial, Health, Browsing, Purchases, Sensitive Info, Other | **No** | Not accessed. |

### Tracking

| Question | Answer |
|---|---|
| Do you or your partners use data for tracking? | **No** |
| Does the app use the AppTrackingTransparency framework? | **No** |
| Third-party analytics or ad SDKs? | **None** |

### Third-party services to disclose

| Service | Role | Data sent | User-initiated? |
|---|---|---|---|
| Google People API | Core function — contact sync | Contact records, to the user's own Google account | Yes — user signs in |
| Anthropic API | Optional duplicate adjudication | Only the two records being compared | Yes — off by default, requires the user's own API key plus an explicit consent toggle |

Neither transmits data to the developer.

---

## 7. Review notes (App Review Information → Notes)

```
Contact SyncMate is a native macOS menu bar app that performs two-way
synchronisation between a user's Google Contacts and their local Apple
Contacts. There is no server component and no developer account system.

SIGNING IN
A Google account is required to exercise the sync features. Please sign in with
any Google account at: Settings → Accounts → "Sign In with Google".

If the OAuth consent screen shows "Google hasn't verified this app", click
Advanced → "Go to Contact SyncMate". Our Google OAuth verification is submitted
and in progress. The app requests only two scopes:
  • .../auth/contacts        — read + write, required for two-way sync
  • .../auth/userinfo.email  — to display which account is connected

macOS PERMISSIONS
On first launch the app requests Contacts access (NSContactsUsageDescription).
This is the app's core function. If the prompt is declined, Settings → Accounts
offers a direct link to System Settings → Privacy & Security → Contacts.

SUGGESTED REVIEW PATH (about 5 minutes)
1. Launch. The onboarding sheet appears; connect Google and grant Contacts.
2. Open the Dashboard and press "Sync Now". A preview lists every pending
   change — no data is written until you confirm.
3. Confirm. The menu bar icon shows live progress; a notification reports the
   result; Sync History logs each individual change.
4. Settings → Backups → "Create Backup Now" writes a snapshot, and any sync can
   be rolled back from there.
5. Settings → General demonstrates appearance, accent colour, menu bar
   customisation, and per-action confirmation preferences.

To test without touching a real address book, create two or three test contacts
in Apple Contacts first; the preview step will show exactly what would change.

NOTES ON SPECIFIC BEHAVIOURS
• The Contacts "note" field is intentionally not synced. It requires the
  com.apple.developer.contacts.notes entitlement, which we do not hold. The
  toggle is disabled with an explanation rather than failing silently.
• AI-assisted duplicate matching is disabled by default and requires the user
  to supply their own Anthropic API key and switch on an explicit consent
  toggle (Settings → AI Matching). Otherwise, matching is fully on-device.
• Backups default to the app container. If the user picks a custom folder, the
  grant is persisted as a security-scoped bookmark so it survives relaunch.
• The app requests no entitlements beyond sandbox, Contacts, outgoing network,
  user-selected files, and keychain access.

Source code is public: https://github.com/mingmanhk/Contact-SyncMate
```

**Demo account fields:** leave *"Sign-in required"* **checked**, and in the
username/password fields enter `See notes — reviewer may use any Google account`.
Do not supply a real credential; Google blocks sign-ins from unfamiliar
locations, which would fail review through no fault of the app.

---

## 8. Screenshots

Required: at least one. Recommended: four to five.

**Accepted macOS sizes** — pick one and use it consistently:
`1280 × 800` · `1440 × 900` · `2560 × 1600` · `2880 × 1800`

| # | Screen | Caption idea |
|---|---|---|
| 1 | Dashboard, sync just completed with the result banner | "See exactly what changed" |
| 2 | Sync Preview sheet listing adds / updates / merges | "Approve every change before it happens" |
| 3 | Menu bar popover open, showing status and Sync Now | "Live status from the menu bar" |
| 4 | Settings → Sync Fields | "Choose what syncs" |
| 5 | Backups tab, or the version-comparison view | "Undo any sync" |

Capture tips:
- `⇧⌘4` then `Space` captures a window with its shadow.
- Use a clean desktop and **fake contact names** — never real people's data.
- Take shots in both light and dark mode and pick whichever reads better; keep
  all five in the same mode for a consistent gallery.

---

## 9. Version information

| Field | Value |
|---|---|
| **Version** | `1.1` |
| **Build** | commit count at archive time — `git rev-list --count HEAD` (see [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), "Versioning & tagging") |
| **Copyright** | `2026 Victor Lam` |
| **What's New** | First release. |

---

## 10. Export compliance

`ITSAppUsesNonExemptEncryption = false` is already in `Info.plist`, so App Store
Connect will **not** ask about encryption on each submission.

Justification if ever queried: the app uses only HTTPS/TLS provided by the
operating system and implements no proprietary cryptography, which qualifies for
the standard exemption.

---

## 11. Pre-submission checklist

- [ ] App record created in App Store Connect with bundle ID `com.victorlam.ContactSyncMate`
- [ ] Rotated Google credentials verified working after a fresh sign-in
- [ ] Sandbox verified: pick a custom backup folder → quit → relaunch → backup still writes
- [ ] Screenshots captured at a single accepted size, using fake contacts
- [ ] Privacy labels set to "Data Not Collected", tracking "No"
- [ ] Review notes pasted, "Sign-in required" checked
- [ ] Archive → Distribute App → App Store Connect → Upload
- [ ] TestFlight self-test on a second Mac before submitting for review
