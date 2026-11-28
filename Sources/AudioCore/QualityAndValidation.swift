import Foundation

public enum SourceCoverageIssue: Equatable, Sendable {
    case documentMismatch
    case segmentRevisionMismatch(String)
    case invalidSpan(String)
    case sourceTextMismatch(String)
    case unauthorizedRewrite(String)
    case outOfOrder(String)
    case duplicateSegmentID(String)
}

public struct SourceCoverageReport: Equatable, Sendable {
    /// Fraction of non-whitespace source bytes covered by at least one structurally valid span.
    public let coverageRatio: Double
    public let missingSpans: [SourceSpan]
    public let overlappingSpans: [SourceSpan]
    public let issues: [SourceCoverageIssue]
    public var isValid: Bool { missingSpans.isEmpty && overlappingSpans.isEmpty && issues.isEmpty }
}

public enum SourceCoverageValidator: Sendable {
    public static func validate(_ script: ScriptDocument, against chapter: ChapterSlice,
                                verbatim: Bool = true) -> SourceCoverageReport {
        let bytes = Array(chapter.text.utf8)
        let base = chapter.sourceSpan.start
        var events: [Int: Int] = [:]
        var issues: [SourceCoverageIssue] = []
        if script.chapterID != chapter.chapterID || script.sourceDocumentRevision != chapter.sourceDocumentRevision {
            issues.append(.documentMismatch)
        }
        var previousStart = base
        var ids: Set<String> = []
        for segment in script.segments {
            let id = segment.segmentID
            if !ids.insert(id).inserted { issues.append(.duplicateSegmentID(id)) }
            if segment.chapterID != script.chapterID || segment.sourceDocumentRevision != script.sourceDocumentRevision
                || segment.scriptRevision != script.scriptRevision {
                issues.append(.segmentRevisionMismatch(id))
            }
            let span = segment.sourceSpan
            guard span.start >= base, span.endExclusive <= chapter.sourceSpan.endExclusive, span.start < span.endExclusive else {
                issues.append(.invalidSpan(id))
                continue
            }
            let lo = span.start - base
            let hi = span.endExclusive - base
            guard bytes[lo] & 0xC0 != 0x80, hi == bytes.count || bytes[hi] & 0xC0 != 0x80 else {
                issues.append(.invalidSpan(id))
                continue
            }
            if span.start < previousStart { issues.append(.outOfOrder(id)) }
            previousStart = span.start
            events[lo, default: 0] += 1
            events[hi, default: 0] -= 1
            if !bytes[lo..<hi].elementsEqual(segment.sourceText.utf8) {
                issues.append(.sourceTextMismatch(id))
            }
            if verbatim, segment.normalizationNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               ChineseCERCalculator.normalize(segment.sourceText) != ChineseCERCalculator.normalize(segment.spokenText) {
                issues.append(.unauthorizedRewrite(id))
            }
        }

        var missing: [SourceSpan] = []
        var overlapping: [SourceSpan] = []
        var total = 0
        var covered = 0
        var offset = 0
        var depth = 0
        var missingStart: Int?
        var overlapStart: Int?
        func updateRun(_ active: Bool, start: inout Int?, spans: inout [SourceSpan]) {
            if active {
                if start == nil { start = offset }
            } else if let begin = start {
                // Offsets are accumulated from whole scalars inside the chapter.
                spans.append(try! SourceSpan(start: base + begin, endExclusive: base + offset))
                start = nil
            }
        }
        for scalar in chapter.text.unicodeScalars {
            depth += events[offset] ?? 0
            let required = !scalar.properties.isWhitespace
            let length = scalar.utf8.count
            if required {
                total += length
                if depth > 0 { covered += length }
            }
            updateRun(required && depth == 0, start: &missingStart, spans: &missing)
            updateRun(depth > 1, start: &overlapStart, spans: &overlapping)
            offset += length
        }
        updateRun(false, start: &missingStart, spans: &missing)
        updateRun(false, start: &overlapStart, spans: &overlapping)
        return .init(coverageRatio: total == 0 ? 1 : Double(covered) / Double(total),
                     missingSpans: missing, overlappingSpans: overlapping, issues: issues)
    }
}

public struct CERReport: Equatable, Sendable {
    public let cer: Double
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceLength: Int
    public let suspectedOmission: Bool
    public let suspectedRepetition: Bool
    public let normalizedReference: String
    public let normalizedHypothesis: String
}

