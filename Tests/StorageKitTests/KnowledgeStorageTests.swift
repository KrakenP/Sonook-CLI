import AudioCore
import Foundation
import StorageKit
import Testing

@Test func failedV4MigrationRollsBackAllIntermediateSchemasAndPreservesV1() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sonook.sqlite")
    for statement in originalSchema.split(separator: ";") { _ = try sqlite(file, String(statement)) }
    let project = ProjectRecord(projectID: "old", name: "旧档案", createdAtISO8601: "t")
    _ = try sqlite(file, "INSERT INTO projects VALUES('old',\(sqlDocument(project)))")
    // Collision on the final DDL statement, after v2, v3 and all FTS5 shadow tables were created.
    _ = try sqlite(file, "CREATE TABLE podcast_plans(existing TEXT)")
    let tables = "SELECT name FROM sqlite_master ORDER BY name"
    let before = try sqlite(file, tables)
    #expect(throws: WorkflowStoreError.self) { try SQLiteWorkspaceStore(rootDirectory: root) }
    #expect(try sqlite(file, tables) == before)
    #expect(try sqlite(file, "SELECT version FROM schema_migrations") == ["1"])
    _ = try sqlite(file, "DROP TABLE podcast_plans")
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await store.project(id: "old") == project)
    #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == ["1", "2", "3", "4", "5"])
}

@Test func knowledgeUpsertReplacesFTSAtomicallyAndScopesSearchToProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    for id in ["p", "other"] { try await store.saveProject(.init(projectID: id, name: id, createdAtISO8601: "t")) }
    func record(_ project: String, count: Int, title: String) -> KnowledgeSourceRecord {
        .init(sourceID: "s", projectID: project, title: title, sourceURI: "s.txt", contentSHA256: "revision",
              ingestedAtISO8601: "2026-01-01T00:00:00Z", chunkCount: count)
    }
    func chunk(_ project: String, _ index: Int, _ text: String) throws -> KnowledgeChunk {
        .init(chunkID: "c\(index)", sourceID: "s", projectID: project, sequenceIndex: index, text: text,
              sourceSpan: try .init(start: 50, endExclusive: 50 + text.utf8.count), tokenEstimate: 8)
    }
    let cjk = try chunk("p", 0, "他们在山神庙前遇见了讲述量子计算的老师。")
    let partial = try chunk("p", 1, "山神正在计算山上的树。")
    let english = try chunk("p", 2, "A blue spectrometer measures visible light.")
    let other = try chunk("other", 0, "山神庙。Spectrometer.")
    let source = record("p", count: 3, title: "记录")
    try await store.upsertKnowledgeSource(source, chunks: [english, cjk, partial])
    try await store.upsertKnowledgeSource(record("other", count: 1, title: "其他项目"), chunks: [other])
    let reopened: any KnowledgeStoreProtocol = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.listKnowledgeSources(projectID: "p") == [source])
    #expect(try await reopened.loadKnowledgeChunks(projectID: "p", sourceID: nil) == [cjk, partial, english])
    for query in ["山神庙", "量子计算", "SPECTROMETER"] {
        let hits = try await reopened.searchKnowledge(projectID: "p", query: query, limit: 1)
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.chunk == (query == "SPECTROMETER" ? english : cjk))
        #expect(hit.sourceTitle == source.title && hit.ingestedAtISO8601 == source.ingestedAtISO8601)
        #expect(hit.snippet == hit.chunk.text && hit.score > 0)
    }
    // Duplicate chunk conflicts after deletion must restore the previous source metadata, chunks AND index.
    let replacement = record("p", count: 2, title: "新记录")
    await #expect(throws: WorkflowStoreError.self) { try await reopened.upsertKnowledgeSource(replacement, chunks: [english, english]) }
    #expect(try await store.listKnowledgeSources(projectID: "p") == [source])
    #expect(try await store.searchKnowledge(projectID: "p", query: "spectrometer", limit: 9).map(\.chunk) == [english])
    let new = try chunk("p", 2, "A glacier in summer.")
    try await store.upsertKnowledgeSource(record("p", count: 1, title: "新记录"), chunks: [new])
    #expect(try await reopened.loadKnowledgeChunks(projectID: "p", sourceID: "s") == [new])
    #expect(try await reopened.searchKnowledge(projectID: "p", query: "spectrometer", limit: 9).isEmpty)
    #expect(try await reopened.searchKnowledge(projectID: "other", query: "spectrometer", limit: 9).map(\.chunk) == [other])
}

@Test func soundscapeAndPodcastPlansRoundTripByCompositeKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    let sounds: any SoundscapeStoreProtocol = store
    let podcasts: any KnowledgeStoreProtocol = store
    for p in ["p", "other"] { try await store.saveProject(.init(projectID: p, name: p, createdAtISO8601: "t")) }
    let cue = SceneCue(cueID: "rain", chapterID: "c", startSegmentID: "a", endSegmentID: "b", sceneTag: "屋檐",
                       preset: .rainLight, mood: "静", gainDB: -12, crossfadeMs: 500, evidenceExcerpt: "雨声")
    let sound = ChapterSoundscapePlan(chapterID: "c", scriptRevision: 2, sceneCues: [cue], sfxCues: [],
                                      provenance: "local", createdAtISO8601: "t")
    try await sounds.saveSoundscapePlan(sound, projectID: "p")
    let episode = PodcastEpisodePlan(projectID: "p", episodeID: "e", title: "雨", topicQuery: "rain", format: .soloExplainer,
                                     hostSpeakerIDs: ["host_a"], outline: [], citations: [],
                                     scriptDocument: .init(chapterID: "e", sourceDocumentRevision: "r", scriptRevision: 1, segments: []),
                                     createdAtISO8601: "t")
    try await podcasts.savePodcastPlan(episode)
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.listPodcastPlans(projectID: "p") == [episode])
    #expect(try await reopened.loadPodcastPlan(projectID: "p", episodeID: "e") == episode)
    #expect(try await reopened.listSoundscapePlans(projectID: "p") == [sound])
    #expect(try await reopened.loadSoundscapePlan(projectID: "p", chapterID: "c") == sound)
    #expect(try await reopened.loadSoundscapePlan(projectID: "other", chapterID: "c") == nil)
    #expect(try await reopened.loadPodcastPlan(projectID: "other", episodeID: "e") == nil)
}
