//
//  SyncCoordinator.swift
//  Contact SyncMate
//
//  Single shared service that owns every sync run.
//  Both DashboardView and MenuBarView use this instead of each running their
//  own SyncEngine, eliminating code duplication and guaranteeing that state
//  (AppState, history, icon) is always consistent.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Sync Phase

enum SyncPhase: Equatable {
    case idle
    case preparing            // fetching contacts, building diff
    case syncing(Double)      // 0.0 – 1.0 progress
    case completed(SyncPhaseResult)
    case failed(String)       // user-friendly message

    var isActive: Bool {
        switch self {
        case .preparing, .syncing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:               return "Idle"
        case .preparing:          return "Preparing…"
        case .syncing(let p):     return p == 0 ? "Syncing…" : "Syncing \(Int(p * 100))%"
        case .completed:          return "Completed"
        case .failed:             return "Failed"
        }
    }

    var sfSymbol: String {
        switch self {
        case .idle:               return "person.2.circle"
        case .preparing:          return "arrow.triangle.2.circlepath"
        case .syncing:            return "arrow.triangle.2.circlepath"
        case .completed(let r):   return r.successful ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed:             return "exclamationmark.circle.fill"
        }
    }
}

struct SyncPhaseResult: Equatable {
    let added: Int
    let updated: Int
    let deleted: Int
    let merged: Int
    let errorCount: Int

    var successful: Bool { errorCount == 0 }

    var summary: String {
        var parts: [String] = []
        if added   > 0 { parts.append("+\(added)") }
        if updated > 0 { parts.append("~\(updated)") }
        if deleted > 0 { parts.append("-\(deleted)") }
        if merged  > 0 { parts.append("merged \(merged)") }
        return parts.isEmpty ? "Everything in sync" : parts.joined(separator: ", ")
    }

    init(from result: SyncResult) {
        added      = result.added
        updated    = result.updated
        deleted    = result.deleted
        merged     = result.merged
        errorCount = result.errors.count
    }
}

// MARK: - SyncCoordinator

/// @MainActor singleton that owns the sync pipeline.
/// Observe `phase` for UI updates; call `runSync()` to start.
@MainActor
final class SyncCoordinator: ObservableObject {

    static let shared = SyncCoordinator()

    // MARK: Published state

    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var stepLabel: String = ""
    @Published private(set) var progress: Double = 0

    /// A prepared session waiting for the user to approve it.
    ///
    /// Set instead of applying when the mode is `.manual`. Whichever view is on
    /// screen presents the preview; the coordinator does not own UI, so it
    /// publishes the session rather than showing a sheet itself.
    @Published var sessionAwaitingReview: SyncSession?

    // MARK: Weak refs (set by AppDelegate after launch)

    weak var appState: AppState?

    // MARK: - Public API

    /// Whether a sync is running right now.
    var isRunning: Bool { phase.isActive }

    /// The task that owns the currently-running sync. Held so `cancelSync()`
    /// has something to cancel — without it, a wrong-direction 500-contact
    /// sync over a slow network could only be watched to the end.
    private var currentRunTask: Task<Void, Never>?

    /// Monotonic id of the run that owns `currentRunTask`. `Task` is a value
    /// type, so identity can't be compared — the generation says whether the
    /// finishing run is still the one holding the handle.
    private var runGeneration = 0

    /// Whether the run being started came from the background timer.
    /// Set synchronously in `runSync` before the body task is spawned, read
    /// by the review-publish path to choose notification vs opening a window.
    private var pendingRunIsScheduled = false

    /// Stop the running sync at the next safe boundary.
    ///
    /// The engine checks for cancellation between contacts, so nothing is
    /// abandoned mid-write: whatever was applied stays applied and counted,
    /// and the history records where the run stopped.
    func cancelSync() {
        guard isRunning else { return }
        SyncHistory.shared.log(source: "SyncCoordinator", action: "sync.cancelRequested",
                               details: stepLabel)
        currentRunTask?.cancel()
    }

