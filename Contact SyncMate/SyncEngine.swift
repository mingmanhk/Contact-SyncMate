//
//  SyncEngine.swift
//  Contact SyncMate
//
//  Created by Victor Lam on 11/8/25.
//

import Foundation
@preconcurrency import Contacts
import Combine

// MARK: - String helpers

private extension String {
    /// Returns nil if the string is empty or whitespace-only
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Map a generic label string to a CNLabel constant where possible
///
/// `nonisolated`: a pure lookup over constants, called from the Contacts write
/// queue via `applyToMac`.
private nonisolated func cnLabelFromString(_ label: String?) -> String? {
    guard let label = label?.lowercased() else { return nil }
    switch label {
    case "home":   return CNLabelHome
    case "work":   return CNLabelWork
    case "other":  return CNLabelOther
    case "mobile", "cell": return CNLabelPhoneNumberMobile
    case "main":   return CNLabelPhoneNumberMain
    case "iphone": return CNLabelPhoneNumberiPhone
    default:       return label.isEmpty ? nil : label
    }
}

/// Core sync engine that orchestrates the sync process
class SyncEngine: ObservableObject {
    let googleConnector: GoogleContactsConnector
    let macConnector: MacContactsConnector
    let mappingStore: ContactMappingStore
    let settings = AppSettings.shared
    
    @Published var isRunning = false
    @Published var progress: SyncProgress?
    @Published var lastError: Error?
    
    init(googleConnector: GoogleContactsConnector,
         macConnector: MacContactsConnector,
         mappingStore: ContactMappingStore) {
        self.googleConnector = googleConnector
        self.macConnector = macConnector
        self.mappingStore = mappingStore
    }
    
    // MARK: - Public Sync Methods
    
    /// Run a manual sync with preview
    func prepareManualSync(direction: SyncDirection) async throws -> SyncSession {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }

        // Set in the same isolated step as the guard. The engine is already
        // MainActor-isolated, so an `await MainActor.run` here is not a no-op:
        // it suspends between check and set, and two overlapping calls can
        // both pass the guard before either marks the sync as running.
        isRunning = true
        progress = SyncProgress(currentStep: "Fetching contacts...", completedItems: 0, totalItems: 0)

        // Released synchronously, not via `Task { @MainActor in … }`.
        // SyncEngine is main-actor isolated, so a deferred Task can only run once
        // the actor yields — but SyncCoordinator calls prepareManualSync and then
        // executeSync with no guaranteed suspension between them. The second call
        // would find isRunning still true and throw "A sync is already in
        // progress" for the sync the user just started.
        defer {
            isRunning = false
            progress = nil
        }
        
        do {
            // Fetch contacts from both sides
            let googleContacts = try await googleConnector.fetchAllContacts()
            // The fetches are the long part of prepare — honour a cancel
            // between them instead of finishing minutes of work first.
            try Task.checkCancellation()
            // Off the main actor: see fetchAllContactsOffMainActor. Driving
            // contactsd XPC from a user-interactive thread inverts priority and
            // corrupts subsequent faulting.
            let macContacts = try await macConnector.fetchAllContactsOffMainActor()
            try Task.checkCancellation()

            // Convert to unified format
            var unifiedGoogleContacts = googleContacts.map { ContactMapper.toUnified(from: $0) }
            var unifiedMacContacts = macContacts.map { ContactMapper.toUnified(from: $0) }

            // Restrict to the selected groups / labels, if the user asked for that.
            if settings.filterByGroups {
                (unifiedGoogleContacts, unifiedMacContacts) = await applyGroupFilter(
                    google: unifiedGoogleContacts,
                    googleSource: googleContacts,
                    mac: unifiedMacContacts
                )
            }

            // Create sync session ID for backup linkage
            let syncSessionId = UUID().uuidString

            // Diff first, back up second.
            //
            // The order used to be reversed, so every scheduled sync wrote a full
            // snapshot of both address books before discovering there was nothing
            // to do. Contacts change rarely, so the overwhelming majority of
            // automatic syncs are exactly that case — and with backup pruning
            // unimplemented, those snapshots accumulate forever.
            //
            // A backup exists to undo changes. No changes, nothing to undo.
            let changes = computeChanges(
                googleContacts: unifiedGoogleContacts,
                macContacts: unifiedMacContacts,
                direction: direction
            )

            // Which fields are driving the changes, counted.
            //
            // A second sync should have close to nothing to do. When it does not,
            // the question is always "which field never settles" — and answering
            // that from a list of per-contact entries means reading hundreds of
            // rows and tallying by eye. One line does it instead.
            Self.logFieldDiffHistogram(changes)

            if changes.isEmpty {
                SyncHistory.shared.log(
                    source: "SyncEngine",
                    action: "sync.noChanges",
                    details: "\(unifiedGoogleContacts.count) Google / \(unifiedMacContacts.count) Mac contacts — already in sync"
                )
            } else if AppSettings.shared.autoBackupEnabled {
                _ = try await ContactBackupManager.shared.createPreSyncBackup(
                    googleContacts: unifiedGoogleContacts,
                    macContacts: unifiedMacContacts,
                    syncSessionId: syncSessionId,
                    syncDirection: "\(direction)",
                    syncMode: "manual"
                )
            }

            // Create session with backup reference
            var session = SyncSession(
                mode: .manual,
                direction: direction,
                startTime: Date(),
                contactChanges: changes
            )
            session.syncSessionId = syncSessionId

            return session
            
        } catch {
            await MainActor.run {
                lastError = error
            }
            throw error
        }
    }
    
    /// Whether an error means every remaining change would fail the same way.
    ///
    /// Only authentication is treated this way. A per-contact failure (a rejected
    /// field, a stale identifier) says nothing about the next contact, so those
    /// must not abort the run.
    private static func isUnrecoverableForRemainingChanges(_ error: Error) -> Bool {
        switch error {
        case GoogleOAuthError.noRefreshToken,
             GoogleOAuthError.notAuthenticated,
             GoogleOAuthError.tokenRefreshFailed,
             GoogleContactsError.notAuthenticated,
             GoogleContactsError.invalidToken:
            return true
        default:
            return false
        }
    }

    /// Execute a prepared sync session
    func executeSync(session: SyncSession) async throws -> SyncResult {
        guard !isRunning else {
            throw SyncEngineError.syncAlreadyInProgress
        }

        // Set in the same isolated step as the guard. The engine is already
        // MainActor-isolated, so an `await MainActor.run` here is not a no-op:
        // it suspends between check and set, and two overlapping calls can
        // both pass the guard before either marks the sync as running.
        isRunning = true
        progress = SyncProgress(
            currentStep: "Syncing...",
            completedItems: 0,
            totalItems: session.contactChanges.count
        )

        // Released synchronously, not via `Task { @MainActor in … }`.
        // SyncEngine is main-actor isolated, so a deferred Task can only run once
        // the actor yields — but SyncCoordinator calls prepareManualSync and then
        // executeSync with no guaranteed suspension between them. The second call
        // would find isRunning still true and throw "A sync is already in
        // progress" for the sync the user just started.
        defer {
            isRunning = false
            progress = nil
        }
        
        let startTime = Date()
        var added = 0
        var updated = 0
        var deleted = 0
        var merged = 0
        var skipped = 0
        var deferredDeletions = 0
        var deferredMerges = 0
        var setAside = 0
        var errors: [SyncError] = []

        // Google-bound writes go out in bulk first; the loop below then walks the
        // same changes for counting, history and the Mac side. Anything already
        // written here is skipped rather than sent twice.
        let batched = await applyGoogleBatches(session: session)

        // Execute each change
        for (index, change) in session.contactChanges.enumerated() {
            // A user cancel stops at a change boundary: whatever was applied
            // stays applied and counted, nothing is abandoned mid-write, and
            // the result reports the partial run honestly.
            if Task.isCancelled {
                SyncHistory.shared.log(
                    source: "SyncEngine", action: "sync.cancelled",
                    details: "Stopped by the user after \(index) of \(session.contactChanges.count) changes")
                break
            }

            // Update progress
            await MainActor.run {
                progress = SyncProgress(
                    currentStep: "Processing \(change.contactName)...",
                    completedItems: index,
                    totalItems: session.contactChanges.count
                )
            }
            
            // Use override if set, otherwise use planned action
            let action = change.userOverride ?? change.action

            // Set aside after repeated failures.
            //
            // A contact that cannot be written was retried on every sync
            // forever: the same failures scrolled past each run and nothing
            // accumulated into something the user could act on. After three
            // attempts it is skipped and listed in Settings → Sync Failures.
            let failureKey = Self.failureKey(for: change)
            if let failureKey, SyncFailureStore.shared.shouldSkip(key: failureKey) {
                skipped += 1
                setAside += 1
                SyncHistory.shared.log(
                    source: "SyncEngine", action: "change.setAside",
                    details: "\(change.contactName) — failed "
                           + "\(SyncFailureStore.attemptsBeforeSkipping)+ times; "
                           + "review in Settings → Sync Failures"
                )
                continue
            }

            // "Ask before deleting contacts": record it, do not do it. The user
            // applies held-back deletions from the sync preview.
            if Self.deletionIsHeldBack(action: action, session: session, settings: settings) {
                skipped += 1
                deferredDeletions += 1
                SyncHistory.shared.log(
                    source: "SyncEngine", action: "delete.heldForReview",
                    details: "\(change.contactName) — enable Sync Now review to apply, "
                           + "or turn off Settings → Confirmations → Ask before deleting contacts"
                )
                continue
            }

            // A merge nobody confirmed is deferred, not applied. The reviewed
            // preview gates these with needsReview; this is the same gate for
            // runs that never see a preview.
            if Self.mergeIsHeldBack(change: change, session: session) {
                skipped += 1
                deferredMerges += 1
                SyncHistory.shared.log(
                    source: "SyncEngine", action: "merge.heldForReview",
                    details: "\(change.contactName) — possible match not confirmed; "
                           + "run Sync Now and review to merge or keep separate"
                )
                continue
            }

            // Dry run: count what would happen, write nothing.
            //
            // Settings promises "no changes will be saved" when this is on, but
            // nothing enforced it — the setting was stored and never read, so a
            // user who enabled it as a safety net still had both address books
            // rewritten. The counters and history still run so the report is
            // identical to a real sync, minus the writes.
            let isDryRun = settings.dryRunMode
            // Already written by the batch pre-pass — count and log it, but do not
            // send it a second time.
            let alreadyWritten = batched.applied.contains(change.id)
            let shouldWrite = !isDryRun && !alreadyWritten

            do {
                // Surface a batch rejection here so it goes through the same error
                // accounting and abort check as a per-contact failure.
                if let batchError = batched.failures[change.id] { throw batchError }

                switch action {
                case .add:
                    if shouldWrite {
                        try await performAdd(change: change, direction: session.direction)
                    }
                    added += 1

                case .update:
                    if shouldWrite {
                        try await performUpdate(change: change, direction: session.direction)
                    }
                    updated += 1

                case .delete:
                    if shouldWrite {
                        try await performDelete(change: change, direction: session.direction)
                    }
                    deleted += 1

                case .merge:
                    if shouldWrite {
                        try await performMerge(change: change, direction: session.direction)
                    }
                    merged += 1

                case .skip:
                    skipped += 1
                }

                // It worked — forget any past failures, so a contact that
                // recovers is not held against its history.
                if let failureKey { SyncFailureStore.shared.clearFailure(key: failureKey) }

                // Per-change audit trail: every applied change is recorded
                // with contact, action, direction, field summary, and the
                // sync-session ID that links it to its pre/post backups —
                // so any individual change can be traced and rolled back
                // via the backup version history.
                if action != .skip {
                    SyncHistory.shared.log(
                        source: "SyncEngine",
                        action: "change.\(action.rawValue.lowercased())",
                        details: "\(isDryRun ? "[DRY RUN] " : "")" +
                                 "\(change.contactName) [\(change.direction)] " +
                                 "session=\(session.syncSessionId ?? "-") " +
                                 "fields=\(change.changes.joined(separator: "; "))"
                    )
                }
            } catch {
                // The explained form, not the raw one. "Cocoa error 134092" is
                // what the user sees on a failed merge, and on its own it says
                // nothing about what failed or whether they can do anything.
                let explained = SyncErrorExplanation.describe(error)
                errors.append(SyncError(
                    contactName: change.contactName,
                    message: explained,
                    timestamp: Date()
                ))
                // Count it against this contact — but only when the failure
                // says something about the contact. On the third strike the
                // next sync will set it aside instead of failing it again.
                var attempts = 0
                if let failureKey, Self.failureCountsTowardSetAside(error) {
                    attempts = SyncFailureStore.shared.recordFailure(
                        key: failureKey,
                        name: change.contactName,
                        reason: explained)
                }
                SyncHistory.shared.log(
                    source: "SyncEngine",
                    action: "change.failed",
                    details: "\(change.contactName) [\(action.rawValue)]: \(explained)"
                           + (attempts > 0 ? " (attempt \(attempts) of \(SyncFailureStore.attemptsBeforeSkipping))" : "")
                )

                // Stop on a failure that every remaining change will hit too.
                //
                // When Google access dies mid-sync, the old behaviour was to keep
                // going and fail all ~100 remaining contacts identically — a wall
                // of "Failed to refresh access token" that buried the one fact
                // that mattered: you need to sign in again. Aborting turns that
                // into a single actionable error.
                if Self.isUnrecoverableForRemainingChanges(error) {
                    SyncHistory.shared.log(
                        source: "SyncEngine",
                        action: "sync.aborted",
                        details: "Authentication failed — stopped after \(index + 1) of \(session.contactChanges.count) changes"
                    )
                    break
                }
            }
        }

        let endTime = Date()

        // Create result
        let result = SyncResult(
            mode: session.mode,
            direction: session.direction,
            startTime: startTime,
            endTime: endTime,
            added: added,
            updated: updated,
            deleted: deleted,
            merged: merged,
            skipped: skipped,
            errors: errors,
            deferredDeletions: deferredDeletions,
            deferredMerges: deferredMerges,
            setAside: setAside
        )

        // Create post-sync backup with actual final state.
        //
        // Also gated on something actually having been written: this re-fetches
        // *both* address books in full, so running it after a no-op sync was the
        // single most expensive thing an idle scheduled sync did — two complete
        // fetches to snapshot a state identical to the one already on disk.
        let wroteSomething = added + updated + deleted + merged > 0
        if wroteSomething,
           AppSettings.shared.autoBackupEnabled,
           let syncSessionId = session.syncSessionId {
            do {
                let googleContacts = try await googleConnector.fetchAllContacts()
                // Off the main actor: see fetchAllContactsOffMainActor. Driving
            // contactsd XPC from a user-interactive thread inverts priority and
            // corrupts subsequent faulting.
            let macContacts = try await macConnector.fetchAllContactsOffMainActor()

                _ = try await ContactBackupManager.shared.createPostSyncBackup(
                    googleContacts: googleContacts.map { ContactMapper.toUnified(from: $0) },
                    macContacts: macContacts.map { ContactMapper.toUnified(from: $0) },
                    syncSessionId: syncSessionId,
                    changesSummary: "Added: \(added), Updated: \(updated), Deleted: \(deleted), Merged: \(merged)"
                )
            } catch {
                // Log but don't fail the sync if backup fails
                SyncHistory.shared.log(
                    source: "SyncEngine",
                    action: "postSyncBackup.failed",
                    details: error.localizedDescription
                )
            }
        }

        // Save to history
        try? await saveToHistory(result: result)

        return result
    }
    
