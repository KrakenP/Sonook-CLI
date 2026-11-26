import AudioCore
import Foundation
import KnowledgeKit
import StorageKit
import Testing

private let secretName = "沈雾川"
private let secretTitle = "潮汐审判"
private let secretAlias = "末代岛主"
private let secretPlot = "暗渠将吞没整座港口"
private let futureStage = "加冕后的威严"
private let safeQuote = "林舟点亮了青灯。"
private let laterInChapter = "柴门后藏着一封密信。"

private func book() async throws -> KnowledgeWorkspace {
    let workspace = try await KnowledgeWorkspace()
    let store = workspace.store
    let stage = VoiceDeliveryStage(stageID: "crown", effectiveFromChapter: 5, stageLabel: futureStage, deliveryBaseline: secretPlot)
    let cards: [CharacterVoiceCard] = [
        .init(characterID: "guide", canonicalName: "林舟", aliases: ["阿舟", secretAlias], personaSummary: secretPlot,
              evidenceExcerpts: [secretTitle], deliveryStages: [stage]),
        .init(characterID: "keeper", canonicalName: "宋桥"),
        .init(characterID: "visitor", canonicalName: secretName, aliases: ["雾君"])
    ]
    try await store.saveCatalog(.init(projectID: "p", cards: cards))
    let contents: [[(id: String, speaker: String, text: String)]] = [
        [("lamp", "guide", safeQuote + "乡亲们叫他阿舟。")],
        [("z-first", "guide", "林舟靠岸了。"), ("m-cutoff", "guide", "他敲响柴门。"), ("a-last", "keeper", "宋桥开门。" + laterInChapter)],
        [("boat", "guide", "一艘木船缓缓开过。")],
        [("visitor", "visitor", secretName + "说：" + secretPlot + "。")],
        [("crown", "visitor", "雾君叫出了林舟的封号：" + secretAlias + "。")]
    ]
    let titles = ["灯下", "柴门", "木船", "归客", secretTitle]
    var chapters: [ChapterRecord] = []
    var offset = 0
    for (index, lines) in contents.enumerated() {
        let id = "ch-\(index + 1)", start = offset
        var segments: [ScriptSegment] = []
        for line in lines {
            let end = offset + line.text.utf8.count
            segments.append(.init(segmentID: line.id, chapterID: id, sourceDocumentRevision: "r", sourceSpan: try .init(start: offset, endExclusive: end),
                                  sourceText: line.text, spokenText: line.text, speakerID: line.speaker, voiceProfileRevision: "1", scriptRevision: 1))
            offset = end
        }
        chapters.append(.init(projectID: "p", chapterID: id, chapterNumber: index + 1, title: titles[index],
                              sourceDocumentRevision: "r", sourceSpan: try .init(start: start, endExclusive: offset)))
        try await store.saveScript(.init(chapterID: id, sourceDocumentRevision: "r", scriptRevision: 1, segments: segments), projectID: "p")
    }
    let source = SourceDocumentRecord(sourceDocumentRevision: "r", projectID: "p", format: .txt, originalFileName: "book.txt",
                                      rawAssetID: "raw", rawSHA256: "a", normalizedAssetID: "normalized", normalizedSHA256: "b",
                                      detectedEncoding: "utf-8", totalUTF8Bytes: offset, chapterCount: chapters.count, importedAtISO8601: "t")
    try await store.saveSourceDocument(source, chapters: chapters)
    for (number, summary, actors) in [(1, "林舟在灯下等人。", ["guide"]), (2, laterInChapter, ["guide", "keeper"]), (5, secretPlot, ["visitor"])] {
        let state = CharacterChapterState(characterID: "guide", canonicalName: "林舟", statusSummary: summary, lastSeenChapter: number)
        try await store.saveChapterMemory(.init(projectID: "p", chapterID: "ch-\(number)", chapterNumber: number,
                                                sourceDocumentRevision: "r", summary: summary, activeCharacterIDs: actors,
                                                characterStates: [state], createdAtISO8601: "t"))
    }
    return workspace
}

