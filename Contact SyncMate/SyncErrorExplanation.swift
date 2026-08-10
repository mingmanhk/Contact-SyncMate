//
//  SyncErrorExplanation.swift
//  Contact SyncMate
//
//  Turns opaque framework error codes into something a person can act on.
//

import Foundation
import Contacts

/// Plain-language readings of the errors this app actually hits.
///
/// "The operation couldn't be completed. (Cocoa error 134092.)" is what
/// `localizedDescription` gives you for a failed Contacts write, and it tells
/// the user nothing: not what failed, not whether it is their fault, not
/// whether trying again could possibly help. It is the system's way of saying
/// the save was refused without saying why.
///
/// So this appends a reading, and is careful about the difference between what
/// the code *means* and what it *usually indicates here*. 134092 does not carry
/// a documented cause; what it reliably means is "Contacts refused the save".
/// Everything past that is this app's own experience of when it shows up, and
/// is worded as a likelihood rather than a diagnosis. Inventing a confident
/// explanation for an error we cannot read is how the retry loop started.
///
/// `nonisolated` because the sync engine formats these off the main actor.
nonisolated enum SyncErrorExplanation {

    /// The original message plus a reading, when there is one worth adding.
    static func describe(_ error: Error) -> String {
        let base = error.localizedDescription
        guard let hint = hint(for: error) else { return base }
        return "\(base) — \(hint)"
    }

    /// What this error tends to mean in this app, or nil when we have nothing
    /// honest to add. Returning nil is a real answer: a wrong guess printed
    /// next to every failure is worse than the bare code.
    static func hint(for error: Error) -> String? {
        let ns = error as NSError

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case 134092:
                // Seen constantly on merges. In every case traced so far the
                // record was one the app could read but not write: a linked
                // (unified) contact, or a contact living in an account macOS
                // exposes read-only — commonly the Google CardDAV mirror, which
                // is why it clusters on contacts that exist on both sides.
                return "macOS refused to save this contact. It usually means the "
                     + "record is read-only or linked to another account — check "
                     + "whether it lives in a Google or Exchange account inside "
                     + "the Contacts app rather than On My Mac."
            case 134030:
                return "The save was rolled back. Another app may have changed "
                     + "this contact at the same time."
            case 134060:
                return "The contact failed validation — a field is longer or "
                     + "differently shaped than Contacts allows."
            case 4, 260:
                return "The contact no longer exists. It was probably deleted "
                     + "after this sync was planned."
            default:
                return nil
            }
        }

        if ns.domain == CNErrorDomain {
            switch CNError.Code(rawValue: ns.code) {
            case .authorizationDenied:
                return "Contacts access is turned off. Grant it in System "
                     + "Settings → Privacy & Security → Contacts."
            case .recordDoesNotExist:
                return "The contact no longer exists on this Mac."
            case .insertedRecordAlreadyExists:
                return "A contact with this identifier already exists."
            case .containmentCycle, .containmentScope:
                return "The contact cannot be saved into that account."
            // `validationConfigurationError`, not `validationConfiguration` —
            // and there is no `validationUnsupportedField` case at all.
            case .validationConfigurationError, .validationMultipleErrors,
                 .validationTypeMismatch:
                return "Contacts rejected one of the fields on this contact."
            default:
                return nil
            }
        }

        return nil
    }
}