public enum ChineseCERCalculator: Sendable {
    /// Fold full-width ASCII, lowercase ASCII A-Z, then discard Unicode punctuation and whitespace.
    /// Optional numeral readings use Mandarin cardinal groups through 兆, and digit readings for
    /// years, leading zeros, fractions and longer identifiers. These rules never modify source bytes.
    public static func normalize(_ text: String, normalizeNumerals: Bool = false) -> String {
        var folded = ""
        for scalar in text.unicodeScalars {
            var n = scalar.value
            if (0xFF01...0xFF5E).contains(n) { n -= 0xFEE0 }
            if (65...90).contains(n) { n += 32 }
            folded.unicodeScalars.append(Unicode.Scalar(n)!)
        }
        if normalizeNumerals {
            folded = folded.replacing(/([0-9]+)(?:\.([0-9]+))?/) { match in
                let year = folded[match.range.upperBound...].hasPrefix("年")
                let whole = reading(match.output.1, digitByDigit: year)
                return whole + (match.output.2.map { "点" + reading($0, digitByDigit: true) } ?? "")
            }
        }
        return String(folded.unicodeScalars.filter {
            !$0.properties.isWhitespace
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }

    private static func reading(_ digits: Substring, digitByDigit: Bool) -> String {
        let names = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let values = digits.utf8.map { Int($0 - 48) }
        if digitByDigit || values.first == 0 || values.count > 16 {
            return values.map { names[$0] }.joined()
        }
        let places = ["", "十", "百", "千"]
        let groups = ["", "万", "亿", "兆"]
        var result = ""
        var start = 0
        var skippedGroup = false
        while start < values.count {
            let group = (values.count - start - 1) / 4
            let end = values.count - group * 4
            let part = values[start..<end]
            if part.contains(where: { $0 != 0 }) {
                if !result.isEmpty && (skippedGroup || part.first == 0) { result += "零" }
                var pendingZero = false
                var started = false
                for index in part.indices {
                    let digit = part[index]
                    if digit == 0 {
                        pendingZero = started
                        continue
                    }
                    if pendingZero { result += "零" }
                    let place = end - index - 1
                    if !(result.isEmpty && digit == 1 && place == 1) { result += names[digit] }
                    result += places[place]
                    started = true
                    pendingZero = false
                }
                result += groups[group]
                skippedGroup = false
            } else {
                skippedGroup = true
            }
            start = end
        }
        return result
    }

    public static func calculate(reference: String, hypothesis: String, normalizeNumerals: Bool = false) -> CERReport {
        let normalizedRef = normalize(reference, normalizeNumerals: normalizeNumerals)
        let normalizedHyp = normalize(hypothesis, normalizeNumerals: normalizeNumerals)
        let ref = Array(normalizedRef)
        let hyp = Array(normalizedHyp)
        var prefix = 0
        while prefix < min(ref.count, hyp.count) && ref[prefix] == hyp[prefix] { prefix += 1 }
        var refEnd = ref.count
        var hypEnd = hyp.count
        while refEnd > prefix && hypEnd > prefix && ref[refEnd - 1] == hyp[hypEnd - 1] { refEnd -= 1; hypEnd -= 1 }

        var edits: [Edit] = []
        align(ref[prefix..<refEnd], hyp[prefix..<hypEnd], into: &edits)
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var repetition = false
        var position = prefix
        var inserted = 0
        func repeatedRun() -> Bool {
            guard inserted > 0 else { return false }
            let start = position - inserted
            let run = hyp[start..<position]
            func adjacentCopy(length: Int) -> Bool {
                let unit = run.prefix(length)
                return (start >= length && hyp[(start - length)..<start].elementsEqual(unit))
                    || (hyp.count - position >= length && hyp[position..<(position + length)].elementsEqual(unit))
            }
            if adjacentCopy(length: inserted) { return true }
            // More than one extra copy can be longer than the original utterance.
            // The prefix function finds the shortest repeating unit in linear time.
            var prefixLengths = Array(repeating: 0, count: inserted)
            for i in 1..<inserted {
                var length = prefixLengths[i - 1]
                while length > 0 && run[start + i] != run[start + length] { length = prefixLengths[length - 1] }
                if run[start + i] == run[start + length] { length += 1 }
                prefixLengths[i] = length
            }
            let period = inserted - prefixLengths[inserted - 1]
            return period < inserted && inserted.isMultiple(of: period) && adjacentCopy(length: period)
        }
        for edit in edits {
            if edit == .insert {
                inserted += 1
                insertions += 1
                position += 1
                continue
            }
            repetition = repetition || repeatedRun()
            inserted = 0
            switch edit {
            case .delete: deletions += 1
            case .replace: substitutions += 1; position += 1
            case .match: position += 1
            case .insert: break
            }
        }
        return .init(cer: Double(substitutions + deletions + insertions) / Double(max(ref.count, 1)),
                     substitutions: substitutions, deletions: deletions, insertions: insertions, referenceLength: ref.count,
                     suspectedOmission: deletions > 0, suspectedRepetition: repetition || repeatedRun(),
                     normalizedReference: normalizedRef, normalizedHypothesis: normalizedHyp)
    }

    private enum Edit { case match, replace, insert, delete }

    // Hirschberg alignment recovers edit counts and insertion locations without a quadratic traceback table.
    private static func align(_ ref: ArraySlice<Character>, _ hyp: ArraySlice<Character>, into edits: inout [Edit]) {
        if ref.isEmpty || hyp.isEmpty {
            edits += repeatElement(ref.isEmpty ? .insert : .delete, count: max(ref.count, hyp.count))
        } else if ref.count == 1 {
            let match = hyp.firstIndex(of: ref[ref.startIndex])
            let anchor = match ?? hyp.startIndex
            edits += repeatElement(.insert, count: anchor - hyp.startIndex)
            edits.append(match == nil ? .replace : .match)
            edits += repeatElement(.insert, count: hyp.endIndex - anchor - 1)
        } else {
            let mid = ref.startIndex + ref.count / 2
            let split = splitIndex(left: ref[..<mid], right: ref[mid...], hyp: hyp)
            align(ref[..<mid], hyp[..<split], into: &edits)
            align(ref[mid...], hyp[split...], into: &edits)
        }
    }

    private static func splitIndex(left: ArraySlice<Character>, right: ArraySlice<Character>,
                                   hyp: ArraySlice<Character>) -> Int {
        let front = distances(left, hyp)
        let back = distances(right.reversed(), hyp.reversed())
        var split = 0
        for i in front.indices where front[i] + back[hyp.count - i] < front[split] + back[hyp.count - split] {
            split = i
        }
        return hyp.startIndex + split
    }

    private static func distances<R: Collection, H: Collection>(_ ref: R, _ hyp: H) -> [Int]
        where R.Element == Character, H.Element == Character {
        var row = Array(0...hyp.count)
        for r in ref {
            var diagonal = row[0]
            row[0] += 1
            for (j, h) in hyp.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(diagonal + (r == h ? 0 : 1), above + 1, row[j] + 1)
                diagonal = above
            }
        }
        return row
    }
}

public struct AudioIntegrityReport: Equatable, Sendable {
    public let durationSeconds: Double
    public let rmsDBFS: Double
    public let peakDBFS: Double
    public let leadingSilenceSeconds: Double
    public let trailingSilenceSeconds: Double
    public let maxInternalSilenceSeconds: Double
    public let clippingSampleCount: Int
    public let isSilent: Bool
    public let isTruncated: Bool
}

public enum AudioIntegrityChecker: Sendable {
    /// Mono PCM, full scale 1. Silence uses an amplitude threshold of 0.001 (-60 dBFS).
    /// A known expected frame count can detect a short buffer even if it ends at a zero crossing.
    public static func analyze(pcmSamples: [Float], sampleRate: Int, expectedFrameCount: Int? = nil) -> AudioIntegrityReport {
        var sumSquares = 0.0
        var peak = 0.0
        var clipped = 0
        var leading = 0
        var run = 0
        var internalMax = 0
        var heard = false
        var damaged = sampleRate <= 0 || pcmSamples.isEmpty || pcmSamples.count < (expectedFrameCount ?? 0)
        for sample in pcmSamples {
            guard sample.isFinite else { damaged = true; continue }
            let magnitude = abs(Double(sample))
            sumSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= 1 { clipped += 1 }
            if magnitude <= 0.001 {
                run += 1
            } else {
                if heard { internalMax = max(internalMax, run) } else { leading = run }
                run = 0
                heard = true
            }
        }
        func seconds(_ count: Int) -> Double { sampleRate > 0 ? Double(count) / Double(sampleRate) : 0 }
        let meanSquare = sumSquares / Double(max(1, pcmSamples.count))
        return .init(durationSeconds: seconds(pcmSamples.count), rmsDBFS: 10 * log10(meanSquare), peakDBFS: 20 * log10(peak),
                     leadingSilenceSeconds: seconds(heard ? leading : run), trailingSilenceSeconds: seconds(run),
                     maxInternalSilenceSeconds: seconds(internalMax), clippingSampleCount: clipped,
                     isSilent: !heard, isTruncated: damaged)
    }