private func json(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

@Test func questionAboutFifthChapterCannotExposeLaterChaptersOrCumulativeCatalog() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let llm = FakeLLMProvider(safeQuote)
    let resolver = SpoilerSafeContextResolver(store: workspace.store, llm: llm)
    let request = SpoilerSafeContextRequest(projectID: "p", maxChapterNumber: 2, query: "请告诉我第五章里\(secretName)在《\(secretTitle)》做了什么？")
    let response = try await resolver.resolve(request)
    #expect(!response.allowSpoilers && response.withheldFutureChapters == 3)
    #expect(response.answer == safeQuote)
    #expect(response.knownCharacters.map(\.canonicalName) == ["林舟", "宋桥"])
    #expect(response.knownCharacters.first?.aliases == ["阿舟"])
    #expect(response.knownCharacters.first?.firstAppearedChapter == 1)
    #expect(Set(response.evidence.map(\.chapterNumber)) == [1, 2])
    let record = try #require(try await workspace.store.listInteractions(projectID: "p", limit: 1).first)
    let prompt = try #require(await llm.prompts.first)
    #expect(prompt.contains(safeQuote))
    for output in [try json(response), try json(record), prompt] {
        for forbidden in [secretName, secretTitle, secretAlias, secretPlot, futureStage, "归客", "雾君"] {
            #expect(!output.contains(forbidden))
        }
    }
}

@Test(arguments: [secretName, secretTitle, secretAlias, secretPlot])
func modelParametricSpoilerFallsBackToTheSameOfflineEvidence(_ leak: String) async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let request = SpoilerSafeContextRequest(projectID: "p", maxChapterNumber: 2, query: "第五章发生了什么？")
    let offline = try await SpoilerSafeContextResolver(store: workspace.store).resolve(request)
    #expect(!offline.spoilerFilterTriggered && !offline.answer.isEmpty)
    let llm = FakeLLMProvider("结局是" + leak)
    let answer = try await SpoilerSafeContextResolver(store: workspace.store, llm: llm).resolve(request)
    let prompt = try #require(await llm.prompts.first)
    #expect(!prompt.contains(leak))
    #expect(answer.spoilerFilterTriggered && answer.answer == offline.answer && answer.evidence == offline.evidence)
    let records = try await workspace.store.listInteractions(projectID: "p", limit: 2)
    let record = try #require(records.first { $0.interactionID == answer.interactionID })
    #expect(record.spoilerFilterTriggered && record.answer == offline.answer && record.query == request.query)
}

@Test func midChapterUsesInclusiveScriptOrderAndWithholdsTheWholeChapterMemory() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let llm = FakeLLMProvider("他敲响柴门。")
    let resolver = SpoilerSafeContextResolver(store: workspace.store, llm: llm)
    let response = try await resolver.resolve(.init(projectID: "p", maxChapterNumber: 2, maxSegmentID: "m-cutoff", query: "接下来呢？"))
    #expect(response.answer == "他敲响柴门。" && !response.spoilerFilterTriggered)
    #expect(response.knownCharacters.map(\.canonicalName) == ["林舟"])
    #expect(Set(response.evidence.compactMap(\.segmentID)) == ["lamp", "z-first", "m-cutoff"])
    let prompt = try #require(await llm.prompts.first)
    for text in [prompt, try json(response)] {
        #expect(!text.contains(laterInChapter) && !text.contains("宋桥"))
    }
    let unknown = try await resolver.resolve(.init(projectID: "p", maxChapterNumber: 2, maxSegmentID: "lamp", query: "回顾"))
    #expect(unknown.evidence.compactMap(\.segmentID) == ["lamp"])
    #expect(!unknown.evidence.map(\.excerpt).contains(laterInChapter))
}

@Test func explicitOptInUnlocksAllChaptersAndCanBeTurnedOffOnTheNextRequest() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let llm = FakeLLMProvider(secretName + "阻止了涨潮。")
    let resolver = SpoilerSafeContextResolver(store: workspace.store, llm: llm)
    let response = try await resolver.resolve(.init(projectID: "p", maxChapterNumber: 2, maxSegmentID: "m-cutoff", query: secretName, allowSpoilers: true))
    #expect(response.allowSpoilers && response.withheldFutureChapters == 0 && !response.spoilerFilterTriggered)
    #expect(response.answer.contains(secretName) && response.evidence.contains { $0.chapterNumber == 5 })
    #expect(response.knownCharacters.contains { $0.canonicalName == secretName })
    #expect(response.knownCharacters.first?.aliases.contains(secretAlias) == true)
    let prompt = try #require(await llm.prompts.first)
    #expect(prompt.contains(secretTitle) && prompt.contains(secretPlot))
    let strict = try await resolver.resolve(.init(projectID: "p", maxChapterNumber: 1, query: "回顾"))
    #expect(strict.spoilerFilterTriggered && !strict.answer.contains(secretName) && strict.withheldFutureChapters == 4)
    #expect(try #require(await llm.prompts.last).contains(secretPlot) == false)
}

