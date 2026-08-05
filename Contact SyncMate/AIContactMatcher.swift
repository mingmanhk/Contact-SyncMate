//
//  AIContactMatcher.swift
//  Contact SyncMate
//
//  AI-powered contact matching layer that sits on top of the deterministic
//  scoring pipeline.  It runs two tiers in order:
//
//   1. Local NLP  — instant, offline, no API key required.
//      Adds signals the rule-based scorer misses:
//        • Nickname / common-name variants  (Bob ↔ Robert)
//        • Name-initial abbreviation        (J. Smith ↔ John Smith)
//        • Transposed name order            (Wei Li ↔ Li Wei)
//        • Phonetic (Soundex) surname match (Schmidt ↔ Schmitt)
//        • Phone suffix match               (local vs. international format)
//        • Email plus-alias detection       (john+work@ ≈ john@)
//        • Compound / split CJK names       (Liwei ↔ Li Wei)
//
//   2. Anthropic API  — called only for borderline pairs (rule score 30–79)
//      when the user has supplied an API key.  Uses claude-haiku for speed
//      and cost-efficiency.  Result is cached per contact-pair for the
//      lifetime of the process.
//

import Foundation

// MARK: - AI Match Result

struct AIMatchResult {
    /// Normalised confidence 0.0 – 1.0
    let confidence: Double
    let isDuplicate: Bool
    /// Human-readable explanation shown in the UI
    let reasoning: String
    let suggestedAction: DuplicateDecision
    /// Individual signals that contributed to the decision
    let matchSignals: [MatchSignal]
    let source: MatchSource

    enum MatchSource: String {
        case localNLP      = "Local NLP"
        case anthropicAPI  = "Claude AI"
        case cached        = "Cached"
    }

    struct MatchSignal: Identifiable {
        let id = UUID()
        let label: String
        let weight: Double
        let isPositive: Bool
    }
}

// MARK: - AI Contact Matcher

/// AI-powered contact matching coordinator.
@MainActor
class AIContactMatcher {

    static let shared = AIContactMatcher()

    // Per-process cache keyed by sorted contact-ID pair
    private var cache: [String: AIMatchResult] = [:]

    // MARK: - Public API

    /// Main entry point.  Returns an `AIMatchResult` for the given pair.
    /// - Parameters:
    ///   - contact1: First contact.
    ///   - contact2: Second contact.
    ///   - existingBreakdown: Score breakdown already computed by the rule engine.
    ///   - apiKey: Optional Anthropic API key.  If nil, only local NLP runs.
    ///   - scoreRangeLow: Lower bound of rule scores that should be escalated to the API (default 30).
    ///   - scoreRangeHigh: Upper bound of rule scores that should be escalated to the API (default 79).
    func analyzeMatch(
        contact1: UnifiedContact,
        contact2: UnifiedContact,
        existingBreakdown: MatchScoreBreakdown,
        apiKey: String?,
        scoreRangeLow: Int = 30,
        scoreRangeHigh: Int = 79
    ) async -> AIMatchResult {

        let cKey = cacheKey(contact1, contact2)
        if let hit = cache[cKey] {
            return AIMatchResult(
                confidence: hit.confidence,
                isDuplicate: hit.isDuplicate,
                reasoning: hit.reasoning,
                suggestedAction: hit.suggestedAction,
                matchSignals: hit.matchSignals,
                source: .cached
            )
        }

        // Tier 1 – local NLP (always runs)
        let localResult = runLocalNLP(c1: contact1, c2: contact2, existing: existingBreakdown)

        // Tier 2 – Anthropic API (only for pairs inside the user-configured score window)
        let baseScore = existingBreakdown.totalScore
        let isAmbiguous = baseScore >= scoreRangeLow && baseScore <= scoreRangeHigh
        var finalResult = localResult

        if isAmbiguous, let key = apiKey, !key.isEmpty {
            if let apiResult = await callAnthropicAPI(c1: contact1, c2: contact2,
                                                       localResult: localResult, apiKey: key) {
                finalResult = apiResult
            }
        }

        cache[cKey] = finalResult
        return finalResult
    }

    /// Invalidate cached results (call after a sync cycle completes)
    func clearCache() { cache.removeAll() }

    // MARK: - Tier 1: Local NLP

