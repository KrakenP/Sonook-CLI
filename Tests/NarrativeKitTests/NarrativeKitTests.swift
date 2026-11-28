import AudioCore
import Foundation
import NarrativeKit
import Testing

actor RecordingLLM: LLMProvider {
    let capabilities = LLMCapabilities(parameters: ["temperature": .anyValue, "seed": .anyValue, "enable_thinking": .anyValue,
                                                     "max_tokens": .anyValue, "system_prompt": .anyValue])
    private(set) var isLoaded = true
    private(set) var requests = [(prompt: String, parameters: [String: String])]()
    let profile: String
    let attribution: String

    init(_ profile: String, attribution: String = #"{"attributions":[]}"#) {
        self.profile = profile
        self.attribution = attribution
    }

    func load() { isLoaded = true }
    func unload() { isLoaded = false }
    func generateAccepted(prompt: String, parameters: AcceptedParameters) -> LLMResponse {
        requests.append((prompt, parameters.values))
        let json = prompt.contains("coreference_notes") ? profile : attribution
        let fence = String(repeating: "`", count: 3)
        return .init(text: "结果\n\(fence)json\n\(json)\n\(fence)", metrics: .init(providerID: "test", modelID: "fake",
                                                                                modelRevision: "1", inferenceDurationMs: 1))
    }
}

private let roster = CharacterVoiceCatalog(projectID: "p", cards: [NarrativeAnalyzer.defaultNarratorCard(),
    .init(characterID: "a", canonicalName: "张三", aliases: ["三哥"]),
    .init(characterID: "b", canonicalName: "李四"), .init(characterID: "c", canonicalName: "小叶")])

private func validate(_ lines: [(String, Bool, String?, Double)]) -> [NarrativeUnitAttribution] {
    let units = lines.enumerated().map { i, line in
        NarrativeUnitInput(index: i, segmentID: "s\(i)", sourceText: line.0, spokenText: line.0, isQuotedDialogue: line.1)
    }
    let predictions = lines.enumerated().compactMap { i, line -> NarrativeUnitAttribution? in
        guard let speaker = line.2 else { return nil }
        return .init(index: i, speakerID: speaker, emotion: "", styleInstruction: "", pauseAfterMs: 300, confidence: line.3, evidence: ["原始依据"])
    }
    return DialogueAttributionValidator.validate(units: units, attributions: predictions, catalog: roster)
}

@Test func vocativeExclusionAndAmbiguousAudience() {
    let lines = [("赶路吧。", true, "李四", 0.9), ("哎哎哎张三张三，快点！", true, "张三", 0.95)]
    let two = validate(lines)
    #expect(two[1].speakerID == "b" && two[1].needsReviewReason == nil)
    #expect(two[1].evidence == ["原始依据", "[validator:vocative_exclusion]"])
    let three = validate(lines + [("三哥、李四，等等！", true, "三哥", 0.95), ("我在桥头。", true, "小叶", 0.92)])
    #expect(three[1].speakerID == "a" && three[1].needsReviewReason == "vocative_speaker_conflict")
    #expect(three[2].needsReviewReason == "vocative_speaker_conflict")
    let mention = validate([("张三说过，明天开门。", true, "张三", 0.95)])
    #expect(mention[0].needsReviewReason == nil)
}

@Test func alternatingRepliesStopAtNarrationOrThirdSpeaker() {
    let four = [("明天出发？",true,"张三",0.95), ("好。",true,"李四",0.95),
                ("那就一起走？",true,"李四",0.95), ("当然。",true,"张三",0.95)]
    let result = validate(four)
    #expect(result.map(\.speakerID) == ["a","b","a","b"])
    #expect(result.suffix(2).allSatisfy { $0.evidence.contains("[validator:alternating_turn]") })
    let three = validate(four + [("我也来。",true,"小叶",0.95),("好，带上我。",true,"小叶",0.95)])
    #expect(three.map(\.speakerID) == ["a","b","a","b","c","c"])
    for narration in ["李四又道：", "李四接着说：", "李四补充道：", "李四举起手。"] {
        let result = validate(four + [(narration,false,"李四",0.9),("不，我改主意了。",true,"李四",0.9)])
        #expect(result.suffix(2).map(\.speakerID) == ["char_narrator","b"])
        #expect(result.last?.evidence == ["原始依据"])
    }
    // Direct vocative call in turn 0 followed by unattributed rebuttal + apology + refusal chains cleanly across 2 speakers.
    let vocativeChain = validate([
        ("哎哎哎张三张三，快拉我一把！", true, "李四", 0.95),
        ("拉你有什么用？一上去就倒。", true, "李四", 0.95),
        ("我的我的……下回换我掩护你！", true, "张三", 0.95),
        ("别别别……还是找别人吧。", true, "李四", 0.95)
    ])
    #expect(vocativeChain.map(\.speakerID) == ["b", "a", "b", "a"])
    #expect(vocativeChain.dropFirst().allSatisfy { $0.evidence.contains("[validator:alternating_turn]") })
}

