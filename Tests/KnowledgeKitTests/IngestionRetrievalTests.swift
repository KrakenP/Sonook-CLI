import AudioCore
import CryptoKit
import Foundation
import KnowledgeKit
import StorageKit
import Testing

struct KnowledgeWorkspace {
    let root: URL
    let store: SQLiteWorkspaceStore

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SQLiteWorkspaceStore(rootDirectory: root)
        try await store.saveProject(.init(projectID: "p", name: "工作笔记", createdAtISO8601: "t"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func markdownFilePreservesEveryUTF8ByteAcrossSectionsAndOverlappingWindows() async throws {
    let workspace = try await KnowledgeWorkspace()
    defer { workspace.remove() }
    let raw = "# 观察 ##\r\n星图👩🏽‍🚀与 cafe\u{301}。\r\n\r\n" + String(repeating: "计算世界🌏", count: 12)
        + String(repeating: "\r\n", count: 45) + "附录\r\n---\r\n```txt\r\n# 围栏中的文字\r\n```\r\n原始结尾。"
    let file = workspace.root.appendingPathComponent("观察.md")
    try Data(raw.utf8).write(to: file)
    let ingestor = KnowledgeIngestor(store: workspace.store, maxChars: 20, overlap: 4)
    let source = try await ingestor.ingest(file: file, projectID: "p", ingestedAt: Date(timeIntervalSince1970: 0))
    #expect(source.title == "观察.md" && source.sourceURI == file.standardizedFileURL.absoluteString)
    #expect(source.contentSHA256 == SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined())
    let chunks = try await workspace.store.loadKnowledgeChunks(projectID: "p", sourceID: source.sourceID)
    #expect(chunks.count == source.chunkCount && chunks.map(\.sequenceIndex) == Array(chunks.indices))
    #expect(Set(chunks.compactMap(\.sectionHeading)) == ["观察", "附录"])
    let appendix = try #require(raw.range(of: "附录")).lowerBound
    let boundary = raw.utf8.distance(from: raw.startIndex, to: appendix)
    var furthest = 0
    var overlaps = 0
    for chunk in chunks {
        #expect(try chunk.sourceSpan.slice(in: raw).utf8.elementsEqual(chunk.text.utf8))
        #expect(chunk.text.count <= 20 && chunk.text.count > 0)
        #expect(chunk.sourceSpan.start <= furthest)
        if chunk.sourceSpan.start < furthest { overlaps += 1 }
        #expect(chunk.sourceSpan.endExclusive > furthest)
        furthest = chunk.sourceSpan.endExclusive
        if chunk.sectionHeading == "观察" { #expect(furthest <= boundary) }
        else { #expect(chunk.sourceSpan.start >= boundary) }
    }
    #expect(furthest == raw.utf8.count && overlaps > 0)
    let oldIDs = Set(chunks.map(\.chunkID))
    let again = try await ingestor.ingest(file: file, projectID: "p")
    #expect(again.sourceID == source.sourceID)
    #expect(try await workspace.store.loadKnowledgeChunks(projectID: "p", sourceID: again.sourceID) == chunks)
    try Data("更新的文件".utf8).write(to: file)
    let updated = try await ingestor.ingest(file: file, projectID: "p")
    #expect(updated.sourceID == again.sourceID && updated.contentSHA256 != again.contentSHA256)
    let fresh = try await workspace.store.loadKnowledgeChunks(projectID: "p", sourceID: updated.sourceID)
    #expect(oldIDs.isDisjoint(with: fresh.map(\.chunkID)))
}

@Test func rejectsOversizeFileAndStringAndInvalidEncodingBeforeWriting() async throws {
    let workspace = try await KnowledgeWorkspace()
    defer { workspace.remove() }
    let ingestor = KnowledgeIngestor(store: workspace.store, maxBytes: 6)
    let file = workspace.root.appendingPathComponent("notes.txt")
    try Data("一二三".utf8).write(to: file)
    await #expect(throws: KnowledgeError.inputTooLarge) { try await ingestor.ingest(file: file, projectID: "p") }
    await #expect(throws: KnowledgeError.inputTooLarge) { try await ingestor.ingest(text: "一二三", projectID: "p", title: "a") }
    try Data([0xff]).write(to: file)
    await #expect(throws: KnowledgeError.invalidUTF8) { try await ingestor.ingest(file: file, projectID: "p") }
    let invalid = KnowledgeIngestor(store: workspace.store, maxChars: 4, overlap: 4)
    await #expect(throws: KnowledgeError.invalidConfiguration) { try await invalid.ingest(text: "a", projectID: "p", title: "a") }
    #expect(try await workspace.store.listKnowledgeSources(projectID: "p").isEmpty)
    _ = try await ingestor.ingest(text: "一二", projectID: "p", title: "边界")
}

@Test func rankedSearchCombinesFTSAndSubstringEvidenceWithStableTies() async throws {
    let workspace = try await KnowledgeWorkspace()
    defer { workspace.remove() }
    let ingestor = KnowledgeIngestor(store: workspace.store)
    let retriever = KnowledgeRetriever(store: workspace.store)
    let body = String(repeating: "前言。", count: 60) + "团队研究量子计算纠错。"
    for (id, text) in [("q2", body), ("q1", body), ("d", "量子山上的计算机。"), ("t", "游人沿小径抵达山神庙。"),
                       ("e", "Quantum algorithms use an interferometer."), ("x", "明日登山。")] {
        try await ingestor.ingest(text: text, projectID: "p", title: id, sourceID: id, ingestedAt: Date(timeIntervalSince1970: 0))
    }
    for (query, expected) in [("山神庙", "t"), ("INTERFEROMETER", "e"), ("量子计算", "q1")] {
        let hit = try #require(try await retriever.search(projectID: "p", query: query, limit: 1).first)
        #expect(hit.chunk.sourceID == expected && hit.sourceTitle == expected)
        #expect(hit.ingestedAtISO8601 == "1970-01-01T00:00:00Z")
        #expect(hit.snippet.localizedCaseInsensitiveContains(query))
    }
    let mixed = try await retriever.search(projectID: "p", query: "量子计算 interferometer")
    #expect(mixed.prefix(2).map(\.chunk.sourceID) == ["q1", "q2"])
    #expect(mixed.contains { $0.chunk.sourceID == "e" })
    #expect(try await retriever.search(projectID: "p", query: "量子计算 interferometer") == mixed)
    #expect(try await retriever.search(projectID: "p", query: "!!!").isEmpty)
    #expect(try await retriever.search(projectID: "p", query: "量子", limit: 0).isEmpty)
}