    private func runLocalNLP(
        c1: UnifiedContact,
        c2: UnifiedContact,
        existing: MatchScoreBreakdown
    ) -> AIMatchResult {

        var signals: [AIMatchResult.MatchSignal] = []
        var delta = 0.0

        let n1 = c1.normalizedForDeduplication
        let n2 = c2.normalizedForDeduplication

        // ── Nickname / common-name variant ───────────────────────────────────
        let nicknameBonus = nicknameMatchBonus(n1: n1, n2: n2, c1: c1, c2: c2)
        if nicknameBonus > 0 {
            signals.append(.init(label: "Nickname / common name variant", weight: nicknameBonus, isPositive: true))
            delta += nicknameBonus
        }

        // ── Name initial abbreviation ("J. Smith" ↔ "John Smith") ───────────
        let initialBonus = initialMatchBonus(n1: n1, n2: n2)
        if initialBonus > 0 {
            signals.append(.init(label: "First-name initial matches full name", weight: initialBonus, isPositive: true))
            delta += initialBonus
        }

        // ── Transposed name order ("Wei Li" ↔ "Li Wei") ─────────────────────
        if isTransposedName(n1: n1, n2: n2) {
            signals.append(.init(label: "Name components match when reordered", weight: 20, isPositive: true))
            delta += 20
        }

        // ── Phonetic (Soundex) surname similarity ────────────────────────────
        let phoneticBonus = phoneticSurnameBonus(n1: n1, n2: n2)
        if phoneticBonus > 0 {
            signals.append(.init(label: "Surnames sound similar (phonetic match)", weight: phoneticBonus, isPositive: true))
            delta += phoneticBonus
        }

        // ── Phone suffix match (last 7 digits) ───────────────────────────────
        if phoneSuffixMatches(c1: c1, c2: c2) {
            signals.append(.init(label: "Phone numbers share last 7 digits", weight: 30, isPositive: true))
            delta += 30
        }

        // ── Email plus-alias detection ("john+work@" ≈ "john@") ─────────────
        if emailAliasMatches(c1: c1, c2: c2) {
            signals.append(.init(label: "Emails appear to be plus-aliases of each other", weight: 40, isPositive: true))
            delta += 40
        }

        // ── Compound / split name ("Liwei" ↔ "Li Wei") ──────────────────────
        let compoundBonus = compoundNameBonus(n1: n1, n2: n2)
        if compoundBonus > 0 {
            signals.append(.init(label: "Possible compound / split name format", weight: compoundBonus, isPositive: true))
            delta += compoundBonus
        }

        // ── Nickname stored in contact record ────────────────────────────────
        if let nn1 = c1.nickname?.lowercased().trimmingCharacters(in: .whitespaces), !nn1.isEmpty {
            let given2 = n2.givenName
            if given2 == nn1 || given2.hasPrefix(nn1) {
                signals.append(.init(label: "Contact's stored nickname matches other name", weight: 20, isPositive: true))
                delta += 20
            }
        }
        if let nn2 = c2.nickname?.lowercased().trimmingCharacters(in: .whitespaces), !nn2.isEmpty {
            let given1 = n1.givenName
            if given1 == nn2 || given1.hasPrefix(nn2) {
                signals.append(.init(label: "Contact's stored nickname matches other name", weight: 20, isPositive: true))
                delta += 20
            }
        }

        let finalScore = min(100.0, Double(existing.totalScore) + delta)
        let isDuplicate = finalScore >= 50
        let reasoning = composeReasoning(existingReasons: existing.reasons, signals: signals, score: finalScore)

        return AIMatchResult(
            confidence: finalScore / 100.0,
            isDuplicate: isDuplicate,
            reasoning: reasoning,
            suggestedAction: decision(for: finalScore),
            matchSignals: signals,
            source: .localNLP
        )
    }

    // MARK: - Signal Detectors

    private func nicknameMatchBonus(
        n1: NormalizedContact, n2: NormalizedContact,
        c1: UnifiedContact, c2: UnifiedContact
    ) -> Double {
        let first1 = n1.givenName.split(separator: " ").first.map(String.init) ?? n1.givenName
        let first2 = n2.givenName.split(separator: " ").first.map(String.init) ?? n2.givenName
        guard !first1.isEmpty && !first2.isEmpty && first1 != first2 else { return 0 }

        guard let g1 = Self.nicknameIndex[first1],
              let g2 = Self.nicknameIndex[first2],
              g1 == g2 else { return 0 }

        // Stronger signal when family names also match
        if !n1.familyName.isEmpty && n1.familyName == n2.familyName { return 35 }
        return 20
    }

