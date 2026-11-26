import AudioCore
import Foundation
import StorageKit
import Testing

@Test(arguments: [[99], [1, 3], [1, 2, 3, 99]])
func unknownVersionIsExplicitlyRejected(_ versions: [Int]) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sonook.sqlite")
    _ = try sqlite(file, "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY)")
    for version in versions { _ = try sqlite(file, "INSERT INTO schema_migrations VALUES(\(version))") }
    #expect(throws: WorkflowStoreError.storageFailure("Unsupported workspace schema")) {
        try SQLiteWorkspaceStore(rootDirectory: root)
    }
    #expect(try sqlite(file, "SELECT version FROM schema_migrations") == versions.map(String.init))
}

// v2 added these three tables to the shipped v1 schema.
private let historicalV2 = """
    CREATE TABLE source_documents(project_id TEXT NOT NULL REFERENCES projects, source_document_revision TEXT NOT NULL,
        imported_at TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, source_document_revision));
    CREATE TABLE chapters(project_id TEXT NOT NULL REFERENCES projects, source_document_revision TEXT NOT NULL,
        chapter_id TEXT NOT NULL, chapter_number INTEGER NOT NULL, document TEXT NOT NULL,
        PRIMARY KEY(project_id, source_document_revision, chapter_id));
    CREATE TABLE segment_approvals(project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL,
        segment_id TEXT NOT NULL, approved_asset_id TEXT NOT NULL, document TEXT NOT NULL,
        PRIMARY KEY(project_id, chapter_id, segment_id));
    CREATE INDEX newest_source ON source_documents(project_id, imported_at DESC, source_document_revision DESC);
    CREATE INDEX ordered_chapters ON chapters(project_id, source_document_revision, chapter_number, chapter_id);
    """

private func memory(_ number: Int, _ id: String, project: String = "p") -> ChapterMemoryRecord {
    .init(projectID: project, chapterID: id, chapterNumber: number, sourceDocumentRevision: "r1",
          summary: "第\(number)章", activeCharacterIDs: ["n"], createdAtISO8601: "t")
}

@Test(arguments: [[1], [1, 2], [2], [1, 2, 3], [2, 3], [3], [1, 2, 3, 4], [4]])
func historicalDataSurvivesSequentialUpgrade(_ versions: [Int]) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sonook.sqlite")
    let hadV4 = versions.contains(4)
    let hadV3 = versions.contains(3) || hadV4
    let hadV2 = versions.contains(2) || hadV3
    let schema = originalSchema + (hadV2 ? historicalV2 : "")
    for statement in schema.split(separator: ";") {
        _ = try sqlite(file, String(statement))
    }
    let project = ProjectRecord(projectID: "p", name: "旧项目", createdAtISO8601: "t")
    let job = JobRecord(jobID: "j", projectID: "p", workflowKind: "book", createdAtISO8601: "t")
    _ = try sqlite(file, "INSERT INTO projects VALUES('p',\(sqlDocument(project)))")
    _ = try sqlite(file, "INSERT INTO jobs VALUES('j','p','book','pending',0,0,'{}',NULL,'t','t')")
    let document = source("r1", at: "t", count: 1)
    let first = try chapter("first", number: 1, revision: "r1")
    let approval = SegmentApprovalRecord(projectID: "p", chapterID: "first", segmentID: "s", approvedAssetID: "a",
                                        reviewerNote: "已听", approvedAtISO8601: "t")
    if hadV2 {
        _ = try sqlite(file, "INSERT INTO schema_migrations VALUES(2)")
        _ = try sqlite(file, "INSERT INTO source_documents VALUES('p','r1','t',\(sqlDocument(document)))")
        _ = try sqlite(file, "INSERT INTO chapters VALUES('p','r1','first',1,\(sqlDocument(first)))")
        _ = try sqlite(file, "INSERT INTO segment_approvals VALUES('p','first','s','a',\(sqlDocument(approval)))")
    }
    let record = memory(1, "first")
    if hadV3 {
        _ = try sqlite(file, """
            CREATE TABLE chapter_memories(project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL,
                chapter_number INTEGER NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id))
            """)
        _ = try sqlite(file, "CREATE INDEX chapter_memories_by_number ON chapter_memories(project_id, chapter_number, chapter_id)")
        _ = try sqlite(file, "INSERT INTO chapter_memories VALUES('p','first',1,\(sqlDocument(record)))")
        _ = try sqlite(file, "INSERT INTO schema_migrations VALUES(3)")
    }
    if hadV4 {
        let snapshot = """
            CREATE TABLE soundscape_plans(project_id TEXT NOT NULL, chapter_id TEXT NOT NULL,
                document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id));
            CREATE TABLE knowledge_sources(project_id TEXT NOT NULL, source_id TEXT NOT NULL,
                document TEXT NOT NULL, PRIMARY KEY(project_id, source_id));
            CREATE TABLE knowledge_chunks(project_id TEXT NOT NULL, source_id TEXT NOT NULL, chunk_id TEXT NOT NULL,
                sequence_index INTEGER NOT NULL, text TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, chunk_id));
            CREATE INDEX chunks_by_source ON knowledge_chunks(project_id, source_id, sequence_index);
            CREATE VIRTUAL TABLE knowledge_chunks_fts USING fts5(chunk_id UNINDEXED, project_id UNINDEXED,
                source_id UNINDEXED, text, tokenize='unicode61');
            CREATE TABLE podcast_plans(project_id TEXT NOT NULL, episode_id TEXT NOT NULL,
                document TEXT NOT NULL, PRIMARY KEY(project_id, episode_id));
            INSERT INTO soundscape_plans VALUES('p','first','sound');
            INSERT INTO knowledge_sources VALUES('p','s','source');
            INSERT INTO knowledge_chunks VALUES('p','s','chunk',1,'survives','chunk');
            INSERT INTO knowledge_chunks_fts VALUES('chunk','p','s','survives');
            INSERT INTO podcast_plans VALUES('p','episode','podcast');
            INSERT INTO schema_migrations VALUES(4);
            """
        for statement in snapshot.split(separator: ";") { _ = try sqlite(file, String(statement)) }
    }
    let earliest = try #require(versions.first)
    _ = try sqlite(file, "DELETE FROM schema_migrations WHERE version<\(earliest)")
    // Fail on the last v5 index, after every pending migration has run.
    _ = try sqlite(file, "CREATE INDEX interactions_by_project ON projects(project_id)")
    let objects = "SELECT name FROM sqlite_master ORDER BY name"
    let before = try sqlite(file, objects)
    #expect(throws: WorkflowStoreError.self) { try SQLiteWorkspaceStore(rootDirectory: root) }
    #expect(try sqlite(file, objects) == before)
    #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == versions.map(String.init))
    _ = try sqlite(file, "DROP INDEX interactions_by_project")
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    let expectedVersions = (earliest...StorageKitInfo.schemaVersion).map(String.init)
    #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == expectedVersions)
    #expect(try await store.project(id: "p") == project)
    #expect(try await store.jobSnapshot(jobID: "j")?.job == job)
    #expect(try await store.latestSourceDocument(projectID: "p") == (hadV2 ? document : nil))
    #expect(try await store.listChapters(projectID: "p", sourceDocumentRevision: nil) == (hadV2 ? [first] : []))
    #expect(try await store.segmentApprovals(projectID: "p", chapterID: "first") == (hadV2 ? [approval] : []))
    #expect(try await store.chapterMemory(projectID: "p", chapterID: "first") == (hadV3 ? record : nil))
    if hadV4 {
        for (table, value) in [("soundscape_plans", "sound"), ("knowledge_sources", "source"),
                               ("knowledge_chunks", "chunk"), ("podcast_plans", "podcast")] {
            #expect(try sqlite(file, "SELECT document FROM \(table)") == [value])
        }
        #expect(try sqlite(file, "SELECT chunk_id FROM knowledge_chunks_fts WHERE knowledge_chunks_fts MATCH 'survives'") == ["chunk"])
    }
    try await store.saveChapterMemory(record)
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.chapterMemory(projectID: "p", chapterID: "first") == record)
}