    /// Start a sync using the current AppSettings configuration.
    /// Safe to call from any async context — always runs on MainActor.
    ///
    /// `scheduled` says whether a human is watching: a user-initiated run
    /// that ends in "changes await review" opens the Dashboard to present
    /// them, while a background timer run only posts a notification — a
    /// window appearing out of nowhere on a schedule is not acceptable.
    func runSync(scheduled: Bool = false) async {
        pendingRunIsScheduled = scheduled
        // Both gates, and the phase claimed *synchronously* before any
        // suspension. The body only marks the phase active once its task gets
        // a main-actor slot — after this method has already suspended — so a
        // second call enqueued in the same breath (timer fire racing a click)
        // used to pass `!isRunning` and spawn a second full run. Claiming the
        // phase here closes that window; the task-handle gate covers the
        // watchdog case where the phase was released but the run still lives.
        guard !isRunning, currentRunTask == nil else { return }
        setPhase(.preparing, step: "Starting…", progress: 0)
        // A coordinator-owned Task, so cancelSync() holds the handle; awaiting
        // its value keeps every caller's structure unchanged.
        runGeneration += 1
        let generation = runGeneration
        currentRunTask = Task { await self.runSyncBody() }
        await currentRunTask?.value
        // Only this run's own handle: a watchdog-released run that finishes
        // late must not disarm Cancel for the successor run.
        if runGeneration == generation { currentRunTask = nil }
    }

    private func runSyncBody() async {
        let settings  = AppSettings.shared
        let direction = settings.autoSyncDirection

        // Pre-flight checks
        let oauth = GoogleOAuthManager.shared
        guard oauth.isAuthenticated else {
            setFailed("Google account is not connected. Sign in via Settings → Accounts.")
            return
        }

        setPhase(.preparing, step: "Fetching contacts…", progress: 0)

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore.shared
        )

        // Forward engine progress to our phase
        var progressCancellable: AnyCancellable?
        progressCancellable = engine.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self, let p else { return }

                // `receive(on:)` hops to the main queue, so a value emitted just
                // before the sync finished can be delivered *after* the phase was
                // set to .completed — cancelling the subscription does not recall
                // a block already enqueued. That late write put the coordinator
                // back into .syncing with a stale step, leaving the UI reading
                // "AI matching… 0%" forever while nothing was running.
                //
                // Progress is only ever meaningful while a sync is active, so
                // ignoring it otherwise closes the race at the source.
                guard self.isRunning else { return }