    // runAutoSync lived here, with no callers. Auto-sync runs through
    // AutoSyncScheduler → AutoSyncConditions.blocker() → SyncCoordinator.
    
    // MARK: - Private Helpers
    
    func computeChanges(
        googleContacts: [UnifiedContact],
        macContacts: [UnifiedContact],
        direction: SyncDirection
    ) -> [ContactChange] {
        var changes: [ContactChange] = []
        
        // Get existing mappings
        let mappings = mappingStore.getAllMappings()
        
        // Create lookup dictionaries
        var googleByResourceName: [String: UnifiedContact] = [:]
        for contact in googleContacts {
            if let resourceName = contact.googleResourceName {
                googleByResourceName[resourceName] = contact
            }
        }
        
        var macByIdentifier: [String: UnifiedContact] = [:]
        for contact in macContacts {
            if let identifier = contact.macContactIdentifier {
                macByIdentifier[identifier] = contact
            }
        }
        
        switch direction {
        case .twoWay:
            changes = compute2WayChanges(
                googleByResourceName: googleByResourceName,
                macByIdentifier: macByIdentifier,
                mappings: mappings
            )
            
        case .googleToMac:
            changes = compute1WayChanges(
                source: googleByResourceName,
                target: macByIdentifier,
                mappings: mappings,
                sourceToTarget: true
            )
            
        case .macToGoogle:
            changes = compute1WayChanges(
                source: macByIdentifier,
                target: googleByResourceName,
                mappings: mappings,
                sourceToTarget: false
            )
        }
        
        return changes
    }
    
    // MARK: - 2-Way Diff

    private func compute2WayChanges(
        googleByResourceName: [String: UnifiedContact],
        macByIdentifier: [String: UnifiedContact],
        mappings: [ContactMapping]
    ) -> [ContactChange] {
        var changes: [ContactChange] = []

        // Build lookup maps from mappings
        var processedGoogle = Set<String>()
        var processedMac    = Set<String>()

        // --- Step 1: Walk all existing mappings ---
        for mapping in mappings {
            let gID  = mapping.googleResourceName
            let mID  = mapping.macContactIdentifier
            let gContact = googleByResourceName[gID]
            let mContact = macByIdentifier[mID]

            processedGoogle.insert(gID)
            processedMac.insert(mID)

            switch (gContact, mContact) {
            case (nil, nil):
                // Both deleted — clean up mapping (handled after loop)
                continue

            case (.some(let g), nil):
                if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: g.displayName, action: .delete,
                        direction: .macToGoogle, changes: ["Deleted on Mac side"],
                        sourceContact: g, targetContact: nil))
                }