    /// Estimates median voiced fundamental frequency (F0, in Hz) using fast decimated autocorrelation
    /// across 40 ms windows (70–320 Hz speech band). Returns `nil` when audio is unvoiced or too short.
    public static func estimateMedianPitchHz(pcmSamples: [Float], sampleRate: Int) -> Double? {
        guard sampleRate >= 8_000, pcmSamples.count >= sampleRate / 10 else { return nil }
        let decimation = max(1, sampleRate / 12_000)
        let dsr = Double(sampleRate) / Double(decimation)
        let win = max(64, Int(0.04 * dsr))
        let minLag = max(1, Int(dsr / 320.0))
        let maxLag = max(minLag + 1, Int(dsr / 70.0))
        var decimated: [Float] = []
        decimated.reserveCapacity(pcmSamples.count / decimation + 1)
        var idx = 0
        while idx < pcmSamples.count {
            decimated.append(pcmSamples[idx])
            idx += decimation
        }
        guard decimated.count > win + maxLag else { return nil }

        var f0s: [Double] = []
        var start = 0
        while start + win + maxLag < decimated.count {
            var energy = 0.0
            for i in 0..<win {
                let v = Double(decimated[start + i])
                energy += v * v
            }
            if energy >= 0.0004 * Double(win) {
                var bestCorr = 0.0
                var bestLag = 0
                for lag in minLag..<maxLag {
                    var sum = 0.0
                    for i in 0..<win {
                        sum += Double(decimated[start + i]) * Double(decimated[start + i + lag])
                    }
                    if sum > bestCorr {
                        bestCorr = sum
                        bestLag = lag
                    }
                }
                if bestLag > 0 && bestCorr / (energy + 1e-9) > 0.45 {
                    f0s.append(dsr / Double(bestLag))
                }
            }
            start += win
        }
        guard f0s.count >= 3 else { return nil }
        f0s.sort()
        return f0s[f0s.count / 2]
    }