@Test func freshWorkspaceUpsertsAndReadsOnlyTheAllowedChapters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(StorageKitInfo.schemaVersion == 5)
    for project in ["p", "other"] {
        try await store.saveProject(.init(projectID: project, name: project, createdAtISO8601: "t"))
    }
    let first = memory(1, "z"), a = memory(3, "a"), b = memory(3, "b"), future = memory(10, "later")
    for record in [future, b, memory(2, "moved"), a, first, memory(1, "z", project: "other"), memory(4, "moved")] {
        try await store.saveChapterMemory(record)
    }
    let file = root.appendingPathComponent("sonook.sqlite")
    // An unreadable future document proves the boundary is applied before JSON decoding.
    _ = try sqlite(file, "UPDATE chapter_memories SET document='invalid' WHERE chapter_id='later'")
    _ = try sqlite(file, "DELETE FROM schema_migrations WHERE version<3")
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.chapterMemoriesUpTo(projectID: "p", maxChapterNumber: 3) == [first, a, b])
    #expect(try await reopened.chapterMemoriesUpTo(projectID: "p", maxChapterNumber: 0).isEmpty)
    #expect(try await reopened.chapterMemory(projectID: "p", chapterID: "moved") == memory(4, "moved"))
    #expect(try await reopened.chapterMemory(projectID: "other", chapterID: "moved") == nil)
}

@Test func failedV3MigrationRollsBackV2BeforeRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sonook.sqlite")
    for statement in originalSchema.split(separator: ";") { _ = try sqlite(file, String(statement)) }
    _ = try sqlite(file, "CREATE INDEX chapter_memories_by_number ON projects(project_id)")
    #expect(throws: WorkflowStoreError.self) { try SQLiteWorkspaceStore(rootDirectory: root) }
    #expect(try sqlite(file, "SELECT version FROM schema_migrations") == ["1"])
    #expect(try sqlite(file, "SELECT name FROM sqlite_master WHERE name IN ('source_documents','chapter_memories')").isEmpty)
    _ = try sqlite(file, "DROP INDEX chapter_memories_by_number")
    _ = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == ["1", "2", "3", "4", "5"])
}

@Test func listAssetsFiltersProjectAndKind() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    func add(_ project: String, _ kind: AssetKind) async throws -> AssetRecord {
        try await store.commitBytes(Data([1]), projectID: project, kind: kind, fileExtension: "bin",
                                    sampleRate: nil, frameCount: nil, provenance: .init())
    }
    for project in ["p", "other"] {
        try await store.saveProject(.init(projectID: project, name: project, createdAtISO8601: "t"))
    }
    let speech = try await add("p", .segmentWAV)
    let report = try await add("p", .qualityReport)
    let other = try await add("other", .segmentWAV)
    #expect(Set(try await store.listAssets(projectID: "p", kind: nil).map(\.assetID)) == [speech.assetID, report.assetID])
    #expect(try await store.listAssets(projectID: "p", kind: .segmentWAV) == [speech])
    #expect(try await store.listAssets(projectID: "other", kind: .segmentWAV) == [other])
    #expect(try await store.listAssets(projectID: "other", kind: .qualityReport).isEmpty)
}
