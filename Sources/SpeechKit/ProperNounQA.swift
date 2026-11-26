import AudioCore
import Foundation

// MARK: - Native Apple Tone-Preserving Pinyin

public enum TonePinyinConverter: Sendable {
    /// Returns true if every scalar in `text` is a CJK Unified Ideograph (Han character).
    public static func isAllHan(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isHan = (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x20000...0x2A6DF).contains(v)
                || (0x2A700...0x2B73F).contains(v)
                || (0x2B740...0x2B81F).contains(v)
                || (0x2B820...0x2CEAF).contains(v)
                || (0xF900...0xFAFF).contains(v)
            if !isHan { return false }
        }
        return true
    }

    /// Converts a pure Han string into normalized, NFC-precomposed, tone-marked lowercase Mandarin Pinyin
    /// using Apple's native ICU transform (`.mandarinToLatin`, zero external dependencies).
    /// Example: `"林清"` -> `"lín qīng"`, `"临青"` -> `"lín qīng"`, `"林晴"` -> `"lín qíng"`.
    public static func tonePinyin(of text: String) -> String? {
        guard isAllHan(text) else { return nil }
        guard let raw = text.applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        let normalized = raw
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    /// Strict exact-tone homophone check: requires equal character length, all Han characters,
    /// and byte-identical NFC tone-marked Pinyin (tone mismatches like `lín qíng` vs `lín qīng` return false).
    public static func isExactToneHomophone(_ reference: String, _ hypothesis: String) -> Bool {
        guard reference.count == hypothesis.count, !reference.isEmpty else { return false }
        guard let refPinyin = tonePinyin(of: reference),
              let hypPinyin = tonePinyin(of: hypothesis) else {
            return false
        }
        return refPinyin == hypPinyin
    }
}

// MARK: - Proper-Noun Tone-Aware ASR Verifier

public struct ProperNounVerificationOutcome: Equatable, Sendable {
    public let verdict: QualityVerdict
    public let rawCERReport: CERReport
    public let audit: SegmentQualityAudit

    public init(verdict: QualityVerdict, rawCERReport: CERReport, audit: SegmentQualityAudit) {
        self.verdict = verdict
        self.rawCERReport = rawCERReport
        self.audit = audit
    }
}

public enum ProperNounAwareASRVerifier: Sendable {
    private enum AlignOp {
        case match(refIdx: Int, hypIdx: Int)
        case replace(refIdx: Int, hypIdx: Int)
        case delete(refIdx: Int)
        case insert(hypIdx: Int)
    }

    private struct ProperNounEntry {
        let characterID: String
        let normalizedName: String
        let chars: [Character]
    }