    /// Signed pitch shift in semitones between a reference anchor F0 and a synthesized segment F0.
    public static func pitchDriftSemitones(referenceHz: Double, candidateHz: Double) -> Double {
        guard referenceHz > 0, candidateHz > 0 else { return 0 }
        return 12.0 * log2(candidateHz / referenceHz)
    }
}

public struct QualityThresholds: Codable, Equatable, Sendable {
    public var maxCER: Double
    public var maxInternalSilenceSeconds: Double
    public var maxClippingSampleCount: Int

    public init(maxCER: Double = 0.02, maxInternalSilenceSeconds: Double = 2, maxClippingSampleCount: Int = 0) {
        self.maxCER = maxCER
        self.maxInternalSilenceSeconds = maxInternalSilenceSeconds
        self.maxClippingSampleCount = maxClippingSampleCount
    }
}

public enum QualityReason: String, Codable, Equatable, Sendable {
    case truncated, silent, clipping, internalSilence, highCER, suspectedOmission, suspectedRepetition, pitchDrift
}

public enum QualityVerdict: Equatable, Sendable {
    case passed
    case retryableFailure([QualityReason])
    case needsReview([QualityReason])
}

public enum QualityEvaluator: Sendable {
    /// Repair defective audio first; ASR disagreement on otherwise usable audio goes to a listener.
    public static func evaluate(cer: CERReport, integrity: AudioIntegrityReport,
                                thresholds: QualityThresholds = .init()) -> QualityVerdict {
        var reasons: [QualityReason] = []
        if integrity.isTruncated { reasons.append(.truncated) }
        if integrity.isSilent { reasons.append(.silent) }
        if integrity.clippingSampleCount > thresholds.maxClippingSampleCount { reasons.append(.clipping) }
        if integrity.maxInternalSilenceSeconds > thresholds.maxInternalSilenceSeconds { reasons.append(.internalSilence) }
        if !reasons.isEmpty { return .retryableFailure(reasons) }
        if cer.cer > thresholds.maxCER { reasons.append(.highCER) }
        if cer.suspectedOmission { reasons.append(.suspectedOmission) }
        if cer.suspectedRepetition { reasons.append(.suspectedRepetition) }
        return reasons.isEmpty ? .passed : .needsReview(reasons)
    }
}
