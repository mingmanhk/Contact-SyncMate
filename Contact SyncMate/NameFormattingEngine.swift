//
//  NameFormattingEngine.swift
//  Contact SyncMate
//
//  Opt-in contact name formatting. When enabled (Settings → Sync Fields →
//  Name Formatting), names are normalised to the user's chosen convention
//  as contacts are written during sync.
//
//  Design rules:
//  • OFF by default — we never rewrite user data unless explicitly asked.
//  • CJK-safe: formatting is skipped for names containing CJK characters,
//    where Latin casing conventions do not apply.
//  • Particle-aware Title Case: "van der Berg", "de la Cruz", "McDonald",
//    "O'Brien", "MacIntyre" are handled correctly.
//  • Idempotent: formatting an already-formatted name is a no-op.
//

import Foundation

// MARK: - Convention

/// The casing convention to apply to contact names.
enum NameCasingConvention: String, CaseIterable, Identifiable {
    /// Leave names exactly as they are (default).
    case asIs = "asIs"
    /// "john SMITH" → "John Smith" (recommended). Particle- and prefix-aware.
    case titleCase = "titleCase"
    /// "John Smith" → "JOHN SMITH"
    case upperCase = "upperCase"
    /// "John Smith" → "john smith"
    case lowerCase = "lowerCase"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asIs:      return "Keep As-Is"
        case .titleCase: return "Title Case (Recommended)"
        case .upperCase: return "UPPERCASE"
        case .lowerCase: return "lowercase"
        }
    }

    var example: String {
        switch self {
        case .asIs:      return "john SMITH → john SMITH"
        case .titleCase: return "john SMITH → John Smith"
        case .upperCase: return "john Smith → JOHN SMITH"
        case .lowerCase: return "John SMITH → john smith"
        }
    }
}

// MARK: - Engine

/// Stateless name formatter. All functions are pure — trivially unit-testable.
enum NameFormattingEngine {

    /// Format a single name component according to the convention.
    /// CJK names are returned unchanged for every convention except `.asIs`
    /// (casing does not apply to CJK scripts).
    static func format(_ name: String?, convention: NameCasingConvention) -> String? {
        guard let name, !name.isEmpty else { return name }
        guard convention != .asIs else { return name }
        guard !containsCJK(name) else { return name }

        switch convention {
        case .asIs:      return name
        case .upperCase: return name.uppercased()
        case .lowerCase: return name.lowercased()
        case .titleCase: return titleCased(name)
        }
    }

    /// Apply the convention to all name components of a UnifiedContact.
    /// Only given/middle/family/prefix/suffix names are touched — nicknames,
    /// organisation names, and phonetic fields are left alone (they carry
    /// deliberate user formatting more often).
    static func applyToContact(_ contact: inout UnifiedContact,
                               convention: NameCasingConvention) {
        guard convention != .asIs else { return }
        contact.givenName  = format(contact.givenName,  convention: convention)
        contact.middleName = format(contact.middleName, convention: convention)
        contact.familyName = format(contact.familyName, convention: convention)
        contact.namePrefix = format(contact.namePrefix, convention: convention)
        contact.nameSuffix = format(contact.nameSuffix, convention: convention)
    }

    // MARK: - Title case implementation

    /// Lowercase particles that stay lowercase in the middle of a name.
    private static let lowercaseParticles: Set<String> = [
        "van", "von", "der", "den", "de", "del", "della", "di", "da",
        "la", "le", "los", "las", "du", "dos", "das", "ter", "ten",
        "af", "av", "zu", "und", "y", "e", "bin", "binti", "ibn", "al", "el"
    ]

    /// Prefixes that force the next letter to capitalise: McDonald, MacIntyre, O'Brien.
    private static func applySpecialPrefixCasing(_ word: String) -> String? {
        let lower = word.lowercased()

        // O'Xxx / D'Xxx
        if lower.count > 2,
           let apostropheIndex = lower.index(lower.startIndex, offsetBy: 1, limitedBy: lower.endIndex),
           (lower.hasPrefix("o'") || lower.hasPrefix("d'")),
           lower[apostropheIndex] == "'" {
            let head = String(lower.prefix(1)).uppercased() + "'"
            let tail = String(lower.dropFirst(2))
            return head + capitaliseFirst(tail)
        }

        // Mc / Mac (Mac only if 5+ chars — avoids over-capitalising "Mack", "Macey")
        if lower.hasPrefix("mc") && lower.count > 2 {
            return "Mc" + capitaliseFirst(String(lower.dropFirst(2)))
        }
        if lower.hasPrefix("mac") && lower.count > 4 {
            return "Mac" + capitaliseFirst(String(lower.dropFirst(3)))
        }

        return nil
    }

    private static func capitaliseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Particle-aware title case. Handles hyphenated names ("jean-luc" →
    /// "Jean-Luc") and multi-word components ("van der berg" → "van der Berg",
    /// except when the particle is the first word: "Van der Berg").
    private static func titleCased(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: false)
        var result: [String] = []

        for (index, wordSub) in words.enumerated() {
            let word = String(wordSub)
            guard !word.isEmpty else { result.append(word); continue }

            // Hyphenated segments each get cased: "jean-luc" → "Jean-Luc"
            let segments = word.split(separator: "-", omittingEmptySubsequences: false)
            let cased = segments.map { seg -> String in
                let segment = String(seg)
                guard !segment.isEmpty else { return segment }
                let lower = segment.lowercased()

                // Interior particles stay lowercase ("van", "der", …)
                if index > 0 && lowercaseParticles.contains(lower) {
                    return lower
                }
                // Special prefixes (Mc/Mac/O')
                if let special = applySpecialPrefixCasing(segment) {
                    return special
                }
                return capitaliseFirst(lower)
            }.joined(separator: "-")

            result.append(cased)
        }

        return result.joined(separator: " ")
    }

    // MARK: - CJK detection

    /// True if the string contains any CJK Unified Ideographs, Hiragana,
    /// Katakana, or Hangul characters — casing does not apply to these scripts.
    static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,     // CJK Unified Ideographs
                 0x3400...0x4DBF,     // CJK Extension A
                 0x3040...0x309F,     // Hiragana
                 0x30A0...0x30FF,     // Katakana
                 0xAC00...0xD7AF:     // Hangul Syllables
                return true
            default:
                continue
            }
        }
        return false
    }
}