@Test func unresolvedAndUncertainRemainReviewable() {
    let result = validate([("屋外雨声。", false,nil,0), ("是谁？",true,nil,0), ("是谁？",true,"路人",1),
                           ("是谁？",true,"旁白",1), ("是谁？",true,"char_narrator",1), ("我来。",true,"李四",0.59)])
    #expect(result[0].speakerID == "char_narrator" && result[0].needsReviewReason == nil)
    #expect(result[1...4].allSatisfy { $0.needsReviewReason == "unresolved_dialogue_speaker" && $0.confidence <= 0.45 })
    #expect(result[5].needsReviewReason == "low_confidence_attribution")
}

@Test func deterministicRequestsBatchesAndReviewCounts() async throws {
    let units = (0..<13).map {
        NarrativeUnitInput(index: $0, segmentID: "s\($0)", sourceText: "原文\($0)号", spokenText: "话", isQuotedDialogue: $0 == 2 || $0 >= 10)
    }
    // The fake returns the same indices for both batches, including out-of-batch rows.
    let fake = RecordingLLM(#"{"coreference_notes":"","characters":[{"canonical_name":"阿七","voice_design_prompt":"清朗"}]}"#,
                            attribution: #"{"attributions":[{"index":2,"speaker":"阿七","confidence":0.95},{"index":10,"speaker":"阿七","confidence":0.96},{"index":11,"speaker":"阿七","confidence":0.3}]}"#)
    func analyze() async throws -> NarrativeChapterOutput {
        try await NarrativeAnalyzer.analyzeChapter(projectID: "p", chapterNumber: 1, chapterText: "原文", units: units,
                                                  existingCatalog: nil, llmProvider: fake, seed: 721)
    }
    let first = try await analyze()
    let second = try await analyze()
    #expect(second.catalog == first.catalog && second.attributions == first.attributions)
    #expect(second.proposedStagesByCharacterID == first.proposedStagesByCharacterID)
    #expect(second.autoAttributedCount == first.autoAttributedCount && second.needsReviewCount == first.needsReviewCount)
    #expect(second.chapterMemory?.summary == first.chapterMemory?.summary)
    #expect(first.autoAttributedCount == 11 && first.needsReviewCount == 2)
    #expect(first.attributions[11].needsReviewReason == "low_confidence_attribution")
    #expect(first.attributions[12].needsReviewReason == "unresolved_dialogue_speaker")
    let requests = await fake.requests
    #expect(requests.count == 6)
    #expect(requests.allSatisfy { $0.parameters["temperature"] == "0.0" && $0.parameters["seed"] == "721" && $0.parameters["enable_thinking"] == "false" })
    #expect(requests[1].prompt.contains("原文11号") && !requests[1].prompt.contains("原文12号"))
    #expect(requests[2].prompt.contains("原文8号") && !requests[2].prompt.contains("原文7号"))

    // Verify pure-narration chapters skip LLM attribution batches entirely (1 profile call only).
    let narrationOnlyUnits = (0..<12).map {
        NarrativeUnitInput(index: $0, segmentID: "n\($0)", sourceText: "叙述\($0)", spokenText: "叙述\($0)", isQuotedDialogue: false)
    }
    let narrFake = RecordingLLM(#"{"coreference_notes":"","characters":[]}"#)
    let narrOut = try await NarrativeAnalyzer.analyzeChapter(projectID: "p", chapterNumber: 1, chapterText: "叙述", units: narrationOnlyUnits,
                                                             existingCatalog: nil, llmProvider: narrFake, seed: 42)
    #expect(await narrFake.requests.count == 1)
    #expect(narrOut.autoAttributedCount == 12 && narrOut.needsReviewCount == 0)
    #expect(narrOut.attributions.allSatisfy { $0.speakerID == "char_narrator" })
}

@Test func stagesAreGroundedInCurrentChapterAndLeaveLockedAnchorIntact() async throws {
    let first = RecordingLLM(#"{"characters":[{"canonical_name":"阿七","aliases":["小七"],"voice_design_prompt":"清朗"}]}"#)
    let chapter1 = try await NarrativeAnalyzer.analyzeChapter(projectID: "p", chapterNumber: 1, chapterText: "阿七走来。", units: [],
                                                              existingCatalog: nil, llmProvider: first)
    var hero = try #require(chapter1.catalog.resolveCharacter(namedOrAliased: "阿七"))
    #expect(hero.locked)
    let anchor = VoiceTimbreAnchor(anchorID: "lock", assetID: "wav", fileSHA256: "digest", generatorProviderID: "local",
                                  generatorModelID: "fake", designPrompt: "清朗", auditionText: "早。", sampleRate: 24000, createdAtISO8601: "t")
    hero.timbreAnchor = anchor
    let initial = VoiceDeliveryStage(stageID: "first", effectiveFromChapter: 1, stageLabel: "初出茅庐", deliveryBaseline: "轻快")
    hero.deliveryStages = [initial, .init(stageID: "future", effectiveFromChapter: 8, stageLabel: "远期秘密", deliveryBaseline: "未来基调")]
    let locked = try chapter1.catalog.merging(incomingCards: [hero])
    let fake = RecordingLLM("""
        {"characters":[{"canonical_name":"小七","voice_design_prompt":"新音色"}],
        "delivery_stage_changes":[{"character_name":"阿七","stage_label":"沉稳","delivery_baseline":"从容克制",
        "speaking_rate":0.96,"reason":"久经风霜","evidence_excerpt":"十年后，他成了船长。"}]}
        """)
    let chapter2 = try await NarrativeAnalyzer.analyzeChapter(projectID: "p", chapterNumber: 2, chapterText: "十年后，他成了船长。",
                                                              units: [], existingCatalog: locked, llmProvider: fake)
    let card = try #require(chapter2.catalog.resolveCharacter(namedOrAliased: "小七"))
    #expect(card.revision == locked.resolveCharacter(namedOrAliased: "阿七")?.revision)
    #expect(card.timbreAnchor == anchor && card.voiceDesignPrompt == "清朗" && card.activeDeliveryStage(forChapter: 1) == initial)
    let stage = try #require(card.activeDeliveryStage(forChapter: 2))
    #expect(stage.stageID == hero.characterID + "_ch0002" && stage.effectiveFromChapter == 2 && stage.speakingRate == 0.96)
    #expect(chapter2.proposedStagesByCharacterID[hero.characterID] == [stage])
    #expect(card.activeDeliveryStage(forChapter: 8)?.stageID == "future")
    let request = try #require(await fake.requests.first)
    #expect(request.prompt.contains("初出茅庐") && !request.prompt.contains("远期秘密") && !request.prompt.contains("未来基调"))
}

actor RetryingLLM: LLMProvider {
    let capabilities = LLMCapabilities(parameters: ["temperature": .anyValue, "seed": .anyValue, "enable_thinking": .anyValue,
                                                     "max_tokens": .anyValue, "system_prompt": .anyValue])
    private(set) var isLoaded = true
    private(set) var maxTokensSeen = [String]()
    private var profileAttempts = 0
    private var attributionAttempts = 0

    func load() { isLoaded = true }
    func unload() { isLoaded = false }
    func generateAccepted(prompt: String, parameters: AcceptedParameters) -> LLMResponse {
        maxTokensSeen.append(parameters.values["max_tokens"] ?? "")
        if prompt.contains("coreference_notes") {
            profileAttempts += 1
            if profileAttempts == 1 {
                // Truncated JSON with an inner object closed but outer object unclosed
                return .init(text: #"{"coreference_notes":"长文","characters":[{"canonical_name":"阿七","voice_design_prompt":"温润"},{"canonical_name":"阿九""#,
                             metrics: .init(providerID: "test", modelID: "fake", modelRevision: "1", inferenceDurationMs: 1))
            }
            return .init(text: #"{"coreference_notes":"ok","characters":[{"canonical_name":"阿七","voice_design_prompt":"温润"}]} 附加说明{忽略}"#,
                         metrics: .init(providerID: "test", modelID: "fake", modelRevision: "1", inferenceDurationMs: 1))
        }
        attributionAttempts += 1
        if attributionAttempts == 1 {
            return .init(text: #"{"attributions":[{"index":0,"speaker":"阿七""#,
                         metrics: .init(providerID: "test", modelID: "fake", modelRevision: "1", inferenceDurationMs: 1))
        }
        return .init(text: #"{"attributions":[{"index":0,"speaker":"阿七","confidence":0.95,"evidence":"开篇说话"}]} 尾注{x}"#,
                     metrics: .init(providerID: "test", modelID: "fake", modelRevision: "1", inferenceDurationMs: 1))
    }
}

@Test func truncatedProfileAndAttributionJSONRetryWithExpandedTokenBudgetAndBalancedDecode() async throws {
    let units = [NarrativeUnitInput(index: 0, segmentID: "s0", sourceText: "“喝茶。”", spokenText: "喝茶。", isQuotedDialogue: true)]
    let fake = RetryingLLM()
    let output = try await NarrativeAnalyzer.analyzeChapter(
        projectID: "p", chapterNumber: 1, chapterText: "“喝茶。”", units: units,
        existingCatalog: nil, llmProvider: fake, seed: 42
    )
    #expect(output.catalog.resolveCharacter(namedOrAliased: "阿七") != nil)
    #expect(output.autoAttributedCount == 1 && output.needsReviewCount == 0)
    #expect(await fake.maxTokensSeen == ["4096", "8192", "2400", "3600"])
}
