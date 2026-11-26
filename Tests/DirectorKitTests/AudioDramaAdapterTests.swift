import AudioCore
import DirectorKit
import Foundation
import Testing

private func authorization(_ authorized: Bool = true, mode: ProductionMode = .audioDramaAdapted,
                           compression: Bool = true, injection: Bool = true) -> AdaptationAuthorization {
    AdaptationAuthorization(authorizedByUser: authorized, mode: mode, allowNarrationCompression: compression,
                            allowSFXInjection: injection, auditNote: "test", authorizedAtISO8601: "2026-01-01T00:00:00Z")
}

private func dramaFixture() throws -> (String, ChapterSlice, ScriptDocument, ChapterSoundscapePlan) {
    let prefix = "前章🌲\n"
    let text = """
        轰隆隆……
        “ 啪嗒…… ”
        「是你吗🪶？」
        他想起那年惊雷夺去了他的马。
        啪，啪，啪……
        锅盖哐当作响。
        啪嗒……
        """
    let chapter = ChapterRecord(projectID: "p", chapterID: "ch_2", chapterNumber: 2, title: "山中",
                                sourceDocumentRevision: "revision", sourceSpan: try SourceSpan(start: prefix.utf8.count,
                                                                                             endExclusive: (prefix + text).utf8.count))
    let (slice, units) = try DirectorSegmenter.segmentChapter(chapter: chapter, normalizedDocumentUTF8: Data((prefix + text).utf8))
    let catalog = CharacterVoiceCatalog(projectID: "p", cards: [.init(characterID: "char_narrator", canonicalName: "旁白"),
                                                               .init(characterID: "a", canonicalName: "小禾")])
    let analysis = NarrativeAnalysisResult(catalog: catalog, attributions: units.map {
        // The quoted sound in segment 1 is unresolved dialogue, assigned provisionally to the narrator.
        AttributedUnit(index: $0.index, speakerID: $0.index == 2 ? "a" : "char_narrator", emotion: "calm",
                       styleInstruction: "克制", pauseAfterMs: 360, confidence: 0.9, evidence: ["text"],
                       needsReviewReason: $0.index == 1 ? "unresolved_dialogue_speaker" : nil)
    }, autoAttributedCount: units.count - 1, needsReviewCount: 1)
    var (script, _) = try ScriptDirector.buildScript(chapter: chapter, slice: slice, units: units, analysis: analysis, scriptRevision: 4)
    for i in script.segments.indices {
        script.segments[i].audioArtifactID = "wav-\(i)"
        if script.segments[i].status != .needsReview { script.segments[i].status = .verified }
    }
    let plan = ChapterSoundscapePlan(chapterID: chapter.chapterID, scriptRevision: 4,
                                     sceneCues: [.init(cueID: "scene", chapterID: "ch_2", startSegmentID: units[0].segmentID,
                                                       endSegmentID: units[6].segmentID, sceneTag: "storm", preset: .stormThunder)],
                                     sfxCues: [.init(cueID: "existing", chapterID: "ch_2", anchorSegmentID: units[0].segmentID,
                                                     soundPrompt: "thunderclap", evidenceExcerpt: "轰隆隆", resolvedAssetID: "asset")],
                                     provenance: "lexical", createdAtISO8601: "2026-01-01T00:00:00Z")
    return (prefix + text, slice, script, plan)
}

private actor FakeDramaProvider: LLMProvider {
    let capabilities = LLMCapabilities(parameters: ["temperature": .anyValue, "seed": .anyValue])
    let isLoaded = true
    private(set) var calls = 0
    func load() {}
    func unload() {}
    func generateAccepted(prompt: String, parameters: AcceptedParameters) -> LLMResponse {
        calls += 1
        return .init(text: """
            <think>{"guess":"x"}</think>
            ```json
            {"directions":[{"segment_id":"ch_2_seg_0003","delivery":"hushed","spoken_text":"伪造台词","speaker_id":"b"},
                           {"segment_id":"ch_2_seg_0004","delivery":"urgent"},{"segment_id":"unknown","delivery":"reply"}]}
            ```
            """, metrics: .init(providerID: "fake", modelID: "test", modelRevision: "1", inferenceDurationMs: 0))
    }
}

