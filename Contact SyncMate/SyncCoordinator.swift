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

    /// Start a sync using the current AppSettings configuration.
    /// Safe to call from any async context — always runs on MainActor.
    func runSync() async {
        guard !isRunning else { return }

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
            mappingStore: ContactMappingStore()
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
                    let usingAI = settings.aiMatchingEnabled && !settings.anthropicAPIKey.isEmpty
                    setPhase(.preparing,
                             step: usingAI ? "AI matching — scanning for duplicates…"
                                           : "Scanning for duplicates…",
                             progress: 0)

                    let scan = await coordinator.scanForDuplicates(
                        googleContacts: google,
                        macContacts: mac,
                        existingMappings: ContactMappingStore().getAllMappings(),
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
            let friendly = friendlyMessage(for: error)
            setFailed(friendly)
            appState?.isSyncing  = false
            appState?.syncProgress = nil

            SyncHistory.shared.log(
                source: "SyncCoordinator",
                action: "sync.failed",
                details: "\(friendly) — \(error.localizedDescription)"
            )

            SyncNotifier.notifySyncFailed(message: friendly)

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

    func friendlyMessage(for error: Error) -> String {
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

        if nsError.domain == "com.google.HTTPStatus" {
            switch nsError.code {
            case 401:
                return "Google session expired. Sign in again via Settings → Accounts."
            case 403:
                return "Permission denied by Google. Check your account permissions."
            case 429:
                return "Google API rate limit reached. Try again in a few minutes."
            case 500...599:
                return "Google's servers returned an error. Try again later."
            default: break
            }
        }

        return error.localizedDescription
    }
}
