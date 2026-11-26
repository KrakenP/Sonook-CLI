import AudioCore
import DirectorKit
import Foundation
import NarrativeKit
import Testing

private func chapterScript(_ lines: [String]) throws -> (ChapterRecord, ScriptDocument) {
    let text = lines.joined(separator: "\n")
    let chapter = ChapterRecord(projectID: "p", chapterID: "ch", chapterNumber: 1, title: "试读",
                                sourceDocumentRevision: "doc", sourceSpan: try SourceSpan(start: 0, endExclusive: text.utf8.count))
    let (_, units) = try DirectorSegmenter.segmentChapter(chapter: chapter, normalizedDocumentUTF8: Data(text.utf8))
    let segments = units.map {
        ScriptSegment(segmentID: "s\($0.index)", chapterID: "ch", sourceDocumentRevision: "doc", sourceSpan: $0.span,
                      sourceText: $0.sourceText, spokenText: $0.spokenText, speakerID: "char_narrator", voiceProfileRevision: "v1",
                      scriptRevision: 3)
    }
    return (chapter, ScriptDocument(chapterID: "ch", sourceDocumentRevision: "doc", scriptRevision: 3, segments: segments))
}

@Test func sunnyForestCampAndStreamNeverAcquireRain() async throws {
    let (chapter, script) = try chapterScript(["阳光洒满山林，鸟语不绝。", "大家在营地歇脚。", "小溪绕过营地。", "他摊开地图。"])
    let date = Date(timeIntervalSince1970: 100)
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, createdAt: date)
    #expect(plan.sceneCues.map(\.preset) == [.forestWind, .streamWater])
    #expect(plan.sceneCues.map(\.startSegmentID) == ["s0", "s2"])
    #expect(plan.sceneCues.map(\.endSegmentID) == ["s1", "s3"])
    #expect(plan.sceneCues.allSatisfy { $0.crossfadeMs == 1800 })
    #expect(plan.sfxCues.isEmpty)
    let replay = try await SoundscapePlanner.plan(chapter: chapter, script: script, createdAt: date)
    #expect(plan == replay)
}

@Test func stormToTempleAndHearthHaveGroundedPointEffects() async throws {
    let (chapter, script) = try chapterScript(["春雨落在山道上。", "大雨打湿衣襟。", "轰隆隆，远处传来雷声。", "他们跑进山神庙。",
                                              "啪，啪，啪……他用打火石点起火堆。", "锅盖乒乒乓乓。"])
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script)
    #expect(plan.sceneCues.map(\.preset) == [.rainLight, .rainHeavy, .stormThunder, .templeQuiet, .campfireHearth])
    #expect(plan.sceneCues.map(\.startSegmentID) == ["s0", "s1", "s2", "s3", "s4"])
    #expect(plan.sceneCues.map(\.endSegmentID) == ["s0", "s1", "s2", "s3", "s5"])
    #expect(plan.sfxCues.map(\.soundPrompt) == ["thunderclap", "flint strike", "fire crackling", "pot lid rattling"])
    #expect(plan.sfxCues.map(\.anchorSegmentID) == ["s2", "s4", "s4", "s5"])
    for cue in plan.sfxCues {
        let anchor = try #require(script.segments.first { $0.segmentID == cue.anchorSegmentID })
        #expect(!cue.evidenceExcerpt.isEmpty && anchor.sourceText.contains(cue.evidenceExcerpt))
    }
}

@Test func englishSettingsAndIndoorReset() async throws {
    let (chapter, script) = try chapterScript(["The train left.", "In the forest, birdsong filled the air.",
                                              "Crickets sang in the moonlight.", "They entered the tavern.",
                                              "He knocked on the door.", "Inside the room she drew her sword.", "There was no rain."])
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script)
    #expect(plan.sceneCues.map(\.preset) == [.none, .forestWind, .nightInsects, .tavernCrowd, .none])
    #expect(plan.sfxCues.map(\.soundPrompt) == ["door knock", "sword unsheathing"])
}

