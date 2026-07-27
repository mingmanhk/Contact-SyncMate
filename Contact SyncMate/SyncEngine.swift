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
        
        await MainActor.run {
            isRunning = true
            progress = SyncProgress(currentStep: "Fetching contacts...", completedItems: 0, totalItems: 0)
        }
        
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
            // Off the main actor: see fetchAllContactsOffMainActor. Driving
            // contactsd XPC from a user-interactive thread inverts priority and
            // corrupts subsequent faulting.
            let macContacts = try await macConnector.fetchAllContactsOffMainActor()

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
        
        await MainActor.run {
            isRunning = true
            progress = SyncProgress(
                currentStep: "Syncing...",
                completedItems: 0,
                totalItems: session.contactChanges.count
            )
        }
        
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
        var errors: [SyncError] = []

        // Google-bound writes go out in bulk first; the loop below then walks the
        // same changes for counting, history and the Mac side. Anything already
        // written here is skipped rather than sent twice.
        let batched = await applyGoogleBatches(session: session)

        // Execute each change
        for (index, change) in session.contactChanges.enumerated() {
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
                errors.append(SyncError(
                    contactName: change.contactName,
                    message: error.localizedDescription,
                    timestamp: Date()
                ))
                SyncHistory.shared.log(
                    source: "SyncEngine",
                    action: "change.failed",
                    details: "\(change.contactName) [\(action.rawValue)]: \(error.localizedDescription)"
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
            deferredDeletions: deferredDeletions
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
    
    /// Run automatic sync (called by background agent)
    func runAutoSync() async throws -> SyncResult {
        guard settings.autoSyncEnabled else {
            throw SyncEngineError.autoSyncDisabled
        }

        // Check conditions
        if !checkAutoSyncConditions() {
            throw SyncEngineError.conditionsNotMet
        }

        // Use incremental sync with sync tokens.
        let direction = settings.autoSyncDirection
        var session = try await prepareManualSync(direction: direction)
        session.mode = .automatic

        // Run deduplication scan if enabled
        if settings.detectGoogleDuplicates {
            let dedupCoordinator = DeduplicationCoordinator()
            let googleContacts = session.contactChanges.compactMap { $0.sourceContact }.filter { $0.googleResourceName != nil }
            let macContacts = session.contactChanges.compactMap { $0.targetContact }.filter { $0.macContactIdentifier != nil }
            if !googleContacts.isEmpty || !macContacts.isEmpty {
                let result = await dedupCoordinator.scanForDuplicates(
                    googleContacts: googleContacts,
                    macContacts: macContacts,
                    existingMappings: mappingStore.getAllMappings(),
                    // Silent auto-merge is opt-in (Settings → General →
                    // Confirmations). When off, every merge goes to review.
                    autoApplyIfSafe: settings.allowSilentAutoMerge
                )
                if result.needsUserConfirmation {
                    SyncHistory.shared.log(
                        source: "SyncEngine",
                        action: "autoSync.dedupDeferred",
                        details: "\(result.groupsNeedingConfirmation.count) duplicate groups need user review"
                    )
                }
            }
        }

        // Auto-execute without user preview
        return try await executeSync(session: session)
    }
    
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
                }
            }
        }

        // --- Step 2: New on Google, not yet mapped ---
        for (gID, gContact) in googleByResourceName where !processedGoogle.contains(gID) {
            let fuzzyMatch = findFuzzyMatch(for: gContact,
                                            in: macByIdentifier.filter { !processedMac.contains($0.key) })
            if let (mID, mContact) = fuzzyMatch {
                changes.append(ContactChange(
                    contactName: gContact.displayName, action: .merge,
                    direction: .twoWay,
                    changes: ["Potential match: \(mContact.displayName) (fuzzy — review before merging)"],
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

        func check<T: Equatable>(_ label: String, _ lhs: T?, _ rhs: T?) {
            if lhs != rhs { diffs.append("\(label) changed") }
        }

        // Core name / identity fields are always diffed
        check("First name",  a.givenName,       b.givenName)
        check("Last name",   a.familyName,       b.familyName)
        check("Middle name", a.middleName,       b.middleName)
        check("Company",     a.organizationName, b.organizationName)

        // Per-field toggles from Settings → Common Sync → Fields to Sync
        if settings.syncJobTitle  { check("Job title", a.jobTitle, b.jobTitle) }
        if settings.syncNotes     { check("Note",      a.note,     b.note)     }
        if settings.syncBirthday  { check("Birthday",  a.birthday, b.birthday) }

        // Multi-value fields: compare as sets so ordering doesn't cause false positives
        let aPhones = Set(a.phoneNumbers.map(\.value))
        let bPhones = Set(b.phoneNumbers.map(\.value))
        if aPhones != bPhones { diffs.append("Phone numbers changed") }

        let aEmails = Set(a.emailAddresses.map { $0.value.lowercased() })
        let bEmails = Set(b.emailAddresses.map { $0.value.lowercased() })
        if aEmails != bEmails { diffs.append("Email addresses changed") }

        if settings.syncAddresses {
            let aAddr = Set(a.postalAddresses.map { $0.formattedAddress })
            let bAddr = Set(b.postalAddresses.map { $0.formattedAddress })
            if aAddr != bAddr { diffs.append("Addresses changed") }
        }

        if settings.syncWebsites {
            let aUrls = Set(a.urls.map(\.value))
            let bUrls = Set(b.urls.map(\.value))
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
    private func findFuzzyMatch(
        for contact: UnifiedContact,
        in pool: [String: UnifiedContact]
    ) -> (String, UnifiedContact)? {
        let normalizedName = ContactNormalizer.normalizeFullName(
            given: contact.givenName, middle: nil, family: contact.familyName)
        let contactEmails = Set(contact.emailAddresses.map { $0.value.lowercased() })

        for (id, candidate) in pool {
            // Email exact match — high confidence
            let candidateEmails = Set(candidate.emailAddresses.map { $0.value.lowercased() })
            if !contactEmails.isEmpty && !contactEmails.isDisjoint(with: candidateEmails) {
                return (id, candidate)
            }
            // Name match — medium confidence (require both given + family)
            let candidateName = ContactNormalizer.normalizeFullName(
                given: candidate.givenName, middle: nil, family: candidate.familyName)
            if !normalizedName.isEmpty && normalizedName == candidateName {
                return (id, candidate)
            }
        }
        return nil
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
            guard !Self.deletionIsHeldBack(action: action, session: session, settings: settings),
                  Self.writesToGoogle(change, action: action, session: session),
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

        await runCreateBatch(creates, into: &outcome)
        await runUpdateBatch(updates, into: &outcome)
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

    private func runCreateBatch(_ creates: [(id: UUID, name: String, macID: String?, contact: GoogleContact)],
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
                        lastSyncedAt: Date()))
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
                        lastSyncedAt: Date()))
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
            try await MacContactsConnector.performWriteOffMain {
                guard let existing = try c.fetchContactSync(withIdentifier: mID) else { return }
                let mutableContact = existing.mutableCopy() as! CNMutableContact
                ContactMapper.applyToMac(from: unified, to: mutableContact)
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
        guard let source = change.sourceContact,
              let target = change.targetContact else {
            SyncHistory.shared.log(source: "SyncEngine", action: "merge.deferred",
                details: "\(change.contactName) — missing contact data for merge")
            return
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
            try await MacContactsConnector.performWriteOffMain {
                guard let existing = try c.fetchContactSync(withIdentifier: mID) else { return }
                let mutable = existing.mutableCopy() as! CNMutableContact
                ContactMapper.applyToMac(from: unified, to: mutable)
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
    private func mergeContacts(primary: UnifiedContact, secondary: UnifiedContact) -> UnifiedContact {
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

    private func mergePhoneNumbers(_ a: [UnifiedContact.PhoneNumber], _ b: [UnifiedContact.PhoneNumber]) -> [UnifiedContact.PhoneNumber] {
        var result = a
        let existingValues = Set(a.map { $0.value.filter(\.isNumber) })
        for phone in b where !existingValues.contains(phone.value.filter(\.isNumber)) {
            result.append(phone)
        }
        return result
    }

    private func mergeEmails(_ a: [UnifiedContact.EmailAddress], _ b: [UnifiedContact.EmailAddress]) -> [UnifiedContact.EmailAddress] {
        var result = a
        let existing = Set(a.map { $0.value.lowercased() })
        for email in b where !existing.contains(email.value.lowercased()) {
            result.append(email)
        }
        return result
    }

    private func mergeAddresses(_ a: [UnifiedContact.PostalAddress], _ b: [UnifiedContact.PostalAddress]) -> [UnifiedContact.PostalAddress] {
        // Keep all from primary; add from secondary only if street differs
        var result = a
        let existingStreets = Set(a.compactMap { $0.street?.lowercased() })
        for addr in b {
            if let street = addr.street?.lowercased(), !existingStreets.contains(street) {
                result.append(addr)
            }
        }
        return result
    }

    private func mergeURLs(_ a: [UnifiedContact.Url], _ b: [UnifiedContact.Url]) -> [UnifiedContact.Url] {
        var result = a
        let existing = Set(a.map { $0.value.lowercased() })
        for url in b where !existing.contains(url.value.lowercased()) {
            result.append(url)
        }
        return result
    }

    private func mergeNotes(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let v?, nil): return v
        case (nil, let v?): return v
        case (let v1?, let v2?):
            if v1 == v2 { return v1 }
            return v1 + "\n---\n" + v2
        }
    }

    private func checkAutoSyncConditions() -> Bool {
        let settings = AppSettings.shared

        // Check power condition
        if settings.autoSyncOnlyOnPower {
            let info = ProcessInfo.processInfo
            if info.isLowPowerModeEnabled { return false }
        }

        // Check that both accounts are connected
        if !GoogleOAuthManager.shared.isAuthenticated { return false }

        return true
    }

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
        
        // Photo
        unified.photoData = macContact.imageData
        
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

    /// Apply fields from a UnifiedContact onto an existing CNMutableContact (for updates)
    /// Preserves the contact's identifier — only overwrites changed fields.
    ///
    /// `nonisolated`: pure field copying with no shared state, and it has to run
    /// on the Contacts write queue — hopping to the main actor mid-write would
    /// reintroduce the priority inversion the queue exists to avoid.
    nonisolated static func applyToMac(from unified: UnifiedContact, to mac: CNMutableContact) {
        if let v = unified.givenName          { mac.givenName          = v }
        if let v = unified.middleName         { mac.middleName         = v }
        if let v = unified.familyName         { mac.familyName         = v }
        if let v = unified.namePrefix         { mac.namePrefix         = v }
        if let v = unified.nameSuffix         { mac.nameSuffix         = v }
        if let v = unified.nickname           { mac.nickname           = v }
        if let v = unified.phoneticGivenName  { mac.phoneticGivenName  = v }
        if let v = unified.phoneticFamilyName { mac.phoneticFamilyName = v }
        if let v = unified.organizationName   { mac.organizationName   = v }
        if let v = unified.department         { mac.departmentName     = v }
        if let v = unified.jobTitle           { mac.jobTitle           = v }
        if let v = unified.note               { mac.note               = v }
        if let v = unified.photoData          { mac.imageData          = v }
        if let v = unified.birthday           { mac.birthday           = v }

        if !unified.phoneNumbers.isEmpty {
            mac.phoneNumbers = unified.phoneNumbers.map {
                CNLabeledValue<CNPhoneNumber>(
                    label: cnLabelFromString($0.label),
                    value: CNPhoneNumber(stringValue: $0.value))
            }
        }
        if !unified.emailAddresses.isEmpty {
            mac.emailAddresses = unified.emailAddresses.map {
                CNLabeledValue<NSString>(
                    label: cnLabelFromString($0.label),
                    value: $0.value as NSString)
            }
        }
        if !unified.postalAddresses.isEmpty {
            mac.postalAddresses = unified.postalAddresses.map { addr in
                let cn = CNMutablePostalAddress()
                cn.street = addr.street ?? ""; cn.city = addr.city ?? ""
                cn.state  = addr.state  ?? ""; cn.postalCode = addr.postalCode ?? ""
                cn.country = addr.country ?? ""
                if let cc = addr.countryCode, !cc.isEmpty { cn.isoCountryCode = cc }
                return CNLabeledValue<CNPostalAddress>(label: cnLabelFromString(addr.label), value: cn)
            }
        }
        if !unified.urls.isEmpty {
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

/// Stores mappings between Google and Mac contact IDs
class ContactMappingStore {

    // In-memory store (backed by JSON on disk for persistence)
    private var mappings: [String: ContactMapping] = [:] // keyed by googleResourceName
    private let queue = DispatchQueue(label: "ContactMappingStore", attributes: .concurrent)
    private let persistenceURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "ContactSyncMate", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        persistenceURL = dir.appendingPathComponent("contact_mappings.json")
        loadFromDisk()
    }

    func getAllMappings() -> [ContactMapping] {
        queue.sync { Array(mappings.values) }
    }

    func getMapping(googleResourceName: String) -> ContactMapping? {
        queue.sync { mappings[googleResourceName] }
    }

    func getMapping(macIdentifier: String) -> ContactMapping? {
        queue.sync { mappings.values.first { $0.macContactIdentifier == macIdentifier } }
    }

    func saveMapping(_ mapping: ContactMapping) {
        queue.async(flags: .barrier) {
            self.mappings[mapping.googleResourceName] = mapping
            self.saveToDisk()
        }
    }

    func deleteMapping(googleResourceName: String) {
        queue.async(flags: .barrier) {
            self.mappings.removeValue(forKey: googleResourceName)
            self.saveToDisk()
        }
    }

    /// Forget every Google ↔ Mac pairing.
    ///
    /// The next sync then treats both address books as unseen and re-matches by
    /// identity. That is what makes a retest a genuine first run — with the
    /// mappings still on disk, a "fresh" install behaves like an established one.
    func deleteAllMappings() {
        queue.sync(flags: .barrier) {
            self.mappings.removeAll()
            self.saveToDisk()
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        struct CodableMapping: Codable {
            var googleResourceName: String
            var macContactIdentifier: String
            var lastSyncedAt: Date
            var googleEtag: String?
        }
        let codable = mappings.values.map {
            CodableMapping(googleResourceName: $0.googleResourceName,
                           macContactIdentifier: $0.macContactIdentifier,
                           lastSyncedAt: $0.lastSyncedAt,
                           googleEtag: $0.googleEtag)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(codable) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        struct CodableMapping: Codable {
            var googleResourceName: String
            var macContactIdentifier: String
            var lastSyncedAt: Date
            var googleEtag: String?
        }
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
    case notImplemented
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
        case .notImplemented:
            return "This feature is not yet implemented."
        case .missingContactData(let name):
            return "Missing contact data for: \(name)"
        case .backupNotFound:
            return "Backup session not found."
        case .batchItemRejected(let name):
            return "Google rejected this contact in a batch request: \(name)"
        }
    }
}