@Test func interactionAnchorsSnapshotExistingPlaybackOrDescribeAnUnsyncedPosition() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let store = workspace.store
    let resolver = SpoilerSafeContextResolver(store: store)
    let request = SpoilerSafeContextRequest(projectID: "p", maxChapterNumber: 2, maxSegmentID: "m-cutoff", query: "回顾",
                                           releaseID: "offline", resumePositionMs: 360)
    let offline = try await resolver.resolve(request)
    #expect(offline.resumeAnchor?.releaseID == "offline" && offline.resumeAnchor?.chapterID == "ch-2")
    #expect(offline.resumeAnchor?.positionMs == 360 && offline.resumeAnchor?.segmentID == "m-cutoff")
    #expect(try await store.loadPlaybackCursor(projectID: "p") == nil)

    let synced = PlaybackCursor(projectID: "p", releaseID: "synced", chapterID: "ch-1", segmentID: "lamp", positionMs: 72,
                                lastEventID: "event", lastDeviceID: "phone", lastDeviceSequence: 8, lastEventType: .rewind, updatedAtISO8601: "t")
    try await store.savePlaybackCursor(synced)
    let response = try await resolver.resolve(request)
    let reopened = try SQLiteWorkspaceStore(rootDirectory: workspace.root)
    #expect(response.resumeAnchor == synced)
    #expect(try await reopened.loadPlaybackCursor(projectID: "p") == synced)
    #expect(try await reopened.listPlaybackEvents(projectID: "p", limit: 10).isEmpty)
    let records = try await reopened.listInteractions(projectID: "p", limit: 10)
    #expect(records.count == 2)
    for result in [offline, response] {
        let record = try #require(records.first { $0.interactionID == result.interactionID })
        #expect(record.answer == result.answer && record.query == request.query)
        #expect(record.resumeReleaseID == result.resumeAnchor?.releaseID && record.resumeChapterID == result.resumeAnchor?.chapterID)
        #expect(record.resumeSegmentID == result.resumeAnchor?.segmentID && record.resumePositionMs == result.resumeAnchor?.positionMs)
    }
}

@Test func questionContainingAnUnnamedFuturePlotIsNotPassedThroughToTheModel() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let llm = FakeLLMProvider(secretPlot)
    let request = SpoilerSafeContextRequest(projectID: "p", maxChapterNumber: 2, query: "林舟知道\(secretPlot)吗？")
    let result = try await SpoilerSafeContextResolver(store: workspace.store, llm: llm).resolve(request)
    let prompt = try #require(await llm.prompts.first)
    #expect(prompt.contains("林舟") && !prompt.contains(secretPlot))
    #expect(result.spoilerFilterTriggered && !result.answer.contains(secretPlot))
}

@Test func laterCatalogIdentityAndStaleScriptCannotRenameAnEarlierSpeaker() async throws {
    let workspace = try await book()
    defer { workspace.remove() }
    let store = workspace.store
    let mystery = CharacterVoiceCard(characterID: "masked", canonicalName: secretName, aliases: ["来客"], personaSummary: secretPlot)
    try await store.saveCatalog(.init(projectID: "p", cards: [mystery]))
    func replaceScript(_ chapter: String, revision: String, text: String) async throws {
        let line = ScriptSegment(segmentID: "masked-line", chapterID: chapter, sourceDocumentRevision: revision,
                                 sourceSpan: try .init(start: 0, endExclusive: text.utf8.count), sourceText: text, spokenText: text,
                                 speakerID: "masked", voiceProfileRevision: "1", scriptRevision: 2)
        try await store.saveScript(.init(chapterID: chapter, sourceDocumentRevision: revision, scriptRevision: 2, segments: [line]), projectID: "p")
    }
    try await replaceScript("ch-1", revision: "r", text: "有人说：等一等。")
    try await replaceScript("ch-2", revision: "old", text: secretName + secretPlot)
    let resolver = SpoilerSafeContextResolver(store: store)
    let request = SpoilerSafeContextRequest(projectID: "p", maxChapterNumber: 2, query: "那是谁？")
    let hidden = try await resolver.resolve(request)
    #expect(hidden.knownCharacters.contains { $0.characterID == "masked" })
    #expect(try !json(hidden).contains(secretName))
    try await replaceScript("ch-1", revision: "r", text: "来客说：等一等。")
    let named = try await resolver.resolve(request)
    #expect(named.knownCharacters.first { $0.characterID == "masked" }?.canonicalName == "来客")
    #expect(try !json(named).contains(secretName))
}