@Test func modelCuesAreGroundedWithinTheirOwnRangesAndBoundsAreRepaired() async throws {
    let (chapter, script) = try chapterScript(["晴朗的山林。", "小溪边传来钟声。", "轰隆隆……", "他跑进破庙。"])
    let json = """
        <think>Maybe {"preset":"rain_heavy"}?</think>
        {"scene_cues":[
          {"start_segment_id":"s0","end_segment_id":"s0","preset":"rain_heavy","mood":"wrong"},
          {"start_segment_id":"s1","end_segment_id":"bogus","preset":"stream_water","mood":"still","gain_db":-20},
          {"start_segment_id":"s3","end_segment_id":"s2","preset":"storm_thunder","mood":"tense"},
          {"start_segment_id":"unknown","end_segment_id":"n/a","preset":"rain_light"}],
         "sfx_cues":[
          {"anchor_segment_id":"s1","sound_prompt":"钟声","evidence_excerpt":"钟声","duration_seconds":22,"gain_db":12,"placement":"before"},
          {"anchor_segment_id":"s2","sound_prompt":"thunderclap","evidence_excerpt":"轰隆隆","duration_seconds":0.01,"gain_db":-80},
          {"anchor_segment_id":"s0","sound_prompt":"thunderclap","evidence_excerpt":"山林","duration_seconds":2,"gain_db":-15},
          {"anchor_segment_id":"bogus","sound_prompt":"钟声","evidence_excerpt":"钟声","duration_seconds":2,"gain_db":-15}]}
        """
    let fake = RecordingLLM("", attribution: json)
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, llm: fake)
    #expect(plan.chapterID == chapter.chapterID && plan.scriptRevision == script.scriptRevision)
    #expect(plan.sceneCues.map(\.preset) == [.forestWind, .streamWater, .stormThunder, .templeQuiet])
    #expect(plan.sceneCues.map(\.startSegmentID) == ["s0", "s1", "s2", "s3"])
    #expect(plan.sceneCues.map(\.endSegmentID) == plan.sceneCues.map(\.startSegmentID))
    #expect(plan.sceneCues[1].mood == "still" && plan.sceneCues[1].gainDB == -20)
    #expect(plan.sfxCues.map(\.soundPrompt) == ["钟声", "thunderclap"])
    #expect(plan.sfxCues.map(\.durationSeconds) == [8, 0.3] && plan.sfxCues.map(\.gainDB) == [-3, -36])
    #expect(plan.sfxCues[0].placement == .before)
    #expect(plan.provenance.contains("lexical fallback: ungrounded rain_heavy") && plan.provenance.contains("repaired scene bounds"))
    #expect(plan.provenance.contains("llm:test/fake@1"))
    let requests = await fake.requests
    #expect(requests.count == 1 && requests[0].parameters == ["temperature": "0.0", "seed": "42"])
}

@Test func neutralRoomRejectsEveryUngroundedEnvironment() async throws {
    let (chapter, script) = try chapterScript(["他在屋里抄书。"])
    for preset in [SceneAtmospherePreset.rainLight, .rainHeavy, .stormThunder, .campfireHearth, .tavernCrowd,
                   .streamWater, .forestWind, .nightInsects] {
        let fake = RecordingLLM("", attribution: """
            {"scene_cues":[{"start_segment_id":"s0","end_segment_id":"s0","preset":"\(preset.rawValue)"}],"sfx_cues":[]}
            """)
        let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, llm: fake)
        #expect(plan.sceneCues.map(\.preset) == [.none])
        #expect(plan.provenance.contains("ungrounded \(preset.rawValue)"))
    }
}

@Test func malformedModelResponseFallsBackToLexicalPlan() async throws {
    let (chapter, script) = try chapterScript(["夜深。", "啪嗒……"])
    let fake = RecordingLLM("", attribution: "{broken")
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, llm: fake)
    #expect(plan.sceneCues.map(\.preset) == [.nightInsects])
    #expect(plan.sfxCues.map(\.anchorSegmentID) == ["s1"])
    #expect(plan.provenance.contains("lexical fallback: invalid JSON"))
}

@Test func clearedWeatherKeepsTheGroundedSettingAndStopsWeatherCarryover() async throws {
    let (chapter, script) = try chapterScript(["山林鸟语，阳光正好。", "溪水潺潺，没有雨声。", "大雨倾盆。", "雨停了。",
                                              "The train crossed the plain.", "In the sunny forest she remembered yesterday's rain."])
    let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script)
    #expect(plan.sceneCues.map(\.preset) == [.forestWind, .streamWater, .rainHeavy, .none, .forestWind])
    #expect(plan.sceneCues.map(\.startSegmentID) == ["s0", "s1", "s2", "s3", "s5"])
}
