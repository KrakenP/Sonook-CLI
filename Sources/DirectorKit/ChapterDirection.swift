import AudioCore
import Foundation

public enum DirectorError: Error, LocalizedError, Sendable {
    case invalidChapter(String)
    case invalidAttribution(String)
    case incompleteCoverage(SourceCoverageReport)

    public var errorDescription: String? {
        switch self {
        case .invalidChapter(let message), .invalidAttribution(let message): return message
        case .incompleteCoverage(let report):
            return "Verbatim coverage failed (\(report.coverageRatio)), missing \(report.missingSpans), issues \(report.issues)"
        }
    }
}

public enum DirectorSegmenter: Sendable {
    public static func segmentChapter(
        chapter: ChapterRecord, normalizedDocumentUTF8: Data, maxCharacters: Int = 0
    ) throws -> (slice: ChapterSlice, units: [DirectedUnit]) {
        let span = chapter.sourceSpan
        guard maxCharacters >= 0, span.endExclusive <= normalizedDocumentUTF8.count else {
            throw DirectorError.invalidChapter("Invalid chapter span or character limit")
        }
        let base = normalizedDocumentUTF8.startIndex
        let bytes = normalizedDocumentUTF8[(base + span.start)..<(base + span.endExclusive)]
        let full = String(decoding: bytes, as: UTF8.self)
        guard [bytes.startIndex, bytes.endIndex].allSatisfy({
            $0 == normalizedDocumentUTF8.endIndex || normalizedDocumentUTF8[$0] & 0xC0 != 0x80
        }), full.utf8.elementsEqual(bytes) else {
            throw DirectorError.invalidChapter("Chapter does not contain scalar-aligned UTF-8")
        }
        var text = full
        if maxCharacters > 0, let limit = full.index(full.startIndex, offsetBy: maxCharacters - 1, limitedBy: full.endIndex),
           let newline = full[limit...].firstIndex(of: "\n") {
            text = String(full[...newline])
        }
        let slice = ChapterSlice(chapterID: chapter.chapterID, title: chapter.title,
                                 sourceDocumentRevision: chapter.sourceDocumentRevision,
                                 sourceSpan: try SourceSpan(start: span.start, endExclusive: span.start + text.utf8.count), text: text)
        var units = [DirectedUnit]()
        func append(_ part: Substring, dialogue: Bool) throws {
            let trimmed = part.trimmingPrefix(while: \.isWhitespace)
            guard let last = trimmed.lastIndex(where: { !$0.isWhitespace }) else { return }
            let source = trimmed[...last]
            let raw = String(source)
            let spoken = dialogue ? source.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines) : raw
            let start = span.start + text.utf8.distance(from: text.startIndex, to: source.startIndex)
            units.append(DirectedUnit(index: units.count,
                                      segmentID: chapter.chapterID + String(format: "_seg_%04ld", units.count + 1),
                                      chapterID: chapter.chapterID,
                                      span: try SourceSpan(start: start, endExclusive: start + source.utf8.count),
                                      sourceText: raw, spokenText: spoken.isEmpty ? raw : spoken, isQuotedDialogue: dialogue))
        }
        func narration(_ part: Substring) throws {
            guard part.count > 180 else { return try append(part, dialogue: false) }
            var start = part.startIndex
            var length = 0
            for i in part.indices {
                length += 1
                if length >= 40, "。！？\n".contains(part[i]) {
                    let end = part.index(after: i)
                    try append(part[start..<end], dialogue: false)
                    start = end
                    length = 0
                }
            }
            try append(part[start...], dialogue: false)
        }
        for line in text.split(separator: "\n") {
            var start = line.startIndex
            var cursor = start
            var missingCloser = Set<Character>()
            while cursor < line.endIndex {
                let opening = line[cursor]
                let next = line.index(after: cursor)
                if opening == "“" || opening == "「" {
                    let closer: Character = opening == "“" ? "”" : "」"
                    if !missingCloser.contains(closer) {
                        if let end = line[next...].firstIndex(of: closer) {
                            try narration(line[start..<cursor])
                            start = line.index(after: end)
                            try append(line[cursor..<start], dialogue: true)
                            cursor = start
                            continue
                        }
                        missingCloser.insert(closer)
                    }
                }
                cursor = next
            }
            try narration(line[start...])
        }
        return (slice, units)
    }
}

public enum ScriptDirector: Sendable {
    public static func buildScript(
        chapter: ChapterRecord, slice: ChapterSlice, units: [DirectedUnit],
        analysis: NarrativeAnalysisResult, scriptRevision: Int = 1
    ) throws -> (script: ScriptDocument, coverage: SourceCoverageReport) {
        guard slice.chapterID == chapter.chapterID, slice.sourceDocumentRevision == chapter.sourceDocumentRevision,
              slice.sourceSpan.start == chapter.sourceSpan.start, slice.sourceSpan.endExclusive <= chapter.sourceSpan.endExclusive,
              slice.text.utf8.count == slice.sourceSpan.endExclusive - slice.sourceSpan.start else {
            throw DirectorError.invalidChapter("Slice is inconsistent with the chapter source")
        }
        var byIndex = [Int: AttributedUnit]()
        for attribution in analysis.attributions {
            guard byIndex.updateValue(attribution, forKey: attribution.index) == nil else {
                throw DirectorError.invalidAttribution("Duplicate attribution at index \(attribution.index)")
            }
        }
        let segments = try units.map { unit in
            guard let attr = byIndex.removeValue(forKey: unit.index),
                  let card = analysis.catalog.resolveCharacter(namedOrAliased: attr.speakerID) else {
                throw DirectorError.invalidAttribution("Missing attribution or character for \(unit.segmentID)")
            }
            let stage = card.activeDeliveryStage(forChapter: chapter.chapterNumber)
            let voiceRevision = "\(card.characterID)_rev_\(card.revision)" + (stage.map { "_st_\($0.stageID)_r\($0.revision)" } ?? "")
            return ScriptSegment(segmentID: unit.segmentID, chapterID: unit.chapterID,
                                 sourceDocumentRevision: chapter.sourceDocumentRevision, sourceSpan: unit.span,
                                 sourceText: unit.sourceText, spokenText: unit.spokenText,
                                 speakerID: card.characterID, voiceProfileRevision: voiceRevision,
                                 direction: .init(emotion: attr.emotion, rate: stage?.speakingRate ?? 1.0,
                                                  pauseAfterMs: attr.pauseAfterMs, styleInstruction: attr.styleInstruction),
                                 scriptRevision: scriptRevision, status: attr.needsReviewReason == nil ? .pending : .needsReview,
                                 attributionConfidence: attr.confidence,
                                 attributionEvidence: attr.evidence + (attr.needsReviewReason.map { [$0] } ?? []))
        }
        guard byIndex.isEmpty else { throw DirectorError.invalidAttribution("Attribution refers to an unknown unit") }
        let script = ScriptDocument(chapterID: chapter.chapterID, sourceDocumentRevision: chapter.sourceDocumentRevision,
                                    scriptRevision: scriptRevision, segments: segments)
        let coverage = SourceCoverageValidator.validate(script, against: slice, verbatim: true)
        guard coverage.isValid else { throw DirectorError.incompleteCoverage(coverage) }
        return (script, coverage)
    }
}