    private func initialMatchBonus(n1: NormalizedContact, n2: NormalizedContact) -> Double {
        let g1 = n1.givenName, g2 = n2.givenName
        guard !g1.isEmpty && !g2.isEmpty else { return 0 }

        let isInit1 = g1.count == 1, isInit2 = g2.count == 1
        guard isInit1 || isInit2 else { return 0 }

        let initial = isInit1 ? g1 : g2
        let full    = isInit1 ? g2 : g1
        guard full.hasPrefix(initial) else { return 0 }

        // Require matching family name for confidence
        if !n1.familyName.isEmpty && n1.familyName == n2.familyName { return 25 }
        return 10
    }

    private func isTransposedName(n1: NormalizedContact, n2: NormalizedContact) -> Bool {
        let f1 = n1.fullName, f2 = n2.fullName
        guard !f1.isEmpty && !f2.isEmpty && f1 != f2 else { return false }
        let t1 = Set(f1.split(separator: " ").map(String.init))
        let t2 = Set(f2.split(separator: " ").map(String.init))
        return t1 == t2 && t1.count >= 2
    }

    private func phoneticSurnameBonus(n1: NormalizedContact, n2: NormalizedContact) -> Double {
        let s1 = soundex(n1.familyName), s2 = soundex(n2.familyName)
        guard !s1.isEmpty && !s2.isEmpty && s1 == s2 && n1.familyName != n2.familyName else { return 0 }
        return 10
    }

    private func phoneSuffixMatches(c1: UnifiedContact, c2: UnifiedContact) -> Bool {
        let digits: (String) -> String = { $0.filter(\.isNumber) }
        for p1 in c1.phoneNumbers.map({ digits($0.value) }) {
            for p2 in c2.phoneNumbers.map({ digits($0.value) }) {
                let s1 = String(p1.suffix(7)), s2 = String(p2.suffix(7))
                if s1.count == 7 && s1 == s2 && p1 != p2 { return true }
            }
        }
        return false
    }

    private func emailAliasMatches(c1: UnifiedContact, c2: UnifiedContact) -> Bool {
        for e1 in c1.emailAddresses.map({ $0.value.lowercased() }) {
            for e2 in c2.emailAddresses.map({ $0.value.lowercased() }) {
                if areEmailAliases(e1, e2) { return true }
            }
        }
        return false
    }

    private func areEmailAliases(_ e1: String, _ e2: String) -> Bool {
        guard e1 != e2 else { return false }
        let p1 = e1.split(separator: "@", maxSplits: 1)
        let p2 = e2.split(separator: "@", maxSplits: 1)
        guard p1.count == 2 && p2.count == 2,
              String(p1[1]) == String(p2[1]) else { return false }
        let stripped: (String) -> String = { String($0.split(separator: "+").first ?? Substring($0)) }
        return stripped(String(p1[0])) == stripped(String(p2[0]))
    }

    /// Bonus when two names are the same once spacing is ignored.
    ///
    /// e.g. "liwei zhang" ↔ "li wei zhang" — the usual CJK romanisation split.
    ///
    /// The guard used to read `c1 != c2 && c1 == c2`, which nothing can satisfy,
    /// so this always returned 0 and the signal never existed. The intent was
    /// "the spaced forms differ, but the unspaced forms match" — otherwise this
    /// would just be re-scoring an exact name match that the caller has already
    /// counted.
    private func compoundNameBonus(n1: NormalizedContact, n2: NormalizedContact) -> Double {
        let c1 = n1.fullName.replacingOccurrences(of: " ", with: "")
        let c2 = n2.fullName.replacingOccurrences(of: " ", with: "")
        guard !c1.isEmpty, !c2.isEmpty,
              n1.fullName != n2.fullName,   // not already an exact match
              c1 == c2                       // identical once spacing is removed
        else { return 0 }
        return 25
    }

    // MARK: - Soundex

