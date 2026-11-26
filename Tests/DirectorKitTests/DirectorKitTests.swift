import AudioCore
import DirectorKit
import Foundation
import Testing

private func chapter(_ number: Int, text: String, start: Int = 0) throws -> ChapterRecord {
    ChapterRecord(projectID: "p", chapterID: String(format: "ch_%03ld", number), chapterNumber: number,
                  title: "试读", sourceDocumentRevision: "doc",
                  sourceSpan: try SourceSpan(start: start, endExclusive: start + text.utf8.count))
}

private func analysis(_ units: [DirectedUnit], review: Int? = nil) -> NarrativeAnalysisResult {
    let stage = VoiceDeliveryStage(stageID: "grown", effectiveFromChapter: 2, revision: 3, stageLabel: "成年",
                                   deliveryBaseline: "平缓", speakingRate: 0.96)
    let catalog = CharacterVoiceCatalog(projectID: "p", cards: [
        .init(characterID: "n", canonicalName: "旁白"),
        .init(characterID: "hero", canonicalName: "小禾", deliveryStages: [stage], revision: 5)])
    let rows = units.map { unit in
        AttributedUnit(index: unit.index, speakerID: unit.isQuotedDialogue ? "hero" : "n", emotion: "calm",
                       styleInstruction: "轻声", pauseAfterMs: 330, confidence: unit.index == review ? 0.4 : 0.95,
                       evidence: ["上下文"], needsReviewReason: unit.index == review ? "low_confidence_attribution" : nil)
    }
    return .init(catalog: catalog, attributions: rows.reversed(), autoAttributedCount: rows.count - (review == nil ? 0 : 1),
                 needsReviewCount: review == nil ? 0 : 1)
}

@Test func unboundedChapterKeepsLongNarrationAndDialogueVerbatim() throws {
    let sentence = String(repeating: "林", count: 45) + "。"
    let text = String(repeating: sentence, count: 25) + "\n他问：“ 出发吗？ ”她答：「走。」\n“ ”\n尾声🪶"
    let record = try chapter(1, text: text)
    let (slice, units) = try DirectorSegmenter.segmentChapter(chapter: record, normalizedDocumentUTF8: Data(text.utf8), maxCharacters: 0)
    #expect(slice.text == text && slice.sourceSpan == record.sourceSpan)
    #expect(units.prefix(25).allSatisfy { $0.sourceText == sentence })
    #expect(units.filter(\.isQuotedDialogue).map(\.spokenText) == ["出发吗？","走。","“ ”"])
    #expect(units.last?.spokenText == "尾声🪶")
    let (script, coverage) = try ScriptDirector.buildScript(chapter: record, slice: slice, units: units, analysis: analysis(units), scriptRevision: 3)
    #expect(script.segments.count == units.count && script.segments.allSatisfy { $0.scriptRevision == 3 && $0.status == .pending })
    #expect(coverage.isValid && coverage.coverageRatio == 1)
    let (preview, _) = try DirectorSegmenter.segmentChapter(chapter: record, normalizedDocumentUTF8: Data(text.utf8), maxCharacters: 40)
    #expect(preview.text == String(repeating: sentence, count: 25) + "\n" && preview.sourceSpan.endExclusive == preview.text.utf8.count)
}

@Test func secondChapterHasBookAbsoluteIDsAndActiveDeliveryRevision() throws {
    let first = "“早。”\n"
    let second = "“ 走吧🛶。 ”\n靠岸。"
    let data = Data((first + second).utf8)
    var allIDs = Set<String>()
    for (number, text, offset) in [(1, first, 0), (2, second, first.utf8.count)] {
        let c = try chapter(number, text: text, start: offset)
        let (slice, units) = try DirectorSegmenter.segmentChapter(chapter: c, normalizedDocumentUTF8: data)
        #expect(units.first?.segmentID == (number == 1 ? "ch_001_seg_0001" : "ch_002_seg_0001"))
        for unit in units {
            #expect(allIDs.insert(unit.segmentID).inserted)
            #expect(unit.span.start >= offset && data[unit.span.start..<unit.span.endExclusive].elementsEqual(unit.sourceText.utf8))
        }
        let (script, coverage) = try ScriptDirector.buildScript(chapter: c, slice: slice, units: units, analysis: analysis(units, review: 0))
        let spoken = try #require(script.segments.first)
        #expect(coverage.isValid && coverage.coverageRatio == 1)
        #expect(spoken.status == .needsReview && spoken.attributionEvidence == ["上下文", "low_confidence_attribution"])
        #expect(spoken.voiceProfileRevision == (number == 1 ? "hero_rev_5" : "hero_rev_5_st_grown_r3"))
        #expect(spoken.direction.rate == (number == 1 ? 1.0 : 0.96))
    }
}

@Test func invalidBoundariesAndCoverageAreRejected() throws {
    let text = "字🪶\n灯亮了。"
    let data = Data(text.utf8)
    for span in [try SourceSpan(start: 1, endExclusive: 4), try SourceSpan(start: 1, endExclusive: 1),
                 try SourceSpan(start: 0, endExclusive: data.count + 1)] {
        let c = ChapterRecord(projectID: "p", chapterID: "c", chapterNumber: 1, title: "", sourceDocumentRevision: "d", sourceSpan: span)
        #expect(throws: DirectorError.self) { try DirectorSegmenter.segmentChapter(chapter: c, normalizedDocumentUTF8: data) }
    }
    let c = try chapter(1, text: text)
    let (slice, original) = try DirectorSegmenter.segmentChapter(chapter: c, normalizedDocumentUTF8: data)
    let incomplete = Array(original.dropLast())
    do {
        _ = try ScriptDirector.buildScript(chapter: c, slice: slice, units: incomplete, analysis: analysis(incomplete))
        Issue.record("Expected missing coverage")
    } catch DirectorError.incompleteCoverage(let report) { #expect(!report.missingSpans.isEmpty) }
}
