import AudioCore
import Foundation
import NarrativeKit
import Testing

@Suite("Cross-chapter memory")
struct ChapterMemoryTests {
    private let catalog = CharacterVoiceCatalog(projectID: "p", cards: (1...100).map { index in
        let tag = String(format: "%03ld", index)
        return .init(characterID: "id" + tag, canonicalName: "角色" + tag, aliases: ["别名" + tag], locked: index == 1)
    })

    private func memory(_ chapter: Int, _ ids: [String], _ summary: String = "", states: [CharacterChapterState] = [],
                        project: String = "p") -> ChapterMemoryRecord {
        .init(projectID: project, chapterID: "ch\(chapter)", chapterNumber: chapter, sourceDocumentRevision: "r",
              summary: summary, activeCharacterIDs: ids, characterStates: states, openThreads: ["线索" + summary],
              createdAtISO8601: "t")
    }

    @Test func boundedRosterPrioritizesMentionsRecentSpeakersThenFrequencyAndLocks() {
        let history = [
            memory(2, ["id066", "id071"]), memory(1, ["id071", "id066", "id035", "id035"]), memory(3, ["id071"]),
            memory(6, ["id050"]), memory(4, ["id048"]), memory(5, ["id049"]),
            memory(7, ["id003"]), memory(8, ["id002"]), memory(6, ["id004"], project: "other")
        ]
        func roster(_ limit: Int, from memories: [ChapterMemoryRecord]) -> [String] {
            ChapterMemoryTracker.selectRelevantRoster(catalog: catalog, chapterNumber: 7, chapterText: "别名100遇见角色099。",
                                                       priorMemories: memories, maxCharacters: limit).map(\.characterID)
        }
        let expected = ["char_narrator", "id099", "id100", "id050", "id049", "id048", "id071", "id066", "id001"]
        #expect(roster(9, from: history) == expected)
        #expect(roster(7, from: history.reversed()) == Array(expected.prefix(7)))
        #expect(roster(-1, from: history) == Array(expected.prefix(2)))
        #expect(roster(20, from: history) == roster(20, from: Array(history.prefix(6))))
    }

