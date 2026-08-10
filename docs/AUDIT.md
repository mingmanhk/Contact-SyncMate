# Contact SyncMate — Full Audit Report

**Date:** 2026-08-09
**Scope:** Static audit of the native macOS/iOS SwiftUI app (Apple Contacts ⇄ Google Contacts sync). 61 Swift source files, 3 test files (126 tests passing).
**Method:** Parallel evidenced code review across five dimensions — data integrity, Swift concurrency/isolation, security & PII, error handling & quality, test coverage. No app run; findings are from source reading with `file:line` evidence.

> **Scope note.** The originating prompt was a *website* audit template. This is a native app with no server, no multi-user roles, and no web surface, so the following template sections are **Not Applicable** and were not fabricated into findings: SEO (meta/OG/canonical/robots.txt/sitemap.xml/JSON-LD/crawlability), Lighthouse / Core Web Vitals / bundle size / lazy-load / asset compression, web WCAG/axe-core, and web RBAC classes (IDOR, CSRF, XSS, privilege escalation — no server or roles exist). Everything that *does* map to a native app is covered below.

---

> **Update (2026-08-09, second pass):** An independent verification cycle re-checked every defect below against the current working tree, ran fresh audit sweeps over the recent commits and the previously-unaudited accessibility/localization/UX dimension, filed **all 41 findings as GitHub issues (#1–#41)**, and expanded the test suite from 126 to **176 tests (all passing)**. Results: **all 23 original defects are still OPEN** (the "audit fix" commits predate this report), and **18 new findings** were added (N-01..N-05 code, A-01..A-06 accessibility, L-01..L-05 localization, U-01..U-02 UX). See §6 for the new findings and §7 for the issue index.

> **Remediation complete (2026-08-09, evening):** All 41 issues (#1–#41) have been fixed, committed with `Fixes #N` references, and verified — test suite at **190 passing, 0 failures**, zero app-file compiler warnings. Every launch blocker below is resolved; the previously `XCTExpectFailure`-pinned regression tests now assert the fixed behavior directly. With the blockers closed and their regression tests green, the §1 condition is met: the verdict flips to **GO** (recommended pre-release step: one manual smoke pass of sign-in → preview → sync → cancel → restore on real accounts, since the automated suite does not exercise the live connectors).

## 1. Verdict at audit time: **NO-GO** (superseded — see remediation note above)

Do not ship to production until **D-01 (#1), D-02 (#2), D-06 (#6), D-07 (#7), and N-01 (#24)** are fixed. The original four blockers all remain open, and the fresh sweep added a fifth: the Google batch pre-pass bypasses the three-strike set-aside, so failed writes retry forever *and* their failures are silently swallowed (N-01). N-02/N-03 (#25/#26) share root causes with D-01/D-06 and should land in the same fixes. Once the blockers are resolved and their staged regression tests (see §3) flip from `XCTExpectFailure` to plain passes, this flips to **GO**.

| Severity | Count (was → now) | Blocks launch? |
|---|---|---|
| Critical | 1 → 1 | Yes (D-01 #1) |
| High | 5 → 10 | Yes (D-02, D-06, D-07, N-01); D-03/D-04 strongly recommended; A-01/L-01/L-02/U-01 pre-launch quality |
| Medium | 9 → 18 | No — fast-follow |
| Low | 8 → 12 | No — backlog |

**What's already good** (verified sound, no action): PKCE+`state` OAuth, tokens in Keychain (not UserDefaults), sign-out revokes server-side, no hardcoded client secret, no secrets in git history, ATS on, hardened runtime, minimal entitlements, the individual-vs-unified fetch fix, snapshot-restore identifier fix, etag stale-refresh retry, three-strike failure set-aside, and a strong diff test suite.

---

## 2. Defect List (GitHub-issue-ready)

Each defect below is formatted for direct issue creation: **Title · Severity · Location · Evidence · Impact · Steps to reproduce · Recommended fix · Acceptance criteria.**

---

### D-01 — Scheduled sync silently auto-merges unrelated contacts that share only a name
- **Severity:** Critical
- **Location:** `Contact SyncMate/SyncEngine.swift:657-664` (Step 2 `nameOnly`), `:714-720` (Step 3 Mac→Google identity match), executed in `executeSync` (`:279-334`)
- **Evidence:** Step 2 emits `ContactChange(action: .merge, userOverride: autoApply ? .merge : nil)` where `autoApply = (confidence == .exactEmail)`; Step 3 emits `.merge` with **no `userOverride`**. In `executeSync` the only deferral guard for an unreviewed run is `deletionIsHeldBack` — which covers deletes only. A `.merge` with `userOverride == nil` is **not** held back and falls straight into `performMerge`, which writes the union to *both* address books.
- **Impact:** On an automatic (never-reviewed) scheduled sync, a name-only fuzzy match or any phone/email identity collision silently fuses two different people and writes the merged record to both Apple and Google. This is the "worse than a duplicate — it destroys data" case the `identityKeys` doc comment explicitly warns about. The reviewed-preview path gates this correctly (`needsReview = .merge && userOverride == nil`); the auto path has no equivalent gate.
- **Steps to reproduce:** Have two distinct contacts named "David Chan" (no shared email/phone) in Apple Contacts. Enable auto-sync. Wait for a scheduled (unreviewed) run. Observe the two records merged into one on both sides.
- **Recommended fix:** In `executeSync`, hold back `.merge` changes with `userOverride == nil` whenever `!session.userReviewed` (mirror `deletionIsHeldBack`), counting them as deferred/needs-review. Alternatively, in `compute2WayChanges` only emit auto-applying merges for identity-key/`.exactEmail` confidence and never for `nameOnly` on unreviewed runs.
- **Acceptance criteria:** An unreviewed scheduled sync never merges two contacts whose only commonality is a name; such matches are deferred and surfaced for review; a regression test asserts a `nameOnly` match on `!userReviewed` produces a deferred (not applied) change.

---

### D-02 — Emptying a whole multi-value field never propagates; diff never converges
- **Severity:** High
- **Location:** `Contact SyncMate/SyncEngine.swift:2009-2039` (`ContactMapper.applyToMac`)
- **Evidence:** Each multi-value block is guarded by non-empty checks: `if !unified.phoneNumbers.isEmpty { … }` (same for emails, addresses, urls). If all phones were deleted on Google, `unified.phoneNumbers == []`, the guard is false, and existing Mac phones are left intact. Scalars have the analog: `if let v = unified.givenName { mac.givenName = v }`, but Google maps `""`→`nil` (`nilIfEmpty`), so a cleared name arrives as `nil` and is never blanked.
- **Impact:** Field deletions (Google→Mac) are lost. Worse, `diffFields` *does* detect the change ("Phone numbers changed"), so the sync reports success, leaves stale data, and **fires the same change on every subsequent sync forever** (never converges).
- **Steps to reproduce:** Delete all phone numbers from a contact on Google. Sync. Observe the Mac copy keeps the numbers and the change re-appears on every following sync.
- **Recommended fix:** For update/merge writes, assign multi-value fields unconditionally (write the empty array to clear). For scalars, define explicit clearing semantics so `applyToMac` and `diffFields` agree on empty-vs-present.
- **Acceptance criteria:** Clearing a multi-value or scalar field on one side propagates to the other; the diff converges (no repeat change on the next sync); regression tests cover cleared-phone-array and cleared-given-name round-trips.

---

### D-06 — `ContactMappingStore` uses blocking `sync`-barriers from the MainActor and mixes async/sync writes
- **Severity:** High *(consolidated: reported independently by the concurrency, data-integrity, and error-handling audits)*
- **Location:** `Contact SyncMate/SyncEngine.swift:2079-2147` — `saveMapping`/`deleteMapping(googleResourceName:)` use `queue.async(flags:.barrier)`; `deleteMapping(macContactIdentifier:)`/`deleteAllMappings` use `queue.sync(flags:.barrier)`; readers `getAllMappings`/`getMapping` use `queue.sync`.
- **Evidence:** The store is a default-`@MainActor` class. Blocking `queue.sync`/`sync(flags:.barrier)` invoked from the MainActor (e.g. `getAllMappings()` from `computeChanges`, and the two `sync`-barrier mutators) parks the main thread behind the concurrent queue — the exact hazard `ContactBackupManager.swift:441-451` documents as having deadlocked. Separately, the async-barrier writers vs sync readers create a **read-your-write** gap: `saveMapping` (async) immediately followed by `getAllMappings` (sync) may not observe the write, and a write enqueued right before termination in `saveToDisk()` can be lost.
- **Impact:** Main-thread stall / potential deadlock under contention; a just-saved mapping invisible to an immediately-following diff → spurious "deleted on Google" changes (the data-loss path warned about at `SyncEngine.swift:1471-1474`); a lost mapping write on exit misreads the pairing on the next two-way sync.
- **Steps to reproduce:** Hard to force deterministically; observe under a large sync with rapid save-then-read of mappings, or unlink a failed contact (calls the `sync`-barrier mutator) during an active sync.
- **Recommended fix:** Convert `ContactMappingStore` to an `actor` (or `@unchecked Sendable` with a private serial queue and **no** `sync` from the MainActor). Make all mutators consistent; guarantee read-after-write ordering. Never call `queue.sync` from the main actor.
- **Acceptance criteria:** No `queue.sync`/`sync(flags:.barrier)` called on the MainActor; save-then-read within a run always observes the write; mapping persists across app termination; no spurious deletes attributable to stale mapping reads.

---

### D-07 — `importBackupFromFile` re-enters `backupQueue.sync(flags:.barrier)` → guaranteed deadlock
- **Severity:** High
- **Location:** `Contact SyncMate/ContactBackupManager.swift:812-814`, inner call `saveBackupSession` (`:947-964`, itself `backupQueue.sync(flags:.barrier)` at `:961`)
- **Evidence:** `@MainActor func importBackupFromFile()` does `try backupQueue.sync(flags:.barrier) { try saveBackupSession(session) }`, and `saveBackupSession` *itself* calls `backupQueue.sync(flags:.barrier)`. A `sync`-barrier nested inside a `sync`-barrier on the same concurrent queue is a re-entrant deadlock — and it is a blocking barrier from the MainActor, the pattern the same file warns against at `:441-451`.
- **Impact:** App hangs when the user imports a backup file.
- **Steps to reproduce:** Use "Import backup from file" on a valid backup. Observe hang/beachball.
- **Recommended fix:** Remove the outer `backupQueue.sync` wrapper (`saveBackupSession` already synchronizes internally), or make the whole import path async off the MainActor.
- **Acceptance criteria:** Importing a backup completes without hanging; no nested same-queue `sync` barriers; a test or manual check confirms import succeeds.

---

### D-03 — Onboarding/Info.plist claim "contacts never leave your device" while the AI tier POSTs PII to Anthropic
- **Severity:** High (privacy/compliance)
- **Location:** `Contact SyncMate/OnboardingView.swift:248`; `Contact SyncMate/Info.plist:40` (`NSContactsUsageDescription`); sender `Contact SyncMate/AIContactMatcher.swift:376-407`
- **Evidence:** Onboarding says *"Your contacts stay on your device. No third-party servers are involved."* and the usage string says *"All processing happens on this Mac — your contacts are never sent to the developer."* But `makePrompt` builds a card with full name, nickname, org, title, **all** emails and **all** phone numbers and POSTs it to `https://api.anthropic.com/v1/messages` for borderline duplicate pairs.
- **Impact:** Full contact PII leaves the device to a third party (Anthropic) whenever the optional AI matcher is enabled. The unqualified "no third-party servers / never sent" claim is materially false in that mode — App Store review, GDPR, and user-trust exposure.
- **Steps to reproduce:** Enable AI matching, provide an Anthropic key, run a dedup scan with an ambiguous pair; observe the outbound request body contains contact fields.
- **Recommended fix:** Gate the claim on whether the AI tier is on; add explicit disclosure/consent at the point the user enters the Anthropic key ("ambiguous pairs' contact fields are sent to Anthropic's API"); consider pseudonymizing phone/email before sending; add a privacy policy line.
- **Acceptance criteria:** No unqualified "never leaves device" claim when AI matching is available; user sees and accepts explicit disclosure before any contact data is sent; disclosure text is verifiable in-app.

---

### D-04 — Google 401/429/500 friendly messages are dead code; users get a generic error
- **Severity:** High
- **Location:** consumer `Contact SyncMate/SyncCoordinator.swift:482-494`; producer `Contact SyncMate/GoogleContactsConnector.swift:875,885,901`
- **Evidence:** `friendlyMessage(for:)` branches on `nsError.domain == "com.google.HTTPStatus"` to give tailored 401/403/429/500 guidance, but the connector throws `GoogleContactsError.apiError(statusCode:message:)` — whose `as NSError` domain is `Contact_SyncMate.GoogleContactsError`, never `com.google.HTTPStatus`. Grep confirms nothing produces that domain.
- **Impact:** On an expired session (401) or rate limit (429), the user gets the raw description instead of the intended actionable hint ("Google session expired. Sign in again"). The 401 re-auth prompt never fires from this path.
- **Steps to reproduce:** Force a 401 (revoke/expire token) and trigger a sync; observe the generic message rather than the sign-in hint.
- **Recommended fix:** Delete the `com.google.HTTPStatus` branch; pattern-match the real type: `if case let GoogleContactsError.apiError(statusCode, _) = error { switch statusCode { case 401: … } }`.
- **Acceptance criteria:** 401/403/429/500 each surface their intended message; a test maps each status to the expected user-facing string.

---

### D-05 — `mergeAddresses` de-dupes on street only; drops distinct addresses and nil-street addresses
- **Severity:** Medium
- **Location:** `Contact SyncMate/SyncEngine.swift:1670-1680`; blunter variant `Contact SyncMate/DeduplicationCoordinator.swift:273`
- **Evidence:** Keeps a secondary address only `if let street = addr.street?.lowercased(), !existingStreets.contains(street)`. Two different addresses sharing a street line collapse to one; a nil-street address is always dropped (the `if let` fails). `mergeInto` (`DeduplicationCoordinator.swift:273`) is worse: `primary.postalAddresses.isEmpty ? secondary : primary` discards all secondary addresses whenever primary has any.
- **Impact:** Silent loss of a secondary postal address during merge.
- **Recommended fix:** Key de-dup on the full normalized address (`normalizeAddress`), including nil-street entries.
- **Acceptance criteria:** Merging two contacts with distinct addresses (incl. same-street-different-city and nil-street) preserves both; regression test asserts count and content.

---

### D-08 — Merge path writes against a diff-time Google snapshot (lost update)
- **Severity:** Medium
- **Location:** `Contact SyncMate/SyncEngine.swift:1602-1607` (`performMerge`)
- **Evidence:** The Mac side is re-fetched live (`fetchContactSync`), but the merge computes the union from the **Google `sourceContact`/`targetContact` captured at diff time**, which can be minutes old (dedup scan + AI matching + user review). A concurrent Google-side edit between diff and apply is overwritten.
- **Impact:** Field-level lost update on the Google side for merges (recoverable from backup, but a real lost edit).
- **Recommended fix:** Re-fetch the individual Google contact before computing the merged union (as the Mac side already does).
- **Acceptance criteria:** A merge applied after a concurrent Google edit does not clobber that edit; the merge uses freshly-fetched Google values.

---

### D-09 — Dedup merge leaves stale mappings and a partial address book on deletion failure
- **Severity:** Medium
- **Location:** `Contact SyncMate/DeduplicationCoordinator.swift:180-235`
- **Evidence:** After writing the merged payload into `primary` and deleting `others`, (a) the deleted `others`' mappings are never removed from `ContactMappingStore` and no mapping is saved for the surviving primary; (b) if the 2nd of several `others` deletions throws, the 1st is already deleted and the merge already applied, but the `catch` only logs `<group>.failed` with no `SyncFailureStore` entry (unlike the SyncEngine path).
- **Impact:** Stale mappings pointing at deleted records (the exact case the Unlink feature exists to clean up), created silently; partial merges invisible to the user.
- **Recommended fix:** Delete the `others`' mappings as records are removed; save the primary's merged mapping; record merge failures into `SyncFailureStore`.
- **Acceptance criteria:** After a merge, no mapping references a deleted record; a partial-merge failure appears in the failures list.

---

### D-10 — Google refresh tokens saved without `kSecAttrAccessible` (eligible for iCloud Keychain sync)
- **Severity:** Medium
- **Location:** `Contact SyncMate/GoogleOAuthManager.swift:829-847` (`saveToKeychain`)
- **Evidence:** The query sets class/account/service/value but **no `kSecAttrAccessible`**, so items take the syncable default. By contrast `KeychainStore.swift:84,92` (Anthropic key) correctly sets `kSecAttrAccessibleAfterFirstUnlock`. `signOut()`'s own comment (`:360`) worries about a synced Keychain as an attack vector — while the save path enables exactly that.
- **Impact:** Long-lived refresh tokens (full read/write to the user's Google contacts) may propagate to other devices/backups, widening theft surface.
- **Recommended fix:** Add `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (or `WhenUnlockedThisDeviceOnly`) to the token save query; ideally unify on `KeychainStore`.
- **Acceptance criteria:** Google tokens are device-bound (non-syncing); a check confirms the accessibility attribute is set.

---

### D-11 — Unencrypted PII (incl. photos/notes) written to disk in backups and sync history
- **Severity:** Medium
- **Location:** `Contact SyncMate/ContactBackupManager.swift:966-971,989-997` (backup JSON incl. `imageData`, notes, addresses at `:38-101`); `Contact SyncMate/SyncHistory.swift:138-143` (`sync_history.json` with `contactName`)
- **Evidence:** `saveBackupSession` encodes the full `BackupSession` to `<id>.json` via `data.write(...)` with no encryption. With a user-picked custom backup folder (`chooseBackupDirectory`), these plaintext files can land in a cloud-synced folder (Dropbox/iCloud Drive), silently uploading PII. Sync-history export offers name redaction (`SyncHistoryView.swift:68`) but the on-disk file is never redacted.
- **Impact:** Full plaintext copy of both address books at rest (only FileVault, which is optional, protects it); PII can be uploaded to a third-party sync service.
- **Recommended fix:** Encrypt backup files at rest (CryptoKit `AES.GCM`, key in Keychain); warn when a chosen folder is inside a known cloud-sync path; document that backups contain unencrypted PII.
- **Acceptance criteria:** Backups are encrypted at rest or the user is clearly warned; documented behavior matches reality.

---

### D-12 — `firebase-debug.log` is committed despite `*.log` being gitignored
- **Severity:** Medium
- **Location:** repo root `firebase-debug.log` (tracked); `.gitignore:78` (`*.log`)
- **Evidence:** `git ls-files --error-unmatch firebase-debug.log` succeeds; the file predates the ignore rule so `.gitignore` doesn't cover it. Content is benign now (`No OAuth tokens found`), but Firebase debug logs *can* contain OAuth/refresh tokens.
- **Impact:** A future Firebase log with tokens would slip in unnoticed since the human assumes `*.log` protects them.
- **Recommended fix:** `git rm --cached firebase-debug.log` and commit; verify it stays ignored; confirm whether Firebase is even used by this client.
- **Acceptance criteria:** The file is untracked and ignored; no `.log` files are tracked.

---

### D-13 — `checkExistingAuth()` can leave `isAuthenticated` stale (UI says "connected", calls 401)
- **Severity:** Medium
- **Location:** `Contact SyncMate/GoogleOAuthManager.swift:105-122`
- **Evidence:** The final `else if let refreshToken = getRefreshToken()` has no trailing `else`. With an expired access token and no refresh token, the method returns without resolving `isAuthenticated`; the expired-with-refresh branch only flips it later, async, if the refresh throws `invalid_grant`.
- **Impact:** After the first launch, any later `checkExistingAuth()` on an expired/unrefreshable credential can leave the UI claiming "connected" while every call 401s — the exact failure the author's own comment (`:95-98`) warns about.
- **Recommended fix:** Add `else { isAuthenticated = false }` so the flag is always resolved synchronously.
- **Acceptance criteria:** After `checkExistingAuth()` on an expired/no-refresh credential, `isAuthenticated == false`; a test covers this branch.

---

### D-14 — `SyncEngine.isRunning` check-then-set has a suspension gap (double-start)
- **Severity:** Medium
- **Location:** `Contact SyncMate/SyncEngine.swift:61-69` (`prepareManualSync`), `:183-195` (`executeSync`)
- **Evidence:** `guard !isRunning else { throw }` is followed by `await MainActor.run { isRunning = true }`. The engine is already MainActor-isolated, so the `await` introduces a suspension between guard and set; two overlapping calls can both pass. (`SyncCoordinator`'s own `phase.isActive` gate makes this defense-in-depth today.)
- **Impact:** Potential concurrent sync runs mutating shared stores.
- **Recommended fix:** Set `isRunning = true` synchronously in the same isolated step as the guard (drop the `await MainActor.run` wrapper for the flag).
- **Acceptance criteria:** No suspension separates the `isRunning` check and set; overlapping `prepareManualSync` calls cannot both proceed.

---

### D-15 — OAuth `signIn` continuation `isResumed` flag is racy (double-resume trap risk)
- **Severity:** Medium
- **Location:** `Contact SyncMate/GoogleOAuthManager.swift:248-308`
- **Evidence:** The `ASWebAuthenticationSession` completion handler runs on an arbitrary queue and captures `self` plus a local `isResumed` Bool mutated from both the completion closure and a nested `Task`, with no synchronization. A continuation resumed twice traps.
- **Impact:** Sign-in crash under an unlucky interleaving (guarded only by ordering luck today).
- **Recommended fix:** Guard `isResumed` with an actor/atomic, or restructure to a single resumption point.
- **Acceptance criteria:** The continuation can resume at most once under concurrent callback+task; no double-resume trap.

---

### D-16 — Batch mapping write stamps `lastSyncedAt` before the paired side is confirmed
- **Severity:** Medium
- **Location:** `Contact SyncMate/SyncEngine.swift:1319-1377` (`runCreateBatch`/`runUpdateBatch`) interacting with `executeSync:279-334`
- **Evidence:** The batch pre-pass `saveMapping(... lastSyncedAt: Date())`. If the Mac side of the same two-way pair later fails in the per-contact loop, the mapping already claims "synced now," skewing the next diff's `gModified > syncedAt` comparison.
- **Impact:** `lastSyncedAt` can advance past a partially-applied change, under-reporting a genuine pending edit on the failed side (can drop a real edit — edge case).
- **Recommended fix:** Stamp `lastSyncedAt` only once both sides of a pair are confirmed written.
- **Acceptance criteria:** A pair with one failed side does not advance `lastSyncedAt`; the pending edit re-appears next sync.

---

### D-17 — `ContactBackupManager` init catch-path assigns `backupSessions` off the barrier queue
- **Severity:** Low
- **Location:** `Contact SyncMate/ContactBackupManager.swift:1016-1020` (catch) vs `:1008` (success, barrier-guarded)
- **Evidence:** On a corrupt/missing index the catch assigns `backupSessions = []` directly on the MainActor while `init` also fires `pruneOldBackups()`/`removeOrphanedBackupFiles()` that barrier-mutate the array async — an unsynchronized write to the undo-of-record array.
- **Impact:** Narrow race on corrupt-index launch.
- **Recommended fix:** Route the catch-path assignment through `backupQueue.async(flags:.barrier)`.
- **Acceptance criteria:** All `backupSessions` writes go through the barrier queue.

---

### D-18 — `Dictionary(uniqueKeysWithValues:)` in dedup scan can trap on duplicate keys
- **Severity:** Low
- **Location:** `Contact SyncMate/ContactDeduplicator.swift:411-413`
- **Evidence:** `Dictionary(uniqueKeysWithValues: existingMappings.map { ($0.googleResourceName, $0.macContactIdentifier) })`. Safe today (store key is unique on Google side), but `compute1WayChanges` (`SyncEngine.swift:782-794`) already switched to `uniquingKeysWith` with a comment that the key is only unique on one side. A duplicate key from a legacy/imported file traps.
- **Impact:** Latent crash in the scan on malformed mapping data.
- **Recommended fix:** Use `uniquingKeysWith: { _, latest in latest }` here too.
- **Acceptance criteria:** Duplicate-keyed mapping data does not crash the scan.

---

### D-19 — AI matcher swallows every HTTP/parse error to `nil` with no diagnostic
- **Severity:** Low
- **Location:** `Contact SyncMate/AIContactMatcher.swift:362,367-373,409-426`
- **Evidence:** `try? JSONSerialization... else return nil`, `return nil` for any non-2xx with the body discarded, `catch { return nil }`. A 401 (bad Anthropic key), 429, or 400 is indistinguishable from "not a duplicate."
- **Impact:** A user with a wrong API key gets zero signal that AI matching is silently off on every contact.
- **Recommended fix:** Keep the nil fallback but log the status/error once (rate-limited) and surface "AI matching unavailable" in the UI.
- **Acceptance criteria:** A misconfigured key produces a diagnosable signal.

---

### D-20 — Pre-sync backup failure aborts the entire sync with no fallback choice
- **Severity:** Low
- **Location:** `Contact SyncMate/SyncEngine.swift:135-143` (pre-sync, throws) vs `:404-428` (post-sync, logged)
- **Evidence:** Pre-sync `try await createPreSyncBackup(...)` inside the `do` aborts sync prep on failure; the same failure post-sync is tolerated. A user with a full/read-only backup destination can then never sync.
- **Impact:** A backup-write failure becomes an un-actionable "sync won't run."
- **Recommended fix:** Surface a "sync without backup?" choice, or fall back to the container backup directory.
- **Acceptance criteria:** A backup-write failure does not silently block syncing without a user-visible option.

---

### D-21 — `AutoSyncScheduler` reschedule writes `nextScheduledSync` from a stale interval
- **Severity:** Low
- **Location:** `Contact SyncMate/AutoSyncScheduler.swift:88-96`
- **Evidence:** The timer's `Task { @MainActor in await triggerSync(); appState?.nextScheduledSync = Date().addingTimeInterval(interval) }` captures `interval`; if `reschedule()` runs (interval changed) while `triggerSync` awaits, the resumed task writes a stale next-fire time.
- **Impact:** Settings countdown momentarily shows a wrong next-fire time. No data effect.
- **Recommended fix:** Recompute the next fire date from current settings inside the MainActor block, or use a generation token.
- **Acceptance criteria:** Next-fire time reflects the current interval after a mid-sync change.

---

### D-22 — `SyncErrorExplanation` collapses distinct CN validation codes to one message
- **Severity:** Low
- **Location:** `Contact SyncMate/SyncErrorExplanation.swift:81-83`
- **Evidence:** `.validationConfigurationError, .validationMultipleErrors, .validationTypeMismatch` all map to "Contacts rejected one of the fields." The offending key path is often in `userInfo`.
- **Impact:** User can't tell which field to fix (raw message is preserved alongside, so minor).
- **Recommended fix:** Append the offending key path (`CNKeyPathErrorKey`/`NSValidationKeyErrorKey`) when present.
- **Acceptance criteria:** Validation errors name the failing field when the OS provides it.

---

### D-23 — `AutoSyncConditions.pathMonitor` / other statics are isolation-incorrect (Swift 6)
- **Severity:** Low
- **Location:** `Contact SyncMate/AutoSyncConditions.swift:112-116` (`static let pathMonitor`, updates on a background queue, read from MainActor at `:93-96`); related: `AppState` not explicitly `@MainActor` (`AppState.swift:25-29`).
- **Evidence:** Project builds in **Swift 5 mode** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and strict concurrency **off**, so these compile but are not race-checked. `NWPathMonitor.currentPath` reads are Apple-sanctioned, but the shared monitor is cross-thread state that would need `nonisolated`/`Sendable` under Swift 6.
- **Impact:** Low runtime risk today; blocks a clean Swift 6 strict-concurrency migration.
- **Recommended fix:** Mark `pathMonitor` `nonisolated(unsafe)` with a rationale; annotate `AppState`/`GoogleOAuthManager` explicitly `@MainActor`; plan a Swift 6 strict-concurrency pass.
- **Acceptance criteria:** The project's isolation invariants are explicit (not inherited); a tracked plan exists for enabling strict concurrency.

---

## 3. Test Coverage & Test Plan

**Current state:** 126 tests, 0 failures. Run with:
```
xcodebuild -project "Contact SyncMate.xcodeproj" -scheme "Contact SyncMate" test
```
(The app is a menu-bar accessory that never quits, so `xcodebuild`'s exit code is unreliable — `Scripts/verify-contact-syncmate.sh` polls the log for `Test Suite 'All tests' passed|failed`.)

**Well covered:** name formatting (thorough), diff/convergence (photo/phone/birthday/URL/country), `ContactMapper` round-trips, `identityKeys`, normalizer basics, dedup blocking keys / candidate-pair count, mapping store CRUD, sync history retention.

**Highest-value gaps (pure logic, currently untested, bugs here corrupt data):**

| Priority | Unit | Why risky | Test to add |
|---|---|---|---|
| Critical | `ContactDeduplicator.calculateMatchScore` | 8-rule scoring decides auto-merge (≥80) vs confirm (≥50); only the async wrapper is tested | Per-rule score asserts; the −20 penalty + "both lack contact info" exception; breakdown sums to total |
| Critical | Conflict auto-resolution branches | Only `.alwaysAsk` tested; `.preferGoogle/.preferMac/.mergeBoth` overwrite user data | One test per resolution mode asserting direction/action, incl. "neither timestamp changed" |
| Critical | `SyncEngine` merge helpers (`mergeContacts`/`mergePhoneNumbers`/`mergeEmails`/`mergeAddresses`/`mergeURLs`/`mergeNotes`) | Second parallel merge impl, pure, untested; **covers D-05** | Field-union + dedup-key per helper |
| Critical | `DeduplicationCoordinator.mergeInto` + `mergeUniquePhones/Emails` | The write-back merge; **covers D-05/D-09** | primary-wins, secondary-fills-gap, digit-only phone dedup, case-insensitive email dedup, note concat |
| Critical | Backup `createSnapshot` ↔ `snapshotToUnifiedContact` round-trip | Restore/undo path; identifier reconstruction is source-dependent | Round-trip equality incl. Google/Mac id; old-backup (missing v2 fields) still decodes |
| High | `deletionIsHeldBack` / asymmetric deletion / `writesToGoogle` | Pure/settings-gated, untested; **covers D-01 regression** | Hold-back by setting+review state; unreviewed `.merge` is deferred; asymmetric delete each direction |
| High | `SyncFailureStore` (3-strike `shouldSkip`, `recordFailure`, `clearFailure`, `ignore`, Codable) | Entirely untested | 3rd-strike threshold, ignore flag, round-trip |
| High | `failureKey(for:)` | Wrong key sets aside the wrong contact | prefers-Mac, falls-back-to-Google, nil for pure add |
| High | `blockingKeys`/`candidatePairs` at 499/500/501 | Exhaustive-vs-blocked switch + pair encoding | Boundary tests; no duplicate pairs |
| High | `normalizeEmail` Gmail dot-strip, `areNamesSimilar`, `levenshteinDistance`, `normalizeAddress` | Feed matching decisions, untested | `john.smith@gmail.com == johnsmith@gmail.com`; Levenshtein distances |
| Medium | `applyToMac` clearing semantics | **Direct D-02 regression** | cleared-phone-array and cleared-given-name propagate + converge |
| Medium | Google status→message mapping | **Direct D-04 regression** | 401/403/429/500 → expected string |

All Critical/High rows are pure or settings-gated (pin `AppSettings` in `setUp`/`tearDown`, as `SyncEngineDiffTests` already does) — no mocking needed. Connectors, OAuth, disk persistence, and IOKit/Network condition checks need mocks/integration and are lower ROI.

---

## 4. Remediation Roadmap

**Sprint 1 — Launch blockers (must fix before GO):**
- D-01 (silent auto-merge), D-02 (field-clear non-convergence), D-06 (mapping store isolation), D-07 (import deadlock).
- Add the Critical/High regression tests above that pin these fixes (esp. deferred-merge, clearing round-trip, mapping read-your-write).
- Est: ~3–5 days. Owner: sync-engine owner.

**Sprint 2 — Privacy/security + high-visibility correctness:**
- D-03 (AI privacy disclosure/consent — also App Store risk), D-04 (Google error messages), D-10 (device-bound tokens), D-12 (untrack log).
- Est: ~2–3 days.

**Sprint 3 — Data-safety fast-follow:**
- D-05, D-08, D-09, D-11 (encrypt backups), D-13, D-14, D-15, D-16.
- Backfill the High-priority test rows (SyncFailureStore, calculateMatchScore, conflict resolution, backup round-trip).
- Est: ~1 week.

**Backlog — Low severity + hardening:**
- D-17…D-23, plus a planned Swift 6 strict-concurrency migration (D-23 is the entry point) and CI wiring (below).

---

## 5. Other Template Dimensions (native mapping)

- **Observability:** No crash/error telemetry (Firebase present in repo but the client's use is unclear — see D-12). Consider opt-in crash reporting; `SyncHistory` is a good local audit trail already.
- **CI/CD:** Tests run via `xcodebuild` + a polling verify script; no evidence of a hosted CI pipeline. Recommend a GitHub Actions macOS workflow running the same `xcodebuild test` on PRs, plus the pre-commit secret scanner already in place.
- **Accessibility (native):** Not audited in depth here (no findings claimed). Recommend a VoiceOver + Dynamic Type + keyboard-focus pass on the main SwiftUI views before launch.
- **Performance:** `PerformanceTests` provides timing smoke gates; dedup uses blocking keys with an exhaustive-vs-blocked switch at 500 contacts (see D-18). Validate on a 5k–10k contact set before GO.
- **Compliance/PII:** D-03, D-11, and retention (D-11's age-cap note) are the material items; a written privacy policy covering the AI tier and on-disk backups is advisable.

---

## 6. Verification-Pass Findings (2026-08-09, second pass)

Full bodies with evidence, repro, fix, and acceptance criteria are in the linked issues.

**New code defects (fresh sweep of recent commits):**
- **N-01 (#24, High)** — Google batch pre-pass bypasses the three-strike set-aside (`SyncEngine.swift:221,244-254,1281-1318`): set-aside contacts are still batched to Google every sync, batch failures are never recorded, and a recovered contact is never un-set-aside. Blocker.
- **N-02 (#25, Medium)** — the new unknown-vs-unknown conflict branch (`SyncEngine.swift:592-628`) makes *every ordinary Mac edit* an unreviewed `.merge` that the D-01 hole auto-applies — `.alwaysAsk` never asks on scheduled syncs. Fix with D-01.
- **N-03 (#26, Medium)** — Unlink writes through a throwaway `ContactMappingStore()` (`SyncFailuresView.swift:192`); a concurrent sync's instance resurrects the deleted mapping (whole-file last-writer-wins). Fix with D-06 (store must become a shared singleton/actor — 8 call sites construct fresh instances).
- **N-04 (#27, Low)** — email-match diff reason embeds `displayName` with no colon, defeating the histogram's name-free sanitizer (`SyncEngine.swift:661` vs `:979-991`).
- **N-05 (#28, Low)** — AI matcher prompt injection: contact-controlled text steers the dedup recommendation bucket and unsanitized AI "reasoning" renders in the UI.

**Verification updates to originals:** D-07 is now a *guaranteed* deadlock (commit 3a765b9's inner barrier) plus new MainActor-blocking backup saves; D-03 has a third unqualified privacy claim (`OnboardingView.swift:159`); D-06 gained the multi-instance amplifier above.

**Accessibility (A), Localization (L), UX (U)** — first audit of this dimension:
- **A-01 (#29, High)** — sync-preview rows: add vs **delete** distinguishable only by an unlabeled icon; VoiceOver users can't tell a deletion before applying. A-02..A-04 (#30–#32, Medium) — unnamed menu-bar toggle, `.onTapGesture` rows invisible to keyboard/VoiceOver, icon-only buttons without labels. A-05/A-06 (#33/#34, Low) — sub-11pt fixed fonts, raw system colors bypassing the semantic tokens.
- **L-01 (#35, High)** — the entire Sync Failures feature is untranslated in zh-Hans/zh-Hant (17 keys). **L-02 (#36, High)** — `String`-typed view props render verbatim, so the menu-bar status area stays English in Chinese even where translations exist. L-03..L-05 (#37–#39, Medium) — English-only error hints, hand-rolled plurals/rawValue grammar, English-only `NSContactsUsageDescription`.
- **U-01 (#40, High)** — long-running syncs cannot be cancelled (progress but no way out). U-02 (#41, Low) — history day-groups sort alphabetically.

**Positives from this pass:** `StatusDot` is exemplary a11y (Differentiate Without Color, Reduce Motion, proper labels); destructive-action confirmations are unusually thorough (two-tier Reset with honest consequences, restore safety snapshots); the 541-key localization catalog and language-switcher infrastructure are solid — the gaps are usage patterns, not architecture.

---

## 7. GitHub Issue Index & Test-Suite Status

All 41 findings filed 2026-08-09 on `mingmanhk/Contact-SyncMate` with `audit`, `severity:*`, and `area:*` labels:
**#1–#23** = D-01–D-23 (in order) · **#24–#28** = N-01–N-05 · **#29–#34** = A-01–A-06 · **#35–#39** = L-01–L-05 · **#40–#41** = U-01–U-02.

**Test suite: 176 tests, 0 failures** (was 126). The 50 new tests implement every Critical row of §3: `calculateMatchScore` per-rule scoring, all four conflict-resolution modes (both branches), the SyncEngine merge helpers, `DeduplicationCoordinator.mergeInto`, the backup snapshot round-trip, `SyncFailureStore` three-strike semantics, and `failureKey`/`deletionIsHeldBack`. Four tests pin known-open bugs via strict `XCTExpectFailure` and will flag automatically when the fix lands: `test_unreviewedMerge_isDeferred` (#1), `test_mergeAddresses_keepsSecondaryAddressWithoutStreet` / `test_mergeAddresses_keepsSameStreetDifferentCity` (#5), `test_mergeInto_keepsSecondaryAddresses` (#5). Twelve pure `private` helpers were made `internal // internal for testing` (no behavior change).

**Updated roadmap (supersedes §4 sprint contents; structure unchanged):**
- **Sprint 1 — blockers:** #1, #2, #6, #7, #24 (+#25, #26 in the same fixes). Regression tests already staged. Est. 4–6 days.
- **Sprint 2 — privacy/security:** #3, #4, #10, #12 (+#28). Est. 2–3 days.
- **Sprint 3 — data-safety fast-follow:** #5, #8, #9, #11, #13, #14, #15, #16, #27. Est. ~1 week.
- **Sprint 4 — launch polish (a11y/l10n/UX High):** #29, #35, #36, #40 (+ #30–#32, #37–#39 as capacity allows). Est. 3–4 days.
- **Backlog:** #17–#23, #33, #34, #41 + Swift 6 strict-concurrency migration + CI (GitHub Actions macOS workflow running `xcodebuild test` on PRs — repo currently has **no CI**).

---

*Generated by an automated multi-agent code audit; verification pass, issue filing, and test-suite expansion completed 2026-08-09. Findings are from static reading with `file:line` evidence; the app itself was not executed (the test suite was). All 41 findings are tracked as GitHub issues #1–#41.*

---

# Second Audit Cycle — 2026-08-10

**Scope:** the dimensions cycle 1 covered lightly, plus an adversarial regression review of the 16 fix commits. Four parallel audits: regression review (R), networking/offline/performance/lifecycle (P), distribution & privacy readiness (S), observability/CI/HIG/hygiene (O). Baseline: 190 tests passing, all 41 cycle-1 issues closed. **43 new findings filed as GitHub issues #42–#84.**

## Verdict: **NO-GO for App Store submission** (app functional; blockers are compliance + regressions)

| Blocker | Issue | Why |
|---|---|---|
| Privacy manifest missing | S-01 #63 | Upload fails validation (ITMS-91053) — required since May 2024 |
| Hosted privacy policy contradiction | S-05 #67 | Reviewer-visible "never any third party" on the Privacy Policy URL vs the disclosed AI tier |
| Listing copy over-promises | S-06 #68 | Guideline 2.3.1 exposure ("Nothing leaves.") |
| Coordinator reentrancy | R-01 #42 | Cancel-wiring regression: two concurrent syncs possible |
| Legacy-backup restore erases fields | R-03 #44 | Field-clearing regression: pre-v2 snapshots wipe nickname/birthday/URLs on restore |
| Transient failures poison set-aside | P-03 #53 | One dropped batch can permanently set aside ~200 contacts |
| Backup index at scale | P-06 #56 | Main-thread encode of all retained sessions (photos incl.); RAM-resident forever |

Severity totals: **0 Critical · 9 High (#42, #53, #56, #63, #67, #68, #78, #79, #80) · 17 Medium · 17 Low** across 43 findings in 34 issues (R-02 absorbs P-14, R-01 absorbs P-15, O-06 absorbs the O-07 assessment; P-12/O-12 were informational, not filed).

**What cycle 2 confirmed sound:** retry/backoff + single-flight token refresh + pagination + batch alignment; zero reachable `try!`/`fatalError`/force-unwrap crash paths; exemplary menu-bar HIG behavior; minimal MAS-appropriate entitlements (the notes-entitlement denial is handled correctly); accurate OAuth verification docs; near-zero TODO debt; all 31 `Task {}` blocks have real error boundaries.

## Cycle-2 roadmap

- **Sprint A — submission blockers:** #42, #43(with #42), #44, #53, #56, #63, #67, #68 (+#70/#71 same edit session as #67). Est. ~1 week.
- **Sprint B — repo/CI health:** #78 (untracked source file), #79 (share scheme), #80 (CI workflow — full YAML drafted in issue), #45 (test hermeticity), #81. Est. 2–3 days.
- **Sprint C — offline & lifecycle robustness:** #46, #47, #54, #55, #57, #58, #59, #62. Est. ~1 week.
- **Backlog:** #48–#52, #60, #61, #64–#66, #69, #72–#77, #82–#84.
- **Test additions to land with fixes:** transient-error strike classification (#53), pre-v2 restore-mask fixture (#44), mapping-store temp-dir isolation (#45), coordinator single-run assertion (#42).

*Second cycle completed 2026-08-10. Static analysis + test-suite execution; the app was not run interactively (O-09 explicitly flags the one finding needing a manual launch check).*