    private func soundex(_ input: String) -> String {
        let upper = input.uppercased().filter(\.isLetter)
        guard let first = upper.first else { return "" }

        let table: [Character: Character] = [
            "B":"1","F":"1","P":"1","V":"1",
            "C":"2","G":"2","J":"2","K":"2","Q":"2","S":"2","X":"2","Z":"2",
            "D":"3","T":"3","L":"4","M":"5","N":"5","R":"6"
        ]

        var result = String(first)
        var prev = table[first] ?? "0"

        for ch in upper.dropFirst() {
            let code = table[ch] ?? "0"
            if code != "0" && code != prev {
                result.append(code)
                if result.count == 4 { break }
            }
            if code != "0" { prev = code } else { prev = "0" }
        }

        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    // MARK: - Tier 2: Anthropic API

    private func callAnthropicAPI(
        c1: UnifiedContact,
        c2: UnifiedContact,
        localResult: AIMatchResult,
        apiKey: String
    ) async -> AIMatchResult? {

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,                   forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",             forHTTPHeaderField: "anthropic-version")

        let prompt = makePrompt(c1: c1, c2: c2, localResult: localResult)
        let body: [String: Any] = [
            "model": AppSettings.shared.aiModel.rawValue,
            "max_tokens": 300,
            "system": """
            You are a contact deduplication expert. Given two contact records, decide whether \
            they refer to the same real-world person. \
            Respond ONLY with a single JSON object — no markdown, no preamble.
            """,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return parseAPIResponse(data: data, localResult: localResult)
        } catch {
            return nil  // Silently fall back to local result on any network error
        }
    }

    private func makePrompt(c1: UnifiedContact, c2: UnifiedContact, localResult: AIMatchResult) -> String {
        func card(_ c: UnifiedContact) -> String {
            var parts: [String] = []
            let name = c.displayName; if !name.isEmpty { parts.append("Name: \(name)") }
            if let nn = c.nickname, !nn.isEmpty { parts.append("Nickname: \(nn)") }
            if let org = c.organizationName, !org.isEmpty { parts.append("Org: \(org)") }
            if let title = c.jobTitle, !title.isEmpty { parts.append("Title: \(title)") }
            let emails = c.emailAddresses.map(\.value).joined(separator: ", ")
            if !emails.isEmpty { parts.append("Email: \(emails)") }
            let phones = c.phoneNumbers.map(\.value).joined(separator: ", ")
            if !phones.isEmpty { parts.append("Phone: \(phones)") }
            return parts.isEmpty ? "(no data)" : parts.joined(separator: " | ")
        }

        let localSignals = localResult.matchSignals.map(\.label).joined(separator: ", ")
        let localSignalText = localSignals.isEmpty ? "none" : localSignals

        return """
        Contact A: \(card(c1))
        Contact B: \(card(c2))

        Local analysis: confidence \(Int(localResult.confidence * 100))%, signals: \(localSignalText)

        Are these the same person? Reply with exactly this JSON structure:
        {
          "is_duplicate": true or false,
          "confidence": integer 0-100,
          "reasoning": "one or two sentence explanation",
          "action": "merge" | "keep_separate" | "review"
        }
        """
    }

    private func parseAPIResponse(data: Data, localResult: AIMatchResult) -> AIMatchResult? {
        // Unwrap Anthropic message envelope
        guard
            let envelope  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content   = (envelope["content"] as? [[String: Any]])?.first,
            let rawText   = content["text"] as? String
        else { return nil }

        // Strip optional markdown code fences
        let cleaned = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jsonData = cleaned.data(using: .utf8),
            let parsed   = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        let isDuplicate = parsed["is_duplicate"] as? Bool ?? localResult.isDuplicate
        let confidence  = (parsed["confidence"] as? Int).map { Double($0) / 100.0 } ?? localResult.confidence
        let reasoning   = parsed["reasoning"]   as? String ?? localResult.reasoning
        let actionStr   = parsed["action"]      as? String ?? "review"

        let action: DuplicateDecision
        switch actionStr {
        case "merge":         action = .merge
        case "keep_separate": action = .keepSeparate
        default:              action = .skip
        }

        return AIMatchResult(
            confidence: confidence,
            isDuplicate: isDuplicate,
            reasoning: reasoning,
            suggestedAction: action,
            matchSignals: localResult.matchSignals,
            source: .anthropicAPI
        )
    }

    // MARK: - Utilities

    private func decision(for score: Double) -> DuplicateDecision {
        if score >= 80 { return .merge }
        if score >= 50 { return .skip }
        return .keepSeparate
    }

    private func composeReasoning(
        existingReasons: [String],
        signals: [AIMatchResult.MatchSignal],
        score: Double
    ) -> String {
        var parts = existingReasons
        parts += signals.filter(\.isPositive).map(\.label)

        if parts.isEmpty {
            return score >= 50
                ? "Contacts appear similar based on available data."
                : "Contacts appear to be different people."
        }
        return parts.joined(separator: "; ")
    }

    /// Cache key includes a content fingerprint of both contacts so that
    /// editing a contact invalidates any cached AI verdict for its pairs.
    /// Previously the key was ID-only, which could serve stale results if a
    /// contact was modified and re-scanned within the same app session.
    private func cacheKey(_ c1: UnifiedContact, _ c2: UnifiedContact) -> String {
        let f1 = fingerprint(c1), f2 = fingerprint(c2)
        return [f1, f2].sorted().joined(separator: ":")
    }

    /// Stable, cheap content fingerprint over the fields that influence
    /// matching. Hash collisions are acceptable (would only cause a cache
    /// hit with identical field content, which is exactly what we want).
    private func fingerprint(_ c: UnifiedContact) -> String {
        var hasher = Hasher()
        hasher.combine(c.id)
        hasher.combine(c.givenName)
        hasher.combine(c.familyName)
        hasher.combine(c.nickname)
        hasher.combine(c.organizationName)
        for e in c.emailAddresses { hasher.combine(e.value) }
        for p in c.phoneNumbers   { hasher.combine(p.value) }
        return String(hasher.finalize())
    }

    // (clearCache() is defined above near the cache declaration.)

    // MARK: - Nickname Dictionary

    /// Exhaustive given-name equivalence groups.
    /// Each array is a set of interchangeable names (full ↔ nicknames).
    static let nicknameGroups: [[String]] = [
        // Male
        ["robert", "bob", "rob", "robby", "bobby", "bert"],
        ["william", "will", "bill", "billy", "liam", "willy"],
        ["james", "jim", "jimmy", "jamie", "jay"],
        ["john", "johnny", "jon", "jack", "jacky"],
        ["charles", "charlie", "chuck", "chaz", "chas"],
        ["richard", "rick", "rich", "dick", "richie", "ric"],
        ["thomas", "tom", "tommy"],
        ["michael", "mike", "mikey", "mick", "mickey", "micky"],
        ["david", "dave", "davey", "davie"],
        ["joseph", "joe", "joey"],
        ["edward", "ed", "eddie", "ned", "ted", "teddy"],
        ["henry", "harry", "hal", "hank"],
        ["george", "georgie"],
        ["samuel", "sam", "sammy"],
        ["daniel", "dan", "danny"],
        ["matthew", "matt", "matty"],
        ["andrew", "andy", "drew"],
        ["christopher", "chris", "kit", "topher"],
        ["nicholas", "nick", "nicky", "nicolas", "nic"],
        ["benjamin", "ben", "benny", "benji"],
        ["anthony", "tony", "ant", "antonio"],
        ["stephen", "steve", "steven", "steph"],
        ["peter", "pete", "petey"],
        ["kenneth", "ken", "kenny"],
        ["donald", "don", "donnie"],
        ["mark", "marc", "marcus"],
        ["paul", "paulie"],
        ["timothy", "tim", "timmy"],
        ["joshua", "josh"],
        ["gregory", "greg", "gregg"],
        ["patrick", "pat", "paddy", "rick"],
        ["alexander", "alex", "al", "alec", "xander", "sasha"],
        ["jonathan", "jon", "johnathan", "jonny"],
        ["raymond", "ray", "raye"],
        ["frank", "franklin", "francis", "fran"],
        ["lawrence", "larry", "laurence", "lars"],
        ["ronald", "ron", "ronny", "ronnie"],
        ["gary", "garry"],
        ["gerald", "jerry", "gerard", "ger"],
        ["harold", "harry", "hal"],
        ["walter", "walt", "wally"],
        ["albert", "al", "albie", "bert"],
        ["fred", "freddy", "frederick", "alfred", "freddie"],
        ["eugene", "gene"],
        ["vincent", "vince", "vinny", "vin"],
        ["jeffrey", "jeff", "geoff"],
        ["arthur", "art", "arty"],
        ["raymond", "ray"],
        ["roger", "rodge"],
        ["stephen", "steve"],
        ["bruce", "brucey"],
        ["wayne", "way"],
        ["gabriel", "gabe"],
        ["jacob", "jake", "jakey"],
        ["ethan", "eth"],
        ["nathaniel", "nathan", "nate", "nat"],
        ["theodore", "theo", "ted", "teddy"],
        ["reginald", "reg", "reggie"],
        ["leonard", "len", "lenny", "leo"],
        ["clifford", "cliff"],
        ["sebastian", "seb", "baz"],
        ["bartholomew", "bart"],
        ["maximilian", "max", "maximillian"],
        ["dominic", "dom", "nick"],
        // Female
        ["elizabeth", "liz", "lizzie", "beth", "betty", "eliza", "ellie", "bess", "bessie", "libby", "lisa", "elspeth"],
        ["margaret", "maggie", "meg", "peggy", "peg", "margie", "marge", "rita"],
        ["katherine", "kate", "kathy", "katie", "kat", "katy", "kathryn", "catherine", "cathy", "cate"],
        ["jennifer", "jen", "jenny"],
        ["patricia", "pat", "patty", "tricia", "trish"],
        ["barbara", "barb", "barbie"],
        ["dorothy", "dot", "dottie"],
        ["helen", "nell", "nellie", "elena"],
        ["nancy", "nan"],
        ["carol", "carrie", "caroline", "carolina", "carole"],
        ["mary", "mae", "molly", "polly", "maria", "marie"],
        ["ann", "anne", "annie", "anna", "ana"],
        ["susan", "sue", "suzie", "susie", "suz"],
        ["linda", "lindy", "lin"],
        ["donna", "donnie"],
        ["laura", "laurie", "lori"],
        ["sarah", "sara", "sadie", "sally"],
        ["jessica", "jess", "jessie"],
        ["amanda", "mandy"],
        ["stephanie", "steph", "stevie"],
        ["ashley", "ash"],
        ["samantha", "sam", "sammy"],
        ["victoria", "vicky", "tori", "vickie", "vix"],
        ["deborah", "deb", "debbie"],
        ["diane", "di", "dee"],
        ["virginia", "ginny", "ginger"],
        ["angela", "angie", "angel"],
        ["melissa", "missy", "mel"],
        ["rebecca", "becca", "becky"],
        ["sandra", "sandy"],
        ["theresa", "terry", "tess", "teresa"],
        ["kristin", "kris", "kristine", "kristen"],
        ["wendy", "gwen", "gwendolyn"],
        ["rachel", "rach"],
        ["emily", "emma", "em", "emmy"],
        ["natalie", "nat", "natalia", "nathalie"],
        ["jacqueline", "jackie", "jacks"],
        ["charlotte", "charlie", "lottie", "charley"],
        ["grace", "gracie"],
        ["sophia", "sophie"],
        ["eleanor", "ellie", "nell", "nora", "leonora"],
        ["abigail", "abby", "gail", "abbey"],
        ["lillian", "lily", "lil", "lilly"],
        ["olivia", "liv", "livy"],
        ["cynthia", "cindy", "cyndy"],
        ["constance", "connie"],
        ["beverly", "bev"],
        ["rosemary", "rose", "rosie", "roz"],
        ["penelope", "penny", "pen"],
        ["veronica", "ronnie", "vera"],
        ["felicia", "fee"],
        ["josephine", "jo", "josie"],
        ["genevieve", "gen", "jenny"],
        ["winifred", "winnie", "freddie"],
        ["harriet", "hattie", "harriett"],
    ]

    /// Flat lookup: given-name string → index into nicknameGroups
    static let nicknameIndex: [String: Int] = {
        var idx: [String: Int] = [:]
        for (i, group) in nicknameGroups.enumerated() {
            for name in group { idx[name] = i }
        }
        return idx
    }()
}