    @Test func promptSummarizesRecentChaptersAndUsesLatestKnownStateOfRecentSpeakers() {
        func state(_ name: String, _ status: String, _ lastSeen: Int) -> CharacterChapterState {
            .init(characterID: name, canonicalName: name, statusSummary: status, location: "桥头",
                  relationships: ["同伴"], lastSeenChapter: lastSeen)
        }
        let history = [
            memory(5, ["甲"], "未来情节", states: [state("甲", "未来状态", 5)]),
            memory(3, ["乙"], "桥边", states: [state("乙", "已归队", 3), state("甲", "越界状态", 5)]),
            memory(4, ["甲"], "灯火", states: [state("甲", "已到达", 4)]),
            memory(1, ["甲", "丙", "丁"], "早期摘要", states: [state("甲", "未出发", 1), state("丙", "旧客", 1), state("丁", "已启程", 1)]),
            memory(2, ["丁"], "同行")
        ]
        let prompt = ChapterMemoryTracker.buildPriorMemoryPrompt(priorMemories: history, beforeChapter: 5, maxRecentChapters: 3)
        for word in ["桥边", "灯火", "线索灯火", "已归队", "已到达", "已启程", "桥头", "同伴"] { #expect(prompt.contains(word)) }
        for word in ["早期摘要", "未出发", "旧客", "未来情节", "未来状态", "越界状态"] { #expect(!prompt.contains(word)) }
        #expect(ChapterMemoryTracker.buildPriorMemoryPrompt(priorMemories: history, beforeChapter: 1).isEmpty)
        #expect(ChapterMemoryTracker.buildPriorMemoryPrompt(priorMemories: history, beforeChapter: 9, maxRecentChapters: -1).isEmpty)
    }

    @Test func analyzerBoundsBothPromptsAndBuildsMemoryFromValidatedTurns() async throws {
        let past = memory(3, ["id050"], "在渡口等候", states: [
            .init(characterID: "id050", canonicalName: "角色050", statusSummary: "等候中", location: "渡口", lastSeenChapter: 3)
        ])
        let fake = RecordingLLM("""
            {"characters":[{"canonical_name":"船工","status_summary":"收起船桨","location":"船尾","relationships":["与旅人同行"]}],
             "chapter_summary":"船工接到了旅人。","open_threads":["航程未定"]}
            """, attribution: """
            {"attributions":[{"index":0,"speaker":"角色050","confidence":1},{"index":1,"speaker":"船工","confidence":0.9},
                             {"index":2,"speaker":"船工","confidence":0.9},{"index":3,"speaker":"角色002","confidence":1}]}
            """)
        let text = "船工招呼别名100。"
        let units = ["天亮了。", "请上船。", "开船了。", "谁在岸上？"].enumerated().map { index, line in
            NarrativeUnitInput(index: index, segmentID: "s\(index)", sourceText: line, spokenText: line, isQuotedDialogue: index > 0)
        }
        let output = try await NarrativeAnalyzer.analyzeChapter(
            projectID: "p", chapterNumber: 4, chapterText: text, units: units, existingCatalog: catalog, llmProvider: fake,
            chapterID: "crossing", sourceDocumentRevision: "r", priorMemories: [
                past, memory(4, ["id002"], "同章秘密"), memory(5, ["id003"], "未来秘密"), memory(3, ["id004"], "他书秘密", project: "other")
            ], maxRosterSize: 4)
        let requests = await fake.requests
        try #require(requests.count == 2)
        #expect(requests[0].prompt.contains("在渡口等候") && requests[0].prompt.contains("等候中"))
        for request in requests {
            for id in ["char_narrator", "id100", "id050"] { #expect(request.prompt.contains(id)) }
            for word in ["id002", "id003", "id004", "id099", "同章秘密", "未来秘密", "他书秘密"] { #expect(!request.prompt.contains(word)) }
        }
        #expect(requests[0].prompt.contains("id001") && !requests[1].prompt.contains("id001"))
        #expect(output.catalog.cards.count == 102)
        let boatman = try #require(output.catalog.resolveCharacter(namedOrAliased: "船工"))
        #expect(requests[1].prompt.contains(boatman.characterID))
        #expect(output.attributions.map(\.speakerID) == ["char_narrator", boatman.characterID, boatman.characterID, "char_narrator"])
        #expect(output.attributions.last?.needsReviewReason == "unresolved_dialogue_speaker")
        let record = try #require(output.chapterMemory)
        #expect(record.projectID == "p" && record.chapterID == "crossing" && record.chapterNumber == 4 && record.sourceDocumentRevision == "r")
        #expect(record.summary == "船工接到了旅人。" && record.openThreads == ["航程未定"])
        #expect(record.activeCharacterIDs == ["char_narrator", boatman.characterID])
        #expect(record.characterStates.map(\.characterID) == record.activeCharacterIDs)
        #expect(record.characterStates.allSatisfy { $0.lastSeenChapter == 4 })
        #expect(record.characterStates.last == .init(characterID: boatman.characterID, canonicalName: "船工", statusSummary: "收起船桨",
                                                     location: "船尾", relationships: ["与旅人同行"], lastSeenChapter: 4))
    }

    @Test func legacyProfileUsesDefaultIDRevisionAndDeterministicSummary() async throws {
        let fake = RecordingLLM(#"{"characters":[]}"#)
        let unit = NarrativeUnitInput(index: 0, segmentID: "s", sourceText: "天亮。", spokenText: "天亮。", isQuotedDialogue: false)
        let output = try await NarrativeAnalyzer.analyzeChapter(projectID: "p", chapterNumber: 12, chapterText: "第12章 晨光\n天亮。",
                                                               units: [unit], existingCatalog: nil, llmProvider: fake)
        let record = try #require(output.chapterMemory)
        #expect(record.chapterID == "ch_012" && record.sourceDocumentRevision == "rev_1")
        #expect(record.summary.contains("第12章 晨光") && record.summary.contains("旁白") && record.openThreads.isEmpty)
        #expect(record.activeCharacterIDs == ["char_narrator"] && record.characterStates.first?.lastSeenChapter == 12)
        #expect(try Date.ISO8601FormatStyle().parse(record.createdAtISO8601) <= .now)
    }

    @Test func malformedOrAlternateKeyStageChangesNeverCrashChapterAnalysis() async throws {
        let catalog = CharacterVoiceCatalog(projectID: "p", cards: [
            NarrativeAnalyzer.defaultNarratorCard(),
            CharacterVoiceCard(characterID: "char_001", canonicalName: "顾辰", voiceDesignPrompt: "青年男声")
        ])
        let raw = """
        {
          "chapter_summary": "顾辰初醒，心境沉静。",
          "characters": [{"canonical_name": "顾辰", "persona_summary": "初醒的青年"}],
          "delivery_stage_changes": [
            {"unexpected_field": "malformed entry missing character_name"},
            {"character_id": "char_001", "stage_label": "劫后余生", "delivery_baseline": "语速放缓，克制低沉", "reason": "经历剧变", "evidence_excerpt": "他缓缓睁眼，声音低沉了许多。"}
          ]
        }
        """
        let fake = RecordingLLM(raw)
        let text = "第2章 苏醒\n他缓缓睁眼，声音低沉了许多。"
        let unit = NarrativeUnitInput(index: 0, segmentID: "ch_002_seg_0001", sourceText: "他缓缓睁眼，声音低沉了许多。", spokenText: "他缓缓睁眼，声音低沉了许多。", isQuotedDialogue: false)
        let output = try await NarrativeAnalyzer.analyzeChapter(
            projectID: "p",
            chapterNumber: 2,
            chapterText: text,
            units: [unit],
            existingCatalog: catalog,
            llmProvider: fake
        )
        let stages = try #require(output.proposedStagesByCharacterID["char_001"])
        #expect(stages.count == 1)
        #expect(stages[0].stageLabel == "劫后余生")
    }
}