    /// Evaluates dry-speech ASR quality with strict proper-noun exact-tone homophone exemption.
    ///
    /// Hard invariants:
    /// 1. Audio integrity defects (truncated/silent/clipping/internal silence) NEVER get exempted.
    /// 2. Omissions (deletions), insertions, and repetitions NEVER get exempted.
    /// 3. Only 1-to-1 substitutions strictly inside a >=2-char Han canonical name or unique alias from `catalog`
    ///    whose tone-marked Mandarin Pinyin matches 100% are exempted, and every exemption is logged in `audit.exemptions`.
    /// 4. Non-name substitutions and wrong-tone substitutions (e.g. `lín qíng` vs `lín qīng`) are NEVER exempted.
    public static func evaluate(
        segmentID: String,
        wavAssetID: String,
        referenceText: String,
        hypothesisTranscript: String,
        integrity: AudioIntegrityReport,
        catalog: CharacterVoiceCatalog?,
        thresholds: QualityThresholds = QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10),
        normalizeNumerals: Bool = true,
        expectedPitchHz: Double? = nil,
        candidatePitchHz: Double? = nil,
        maxPitchDriftSemitones: Double = 3.5
    ) -> ProperNounVerificationOutcome {
        let rawReport = ChineseCERCalculator.calculate(
            reference: referenceText,
            hypothesis: hypothesisTranscript,
            normalizeNumerals: normalizeNumerals
        )

        let refChars = Array(rawReport.normalizedReference)
        let hypChars = Array(rawReport.normalizedHypothesis)
        let ops = alignDetailed(ref: refChars, hyp: hypChars)

        // Build whitelist of >=2-char Han proper nouns from catalog (excluding narrator and ambiguous aliases).
        let properNouns = extractProperNouns(from: catalog, normalizeNumerals: normalizeNumerals)

        // Index alignment positions per reference character.
        // For a reference span [start..<end) to be cleanly 1-to-1 aligned with hyp:
        // - Every ref index i in start..<end must map to either .match or .replace (no .delete)
        // - No .insert ops may occur strictly between ref[start] and ref[end-1]
        var refToOpIdx = Array(repeating: -1, count: refChars.count)
        for (opIdx, op) in ops.enumerated() {
            switch op {
            case .match(let r, _), .replace(let r, _), .delete(let r):
                refToOpIdx[r] = opIdx
            case .insert:
                break
            }
        }

        // Find non-overlapping proper noun spans in normalizedReference (longest match first).
        var coveredRefIndices = Set<Int>()
        var exemptedSubstitutions = 0
        var exemptions: [ProperNounExemption] = []

        if !properNouns.isEmpty && !refChars.isEmpty {
            var pos = 0
            while pos < refChars.count {
                var matchedEntry: ProperNounEntry?
                for entry in properNouns {
                    let end = pos + entry.chars.count
                    guard end <= refChars.count else { continue }
                    if refChars[pos..<end].elementsEqual(entry.chars) {
                        matchedEntry = entry
                        break
                    }
                }

                guard let entry = matchedEntry else {
                    pos += 1
                    continue
                }

                let start = pos
                let end = pos + entry.chars.count
                let firstOpIdx = refToOpIdx[start]
                let lastOpIdx = refToOpIdx[end - 1]

                // Verify strict 1-to-1 alignment with zero internal deletions or insertions
                if firstOpIdx >= 0, lastOpIdx >= firstOpIdx, (lastOpIdx - firstOpIdx + 1) == entry.chars.count {
                    var hypSliceChars: [Character] = []
                    var substCountInSpan = 0
                    var strictOneToOne = true

                    for opIdx in firstOpIdx...lastOpIdx {
                        switch ops[opIdx] {
                        case .match(_, let h):
                            hypSliceChars.append(hypChars[h])
                        case .replace(_, let h):
                            hypSliceChars.append(hypChars[h])
                            substCountInSpan += 1
                        case .delete, .insert:
                            strictOneToOne = false
                        }
                    }

                    if strictOneToOne && substCountInSpan > 0 {
                        let refSlice = String(refChars[start..<end])
                        let hypSlice = String(hypSliceChars)
                        if TonePinyinConverter.isExactToneHomophone(refSlice, hypSlice),
                           let pinyin = TonePinyinConverter.tonePinyin(of: refSlice) {
                            exemptedSubstitutions += substCountInSpan
                            for i in start..<end { coveredRefIndices.insert(i) }
                            exemptions.append(ProperNounExemption(
                                characterID: entry.characterID,
                                referenceText: refSlice,
                                hypothesisText: hypSlice,
                                tonePinyin: pinyin,
                                charStart: start,
                                charEndExclusive: end,
                                ruleVersion: SpeechKitInfo.pinyinExemptionRuleVersion
                            ))
                        }
                    }
                }
                pos = end
            }
        }

        let nonExemptSubstitutions = max(0, rawReport.substitutions - exemptedSubstitutions)
        let adjustedEditCount = nonExemptSubstitutions + rawReport.deletions + rawReport.insertions
        let adjustedCER = Double(adjustedEditCount) / Double(max(refChars.count, 1))

        // Evaluate verdict: audio integrity defects first, then adjusted CER + unexempted omission/repetition.
        var integrityReasons: [QualityReason] = []
        if integrity.isTruncated { integrityReasons.append(.truncated) }
        if integrity.isSilent { integrityReasons.append(.silent) }
        if integrity.clippingSampleCount > thresholds.maxClippingSampleCount { integrityReasons.append(.clipping) }
        if integrity.maxInternalSilenceSeconds > thresholds.maxInternalSilenceSeconds { integrityReasons.append(.internalSilence) }

        let verdict: QualityVerdict
        let verdictLabel: String
        let failureReasons: [String]

        if !integrityReasons.isEmpty {
            verdict = .retryableFailure(integrityReasons)
            verdictLabel = "retryable_failure"
            failureReasons = integrityReasons.map(\.rawValue)
        } else {
            var textReasons: [QualityReason] = []
            if adjustedCER > thresholds.maxCER { textReasons.append(.highCER) }
            if rawReport.suspectedOmission { textReasons.append(.suspectedOmission) }
            if rawReport.suspectedRepetition { textReasons.append(.suspectedRepetition) }
            if let refF0 = expectedPitchHz, let candF0 = candidatePitchHz, refF0 > 0, candF0 > 0 {
                let drift = abs(AudioIntegrityChecker.pitchDriftSemitones(referenceHz: refF0, candidateHz: candF0))
                if drift > maxPitchDriftSemitones {
                    textReasons.append(.pitchDrift)
                }
            }

            if textReasons.isEmpty {
                verdict = .passed
                verdictLabel = "passed"
                failureReasons = []
            } else {
                verdict = .needsReview(textReasons)
                verdictLabel = "needs_review"
                failureReasons = textReasons.map(\.rawValue)
            }
        }

        let audit = SegmentQualityAudit(
            segmentID: segmentID,
            wavAssetID: wavAssetID,
            rawTranscript: hypothesisTranscript,
            rawCER: rawReport.cer,
            adjustedCER: adjustedCER,
            exemptions: exemptions,
            nonExemptSubstitutions: nonExemptSubstitutions,
            deletions: rawReport.deletions,
            insertions: rawReport.insertions,
            rmsDBFS: integrity.rmsDBFS.isFinite ? integrity.rmsDBFS : -120.0,
            verdictLabel: verdictLabel,
            failureReasons: failureReasons,
            ruleVersion: SpeechKitInfo.qaRuleVersion
        )

        return ProperNounVerificationOutcome(verdict: verdict, rawCERReport: rawReport, audit: audit)
    }

    private static func extractProperNouns(
        from catalog: CharacterVoiceCatalog?,
        normalizeNumerals: Bool
    ) -> [ProperNounEntry] {
        guard let catalog else { return [] }
        // Track which character IDs claim each normalized name; drop names shared across multiple distinct characters.
        var nameToCharacterIDs: [String: Set<String>] = [:]
        for card in catalog.cards {
            if card.characterID == "char_narrator" || card.canonicalName == "旁白" {
                continue
            }
            let candidates = [card.canonicalName] + card.aliases
            for raw in candidates {
                let norm = ChineseCERCalculator.normalize(raw, normalizeNumerals: normalizeNumerals)
                guard norm.count >= 2, TonePinyinConverter.isAllHan(norm) else { continue }
                nameToCharacterIDs[norm, default: []].insert(card.characterID)
            }
        }

        var entries: [ProperNounEntry] = []
        for (name, charIDs) in nameToCharacterIDs where charIDs.count == 1 {
            if let cid = charIDs.first {
                entries.append(ProperNounEntry(characterID: cid, normalizedName: name, chars: Array(name)))
            }
        }
        // Longest match first, deterministic tie-breaker by characterID then name.
        return entries.sorted { lhs, rhs in
            if lhs.chars.count != rhs.chars.count {
                return lhs.chars.count > rhs.chars.count
            }
            if lhs.characterID != rhs.characterID {
                return lhs.characterID < rhs.characterID
            }
            return lhs.normalizedName < rhs.normalizedName
        }
    }

    /// Exact character-level Levenshtein alignment (segments are short, typically <=250 chars).
    /// Deterministic tie-breaking: match/replace before delete before insert.
    private static func alignDetailed(ref: [Character], hyp: [Character]) -> [AlignOp] {
        let n = ref.count
        let m = hyp.count
        if n == 0 {
            return (0..<m).map { .insert(hypIdx: $0) }
        }
        if m == 0 {
            return (0..<n).map { .delete(refIdx: $0) }
        }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let subCost = dp[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                let delCost = dp[i - 1][j] + 1
                let insCost = dp[i][j - 1] + 1
                dp[i][j] = min(subCost, delCost, insCost)
            }
        }

        var ops: [AlignOp] = []
        ops.reserveCapacity(max(n, m))
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let isMatch = (ref[i - 1] == hyp[j - 1])
                let diag = dp[i - 1][j - 1] + (isMatch ? 0 : 1)
                if dp[i][j] == diag {
                    ops.append(isMatch ? .match(refIdx: i - 1, hypIdx: j - 1) : .replace(refIdx: i - 1, hypIdx: j - 1))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                ops.append(.delete(refIdx: i - 1))
                i -= 1
            } else {
                ops.append(.insert(hypIdx: j - 1))
                j -= 1
            }
        }
        return ops.reversed()
    }
}
