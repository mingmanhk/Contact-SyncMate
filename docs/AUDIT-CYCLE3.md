# Contact SyncMate — Third Audit Cycle (2026-08-11)

**Baseline:** HEAD `923f4e0`, clean tree, 214 tests passing locally and on CI (macos-26). All 84 prior issues (#1–#84) closed.
**Method:** four parallel audits — (R) adversarial regression review of the cycle-2 remediation commits, (F) fresh full-repo sweep with lenses the prior cycles never applied (state-machine correctness, fetch/update-mask symmetry, settings matrix, end-to-end convergence), (T) test-suite *quality* review, (D) docs/release-readiness re-derivation. **54 findings, filed as GitHub issues #85–#138.**

## Verdict: **NO-GO** — the fresh lenses found pre-existing functional breakage both prior cycles missed

The most important lesson of this cycle: cycles 1–2 audited *code units* (and fixed them well — the regression review found cycle-2's fixes largely sound). Cycle 3's **flow-level** lenses found that several complete user flows do not work:

| Blocker | Finding | Issue |
|---|---|---|
| The conflict-review sheet **discards every decision** — "Apply" then merges unconfirmed name-only matches into both address books (the D-01 data destroyer, resurrected through the *approved* path) | C3F-01 (Critical) | #86 |
| With the default "manual/review" sync type, review sessions are **orphaned unless the Dashboard is already open** — menu-bar and scheduled syncs fetch, diff, and silently do nothing | C3F-05 (High) | #90 |
| Group filtering makes mapped out-of-group contacts look **deleted** — enabling the filter proposes deleting every contact outside the groups | C3F-02 (High) | #87 |
| Google `updateTime` parsing rejects fractional seconds → likely **every Google edit** lands in the unknown-vs-unknown conflict branch | C3F-10 (High) | #95 |
| The new photo rule routes photo-only diffs into the conflict branch: perpetual deferred merges or non-converging Google writes | C3R-01 (High) | #85-group |
| Running ⌘U **wipes the user's real sync history** (tests write through the production file) | C3T-01 (High) | #100-group |

Severity totals: **1 Critical · 12 High · 23 Medium · 18 Low.**

The four full agent reports below are the authoritative reference for every finding; issues quote the finding ID.

---

## Report R — Regression review of cycle-2 fixes (C3R-01…05)

C3R-01 High — photo-only diffs on mapped pairs fall into the conflict branch (SyncEngine.swift:1017,660–697): `.alwaysAsk` → perpetual deferred merges; `.preferMac` → non-converging Google PATCH every sync; `.mergeBoth` → full two-sided merge per photo'd contact. Photos travel one way; "photo differs" is not a conflict. Fix: emit `update .googleToMac` directly for the photo component.

C3R-02 Medium — after the watchdog cancels a run stuck in synchronous XPC (never observes cancellation), `currentRunTask` never clears and every subsequent sync silently no-ops until relaunch (SyncCoordinator.swift:142,480). Fix: surface the refusal; let the next user-initiated sync orphan the zombie via generation bump.

C3R-03 Low — keychain migration is delete-first: if `SecItemAdd` with `kSecUseDataProtectionKeychain` fails (unsigned/ad-hoc dev builds → errSecMissingEntitlement), the only copy of the refresh token is already gone (GoogleOAuthManager.swift:976–1010). Fix: fall back to a legacy add on failure.

C3R-04 Low — legacy backup-index migration can lose a session body when the big body write fails but the small index write succeeds (ContactBackupManager.swift:1471–1497). Fix: rewrite the index only after bodies are verified (or keep `backup_index.legacy.json`).

C3R-05 Low — photo JIT has no circuit breaker; only logging is rate-limited. A stalling photo host adds up to 30 s per contact (SyncEngine.swift:1616–1650). Fix: stop attempting after N consecutive failures per run.

Clean: backup summary index mechanics (continuation, migration detection, container merge, prune), Settings scene paths, termination handler (single reply, no flush deadlock), coordinator generation logic, off-main decode ordering, offline revival wiring, strike×cancel interplay. Pre-existing notes: auth-abort `break` lacks the batch fold-in that cancel got; legacy-index `Data(contentsOf:)` on main.

---

## Report F — Fresh sweep, new lenses (C3F-01…15)

C3F-01 **Critical** — the conflict review UI discards every decision (ContactDiffView.swift:215–222 writes to its own `@State` copy; no callback; SyncPreviewView presents via `.sheet(item:)` and receives nothing). `reviewedSession()` then sets `userReviewed = true`, and `mergeIsHeldBack` requires `!userReviewed` — so Apply merges every unconfirmed name-only match into both address books, regardless of what the user chose. Fix: thread decisions back into the session as `userOverride` per change id; refuse `.merge` with nil override even on reviewed sessions.

C3F-02 High — group filtering runs before `computeChanges`; mapped pairs whose contact is merely outside the selected groups classify as "deleted on <side>" (SyncEngine.swift:100–107,585–604,1255–1293). With deletion sync on, enabling/narrowing the filter proposes deleting every previously synced out-of-group contact — silently on scheduled runs if confirmation is off. Fix: check absent-from-filtered contacts against the unfiltered fetch before classifying as deleted.

C3F-03 High — phonetic names never round-trip Google (PersonName lacks the fields; GoogleContactsConnector.swift:1005–1012, 737–747) yet `applyToMac` writes `unified.phoneticGivenName ?? ""` (clears Mac phonetics on any inbound update) and the `names` update mask replaces the whole object (clears Google-side phonetics on outbound). Silent recurring loss, invisible to the diff — worst for CJK address books. Fix: add phonetics to PersonName + convertToAPIPerson, or stop writing them.

C3F-04 High (latent) — `biographies` is missing from fetch personFields and the update mask while notes are diffed/written/cleared (GoogleContactsConnector.swift:63–69,177,232 vs SyncEngine.swift:944,2371). Fully masked today by `notesFieldAvailable = false`; the documented one-line re-enable arms note-clearing and a permanent notes diff loop. Fix now while free.

C3F-05 High — review sessions orphaned: only DashboardView's `onChange` consumes `sessionAwaitingReview`; menu-bar Sync Now, ⌘R, and every scheduled run under the default review-gated sync type build the full diff and drop it — no UI, no notification, nothing applied (SyncCoordinator.swift:253–265; DashboardView.swift:144–149). Fix: notify/open Dashboard on publish; `.onAppear` pickup; reconsider auto-sync × review-gated interaction.

C3F-06 Medium — Dashboard "Sync Now" bypasses the coordinator entirely (DashboardView.swift:684–745): phase divergence, uncancellable, unwatched, no dedup scan, reentrancy gap vs scheduled runs. Fix: route through `coordinator.runSync()` (also fixes C3F-05's presenter).

C3F-07 Medium — nickname/prefix/suffix/department are written unconditionally but never diffed: Mac-only edits never propagate and are erased by the next inbound update (SyncEngine.swift:932–944 vs 2353–2360). Fix: diff them or make writes presence-preserving for undiffed fields.

C3F-08 Medium — 1-way sync "deleted on target": `performDelete` needs the target-side id that a source-side unified contact lacks → silent no-op counted as `deleted += 1`, mapping never cleaned, phantom delete re-reported every run (SyncEngine.swift:892–898,1795–1833). Fix: define semantics (re-add or propagate) + clean mapping + honest counting.

C3F-09 Medium — a chunk-level batch 4xx (e.g. one stale etag) is attributed to all ~200 members and `failureCountsTowardSetAside` treats 4xx as contact-specific: three such syncs set aside 200 innocents (SyncEngine.swift:1554–1598,1365–1368). Fix: only `batchItemRejected` (item-specific) strikes; chunk-level HTTP errors never do.

C3F-10 High — `updateTimeFormatter` lacks `.withFractionalSeconds`; People API updateTime carries them → parse nil → `gChanged` never true → every Google edit demotes to the unknown-vs-unknown conflict branch (GoogleContactsConnector.swift:632,724–727). Confirm with one live response; fix with both-options parse fallback and prefer the CONTACT source.

C3F-11 Medium — the dedup confirmation flow is unreachable: the scanning coordinator is a discarded local; `DeduplicationConfirmationView` is presented nowhere; the "needs review" notification points at nothing (SyncCoordinator.swift:207–244; DeduplicationCoordinator.swift:140–149).

C3F-12 Low — "both deleted — handled after loop" mapping cleanup does not exist (SyncEngine.swift:586–588); dead mappings accumulate forever.
C3F-13 Low — a persistently failing photo URL triggers a full update + pre/post backup pair every scheduled sync forever (SyncEngine.swift:1017,458–496).
C3F-14 Low — auth pre-flight failure sets `.failed` with no idle reset (SyncCoordinator.swift:161–164).
C3F-15 Low — dry run clears strike history and triggers real post-sync backups (SyncEngine.swift:329–333,458–461).

Clean lenses: resource lifecycle (observers/cancellables/timers), privacy of new code (crash payloads carry no contact data; new Logger lines PII-clean), multi-group membership, unicode/emoji normalization, deleted-on-both degradation.

---

## Report T — Test-suite quality (C3T-01…15; grade **B-**)

C3T-01 High — `SyncHistoryTests`/`PerformanceTests` call `SyncHistory.shared.clear()` which writes through to the user's real history file: **⌘U destroys real sync history.** Needs the same temp-file seam the mapping store got (#45).
C3T-02 High — #44's regression test covers the mask but not the legacy-detection predicate (`urls == nil`); the detection could regress silently. Add a v1-JSON fixture test through the real restore path.
C3T-03 High — the #1/#24/#53 gates are tested as pure functions; no test drives `executeSync`/`applyGoogleBatches`, so un-wiring any gate stays green. Needs a connector-protocol seam + recording stubs.
C3T-04 Medium — retention "count cap keeps most recent" test feeds newest-first input and actually pins keep-oldest positional behavior.
C3T-05 Medium — failure-store tests write the user's real persisted ledger (cleanup is sound; crash residue visible in UI).
C3T-06 Medium — dedup tests use `DeduplicationDecisionStore.shared` (real user file + real history writes).
C3T-07 Medium — settings pinning inconsistent across classes (`syncDeletedContacts`, `historyRetentionDays` unpinned where they matter).
C3T-08 Medium — `test_getAllMappings_initiallyEmpty` asserts NotNil on a non-optional; should assert isEmpty.
C3T-09 Medium — count-only diff assertions never verify which contacts got paired.
C3T-10 Medium — `Thread.sleep(0.05)` flush-waiting in ~8 helpers; store needs a test flush.
C3T-11..15 Low — ~25 construct-and-read tautologies, self-asserting case-count tests, `XCTAssertNoThrow` no-ops, a duplicated OR-literal assertion, digit-`contains` summary assertions. PerformanceTests measure no app code and have no protective value.

Top adds: executeSync integration class behind a connector seam; batchSyncStamp/awaitingMacWrite; legacy-restore end-to-end; SyncErrorExplanation mapping table; SyncHistory temp-file rewrite with corrected prune tests.

---

## Report D — Docs & release readiness (C3D-01…19)

Highs: C3D-03 — fresh clone cannot build following README (bootstrap-config.sh documented nowhere); C3D-06 — CHANGELOG frozen pre-1.0 with placeholder repo URLs, failing the checklist's own §D; C3D-08 — App Store description measured 4,563 chars (> 4,000 limit), still untrimmed.
Mediums: README says 109 tests (real: 214) and never mentions CI (C3D-01/02); missing LICENSE despite "auditable source" positioning (C3D-04); inner `Contact SyncMate/README.md` still says the app is unbuilt scaffolding (C3D-05); build numbers three-way inconsistent — listing 1 / pbxproj 103 / convention 110 (C3D-07); ExportOptions.plist referenced but absent (C3D-09); checklist §C prescribes the hanging `xcodebuild test` its own scripts warn about (C3D-10); "waiting for a network connection" + coordinator phase labels + crash-reports row + cloud-folder NSAlert are unlocalized new strings (C3D-13/14/15).
Lows: broken tag command in the checklist, stale "199" in ci.yml, AUDIT.md "34 issues" arithmetic, terms.html omits Anthropic from third-party list, privacy.html §5 omits nickname from the exact field enumeration, README project tree lists a nonexistent file (C3D-11/12/16/17/18/19).

Re-derived clean: consent gate hard-gates the API call and dedup path; scopes match everywhere; photo sync documented correctly; backup-encryption honesty implemented; privacy manifest matches the label; no unqualified privacy claims anywhere; CI green 214/214; all 605 existing catalog keys fully translated (gaps are un-extracted new strings).

**Submission-readiness:** four real actions stand before Upload — trim the description (C3D-08), reconcile build numbers via the checklist's own agvtool step (C3D-07), write the 1.1 CHANGELOG (C3D-06), and the manual runtime pass — *plus, after this cycle, the functional blockers above.*