                let frac = p.totalItems > 0
                    ? Double(p.completedItems) / Double(p.totalItems)
                    : 0
                self.setPhase(.syncing(frac), step: p.currentStep, progress: frac)
                self.appState?.syncProgress = p
            }

        do {
            // Prepare diff
            var session = try await engine.prepareManualSync(direction: direction)
            session.mode = .manual

            // Run deduplication if enabled — with visible progress steps so
            // the user can see the AI matching phase happening.
            if settings.detectGoogleDuplicates {
                let coordinator = DeduplicationCoordinator()
                let google = session.contactChanges.compactMap { $0.sourceContact }
                    .filter { $0.googleResourceName != nil }
                let mac    = session.contactChanges.compactMap { $0.targetContact }
                    .filter { $0.macContactIdentifier != nil }
                if !google.isEmpty || !mac.isEmpty {
                    // Consent gates the cloud tier (AIContactMatcher refuses
                    // without it), so with a key entered but consent declined
                    // the scan runs purely locally — and the label must not
                    // claim "AI matching" for a run where nothing leaves the
                    // device.
                    let usingAI = settings.aiMatchingEnabled
                        && settings.aiCloudConsentGiven
                        && !settings.anthropicAPIKey.isEmpty
                    setPhase(.preparing,
                             step: usingAI ? "AI matching — scanning for duplicates…"
                                           : "Scanning for duplicates…",
                             progress: 0)

                    let scan = await coordinator.scanForDuplicates(
                        googleContacts: google,
                        macContacts: mac,
                        existingMappings: ContactMappingStore.shared.getAllMappings(),
                        // Honour the user's confirmation preference — silent
                        // auto-merge only when explicitly opted in.
                        autoApplyIfSafe: settings.allowSilentAutoMerge
                    )

                    // Surface the outcome: banner step + system notification
                    // when duplicate groups are waiting for review.
                    if scan.needsUserConfirmation {
                        let n = scan.groupsNeedingConfirmation.count
                        setPhase(.preparing,
                                 step: "\(n) duplicate group\(n == 1 ? "" : "s") need review",
                                 progress: 0)
                        SyncNotifier.notifyConflictsNeedReview(count: n)
                    }
                }
            }

            // Review mode: hand the session to the UI instead of applying it.
            //
            // Only the Dashboard used to branch on this, so "Sync Now" from the
            // menu bar or from Settings applied everything immediately even with
            // Review Before Applying selected. Deciding it here means every entry
            // point behaves the same, because they all come through runSync.
            if settings.selectedSyncType == .manual {
                progressCancellable?.cancel()
                appState?.currentSyncSession = session
                appState?.isSyncing = false
                appState?.syncProgress = nil
                setPhase(.idle)
                sessionAwaitingReview = session
                SyncHistory.shared.log(
                    source: "SyncCoordinator", action: "sync.awaitingReview",
                    details: "\(session.contactChanges.count) changes prepared for review"
                )
                // A published session needs a presenter. Only the Dashboard
                // consumes it, so a menu-bar or scheduled run used to fetch,
                // diff — and silently drop the whole thing. User-initiated
                // runs open the Dashboard (whose onChange/onAppear present
                // the sheet); scheduled runs notify instead of surprising
                // the user with a window.
                if pendingRunIsScheduled {
                    SyncNotifier.notifyChangesAwaitingReview(
                        count: session.contactChanges.count)
                } else {
                    NotificationCenter.default.post(
                        name: .openDashboardWindow, object: nil)
                }
                return
            }

            // Execute
            let result = try await engine.executeSync(session: session)
            progressCancellable?.cancel()

            let phaseResult = SyncPhaseResult(from: result)
            setPhase(.completed(phaseResult), step: phaseResult.summary, progress: 1)

            appState?.isSyncing   = false
            appState?.lastSyncDate = Date()
            appState?.lastSyncResult = result
            appState?.syncProgress   = nil

            SyncHistory.shared.log(
                source: "SyncCoordinator",
                action: "sync.complete",
                details: result.summary
            )

            // System notification so the user knows the sync finished even
            // when the popover is closed (Settings → General → Notifications).
            //
            // Suppressed when the sync changed nothing and hit no errors: with a
            // scheduled sync every few hours and an address book that rarely
            // moves, that is most runs, and "0 added, 0 updated" six times a day
            // trains the user to dismiss the one notification that matters.
            let changedSomething = result.added + result.updated
                + result.deleted + result.merged > 0
            if changedSomething || !result.errors.isEmpty {
                SyncNotifier.notifySyncCompleted(
                    added: result.added,
                    updated: result.updated,
                    deleted: result.deleted,
                    errorCount: result.errors.count
                )
            }

            // Spotlight: make this sync findable via ⌘Space ("contact sync").
            // Summaries only — no contact data is indexed.
            SpotlightIndexer.indexSyncResult(
                added: result.added,
                updated: result.updated,
                deleted: result.deleted,
                errorCount: result.errors.count,
                date: result.endTime
            )

            // Auto-reset to idle after 8 s
            scheduleIdleReset(after: 8)

        } catch {
            progressCancellable?.cancel()
            let friendly = Self.friendlyMessage(for: error)
            setFailed(friendly)
            appState?.isSyncing  = false
            appState?.syncProgress = nil

            SyncHistory.shared.log(
                source: "SyncCoordinator",
                action: "sync.failed",
                details: Self.failureDetails(friendly: friendly, error: error)
            )

            // A cancel is the user's own action, not a failure — the banner
            // already says "Sync cancelled.", and a system notification titled
            // "Sync failed" for something they just did is a false alarm.
            if !(error is CancellationError) {
                SyncNotifier.notifySyncFailed(message: friendly)
            }

            scheduleIdleReset(after: 12)
        }
    }

    /// Apply a session the user approved in the preview sheet.
    ///
    /// Goes through the coordinator rather than around it. The Dashboard used to
    /// build its own `SyncEngine` for this, which meant the apply ran with
    /// nothing subscribed to `engine.$progress` — so the header said "Syncing…"
    /// while the progress bar, the step label and the live event list all sat
    /// idle, because every one of them reads `SyncCoordinator.phase`.
    ///
    /// Everything after the execute call is deliberately identical to `runSync`:
    /// same completion phase, same AppState updates, same notification, same
    /// Spotlight entry. Two ways to finish a sync is how they drift apart.
    func applyReviewed(_ session: SyncSession) async {
        // Same double-start closure as runSync: claim the phase before the
        // first suspension, clear only our own handle afterwards.
        guard !isRunning, currentRunTask == nil else { return }
        setPhase(.syncing(0), step: "Applying reviewed changes…", progress: 0)
        runGeneration += 1
        let generation = runGeneration
        currentRunTask = Task { await self.applyReviewedBody(session) }
        await currentRunTask?.value
        if runGeneration == generation { currentRunTask = nil }
    }

    private func applyReviewedBody(_ session: SyncSession) async {
        setPhase(.syncing(0), step: "Applying reviewed changes…", progress: 0)
        appState?.isSyncing = true

        let engine = SyncEngine(
            googleConnector: GoogleContactsConnector(),
            macConnector: MacContactsConnector(),
            mappingStore: ContactMappingStore.shared
        )

        var progressCancellable: AnyCancellable?
        progressCancellable = engine.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self, let p, self.isRunning else { return }
                let frac = p.totalItems > 0
                    ? Double(p.completedItems) / Double(p.totalItems)
                    : 0
                self.setPhase(.syncing(frac), step: p.currentStep, progress: frac)
                self.appState?.syncProgress = p
            }

        do {
            let result = try await engine.executeSync(session: session)
            progressCancellable?.cancel()

            let phaseResult = SyncPhaseResult(from: result)
            setPhase(.completed(phaseResult), step: phaseResult.summary, progress: 1)

            appState?.isSyncing = false
            appState?.lastSyncDate = Date()
            appState?.lastSyncResult = result
            appState?.syncProgress = nil
            appState?.currentSyncSession = nil

            SyncHistory.shared.log(source: "SyncCoordinator", action: "sync.complete",
                                   details: result.summary)

            let changedSomething = result.added + result.updated
                + result.deleted + result.merged > 0
            if changedSomething || !result.errors.isEmpty {
                SyncNotifier.notifySyncCompleted(
                    added: result.added, updated: result.updated,
                    deleted: result.deleted, errorCount: result.errors.count)
            }

            SpotlightIndexer.indexSyncResult(
                added: result.added, updated: result.updated,
                deleted: result.deleted, errorCount: result.errors.count,
                date: result.endTime)

            scheduleIdleReset(after: 8)

        } catch {
            progressCancellable?.cancel()
            let friendly = Self.friendlyMessage(for: error)
            setFailed(friendly)
            appState?.isSyncing = false
            appState?.syncProgress = nil

            SyncHistory.shared.log(source: "SyncCoordinator", action: "sync.failed",
                                   details: Self.failureDetails(friendly: friendly, error: error))
            // Same as runSync: a user cancel is not a failure to notify about.
            if !(error is CancellationError) {
                SyncNotifier.notifySyncFailed(message: friendly)
            }
            scheduleIdleReset(after: 12)
        }
    }

    // MARK: - Private helpers

    private func setPhase(_ p: SyncPhase, step: String = "", progress pg: Double = 0) {
        phase     = p
        stepLabel = step
        progress  = pg
        appState?.isSyncing = p.isActive

        // An active phase is a claim that work is in flight. If that claim ever
        // outlives the work — a swallowed error, a cancelled task, a delivery
        // race — the UI shows a frozen progress bar and `guard !isRunning` in
        // runSync() refuses every subsequent sync, so the app is stuck until
        // relaunch. The watchdog makes that state self-healing instead.
        if p.isActive {
            startWatchdog()
        } else {
            watchdogTask?.cancel()
            watchdogTask = nil
        }
    }

    /// How long an active phase may go without any phase update before it is
    /// treated as abandoned. Generous: a large address book legitimately spends
    /// minutes inside a single step.
    private static let watchdogTimeout: TimeInterval = 300

    private var watchdogTask: Task<Void, Never>?

    private func startWatchdog() {
        // Restarted on every phase update, so the timeout measures silence rather
        // than total sync duration.
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.watchdogTimeout))
            guard !Task.isCancelled, let self, self.isRunning else { return }

            SyncHistory.shared.log(
                source: "SyncCoordinator",
                action: "sync.abandoned",
                details: "No progress for \(Int(Self.watchdogTimeout))s — releasing the stuck phase"
            )
            // Actually cancel the stuck run — releasing only the phase left a
            // zombie task writing contacts while the message claimed it was
            // cancelled, and let a new run start and overlap it. The task
            // handle stays set until the run really ends, so the runSync gate
            // blocks a successor from overlapping a zombie that ignores
            // cancellation for a while.
            self.currentRunTask?.cancel()
            self.setFailed("Sync stopped responding and was cancelled. Please try again.")
            self.appState?.isSyncing = false
            self.appState?.syncProgress = nil
            self.scheduleIdleReset(after: 12)
        }
    }

    private func setFailed(_ message: String) {
        phase     = .failed(message)
        stepLabel = message
        progress  = 0
        // .failed is not an active phase, so the watchdog has nothing left to
        // guard — and leaving it armed would fire spuriously later.
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func scheduleIdleReset(after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Only reset if we haven't already started another sync
            if !isRunning { phase = .idle; stepLabel = ""; progress = 0 }
        }
    }

    // MARK: - Friendly error messages

    // `nonisolated static`: pure error-to-text mapping with no coordinator
    // state, callable from tests and any isolation context.
    nonisolated static func friendlyMessage(for error: Error) -> String {
        // User-initiated, not a failure — reached when a cancel lands during
        // the prepare phase (fetches), which throws rather than returning a
        // partial result.
        if error is CancellationError {
            return "Sync cancelled."
        }

        if let syncError = error as? SyncEngineError {
            switch syncError {
            case .syncAlreadyInProgress:
                return "A sync is already in progress. Please wait."
            case .autoSyncDisabled:
                return "Auto-sync is disabled. Enable it in Settings → Auto Sync."
            case .conditionsNotMet:
                return "Sync conditions not met — check power, network, and idle settings."
            case .missingContactData(let detail):
                return "Missing contact data: \(detail)"
            case .backupNotFound:
                return "Backup not found. Check Settings → Backups."
            case .batchItemRejected(let name):
                return "Google rejected \(name). Other contacts in the same batch were unaffected."
            }
        }

        // `invalid_client` is not a session problem, and telling the user to
        // sign in again — which is what the generic auth wording does — sends
        // them into a loop that cannot succeed. Google is saying the client ID
        // itself is unknown to it: deleted in the Cloud Console, or belonging to
        // a project that no longer exists. Signing in again uses the same ID and
        // fails the same way.
        let text = error.localizedDescription
        if text.contains("invalid_client") {
            return "Google no longer recognises this app's OAuth client. "
                 + "It was most likely deleted in Google Cloud Console. Create a "
                 + "new iOS client and run Scripts/set-oauth-client.sh with its ID "
                 + "— signing in again will not help until then."
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Check your network and try again."
            case NSURLErrorTimedOut:
                return "Request timed out. Google's servers may be slow — try again later."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost during sync. Try again."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Cannot reach Google. Check your internet connection."
            default: break
            }
        }

        // The connector throws GoogleContactsError.apiError — there is no
        // "com.google.HTTPStatus" NSError domain anywhere in this app, so the
        // branch that used to match on it was dead code and every 401/429/5xx
        // fell through to the raw description.
        if case let GoogleContactsError.apiError(statusCode, _) = error {
            switch statusCode {
            case 401:
                return "Google session expired. Sign in again via Settings → Accounts."
            case 403:
                // errorDescription already leads with the specific 403
                // diagnosis (API disabled / missing scope / test-user) —
                // fall through and keep it.
                break
            case 429:
                return "Google API rate limit reached. Try again in a few minutes."
            case 500...599:
                return "Google's servers returned an error. Try again later."
            default: break
            }
        }
        if case GoogleContactsError.invalidToken = error {
            return "Google session expired. Sign in again via Settings → Accounts."
        }

        return error.localizedDescription
    }

    /// The log line for a failed sync: the friendly reading, plus the raw error
    /// only when it adds something.
    ///
    /// This was unconditionally `"\(friendly) — \(error.localizedDescription)"`,
    /// and `friendlyMessage` falls back to returning `localizedDescription`
    /// verbatim when it has no better wording. So every unrecognised error was
    /// logged twice in one line, joined by a dash — "The OAuth client was not
    /// found. — The OAuth client was not found." Reading that, you look for the
    /// difference between the two halves, and there isn't one.
    nonisolated static func failureDetails(friendly: String, error: Error) -> String {
        let raw = error.localizedDescription
        return friendly == raw ? friendly : "\(friendly) — \(raw)"
    }
}