@Test func audioDramaAuthorizationIsCheckedBeforeAnyOtherWork() async throws {
    var (_, _, script, plan) = try dramaFixture()
    let fake = FakeDramaProvider()
    for auth in [authorization(false), authorization(mode: .audiobookVerbatim), authorization(mode: .privatePodcast)] {
        await #expect(throws: AudioDramaAdapterError.adaptationNotAuthorized) {
            try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: auth, llm: fake)
        }
    }
    script.segments = []
    await #expect(throws: AudioDramaAdapterError.adaptationNotAuthorized) {
        try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: authorization(false), llm: fake)
    }
    await #expect(throws: AudioDramaAdapterError.emptyScript) {
        try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: authorization(), llm: fake)
    }
    #expect(await fake.calls == 0)
}

@Test func compressedDramaRetainsExactSourceCoverageDialogueAndTimeline() async throws {
    let (fullText, slice, script, plan) = try dramaFixture()
    let drama = try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: authorization())
    let adapted = drama.asScriptDocument()
    #expect(adapted.segments.map(\.segmentID) == script.segments.map(\.segmentID))
    #expect(adapted.segments.map(\.speakerID) == script.segments.map(\.speakerID))
    #expect(adapted.segments.map(\.voiceProfileRevision) == script.segments.map(\.voiceProfileRevision))
    #expect(adapted.scriptRevision == 5 && adapted.scriptRevision == drama.soundscape.scriptRevision)
    #expect(SourceCoverageValidator.validate(adapted, against: slice, verbatim: false).isValid)
    #expect(try JSONDecoder().decode(AudioDramaScriptDocument.self, from: JSONEncoder().encode(drama)) == drama)
    #expect(drama.soundscape.sceneCues == plan.sceneCues && drama.soundscape.sfxCues.first == plan.sfxCues.first)
    #expect(drama.soundscape.sfxCues.map(\.soundPrompt) == ["thunderclap", "flint strike", "pot lid rattling", "single pattering tap"])
    #expect(drama.adaptationOrigins.count == script.segments.count)
    for (i, segment) in adapted.segments.enumerated() {
        let original = script.segments[i]
        let origin = try #require(drama.adaptationOrigins[segment.segmentID])
        #expect(origin.sourceSpan == original.sourceSpan && origin.sourceText == original.sourceText)
        #expect(try origin.sourceSpan.slice(in: fullText).utf8.elementsEqual(origin.sourceText.utf8))
        #expect(!origin.adaptationReason.isEmpty)
        if [0, 4, 5, 6].contains(i) {
            let cue = try #require(drama.soundscape.sfxCues.first { $0.anchorSegmentID == segment.segmentID })
            #expect(origin.adaptationReason.contains(cue.cueID))
            #expect(segment.spokenText == "……" && segment.audioArtifactID == nil && segment.status == .pending)
        } else {
            #expect(segment.spokenText.utf8.elementsEqual(original.spokenText.utf8))
        }
    }
    #expect(adapted.segments[1].spokenText == "啪嗒……" && adapted.segments[1].status == .needsReview)
    #expect(adapted.segments[1].direction.pauseAfterMs == 150 && adapted.segments[2].direction.pauseAfterMs == 360)
    #expect(adapted.segments[2].direction.styleInstruction?.contains("疑问") == true)
    #expect(adapted.segments[3].status == .verified && adapted.segments[3].audioArtifactID == "wav-3")
}

@Test func compressionRequiresBothFlagsAndLLMOnlyDirectsPerformance() async throws {
    let (_, _, script, plan) = try dramaFixture()
    let fake = FakeDramaProvider()
    for auth in [authorization(compression: false), authorization(injection: false), authorization(compression: false, injection: false)] {
        let drama = try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: auth, llm: fake)
        #expect(drama.segments.map(\.spokenText) == script.segments.map(\.spokenText))
        #expect(drama.segments.map(\.speakerID) == script.segments.map(\.speakerID))
        #expect(drama.soundscape.sfxCues == plan.sfxCues)
        #expect(drama.segments[2].direction.styleInstruction == "克制；压低声音，轻声说")
        #expect(drama.segments[3].direction == script.segments[3].direction)
    }
    #expect(await fake.calls == 3)
}

@Test func malformedSourceSpanIsRejectedBeforeCallingTheModel() async throws {
    var (_, _, script, plan) = try dramaFixture()
    let fake = FakeDramaProvider()
    let original = script.segments[0].sourceSpan
    for span in [try SourceSpan(start: original.start, endExclusive: original.endExclusive - 1),
                 try SourceSpan(start: original.start + 2, endExclusive: original.endExclusive + 2)] {
        script.segments[0].sourceSpan = span
        await #expect(throws: AudioDramaAdapterError.invalidSourceSpan) {
            try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: authorization(), llm: fake)
        }
    }
    #expect(await fake.calls == 0)
}