            case (nil, .some(let m)):
                if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: m.displayName, action: .delete,
                        direction: .googleToMac, changes: ["Deleted on Google side"],
                        sourceContact: m, targetContact: nil))
                }

            case (.some(let g), .some(let m)):
                let fieldDiffs = diffFields(g, m)
                if fieldDiffs.isEmpty { continue }

                let gModified = g.lastModified ?? .distantPast
                let mModified = m.lastModified ?? .distantPast
                let syncedAt  = mapping.lastSyncedAt
                let gChanged  = gModified > syncedAt
                let mChanged  = mModified > syncedAt

                if gChanged && mChanged {
                    // Both sides changed since last sync — check conflict resolution preference
                    switch settings.defaultConflictResolution {
                    case .alwaysAsk:
                        // Present as a merge/conflict for the user to resolve
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .merge,
                            direction: .twoWay,
                            changes: fieldDiffs + ["⚠️ Conflict: both sides changed since last sync"],
                            sourceContact: g, targetContact: m))
                    case .preferGoogle:
                        // Auto-resolve: Google wins, push to Mac silently
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .update,
                            direction: .googleToMac,
                            changes: fieldDiffs + ["Auto-resolved: Google preferred"],
                            sourceContact: g, targetContact: m))
                    case .preferMac:
                        // Auto-resolve: Mac wins, push to Google silently
                        changes.append(ContactChange(
                            contactName: m.displayName, action: .update,
                            direction: .macToGoogle,
                            changes: fieldDiffs + ["Auto-resolved: Mac preferred"],
                            sourceContact: m, targetContact: g))
                    case .mergeBoth:
                        // Auto-resolve by combining: performMerge writes the union
                        // to both sides, so neither loses a field the other has.
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .merge,
                            direction: .twoWay,
                            changes: fieldDiffs + ["Auto-resolved: merged both sides"],
                            userOverride: .merge,
                            sourceContact: g, targetContact: m))
                    }
                } else if gChanged {
                    changes.append(ContactChange(
                        contactName: g.displayName, action: .update,
                        direction: .googleToMac, changes: fieldDiffs,
                        sourceContact: g, targetContact: m))
                } else if mChanged {
                    changes.append(ContactChange(
                        contactName: m.displayName, action: .update,
                        direction: .macToGoogle, changes: fieldDiffs,
                        sourceContact: m, targetContact: g))
                } else {
                    // The fields differ but no timestamp says who moved.
                    //
                    // This branch did not exist, and the change was dropped —
                    // silently, for the most common case there is. `CNContact`
                    // exposes no modification date, so a Mac contact's
                    // `lastModified` is always nil and `mChanged` is always
                    // false. An edit made only on the Mac therefore satisfied
                    // neither branch above, and a mapped pair could differ
                    // forever while every sync reported nothing to do.
                    //
                    // Unknown-vs-unknown is exactly the ambiguity the conflict
                    // preference exists to settle, so it is settled the same way
                    // rather than by picking a side here.
                    switch settings.defaultConflictResolution {
                    case .alwaysAsk:
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .merge,
                            direction: .twoWay,
                            changes: fieldDiffs + ["Differs, but neither side reports when it changed"],
                            sourceContact: g, targetContact: m))
                    case .preferGoogle:
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .update,
                            direction: .googleToMac, changes: fieldDiffs,
                            sourceContact: g, targetContact: m))
                    case .preferMac:
                        changes.append(ContactChange(
                            contactName: m.displayName, action: .update,
                            direction: .macToGoogle, changes: fieldDiffs,
                            sourceContact: m, targetContact: g))
                    case .mergeBoth:
                        changes.append(ContactChange(
                            contactName: g.displayName, action: .merge,
                            direction: .twoWay, changes: fieldDiffs,
                            userOverride: .merge,
                            sourceContact: g, targetContact: m))
                    }
                }
            }
        }

        // --- Step 2: New on Google, not yet mapped ---
        //
        // Index built once, outside the loop. This used to call
        // `macByIdentifier.filter { … }` per contact — rebuilding the entire
        // dictionary on every iteration — and then scan it linearly, normalising
        // each candidate's name again each time. On a first sync between two
        // populated address books that is every contact against every contact:
        // ~500,000 dictionary insertions and as many name normalisations for
        // 650 Google × 770 Mac. Lookups are now O(1).
        let macIndex = FuzzyIndex(contacts: macByIdentifier)

        for (gID, gContact) in googleByResourceName where !processedGoogle.contains(gID) {
            let fuzzyMatch = macIndex.match(gContact, excluding: processedMac)
            if let (mID, mContact, confidence) = fuzzyMatch {
                // Only the uncertain matches ask.
                //
                // Every fuzzy match used to be queued for review, so a first
                // sync between two populated address books produced hundreds of
                // identical prompts — and a shared email address is not a guess.
                // Confirmation fatigue is its own failure mode: a dialog shown
                // two hundred times stops being read, which is worse than not
                // showing it for the cases that never needed it.
                let autoApply = confidence == .exactEmail
                changes.append(ContactChange(
                    contactName: gContact.displayName, action: .merge,
                    direction: .twoWay,
                    // Variable detail after the colon on both branches: the
                    // diff-reason histogram keys on everything before the first
                    // colon, so a name embedded mid-sentence became its own
                    // bucket — and put the name in sync_history.json, which the
                    // histogram promises never to do.
                    changes: [autoApply
                        ? "Matched on a shared email address: \(mContact.displayName)"
                        : "Possible match: \(mContact.displayName) (same name only — review before merging)"],
                    userOverride: autoApply ? .merge : nil,
                    sourceContact: gContact, targetContact: mContact))
                processedMac.insert(mID)
            } else {
                changes.append(ContactChange(
                    contactName: gContact.displayName, action: .add,
                    direction: .googleToMac, changes: ["New contact from Google"],
                    sourceContact: gContact, targetContact: nil))
            }
        }

        // --- Step 3: New on Mac, not yet mapped ---
        //
        // Identity index over *every* Google contact, not just the unmapped ones.
        //
        // Step 2 checks for a match before creating a Mac contact; Step 3 did not,
        // and blindly pushed every unmapped Mac contact to Google as new. On a
        // first sync between two address books that already hold the same people —
        // the normal case — there are no mappings yet, so this duplicated the
        // entire address book into Google. It produced 229 spurious adds here.
        //
        // Matching against all Google contacts (not only unprocessed ones) matters:
        // a Mac contact can correspond to a Google contact that Step 1 already
        // handled under a different mapping, and adding it again would duplicate
        // regardless.
        var googleIdentityIndex: [String: (String, UnifiedContact)] = [:]
        for (gID, gContact) in googleByResourceName {
            for key in Self.identityKeys(for: gContact) where googleIdentityIndex[key] == nil {
                googleIdentityIndex[key] = (gID, gContact)
            }
        }

        for (_, mContact) in macByIdentifier where !processedMac.contains(mContact.macContactIdentifier ?? "") {
            // Empty rows are not worth propagating: pushing one to Google creates
            // a permanent blank contact there, and it will come back as a
            // "new contact" on every future sync from the other side.
            guard mContact.hasSyncableContent else {
                SyncHistory.shared.log(
                    source: "SyncEngine",
                    action: "change.skippedEmpty",
                    details: "Mac contact \(mContact.macContactIdentifier ?? "?") has no name, phone, email or organisation"
                )
                continue
            }

            // Already on the other side? Link them instead of creating a copy.
            let match = Self.identityKeys(for: mContact)
                .lazy
                .compactMap { googleIdentityIndex[$0] }
                .first

            if let (_, gContact) = match {
                changes.append(ContactChange(
                    contactName: mContact.displayName, action: .merge,
                    direction: .twoWay,
                    changes: ["Matched an existing Google contact — linking instead of adding a duplicate"],
                    sourceContact: gContact, targetContact: mContact))
                continue
            }

            changes.append(ContactChange(
                contactName: mContact.displayName, action: .add,
                direction: .macToGoogle, changes: ["New contact from Mac"],
                sourceContact: mContact, targetContact: nil))
        }

        return changes
    }

    /// Strong identity keys for cross-matching a contact between providers.
    ///
    /// Only signals that identify a *person*, never a shared attribute: a company
    /// switchboard or a shared family address would otherwise fuse unrelated
    /// people together, which is worse than a duplicate because it destroys data.
    ///
    /// Names alone are excluded for the same reason — two different "David Chan"
    /// entries are common. `findFuzzyMatch` may still pair on a name, but that path
    /// produces a reviewable merge rather than a silent link.
    static func identityKeys(for contact: UnifiedContact) -> [String] {
        var keys: [String] = []

        for email in contact.emailAddresses {
            if let normalized = email.value.nonBlank?.lowercased() {
                keys.append("email:\(normalized)")
            }
        }

        for phone in contact.phoneNumbers {
            // Compare the last 8 digits: the same number is routinely stored as
            // +852 9123 4567 on one side and 91234567 on the other, and a literal
            // string comparison would miss every one of them.
            let digits = phone.value.filter(\.isNumber)
            if digits.count >= 8 {
                keys.append("phone:\(String(digits.suffix(8)))")
            }
        }

        return keys
    }

    // MARK: - 1-Way Diff

    private func compute1WayChanges(
        source: [String: UnifiedContact],
        target: [String: UnifiedContact],
        mappings: [ContactMapping],
        sourceToTarget: Bool
    ) -> [ContactChange] {
        var changes: [ContactChange] = []

        // Build source→target ID lookup from mappings
        let sourceToTargetMap: [String: String]
        let direction: SyncDirection
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the mapping store is
        // keyed by googleResourceName, so macContactIdentifier is NOT unique —
        // two Google contacts pointing at one Mac contact is the normal shape
        // after a fuzzy match or a dedup merge. `uniqueKeysWithValues` traps on
        // a duplicate key, so a Mac → Google sync could hard-crash on perfectly
        // ordinary data. Last mapping wins, matching the store's own semantics.
        if sourceToTarget {
            sourceToTargetMap = Dictionary(
                mappings.map { ($0.googleResourceName, $0.macContactIdentifier) },
                uniquingKeysWith: { _, latest in latest }
            )
            direction = .googleToMac
        } else {
            sourceToTargetMap = Dictionary(
                mappings.map { ($0.macContactIdentifier, $0.googleResourceName) },
                uniquingKeysWith: { _, latest in latest }
            )
            direction = .macToGoogle
        }

        var mappedTargetIDs = Set<String>()

        // Walk source contacts
        for (sourceID, sourceContact) in source {
            if let targetID = sourceToTargetMap[sourceID] {
                mappedTargetIDs.insert(targetID)
                if let targetContact = target[targetID] {
                    let diffs = diffFields(sourceContact, targetContact)
                    if !diffs.isEmpty {
                        // "Merge during 1-way sync": a 1-way sync normally
                        // replaces the target from the source, which clears any
                        // field the target has and the source does not. Merging
                        // first keeps those. The setting was stored and never
                        // read, so the choice did not exist.
                        let payload = settings.mergeContacts1Way
                            ? mergeContacts(primary: sourceContact, secondary: targetContact)
                            : sourceContact

                        changes.append(ContactChange(
                            contactName: sourceContact.displayName,
                            action: .update, direction: direction, changes: diffs,
                            sourceContact: payload, targetContact: targetContact))
                    }
                } else if settings.syncDeletedContacts {
                    changes.append(ContactChange(
                        contactName: sourceContact.displayName,
                        action: .delete, direction: direction,
                        changes: ["Deleted on target side"],
                        sourceContact: sourceContact, targetContact: nil))
                }
            } else {
                changes.append(ContactChange(
                    contactName: sourceContact.displayName,
                    action: .add, direction: direction, changes: ["New contact"],
                    sourceContact: sourceContact, targetContact: nil))
            }
        }

        return changes
    }

    // MARK: - Field Diff

    /// Returns human-readable list of changed fields between two contacts.
    /// Only includes fields that are enabled in the user's per-field sync settings.
    private func diffFields(_ a: UnifiedContact, _ b: UnifiedContact) -> [String] {
        var diffs: [String] = []

        // "Force update all contacts" — write every mapped contact even when the
        // fields look identical. The setting existed and was read nowhere, so the
        // one thing it is for (repairing a side whose contents drifted from what
        // the mappings claim) could not be done.
        if settings.forceUpdateAll {
            diffs.append("Forced update")
        }

        // Core name / identity fields.
        //
        // Trimmed and case-folded, and an empty string treated as absent — the
        // two providers disagree about how to say "no value" (Google omits the
        // key, Contacts returns ""), and a name that differs only in whitespace
        // is not an edit anyone made. Comparing raw optionals reported both as
        // changes on every single sync.
        func textual(_ label: String, _ lhs: String?, _ rhs: String?) {
            let left = lhs?.nonBlank?.lowercased()
            let right = rhs?.nonBlank?.lowercased()
            if left != right { diffs.append("\(label) changed") }
        }
        textual("First name",  a.givenName,       b.givenName)
        textual("Last name",   a.familyName,       b.familyName)
        textual("Middle name", a.middleName,       b.middleName)
        textual("Company",     a.organizationName, b.organizationName)

        // Per-field toggles from Settings → Common Sync → Fields to Sync
        if settings.syncJobTitle { textual("Job title", a.jobTitle, b.jobTitle) }
        if settings.syncNotes    { textual("Note",      a.note,     b.note)     }

        // Birthday compared field by field, not as a whole DateComponents.
        //
        // The two sides populate different members of the struct — Contacts
        // fills in `calendar` and `era`, Google does not — so two identical
        // birthdays were never equal, and every contact with one reported a
        // change on every sync. Only the three parts that mean "a birthday" are
        // compared, and a year of 0 or 1604 (the placeholder for "no year")
        // counts as absent.
        if settings.syncBirthday {
            if Self.birthdayKey(a.birthday) != Self.birthdayKey(b.birthday) {
                diffs.append("Birthday changed")
            }
        }

        // Multi-value fields: compared as *normalised* sets.
        //
        // This is why a sync never converged. Apple Contacts reformats a phone
        // number when it saves it — "+15551234567" comes back as
        // "+1 (555) 123-4567" — while Google returns exactly what it was sent.
        // Comparing the raw strings therefore reported "Phone numbers changed"
        // for a contact that had just been synced, on every run, forever. The
        // same held for addresses, where the two sides differ in spacing and
        // capitalisation, and for URLs with or without a trailing slash.
        //
        // The matching code has always normalised — `identityKeys` and
        // `FuzzyIndex` both do. Only the diff compared raw values, so the app
        // could recognise two records as the same contact and then insist
        // forever that they differed.
        let aPhones = ContactNormalizer.normalizePhones(a.phoneNumbers.map(\.value))
        let bPhones = ContactNormalizer.normalizePhones(b.phoneNumbers.map(\.value))
        if aPhones != bPhones { diffs.append("Phone numbers changed") }

        let aEmails = ContactNormalizer.normalizeEmails(a.emailAddresses.map(\.value))
        let bEmails = ContactNormalizer.normalizeEmails(b.emailAddresses.map(\.value))
        if aEmails != bEmails { diffs.append("Email addresses changed") }

        if settings.syncAddresses {
            let aAddr = Set(a.postalAddresses.map(Self.normalizedAddress))
            let bAddr = Set(b.postalAddresses.map(Self.normalizedAddress))
            if aAddr != bAddr { diffs.append("Addresses changed") }
        }

        if settings.syncWebsites {
            let aUrls = Set(a.urls.map { Self.normalizedURL($0.value) })
            let bUrls = Set(b.urls.map { Self.normalizedURL($0.value) })
            if aUrls != bUrls { diffs.append("Websites changed") }
        }

        if settings.syncPhotos {
            // Photos only travel Google → Mac.
            //
            // The People API rejects `photos` in an update mask — it has a
            // separate updateContactPhoto endpoint — so a photo that exists only
            // on the Mac side cannot be pushed. The old test was symmetric
            // (`(a.photoData == nil) != (b.photoData == nil)`), so every
            // Mac-only photo produced a "Photo changed" entry, an update that
            // wrote nothing, and the identical entry again on the next sync.
            // Forever, for the same contacts.
            //
            // Reporting only the direction that can actually be applied means
            // the diff converges: one sync copies the photo to the Mac, and the
            // next sync has nothing to say about it.
            let google = a.googleResourceName != nil ? a : b
            let mac    = a.macContactIdentifier != nil ? a : b
            if google.photoData != nil && mac.photoData == nil {
                diffs.append("Photo changed")
            }
        }

        return diffs
    }

    /// Strip fields that the user has disabled in Settings → Common Sync → Fields to Sync
    /// from a unified contact before it is written to either side.
    /// This ensures we never overwrite a field on the target that the user opted out of syncing.
    ///
    /// Also applies the user's opt-in name casing convention
    /// (Settings → Sync Fields → Name Formatting). Formatting happens at
    /// write time only — reads and diff comparisons are unaffected, so a
    /// name that differs only in casing does not create spurious diffs
    /// (ContactNormalizer already compares case-insensitively).
    private func applyFieldSettings(to contact: UnifiedContact) -> UnifiedContact {
        var c = contact
        if !settings.syncNotes     { c.note           = nil }
        if !settings.syncBirthday  { c.birthday        = nil }
        if !settings.syncWebsites  { c.urls            = []  }
        if !settings.syncAddresses { c.postalAddresses = []  }
        if !settings.syncJobTitle  { c.jobTitle        = nil }
        if !settings.syncPhotos    { c.photoData       = nil }

        // "Normalise postal country codes". Google returns ISO codes, the Mac
        // stores whatever was typed, so the same address round-trips as
        // "US" / "United States" / "usa" and reads as a change every sync. When
        // the setting is off the raw values are written through unchanged.
        if settings.syncPostalCountryCodes {
            c.postalAddresses = c.postalAddresses.map(Self.normalizingCountry)
        }

        if settings.nameFormattingEnabled {
            NameFormattingEngine.applyToContact(&c, convention: settings.nameCasingConvention)
        }
        return c
    }

    /// Tally the diff reasons across a change set and log the top ones.
    ///
    /// Contact names are not included — this counts reasons, not people, so it
    /// is safe to paste into a bug report.
    nonisolated static func logFieldDiffHistogram(_ changes: [ContactChange]) {
        guard !changes.isEmpty else { return }

        var counts: [String: Int] = [:]
        for change in changes {
            for reason in change.changes {
                counts[histogramKey(for: reason), default: 0] += 1
            }
        }

        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        var actions: [String: Int] = [:]
        for change in changes {
            actions[(change.userOverride ?? change.action).rawValue, default: 0] += 1
        }
        let byAction = actions.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        SyncHistory.shared.log(
            source: "SyncEngine", action: "diff.reasons",
            details: "\(changes.count) changes — by action: \(byAction) — top fields: \(ranked)")
    }

    /// The histogram bucket for one diff reason: everything before the first
    /// colon. Reason strings put their per-contact detail — a name, a field
    /// value — after the colon, so this is what keeps the histogram's
    /// name-free promise; a reason that embeds a name before the colon (or has
    /// none) leaks it into `sync_history.json` as its own bucket.
    nonisolated static func histogramKey(for reason: String) -> String {
        guard let colon = reason.firstIndex(of: ":") else { return reason }
        return String(reason.prefix(upTo: colon))
    }

    /// A birthday reduced to the three numbers that mean one.
    ///
    /// `nil` when there is no birthday. 1604 is Apple's "year unknown"
    /// placeholder and 0 is Google's, so both are treated as no year — a
    /// birthday with a year on one side and none on the other still differs,
    /// which is a real difference, but two absent years now agree.
    nonisolated static func birthdayKey(_ components: DateComponents?) -> String? {
        guard let components,
              let month = components.month,
              let day = components.day else { return nil }
        let year = components.year.flatMap { ($0 == 0 || $0 == 1604) ? nil : $0 }
        return "\(year.map(String.init) ?? "-")-\(month)-\(day)"
    }

    /// An address reduced to what the two sides actually agree on.
    nonisolated static func normalizedAddress(_ address: UnifiedContact.PostalAddress) -> String {
        ContactNormalizer.normalizeAddress(
            street: address.street, city: address.city, state: address.state,
            postalCode: address.postalCode, country: address.country)
    }

    /// A URL reduced to what the two sides agree on.
    ///
    /// Case and a trailing slash are not a change anyone made — but Google and
    /// Contacts disagree about both, so comparing raw strings reported one.
    nonisolated static func normalizedURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    /// Fill in a missing ISO country code, and align the country name with it.
    ///
    /// Uses Foundation's locale data rather than a hand-written country table:
    /// the mapping is large, changes over time, and is already on the system.
    nonisolated static func normalizingCountry(_ address: UnifiedContact.PostalAddress)
        -> UnifiedContact.PostalAddress {
        var normalized = address

        if let code = address.countryCode?.nonBlank?.uppercased(),
           Locale.Region.isoRegions.contains(where: { $0.identifier == code }) {
            normalized.countryCode = code
            if let name = Locale.current.localizedString(forRegionCode: code) {
                normalized.country = name
            }
            return normalized
        }

        // No usable code — try to derive one from the country name.
        guard let country = address.country?.nonBlank else { return normalized }
        let match = Locale.Region.isoRegions.first { region in
            Locale.current.localizedString(forRegionCode: region.identifier)?
                .compare(country, options: .caseInsensitive) == .orderedSame
        }
        if let match {
            normalized.countryCode = match.identifier
            normalized.country = Locale.current.localizedString(forRegionCode: match.identifier)
                ?? country
        }
        return normalized
    }

    // MARK: - Fuzzy Match

    /// Find a probable match for a contact in an unmapped pool using name + email
    /// Email and normalised-name lookup over a set of contacts, built once.
    ///
    /// Replaces a linear scan that re-derived every candidate's emails and
    /// normalised name on each probe. Besides the cost, that scan walked a
    /// dictionary in arbitrary order and returned the first hit — so when two
    /// contacts both matched, which one won varied between runs. Ordering the
    /// candidates makes the result reproducible, which matters when the
    /// consequence of a wrong match is a merged or duplicated contact.
    struct FuzzyIndex {
        private var byEmail: [String: [String]] = [:]
        private var byName: [String: [String]] = [:]
        private let contacts: [String: UnifiedContact]

        init(contacts: [String: UnifiedContact]) {
            self.contacts = contacts
            for (id, contact) in contacts {
                for email in contact.emailAddresses {
                    guard let key = email.value.nonBlank?.lowercased() else { continue }
                    byEmail[key, default: []].append(id)
                }
                let name = ContactNormalizer.normalizeFullName(
                    given: contact.givenName, middle: nil, family: contact.familyName)
                if !name.isEmpty { byName[name, default: []].append(id) }
            }
            // Sorted so a tie resolves the same way every run.
            for key in byEmail.keys { byEmail[key]?.sort() }
            for key in byName.keys { byName[key]?.sort() }
        }

        /// How a candidate was found. The caller needs this: an email match and
        /// a name match are not equally trustworthy, and treating them as one
        /// thing meant every merge — including the obvious ones — went through
        /// a confirmation dialog. Two hundred prompts is not review; it is a
        /// button people learn to click without reading.
        enum Confidence {
            /// A shared email address. Two contacts with the same address are
            /// the same person in every practical case.
            case exactEmail
            /// Same normalised name and nothing else. "David Chen" is a real
            /// person twice over; this always needs a human.
            case nameOnly
        }

        /// Email match first, then name — the same precedence as before.
        func match(_ contact: UnifiedContact,
                   excluding used: Set<String>) -> (String, UnifiedContact, Confidence)? {
            for email in contact.emailAddresses {
                guard let key = email.value.nonBlank?.lowercased() else { continue }
                if let id = byEmail[key]?.first(where: { !used.contains($0) }),
                   let match = contacts[id] {
                    return (id, match, .exactEmail)
                }
            }

            let name = ContactNormalizer.normalizeFullName(
                given: contact.givenName, middle: nil, family: contact.familyName)
            guard !name.isEmpty,
                  let id = byName[name]?.first(where: { !used.contains($0) }),
                  let match = contacts[id] else { return nil }
            return (id, match, .nameOnly)
        }
    }

    // MARK: - Apply Changes

    // MARK: - Group / label filtering

    /// Narrow both sides to the groups and labels the user selected.
    ///
    /// "Filter sync by groups / labels" had a full picker behind it — Mac groups
    /// and Google labels, loaded from both services — and the selections were
    /// saved. Nothing ever read them, so the filter was purely decorative and a
    /// user who set it still synced their entire address book.
    ///
    /// An enabled filter with nothing selected on a side leaves that side
    /// untouched. The alternative — treating "no selection" as "match nothing" —
    /// would silently turn every contact on that side into a deletion candidate.
    private func applyGroupFilter(
        google: [UnifiedContact],
        googleSource: [GoogleContact],
        mac: [UnifiedContact]
    ) async -> (google: [UnifiedContact], mac: [UnifiedContact]) {
        var filteredGoogle = google
        var filteredMac = mac

        let selectedLabels = Set(settings.selectedGoogleLabels)
        if !selectedLabels.isEmpty {
            let allowed = Set(
                googleSource
                    .filter { !Set($0.groupResourceNames).isDisjoint(with: selectedLabels) }
                    .map(\.resourceName)
            )
            filteredGoogle = google.filter {
                guard let id = $0.googleResourceName else { return true }
                return allowed.contains(id)
            }
        }

        let selectedGroups = settings.selectedMacGroups
        if !selectedGroups.isEmpty {
            // Off the main actor with every other Contacts query.
            let allowed = await Task.detached(priority: .userInitiated) {
                MacContactsConnector.contactIdentifiers(inGroups: selectedGroups)
            }.value
            filteredMac = mac.filter {
                guard let id = $0.macContactIdentifier else { return true }
                return allowed.contains(id)
            }
        }

        SyncHistory.shared.log(
            source: "SyncEngine", action: "groupFilter.applied",
            details: "google \(google.count)→\(filteredGoogle.count), "
                   + "mac \(mac.count)→\(filteredMac.count)"
        )
        return (filteredGoogle, filteredMac)
    }

    // MARK: - Batched Google writes

    /// What the batch pre-pass managed to do, keyed by `ContactChange.id`.
    ///
    /// Deliberately not a "results" array: `executeSync` still owns all counting,
    /// history logging and abort logic, and it walks the changes in order. This
    /// only tells it which changes are already written and which the API refused.
    private struct BatchOutcome {
        var applied: Set<UUID> = []
        var failures: [UUID: Error] = [:]
    }

    /// Below this, batching costs the same number of requests as the per-contact
    /// path but loses its per-contact error messages and stale-etag retry.
    private static let minimumBatchSize = 2

    /// Stable identity for failure tracking.
    ///
    /// Prefers the Mac identifier because that is what the failing writes are
    /// about — 134092 comes from `CNSaveRequest`, and the Google resource name
    /// of the same pair can change when a contact is recreated. Falls back to
    /// the Google side for Google-only changes. A change with neither (a pure
    /// add, where nothing exists yet) returns nil and is never set aside: there
    /// is no record to blame, and retrying an add is harmless.
    static func failureKey(for change: ContactChange) -> String? {
        for contact in [change.targetContact, change.sourceContact] {
            if let id = contact?.macContactIdentifier, !id.isEmpty { return "mac:" + id }
        }
        for contact in [change.targetContact, change.sourceContact] {
            if let id = contact?.googleResourceName, !id.isEmpty { return "google:" + id }
        }
        return nil
    }

    /// Whether "Ask before deleting contacts" should hold this deletion back.
    ///
    /// The setting existed and was never read, so a scheduled sync could delete
    /// on both sides with nobody watching. Rather than block on a dialog that a
    /// 4-hourly background run has no way to show, an unreviewed run records the
    /// deletion and leaves it: the user applies it from the sync preview, where
    /// they can see exactly what would go. Adds and updates are recoverable from
    /// a backup; a deletion propagated to both address books is the change that
    /// actually costs people data.
    static func deletionIsHeldBack(action: SyncAction,
                                   session: SyncSession,
                                   settings: AppSettings) -> Bool {
        action == .delete && settings.confirmPendingDeletions && !session.userReviewed
    }

    /// Whether a failure is a judgement about *this contact* (malformed
    /// field, rejected payload) rather than about the world (network down,
    /// rate limit, server error, expired session, user cancel).
    ///
    /// Only contact-specific failures may count toward the three-strike
    /// set-aside. A dropped connection mid-batch hands the identical error to
    /// every contact in the chunk — up to 200 at once — and three syncs on
    /// flaky Wi-Fi could silently set aside half an address book forever,
    /// which inverts the store's purpose: it exists to absorb *persistent*
    /// per-contact failures, not transient environmental ones.
    static func failureCountsTowardSetAside(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is URLError { return false }
        if error is GoogleOAuthError { return false }
        switch error {
        case GoogleContactsError.rateLimitExceeded,
             GoogleContactsError.networkError,
             GoogleContactsError.notAuthenticated,
             GoogleContactsError.invalidToken:
            return false
        case let GoogleContactsError.apiError(statusCode, _):
            // 4xx (bar 429) judge the payload — this contact. 429 and 5xx
            // are Google's problem and will pass on their own.
            return statusCode != 429 && statusCode < 500
        default:
            return true
        }
    }

    /// Whether an unconfirmed merge should be held back from an unreviewed run.
    ///
    /// A `.merge` with no `userOverride` is a proposal, not a decision: the
    /// preview path marks exactly these as needs-review, but a scheduled run
    /// never reaches a preview, and until now they fell straight through to
    /// `performMerge` — fusing two people who share only a name and writing the
    /// union to both address books. A wrong merge is worse than a duplicate: it
    /// destroys the fact that these were two records. Confirmed merges
    /// (`userOverride == .merge` — a shared-email match, an explicit
    /// "merge both sides" preference, or the user's own choice in review)
    /// still apply.
    static func mergeIsHeldBack(change: ContactChange,
                                session: SyncSession) -> Bool {
        change.action == .merge && change.userOverride == nil && !session.userReviewed
    }

    /// Whether a change writes to Google, resolving `.twoWay` the way the
    /// per-contact apply paths do.
    ///
    /// Adds and updates push toward the side that lacks the contact; a delete
    /// removes it from the side that still has it — which is why `.delete`
    /// inverts the test rather than sharing it.
    private static func writesToGoogle(_ change: ContactChange,
                                       action: SyncAction,
                                       session: SyncSession) -> Bool {
        switch session.direction {
        case .macToGoogle: return true
        case .googleToMac: return false
        case .twoWay:
            guard let source = change.sourceContact else { return false }
            let hasGoogleID = source.googleResourceName?.nonBlank != nil
            return action == .delete ? hasGoogleID : !hasGoogleID
        }
    }

    /// Whether the batch pre-pass may write this change to Google.
    ///
    /// Mirrors every gate the per-contact loop applies *before* writing.
    /// The batch used to check only the deletion hold-back — so a contact set
    /// aside after three failures was still submitted to Google on every sync,
    /// its rejection never recorded (the per-contact loop `continue`s at the
    /// set-aside check before it reads batch failures), and a set-aside
    /// contact whose batch write *succeeded* was still counted as skipped,
    /// never cleared, and its Mac half never written. Set-aside means set
    /// aside: the contact must not reach the wire at all.
    static func batchMaySend(_ change: ContactChange,
                             session: SyncSession,
                             settings: AppSettings) -> Bool {
        let action = change.userOverride ?? change.action
        if deletionIsHeldBack(action: action, session: session, settings: settings) { return false }
        if let key = failureKey(for: change),
           SyncFailureStore.shared.shouldSkip(key: key) { return false }
        return writesToGoogle(change, action: action, session: session)
    }

    /// Apply every Google-bound add/update/delete through the People API batch
    /// endpoints before the per-contact loop runs.
    ///
    /// Google is the rate-limited side of this sync — a 300-contact run was 300
    /// requests, which is what produced the wall of refresh-token failures. The
    /// batch endpoints take 200 writes (500 deletes) per call, so the same run
    /// becomes a handful. Mac writes stay per-contact: they go to a local serial
    /// queue, not a quota.
    ///
    /// Merges are excluded on purpose. They write to *both* sides and the two
    /// writes have to stay together, so splitting the Google half into a batch
    /// would let one half land without the other.
    private func applyGoogleBatches(session: SyncSession) async -> BatchOutcome {
        var outcome = BatchOutcome()
        guard settings.batchGoogleUpdates, !settings.dryRunMode else { return outcome }

        typealias Pending = (id: UUID, name: String, macID: String?, contact: GoogleContact)
        var creates: [Pending] = []
        var updates: [Pending] = []
        var deletes: [(id: UUID, resourceName: String)] = []

        for change in session.contactChanges {
            let action = change.userOverride ?? change.action
            guard Self.batchMaySend(change, session: session, settings: settings),
                  let rawSource = change.sourceContact else { continue }
            let source = applyFieldSettings(to: rawSource)

            switch action {
            case .add:
                creates.append((change.id, change.contactName, source.macContactIdentifier,
                                ContactMapper.toGoogle(from: source)))

            case .update:
                guard let gID = change.targetContact?.googleResourceName?.nonBlank else { continue }
                var googleContact = GoogleContact(id: gID)
                ContactMapper.applyToGoogle(from: source, to: &googleContact)
                googleContact.etag = googleConnector.knownETag(for: gID)
                updates.append((change.id, change.contactName,
                                source.macContactIdentifier, googleContact))

            case .delete:
                guard let gID = source.googleResourceName?.nonBlank else { continue }
                deletes.append((change.id, gID))

            case .merge, .skip:
                continue
            }
        }

        // Pairs that still have a Mac-bound half coming in the per-contact
        // loop. Invariant: `lastSyncedAt` may only reach "now" once *both*
        // sides of a pair are confirmed written. The batch writes the Google
        // half only, and stamping "now" for it meant a later Mac-side failure
        // left the mapping claiming "synced" — so the next diff's
        // `modified > lastSyncedAt` test silently dropped the genuinely
        // pending edit. The Mac write path advances the stamp itself once its
        // half lands.
        var awaitingMacWrite: Set<String> = []
        for change in session.contactChanges {
            let action = change.userOverride ?? change.action
            guard action == .add || action == .update,
                  !Self.writesToGoogle(change, action: action, session: session) else { continue }
            if let gID = (change.sourceContact?.googleResourceName
                            ?? change.targetContact?.googleResourceName)?.nonBlank {
                awaitingMacWrite.insert("google:" + gID)
            }
            if let mID = (change.targetContact?.macContactIdentifier
                            ?? change.sourceContact?.macContactIdentifier)?.nonBlank {
                awaitingMacWrite.insert("mac:" + mID)
            }
        }

        await runCreateBatch(creates, awaitingMacWrite: awaitingMacWrite, into: &outcome)
        await runUpdateBatch(updates, awaitingMacWrite: awaitingMacWrite, into: &outcome)
        await runDeleteBatch(deletes, into: &outcome)

        if !outcome.applied.isEmpty || !outcome.failures.isEmpty {
            SyncHistory.shared.log(
                source: "SyncEngine", action: "batch.summary",
                details: "applied=\(outcome.applied.count) rejected=\(outcome.failures.count) "
                       + "(created=\(creates.count) updated=\(updates.count) deleted=\(deletes.count))"
            )
        }
        return outcome
    }

    /// The `lastSyncedAt` a batch write may record for a pair.
    ///
    /// "Now" only when the Google half just written is the whole change. If
    /// the same pair still has a Mac-bound half in this session's per-contact
    /// loop, the stamp keeps its previous value (`.distantPast` for a new
    /// pair), so a Mac-side failure leaves the pending edit visible to the
    /// next diff; the Mac write path stamps "now" when its half completes.
    private func batchSyncStamp(googleResourceName: String, macID: String,
                                awaitingMacWrite: Set<String>) -> Date {
        guard awaitingMacWrite.contains("google:" + googleResourceName)
                || awaitingMacWrite.contains("mac:" + macID) else { return Date() }
        return mappingStore.getMapping(googleResourceName: googleResourceName)?.lastSyncedAt
            ?? mappingStore.getMapping(macIdentifier: macID)?.lastSyncedAt
            ?? .distantPast
    }

    private func runCreateBatch(_ creates: [(id: UUID, name: String, macID: String?, contact: GoogleContact)],
                                awaitingMacWrite: Set<String>,
                                into outcome: inout BatchOutcome) async {
        guard creates.count >= Self.minimumBatchSize else { return }
        do {
            let created = try await googleConnector.batchCreateContacts(creates.map(\.contact))
            for (index, item) in creates.enumerated() {
                // Positional: batchCreateContacts pads its result to the request
                // length precisely so this index stays meaningful.
                guard index < created.count, let person = created[index] else {
                    outcome.failures[item.id] = SyncEngineError.batchItemRejected(item.name)
                    continue
                }
                if let macID = item.macID {
                    mappingStore.saveMapping(ContactMapping(
                        googleResourceName: person.resourceName,
                        macContactIdentifier: macID,
                        lastSyncedAt: batchSyncStamp(googleResourceName: person.resourceName,
                                                     macID: macID,
                                                     awaitingMacWrite: awaitingMacWrite)))
                }
                outcome.applied.insert(item.id)
            }
        } catch {
            // One failed call fails its whole chunk. Attributing the error to every
            // contact in it lets executeSync report and, for auth failures, abort.
            for item in creates { outcome.failures[item.id] = error }
        }
    }

    private func runUpdateBatch(_ updates: [(id: UUID, name: String, macID: String?, contact: GoogleContact)],
                                awaitingMacWrite: Set<String>,
                                into outcome: inout BatchOutcome) async {
        guard updates.count >= Self.minimumBatchSize else { return }
        do {
            let updated = try await googleConnector.batchUpdateContacts(updates.map(\.contact))
            for item in updates {
                guard updated[item.contact.resourceName] != nil else {
                    outcome.failures[item.id] = SyncEngineError.batchItemRejected(item.name)
                    continue
                }
                if let macID = item.macID {
                    mappingStore.saveMapping(ContactMapping(
                        googleResourceName: item.contact.resourceName,
                        macContactIdentifier: macID,
                        lastSyncedAt: batchSyncStamp(googleResourceName: item.contact.resourceName,
                                                     macID: macID,
                                                     awaitingMacWrite: awaitingMacWrite)))
                }
                outcome.applied.insert(item.id)
            }
        } catch {
            for item in updates { outcome.failures[item.id] = error }
        }
    }

    private func runDeleteBatch(_ deletes: [(id: UUID, resourceName: String)],
                               into outcome: inout BatchOutcome) async {
        guard deletes.count >= Self.minimumBatchSize else { return }
        do {
            try await googleConnector.batchDeleteContacts(resourceNames: deletes.map(\.resourceName))
            for item in deletes {
                mappingStore.deleteMapping(googleResourceName: item.resourceName)
                outcome.applied.insert(item.id)
            }
        } catch {
            for item in deletes { outcome.failures[item.id] = error }
        }
    }

    private func performAdd(change: ContactChange, direction: SyncDirection) async throws {
        guard let rawSource = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }
        // Strip any fields the user has turned off before writing to either side
        let source = applyFieldSettings(to: rawSource)

        switch direction {
        case .googleToMac:
            // Add Google contact to Mac
            let cnContact = ContactMapper.toMac(from: source)
            // Off-main: contactsd XPC from a user-interactive thread inverts
            // priority, and that contention is what fails the faulting during
            // save (Cocoa 134092).
            let connector = macConnector
            try await MacContactsConnector.performWriteOffMain {
                try connector.saveContactSync(cnContact, to: nil)
            }
            // Store mapping using the new Mac identifier
            if let gID = source.googleResourceName {
                let mID = cnContact.identifier
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .macToGoogle:
            // Add Mac contact to Google
            let googleContact = ContactMapper.toGoogle(from: source)
            let created = try await googleConnector.createContact(googleContact)
            // Store mapping
            if let mID = source.macContactIdentifier {
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: created.resourceName,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .twoWay:
            // twoWay adds go toward the side that doesn't have the contact
            if source.googleResourceName != nil {
                try await performAdd(change: change, direction: .googleToMac)
            } else {
                try await performAdd(change: change, direction: .macToGoogle)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "add",
            details: "\(change.contactName) → \(direction == .googleToMac ? "Mac" : "Google")")
    }

    /// The settings-derived write mask for Mac writes of engine-stripped
    /// contacts. `applyFieldSettings` empties opted-out fields, and
    /// `applyToMac` clears whatever the mask allows — passing `.all` for a
    /// stripped contact would erase every opted-out field from the Mac copy.
    private var macWriteFields: ContactMapper.MacWriteFields {
        ContactMapper.MacWriteFields(
            jobTitle:  settings.syncJobTitle,
            notes:     settings.syncNotes,
            birthday:  settings.syncBirthday,
            websites:  settings.syncWebsites,
            addresses: settings.syncAddresses,
            photos:    settings.syncPhotos)
    }

    private func performUpdate(change: ContactChange, direction: SyncDirection) async throws {
        guard let rawSource = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }
        // Strip any fields the user has turned off before writing to either side
        let source = applyFieldSettings(to: rawSource)

        switch direction {
        case .googleToMac:
            // Update Mac contact with Google data
            guard let mID = change.targetContact?.macContactIdentifier else { return }
            // Fetch and write on the same off-main queue: the fetch is XPC too,
            // and doing it here kept a priority inversion on the hot path.
            let c = macConnector
            let unified = source
            let mask = macWriteFields
            try await MacContactsConnector.performWriteOffMain {
                guard let existing = try c.fetchContactSync(withIdentifier: mID) else { return }
                let mutableContact = existing.mutableCopy() as! CNMutableContact
                ContactMapper.applyToMac(from: unified, to: mutableContact, fields: mask)
                try c.updateContactSync(mutableContact)
            }

            // Only store a mapping when there is a real Google id to store.
            // `?? ""` poisoned the store with an empty key that matches no Google
            // contact — and on the next two-way sync that looks like "deleted on
            // Google", which can delete a live Mac contact.
            if let gID = source.googleResourceName?.nonBlank {
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .macToGoogle:
            // Update Google contact with Mac data, preserving the existing resource name
            guard let gID = change.targetContact?.googleResourceName else { return }
            var googleContact = GoogleContact(id: gID)
            ContactMapper.applyToGoogle(from: source, to: &googleContact)
            // Reuse the etag captured during the initial fetch. Without it,
            // updateContact pays an extra GET per contact — and the change cannot
            // qualify for batching either.
            googleContact.etag = googleConnector.knownETag(for: gID)
            _ = try await googleConnector.updateContact(googleContact)
            if let mID = source.macContactIdentifier {
                mappingStore.saveMapping(ContactMapping(
                    googleResourceName: gID,
                    macContactIdentifier: mID,
                    lastSyncedAt: Date()))
            }

        case .twoWay:
            // 2-way updates: source drives the direction
            if source.googleResourceName != nil {
                try await performUpdate(change: change, direction: .googleToMac)
            } else {
                try await performUpdate(change: change, direction: .macToGoogle)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "update",
            details: "\(change.contactName): \(change.changes.joined(separator: ", "))")
    }

    private func performDelete(change: ContactChange, direction: SyncDirection) async throws {
        guard let source = change.sourceContact else {
            throw SyncEngineError.missingContactData(change.contactName)
        }

        switch direction {
        case .googleToMac:
            // Delete from Mac (Google side was deleted)
            if let mID = source.macContactIdentifier {
                // Off-main like every other Contacts mutation: `deleteContact`
                // fetches the live record first, and that fetch is the same
                // synchronous XPC hop that inverts priority from the main actor.
                let c = macConnector
                try await MacContactsConnector.performWriteOffMain {
                    try c.deleteContactSync(withIdentifier: mID)
                }
                if let gID = source.googleResourceName {
                    mappingStore.deleteMapping(googleResourceName: gID)
                }
            }

        case .macToGoogle:
            // Delete from Google (Mac side was deleted)
            if let gID = source.googleResourceName {
                try await googleConnector.deleteContact(resourceName: gID)
                mappingStore.deleteMapping(googleResourceName: gID)
            }

        case .twoWay:
            if source.googleResourceName != nil {
                try await performDelete(change: change, direction: .macToGoogle)
            } else {
                try await performDelete(change: change, direction: .googleToMac)
            }
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "delete",
            details: change.contactName)
    }

    private func performMerge(change: ContactChange, direction: SyncDirection) async throws {
        // If the user has chosen an override action, execute that instead
        if let override = change.userOverride {
            switch override {
            case .add:
                try await performAdd(change: change, direction: direction)
                return
            case .update:
                try await performUpdate(change: change, direction: direction)
                return
            case .skip:
                SyncHistory.shared.log(source: "SyncEngine", action: "merge.skipped",
                    details: "\(change.contactName) — user chose to skip")
                return
            case .delete:
                try await performDelete(change: change, direction: direction)
                return
            case .merge:
                break // fall through to merge logic below
            }
        }

        // Merge: combine data from both source and target, then write to both sides
        guard var source = change.sourceContact,
              var target = change.targetContact else {
            SyncHistory.shared.log(source: "SyncEngine", action: "merge.deferred",
                details: "\(change.contactName) — missing contact data for merge")
            return
        }

        // The Mac half is re-read at write time below, but the Google half was
        // captured when the diff was computed — and a reviewed merge can be
        // applied minutes later (dedup scan, AI matching, the review sheet
        // itself). A Google-side edit made in that window would be silently
        // overwritten by the stale union. Re-fetch the individual contact so
        // the merge combines current values; caching its etag also lets the
        // update below assert against the version it actually read.
        if let gID = (target.googleResourceName ?? source.googleResourceName)?.nonBlank {
            let fetched = try await googleConnector.fetchContact(resourceName: gID)
            googleConnector.cacheETags(from: [fetched])
            var fresh = ContactMapper.toUnified(from: fetched)
            if target.googleResourceName?.nonBlank == gID {
                fresh.macContactIdentifier = target.macContactIdentifier
                target = fresh
            } else {
                fresh.macContactIdentifier = source.macContactIdentifier
                source = fresh
            }
        }

        // Build a merged contact: prefer source for non-empty fields, keep target's extras
        let merged = mergeContacts(primary: source, secondary: target)
        let finalMerged = applyFieldSettings(to: merged)

        // Write merged result to Mac side
        if let mID = target.macContactIdentifier ?? source.macContactIdentifier {
            // Fetch, mutate and write inside one off-main block. Fetching on the
            // main actor and only writing off it still leaves the inversion on
            // the hot path — the fetch is XPC too.
            let c = macConnector
            let unified = finalMerged
            let mask = macWriteFields
            try await MacContactsConnector.performWriteOffMain {
                guard let existing = try c.fetchContactSync(withIdentifier: mID) else { return }
                let mutable = existing.mutableCopy() as! CNMutableContact
                ContactMapper.applyToMac(from: unified, to: mutable, fields: mask)
                try c.updateContactSync(mutable)
            }
        }

        // Write merged result to Google side
        if let gID = target.googleResourceName ?? source.googleResourceName {
            var googleContact = GoogleContact(id: gID)
            ContactMapper.applyToGoogle(from: finalMerged, to: &googleContact)
            googleContact.etag = googleConnector.knownETag(for: gID)
            _ = try await googleConnector.updateContact(googleContact)
        }

        // Save mapping
        if let gID = source.googleResourceName ?? target.googleResourceName,
           let mID = source.macContactIdentifier ?? target.macContactIdentifier {
            mappingStore.saveMapping(ContactMapping(
                googleResourceName: gID,
                macContactIdentifier: mID,
                lastSyncedAt: Date()))
        }

        SyncHistory.shared.log(source: "SyncEngine", action: "merge",
            details: "\(change.contactName) — merged from both sources")
    }

    /// Merge two contacts: primary wins for non-empty fields, secondary fills gaps
    func mergeContacts(primary: UnifiedContact, secondary: UnifiedContact) -> UnifiedContact { // internal for testing
        UnifiedContact(
            id: primary.id,
            googleResourceName: primary.googleResourceName ?? secondary.googleResourceName,
            macContactIdentifier: primary.macContactIdentifier ?? secondary.macContactIdentifier,
            givenName: primary.givenName?.isEmpty == false ? primary.givenName : secondary.givenName,
            middleName: primary.middleName?.isEmpty == false ? primary.middleName : secondary.middleName,
            familyName: primary.familyName?.isEmpty == false ? primary.familyName : secondary.familyName,
            namePrefix: primary.namePrefix?.isEmpty == false ? primary.namePrefix : secondary.namePrefix,
            nameSuffix: primary.nameSuffix?.isEmpty == false ? primary.nameSuffix : secondary.nameSuffix,
            nickname: primary.nickname?.isEmpty == false ? primary.nickname : secondary.nickname,
            phoneticGivenName: primary.phoneticGivenName ?? secondary.phoneticGivenName,
            phoneticMiddleName: primary.phoneticMiddleName ?? secondary.phoneticMiddleName,
            phoneticFamilyName: primary.phoneticFamilyName ?? secondary.phoneticFamilyName,
            organizationName: primary.organizationName?.isEmpty == false ? primary.organizationName : secondary.organizationName,
            department: primary.department?.isEmpty == false ? primary.department : secondary.department,
            jobTitle: primary.jobTitle?.isEmpty == false ? primary.jobTitle : secondary.jobTitle,
            // Merge lists: combine unique entries
            phoneNumbers: mergePhoneNumbers(primary.phoneNumbers, secondary.phoneNumbers),
            emailAddresses: mergeEmails(primary.emailAddresses, secondary.emailAddresses),
            postalAddresses: mergeAddresses(primary.postalAddresses, secondary.postalAddresses),
            urls: mergeURLs(primary.urls, secondary.urls),
            birthday: primary.birthday ?? secondary.birthday,
            note: mergeNotes(primary.note, secondary.note),
            photoData: primary.photoData ?? secondary.photoData,
            lastModified: Date()
        )
    }

    func mergePhoneNumbers(_ a: [UnifiedContact.PhoneNumber], _ b: [UnifiedContact.PhoneNumber]) -> [UnifiedContact.PhoneNumber] { // internal for testing
        var result = a
        let existingValues = Set(a.map { $0.value.filter(\.isNumber) })
        for phone in b where !existingValues.contains(phone.value.filter(\.isNumber)) {
            result.append(phone)
        }
        return result
    }

    func mergeEmails(_ a: [UnifiedContact.EmailAddress], _ b: [UnifiedContact.EmailAddress]) -> [UnifiedContact.EmailAddress] { // internal for testing
        var result = a
        let existing = Set(a.map { $0.value.lowercased() })
        for email in b where !existing.contains(email.value.lowercased()) {
            result.append(email)
        }
        return result
    }

    func mergeAddresses(_ a: [UnifiedContact.PostalAddress], _ b: [UnifiedContact.PostalAddress]) -> [UnifiedContact.PostalAddress] { // internal for testing
        // De-dup on the full normalized address, not the street line: the same
        // street exists in different cities, and a city/PO-box-only address has
        // no street at all — keying on street alone collapsed the former and
        // dropped the latter outright.
        var result = a
        var seen = Set(a.map(Self.normalizedAddress))
        for addr in b where seen.insert(Self.normalizedAddress(addr)).inserted {
            result.append(addr)
        }
        return result
    }

    func mergeURLs(_ a: [UnifiedContact.Url], _ b: [UnifiedContact.Url]) -> [UnifiedContact.Url] { // internal for testing
        var result = a
        let existing = Set(a.map { $0.value.lowercased() })
        for url in b where !existing.contains(url.value.lowercased()) {
            result.append(url)
        }
        return result
    }

    func mergeNotes(_ a: String?, _ b: String?) -> String? { // internal for testing
        switch (a, b) {
        case (nil, nil): return nil
        case (let v?, nil): return v
        case (nil, let v?): return v
        case (let v1?, let v2?):
            if v1 == v2 { return v1 }
            return v1 + "\n---\n" + v2
        }
    }

    // checkAutoSyncConditions went with runAutoSync, its only caller.

    private func saveToHistory(result: SyncResult) async throws {
        SyncHistory.shared.log(
            source: "SyncEngine",
            action: "sync.complete",
            details: result.summary
        )
    }
}

// MARK: - Contact Mapper

/// Converts between Google, Mac, and Unified contact formats
enum ContactMapper {
    static func toUnified(from googleContact: GoogleContact) -> UnifiedContact {
        var unified = UnifiedContact(id: UUID())
        unified.googleResourceName  = googleContact.resourceName
        unified.givenName           = googleContact.givenName?.nilIfEmpty
        unified.middleName          = googleContact.middleName?.nilIfEmpty
        unified.familyName          = googleContact.familyName?.nilIfEmpty
        unified.namePrefix          = googleContact.namePrefix?.nilIfEmpty
        unified.nameSuffix          = googleContact.nameSuffix?.nilIfEmpty
        unified.nickname            = googleContact.nickname?.nilIfEmpty
        unified.phoneticGivenName   = googleContact.phoneticGivenName?.nilIfEmpty
        unified.phoneticMiddleName  = googleContact.phoneticMiddleName?.nilIfEmpty
        unified.phoneticFamilyName  = googleContact.phoneticFamilyName?.nilIfEmpty
        unified.organizationName    = googleContact.organizationName?.nilIfEmpty
        unified.department          = googleContact.department?.nilIfEmpty
        unified.jobTitle            = googleContact.jobTitle?.nilIfEmpty
        unified.note                = googleContact.note?.nilIfEmpty
        unified.photoData           = googleContact.photoData
        unified.lastModified        = googleContact.updateTime

        // Phone numbers
        unified.phoneNumbers = googleContact.phoneNumbers.map {
            UnifiedContact.PhoneNumber(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Email addresses
        unified.emailAddresses = googleContact.emailAddresses.map {
            UnifiedContact.EmailAddress(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Postal addresses
        unified.postalAddresses = googleContact.addresses.map { addr in
            UnifiedContact.PostalAddress(
                street: addr.streetAddress ?? "",
                city: addr.city ?? "",
                state: addr.region ?? "",
                postalCode: addr.postalCode ?? "",
                country: addr.country ?? "",
                countryCode: addr.countryCode ?? "",
                label: addr.label ?? addr.type ?? ""
            )
        }

        // URLs
        unified.urls = googleContact.urls.map {
            UnifiedContact.Url(value: $0.value, label: $0.label ?? $0.type ?? "")
        }

        // Birthday
        if let bd = googleContact.birthday {
            var comps = DateComponents()
            comps.year  = bd.year
            comps.month = bd.month
            comps.day   = bd.day
            unified.birthday = comps
        }

        return unified
    }
    
    static func toUnified(from macContact: CNContact) -> UnifiedContact {
        var unified = UnifiedContact(id: UUID())
        unified.macContactIdentifier = macContact.identifier
        unified.givenName = macContact.givenName
        unified.middleName = macContact.middleName
        unified.familyName = macContact.familyName
        unified.namePrefix = macContact.namePrefix
        unified.nameSuffix = macContact.nameSuffix
        unified.nickname = macContact.nickname
        unified.phoneticGivenName = macContact.phoneticGivenName
        unified.phoneticMiddleName = macContact.phoneticMiddleName
        unified.phoneticFamilyName = macContact.phoneticFamilyName
        unified.organizationName = macContact.organizationName
        unified.department = macContact.departmentName
        unified.jobTitle = macContact.jobTitle
        
        // Phone numbers
        unified.phoneNumbers = macContact.phoneNumbers.map { phoneNumber in
            UnifiedContact.PhoneNumber(
                value: phoneNumber.value.stringValue,
                label: CNLabeledValue<NSString>.localizedString(forLabel: phoneNumber.label ?? "")
            )
        }
        
        // Email addresses
        unified.emailAddresses = macContact.emailAddresses.map { email in
            UnifiedContact.EmailAddress(
                value: email.value as String,
                label: CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "")
            )
        }
        
        // Postal addresses
        unified.postalAddresses = macContact.postalAddresses.map { addressValue in
            let address = addressValue.value
            return UnifiedContact.PostalAddress(
                street: address.street,
                city: address.city,
                state: address.state,
                postalCode: address.postalCode,
                country: address.country,
                countryCode: address.isoCountryCode,
                label: CNLabeledValue<NSString>.localizedString(forLabel: addressValue.label ?? "")
            )
        }
        
        // URLs
        unified.urls = macContact.urlAddresses.map { urlValue in
            UnifiedContact.Url(
                value: urlValue.value as String,
                label: CNLabeledValue<NSString>.localizedString(forLabel: urlValue.label ?? "")
            )
        }
        
        // Birthday
        unified.birthday = macContact.birthday
        
        // Note (requires com.apple.developer.contacts.notes entitlement since macOS 13)
        if macContact.isKeyAvailable(CNContactNoteKey) {
            unified.note = macContact.note
        }
        
        // Photo.
        //
        // Guarded like `note` above, and for the same reason: image data is only
        // fetched when photo sync is on, and reading an unfetched property
        // raises CNContactPropertyNotFetchedException. That is an ObjC
        // exception — not catchable as a Swift error, so it takes the process
        // down rather than surfacing as a failed sync.
        if macContact.isKeyAvailable(CNContactImageDataKey) {
            unified.photoData = macContact.imageData
        }

        return unified
    }
    
    static func toGoogle(from unified: UnifiedContact) -> GoogleContact {
        var google = GoogleContact(id: unified.googleResourceName ?? "")
        google.givenName          = unified.givenName
        google.middleName         = unified.middleName
        google.familyName         = unified.familyName
        google.namePrefix         = unified.namePrefix
        google.nameSuffix         = unified.nameSuffix
        google.nickname           = unified.nickname
        google.phoneticGivenName  = unified.phoneticGivenName
        google.phoneticMiddleName = unified.phoneticMiddleName
        google.phoneticFamilyName = unified.phoneticFamilyName
        google.organizationName   = unified.organizationName
        google.department         = unified.department
        google.jobTitle           = unified.jobTitle
        google.note               = unified.note
        google.photoData          = unified.photoData

        google.phoneNumbers = unified.phoneNumbers.map {
            GooglePhoneNumber(value: $0.value, type: $0.label, label: $0.label)
        }
        google.emailAddresses = unified.emailAddresses.map {
            GoogleEmailAddress(value: $0.value, type: $0.label, label: $0.label)
        }
        google.addresses = unified.postalAddresses.map { addr in
            GoogleAddress(
                streetAddress: addr.street,
                city: addr.city,
                region: addr.state,
                postalCode: addr.postalCode,
                country: addr.country,
                countryCode: addr.countryCode,
                type: addr.label,
                label: addr.label
            )
        }
        google.urls = unified.urls.map {
            GoogleUrl(value: $0.value, type: $0.label, label: $0.label)
        }

        if let bd = unified.birthday {
            google.birthday = GoogleDate(year: bd.year, month: bd.month, day: bd.day)
        }

        return google
    }
    
    /// `nonisolated` for the same reason as `applyToMac`: it is pure construction
    /// and runs on the Contacts write queue.
    nonisolated static func toMac(from unified: UnifiedContact) -> CNMutableContact {
        let mac = CNMutableContact()
        
        mac.givenName = unified.givenName ?? ""
        mac.middleName = unified.middleName ?? ""
        mac.familyName = unified.familyName ?? ""
        mac.namePrefix = unified.namePrefix ?? ""
        mac.nameSuffix = unified.nameSuffix ?? ""
        mac.nickname = unified.nickname ?? ""
        mac.phoneticGivenName = unified.phoneticGivenName ?? ""
        mac.phoneticMiddleName = unified.phoneticMiddleName ?? ""
        mac.phoneticFamilyName = unified.phoneticFamilyName ?? ""
        mac.organizationName = unified.organizationName ?? ""
        mac.departmentName = unified.department ?? ""
        mac.jobTitle = unified.jobTitle ?? ""

        // Phone numbers
        mac.phoneNumbers = unified.phoneNumbers.map { phone in
            let cnPhone = CNPhoneNumber(stringValue: phone.value)
            let label   = CNLabeledValue<CNPhoneNumber>(
                label: cnLabelFromString(phone.label), value: cnPhone)
            return label
        }

        // Email addresses
        mac.emailAddresses = unified.emailAddresses.map { email in
            CNLabeledValue<NSString>(
                label: cnLabelFromString(email.label),
                value: email.value as NSString)
        }

        // Postal addresses
        mac.postalAddresses = unified.postalAddresses.map { addr in
            let cnAddr = CNMutablePostalAddress()
            cnAddr.street     = addr.street     ?? ""
            cnAddr.city       = addr.city       ?? ""
            cnAddr.state      = addr.state      ?? ""
            cnAddr.postalCode = addr.postalCode ?? ""
            cnAddr.country    = addr.country    ?? ""
            if let cc = addr.countryCode, !cc.isEmpty {
                cnAddr.isoCountryCode = cc
            }
            return CNLabeledValue<CNPostalAddress>(
                label: cnLabelFromString(addr.label),
                value: cnAddr)
        }

        // URLs
        mac.urlAddresses = unified.urls.map { url in
            CNLabeledValue<NSString>(
                label: cnLabelFromString(url.label),
                value: url.value as NSString)
        }

        // Birthday
        if let bd = unified.birthday {
            mac.birthday = bd
        }

        // Assigning `note` without com.apple.developer.contacts.notes makes
        // CNContactStore reject the *entire* save with Cocoa error 134092 — not
        // just drop the field. An exported log showed 47 of 48 writes failing
        // this way, because Google biographies populate `unified.note` on nearly
        // every contact. The entitlement gate already existed in Settings and in
        // `syncNotes`; the write path was the one place that ignored it.
        if MacContactsConnector.notesFieldAvailable, let note = unified.note {
            mac.note = note
        }

        if let photoData = unified.photoData {
            mac.imageData = photoData
        }

        return mac
    }

    /// Which of the user-toggleable field groups a Mac write may touch.
    ///
    /// `applyToMac` clears a field when the incoming contact lacks it — that is
    /// what makes a deletion on Google converge instead of re-diffing forever.
    /// But the engine strips opted-out fields to nil/empty *before* writing
    /// (`applyFieldSettings`), which is indistinguishable from "cleared on the
    /// other side". Without this mask, turning a field's sync toggle off would
    /// erase that field from every Mac contact on the next sync. Callers that
    /// write engine-stripped contacts must pass the settings-derived mask;
    /// restore/dedup paths write full contacts and use `.all`.
    struct MacWriteFields: Sendable {
        var jobTitle  = true
        var notes     = true
        var birthday  = true
        var websites  = true
        var addresses = true
        var photos    = true
        /// The scalars added to `ContactSnapshot` after the first release
        /// (prefix/suffix, nickname, phonetics, department). Restores of
        /// pre-v2 backups decode them as nil — meaning "never captured", not
        /// "cleared" — and must not blank the live values.
        var extendedNames = true
        // `nonisolated`: referenced as the default argument of the
        // nonisolated `applyToMac`, which runs on the Contacts write queue.
        nonisolated static let all = MacWriteFields()

        /// The mask for restoring a backup snapshot: full-fidelity for v2
        /// snapshots; for legacy snapshots, only the fields v1 captured.
        nonisolated static func forRestore(ofLegacySnapshot legacy: Bool) -> MacWriteFields {
            var mask = MacWriteFields()
            if legacy {
                mask.websites = false
                mask.birthday = false
                mask.extendedNames = false
            }
            return mask
        }
    }

    /// Apply fields from a UnifiedContact onto an existing CNMutableContact (for updates)
    /// Preserves the contact's identifier.
    ///
    /// Fields the mask allows are written *unconditionally*: an empty array or
    /// nil scalar clears the Mac value. The old guards (`if !isEmpty`, `if let`)
    /// meant a field emptied on Google could never be emptied on the Mac — the
    /// diff kept reporting "Phone numbers changed", the sync kept "succeeding",
    /// and the same change fired on every run forever.
    ///
    /// `nonisolated`: pure field copying with no shared state, and it has to run
    /// on the Contacts write queue — hopping to the main actor mid-write would
    /// reintroduce the priority inversion the queue exists to avoid.
    nonisolated static func applyToMac(from unified: UnifiedContact,
                                       to mac: CNMutableContact,
                                       fields: MacWriteFields = .all) {
        // Always-synced scalars. Google says "no value" by omitting the key
        // (mapped to nil via nilIfEmpty), Contacts says it with "" — writing ""
        // for nil is how a name cleared on Google gets cleared here, and the
        // diff's `nonBlank` comparison treats the two as equal, so it converges.
        mac.givenName          = unified.givenName          ?? ""
        mac.middleName         = unified.middleName         ?? ""
        mac.familyName         = unified.familyName         ?? ""
        mac.organizationName   = unified.organizationName   ?? ""

        if fields.extendedNames {
            mac.namePrefix         = unified.namePrefix         ?? ""
            mac.nameSuffix         = unified.nameSuffix         ?? ""
            mac.nickname           = unified.nickname           ?? ""
            mac.phoneticGivenName  = unified.phoneticGivenName  ?? ""
            mac.phoneticFamilyName = unified.phoneticFamilyName ?? ""
            mac.departmentName     = unified.department         ?? ""
        }

        if fields.jobTitle { mac.jobTitle = unified.jobTitle ?? "" }

        // Guarded, exactly as `toMac` guards it.
        //
        // Writing `note` without the com.apple.developer.contacts.notes
        // entitlement makes Contacts reject the *entire* save — every field, not
        // just the note — as Cocoa 134092. `toMac` had this guard; this function
        // did not, and it is the one the merge path uses. That is why merges
        // failed with 134092 while adds and updates succeeded.
        if MacContactsConnector.notesFieldAvailable, fields.notes {
            mac.note = unified.note ?? ""
        }

        // Photos stay presence-only on purpose: they only travel Google → Mac,
        // and `diffFields` never reports a photo *removal* — so clearing here
        // would wipe a Mac photo through a change no preview ever showed.
        if fields.photos, let v = unified.photoData { mac.imageData = v }

        if fields.birthday { mac.birthday = unified.birthday }

        mac.phoneNumbers = unified.phoneNumbers.map {
            CNLabeledValue<CNPhoneNumber>(
                label: cnLabelFromString($0.label),
                value: CNPhoneNumber(stringValue: $0.value))
        }
        mac.emailAddresses = unified.emailAddresses.map {
            CNLabeledValue<NSString>(
                label: cnLabelFromString($0.label),
                value: $0.value as NSString)
        }
        if fields.addresses {
            mac.postalAddresses = unified.postalAddresses.map { addr in
                let cn = CNMutablePostalAddress()
                cn.street = addr.street ?? ""; cn.city = addr.city ?? ""
                cn.state  = addr.state  ?? ""; cn.postalCode = addr.postalCode ?? ""
                cn.country = addr.country ?? ""
                if let cc = addr.countryCode, !cc.isEmpty { cn.isoCountryCode = cc }
                return CNLabeledValue<CNPostalAddress>(label: cnLabelFromString(addr.label), value: cn)
            }
        }
        if fields.websites {
            mac.urlAddresses = unified.urls.map {
                CNLabeledValue<NSString>(
                    label: cnLabelFromString($0.label),
                    value: $0.value as NSString)
            }
        }
    }

    /// Apply fields from UnifiedContact onto an existing GoogleContact (for updates)
    static func applyToGoogle(from unified: UnifiedContact, to google: inout GoogleContact) {
        google.givenName          = unified.givenName
        google.middleName         = unified.middleName
        google.familyName         = unified.familyName
        google.namePrefix         = unified.namePrefix
        google.nameSuffix         = unified.nameSuffix
        google.nickname           = unified.nickname
        google.phoneticGivenName  = unified.phoneticGivenName
        google.phoneticMiddleName = unified.phoneticMiddleName
        google.phoneticFamilyName = unified.phoneticFamilyName
        google.organizationName   = unified.organizationName
        google.department         = unified.department
        google.jobTitle           = unified.jobTitle
        google.note               = unified.note
        google.photoData          = unified.photoData

        google.phoneNumbers    = unified.phoneNumbers.map    { GooglePhoneNumber(value: $0.value,    type: $0.label, label: $0.label) }
        google.emailAddresses  = unified.emailAddresses.map  { GoogleEmailAddress(value: $0.value,  type: $0.label, label: $0.label) }
        google.urls            = unified.urls.map            { GoogleUrl(value: $0.value, type: $0.label, label: $0.label) }
        google.addresses       = unified.postalAddresses.map { addr in
            GoogleAddress(streetAddress: addr.street, city: addr.city, region: addr.state,
                         postalCode: addr.postalCode, country: addr.country,
                         countryCode: addr.countryCode, type: addr.label, label: addr.label)
        }
        if let bd = unified.birthday {
            google.birthday = GoogleDate(year: bd.year, month: bd.month, day: bd.day)
        }
    }
}

// MARK: - Contact Mapping Store

/// Stores mappings between Google and Mac contact IDs.
///
/// One shared instance, one in-memory dictionary, mutated only on the main
/// actor. The previous shape — a concurrent queue with sync readers, async-
/// barrier writers, and *eight* call sites each constructing a private
/// instance over the same JSON file — had three real failure modes:
/// blocking `queue.sync` parked the main thread behind the barrier queue; an
/// async-barrier write followed by a sync read could miss its own write; and
/// because `saveToDisk` rewrites the whole file from one instance's snapshot,
/// a stale instance's flush silently resurrected mappings another instance
/// had just deleted (the Unlink-undoes-itself bug). All production access now
/// goes through `.shared`: reads and writes are plain main-actor dictionary
/// operations (read-your-write is trivially true, nothing blocks), and only
/// the disk write leaves the main thread, in order, on a serial IO queue.
final class ContactMappingStore {

    /// The one production store. Constructing a private instance re-creates
    /// the last-writer-wins file race — only tests should use `init`.
    static let shared = ContactMappingStore()

    // In-memory store (backed by JSON on disk for persistence)
    private var mappings: [String: ContactMapping] = [:] // keyed by googleResourceName
    /// Disk writes only. Serial, so snapshots land in mutation order.
    private let io = DispatchQueue(label: "ContactMappingStore.io", qos: .utility)
    private let persistenceURL: URL

    /// `persistenceURL` exists for tests: a private instance over the real
    /// file re-creates the last-writer-wins race the singleton removed, and
    /// test writes were landing in the developer's live mapping file.
    /// Production always uses `.shared` with the default path.
    init(persistenceURL: URL? = nil) {
        if let persistenceURL {
            self.persistenceURL = persistenceURL
        } else {
            let fm = FileManager.default
            let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)) ?? fm.temporaryDirectory
            let dir = appSupport.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "ContactSyncMate", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.persistenceURL = dir.appendingPathComponent("contact_mappings.json")
        }
        loadFromDisk()
    }

    func getAllMappings() -> [ContactMapping] {
        Array(mappings.values)
    }

    func getMapping(googleResourceName: String) -> ContactMapping? {
        mappings[googleResourceName]
    }

    func getMapping(macIdentifier: String) -> ContactMapping? {
        mappings.values.first { $0.macContactIdentifier == macIdentifier }
    }

    func saveMapping(_ mapping: ContactMapping) {
        mappings[mapping.googleResourceName] = mapping
        persist()
    }

    func deleteMapping(googleResourceName: String) {
        mappings.removeValue(forKey: googleResourceName)
        persist()
    }

    /// Forget one pairing, addressed from the Mac side.
    ///
    /// The dictionary is keyed by Google resource name, so removing a mapping
    /// when all you hold is a Mac identifier means a scan. That is the shape
    /// the Sync Failures list needs: a failed `CNSaveRequest` names the Mac
    /// record, not the Google one.
    func deleteMapping(macContactIdentifier: String) {
        let stale = mappings.filter { $0.value.macContactIdentifier == macContactIdentifier }
        guard !stale.isEmpty else { return }
        for key in stale.keys { mappings.removeValue(forKey: key) }
        persist()
    }

    /// Forget every Google ↔ Mac pairing.
    ///
    /// The next sync then treats both address books as unseen and re-matches by
    /// identity. That is what makes a retest a genuine first run — with the
    /// mappings still on disk, a "fresh" install behaves like an established one.
    func deleteAllMappings() {
        mappings.removeAll()
        persist()
    }

    // MARK: - Persistence

    private struct CodableMapping: Codable {
        var googleResourceName: String
        var macContactIdentifier: String
        var lastSyncedAt: Date
        var googleEtag: String?
    }

    /// Snapshot the current state and write it out off the main thread.
    /// The serial queue preserves mutation order, so the file always ends at
    /// the latest state even when saves burst during a large sync.
    private func persist() {
        let codable = mappings.values.map {
            CodableMapping(googleResourceName: $0.googleResourceName,
                           macContactIdentifier: $0.macContactIdentifier,
                           lastSyncedAt: $0.lastSyncedAt,
                           googleEtag: $0.googleEtag)
        }
        let url = persistenceURL
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(codable) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: persistenceURL),
              let loaded = try? decoder.decode([CodableMapping].self, from: data) else { return }
        for m in loaded {
            mappings[m.googleResourceName] = ContactMapping(
                googleResourceName: m.googleResourceName,
                macContactIdentifier: m.macContactIdentifier,
                lastSyncedAt: m.lastSyncedAt,
                googleEtag: m.googleEtag)
        }
    }
}

struct ContactMapping {
    var googleResourceName: String
    var macContactIdentifier: String
    var lastSyncedAt: Date
    var googleEtag: String?
}

// MARK: - Errors

enum SyncEngineError: LocalizedError {
    case syncAlreadyInProgress
    case autoSyncDisabled
    case conditionsNotMet
    case missingContactData(String)
    case backupNotFound
    case batchItemRejected(String)

    var errorDescription: String? {
        switch self {
        case .syncAlreadyInProgress:
            return "A sync operation is already in progress."
        case .autoSyncDisabled:
            return "Automatic sync is disabled in settings."
        case .conditionsNotMet:
            return "Auto-sync conditions not met (check power/network/idle settings)."
        case .missingContactData(let name):
            return "Missing contact data for: \(name)"
        case .backupNotFound:
            return "Backup session not found."
        case .batchItemRejected(let name):
            return "Google rejected this contact in a batch request: \(name)"
        }
    }
}
