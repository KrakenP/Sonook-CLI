import AudioCore
import Foundation
import StorageKit
import Testing

// Snapshot of the shipped v1 layout, independent of the current migrator.
let originalSchema = """
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY);
        INSERT INTO schema_migrations VALUES (1);
        CREATE TABLE projects(project_id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL);
        CREATE TABLE models(model_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE voice_catalogs(project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects, document TEXT NOT NULL);
        CREATE TABLE scripts(project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL,
                            document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id));
        CREATE TABLE assets(asset_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects,
                            relative_path TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE jobs(
            job_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects, workflow_kind TEXT NOT NULL,
            status TEXT NOT NULL, priority INTEGER NOT NULL, cancel_requested INTEGER NOT NULL,
            config_json TEXT NOT NULL, summary TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE job_nodes(
            job_id TEXT NOT NULL REFERENCES jobs, node_id TEXT NOT NULL, kind TEXT NOT NULL,
            status TEXT NOT NULL, priority INTEGER NOT NULL, input_fingerprint TEXT NOT NULL, payload_json TEXT NOT NULL,
            attempt_count INTEGER NOT NULL, max_attempts INTEGER NOT NULL, next_retry_at TEXT, lease_owner TEXT,
            lease_generation INTEGER NOT NULL, lease_expires_at TEXT, output_asset_id TEXT REFERENCES assets,
            output_payload_json TEXT, last_error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY(job_id, node_id)
        );
        CREATE TABLE job_edges(
            job_id TEXT NOT NULL, from_node_id TEXT NOT NULL, to_node_id TEXT NOT NULL, requires_verified INTEGER NOT NULL,
            PRIMARY KEY(job_id, from_node_id, to_node_id),
            FOREIGN KEY(job_id, from_node_id) REFERENCES job_nodes(job_id, node_id),
            FOREIGN KEY(job_id, to_node_id) REFERENCES job_nodes(job_id, node_id)
        );
        CREATE INDEX nodes_by_status ON job_nodes(job_id, status, priority DESC, created_at, node_id);
        CREATE INDEX incoming_edges ON job_edges(job_id, to_node_id);
        """

func source(_ revision: String, at timestamp: String, count: Int) -> SourceDocumentRecord {
    .init(sourceDocumentRevision: revision, projectID: "p", format: .txt, originalFileName: "sample.txt", rawAssetID: "raw",
          rawSHA256: "a", normalizedAssetID: "normalized", normalizedSHA256: "b", detectedEncoding: "utf-8",
          totalUTF8Bytes: 12, chapterCount: count, importedAtISO8601: timestamp)
}

func chapter(_ id: String, number: Int, revision: String) throws -> ChapterRecord {
    .init(projectID: "p", chapterID: id, chapterNumber: number, title: "章节", sourceDocumentRevision: revision,
          sourceSpan: try .init(start: 0, endExclusive: 12))
}

func sqlDocument(_ value: some Encodable) throws -> String {
    "'" + String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "'", with: "''") + "'"
}

@Test func upgradePopulatedV1ThenReopenSourceCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sonook.sqlite")
    for statement in originalSchema.split(separator: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try sqlite(file, String(statement))
    }
    let project = ProjectRecord(projectID: "p", name: "旧项目", createdAtISO8601: "t")
    let model = ModelRegistryEntry(modelID: "m", kind: .tts, providerID: "local", localPath: "model", estimatedPeakBytes: 0, registeredAtISO8601: "t")
    let catalog = CharacterVoiceCatalog(projectID: "p", cards: [.init(characterID: "c", canonicalName: "小河")])
    let script = ScriptDocument(chapterID: "old", sourceDocumentRevision: "v1", scriptRevision: 3, segments: [])
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let asset = AssetRecord(assetID: "a", projectID: "p", kind: .sourceDocument, relativePath: "assets/source_document/\(digest).txt",
                            fileExtension: "txt", fileSHA256: digest, byteSize: 3, createdAtISO8601: "t")
    let oldFile = root.appendingPathComponent(asset.relativePath)
    try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("abc".utf8)
    try bytes.write(to: oldFile)
    let job = JobRecord(jobID: "j", projectID: "p", workflowKind: "book", createdAtISO8601: "t")
    _ = try sqlite(file, "INSERT INTO projects VALUES('p',\(sqlDocument(project)))")
    _ = try sqlite(file, "INSERT INTO models VALUES('m','tts',\(sqlDocument(model)))")
    _ = try sqlite(file, "INSERT INTO voice_catalogs VALUES('p',\(sqlDocument(catalog)))")
    _ = try sqlite(file, "INSERT INTO scripts VALUES('p','old',\(sqlDocument(script)))")
    _ = try sqlite(file, "INSERT INTO assets VALUES('a','p','\(asset.relativePath)',\(sqlDocument(asset)))")
    _ = try sqlite(file, "INSERT INTO jobs VALUES('j','p','book','pending',0,0,'{}',NULL,'t','t')")
    for id in ["one", "two"] {
        _ = try sqlite(file, "INSERT INTO job_nodes VALUES('j','\(id)','speak','completed',0,'fp','{}',1,2,NULL,NULL,1,NULL,'a',NULL,NULL,'t','t')")
    }
    _ = try sqlite(file, "INSERT INTO job_edges VALUES('j','one','two',1)")
    #expect(try sqlite(file, "SELECT version FROM schema_migrations") == ["1"])

    let document = source("r2", at: "2026-01-01", count: 1)
    let first = try chapter("first", number: 1, revision: "r2")
    let approval = SegmentApprovalRecord(projectID: "p", chapterID: "first", segmentID: "s", approvedAssetID: "a",
                                        reviewerNote: "已听", approvedAtISO8601: "t")
    do {
        let migrated = try SQLiteWorkspaceStore(rootDirectory: root)
        #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == ["1", "2", "3", "4", "5"])
        #expect(try await migrated.listProjects() == [project])
        #expect(try await migrated.model(id: "m") == model)
        #expect(try await migrated.loadCatalog(projectID: "p") == catalog)
        #expect(try await migrated.listScripts(projectID: "p") == [script])
        #expect(try await migrated.asset(id: "a") == asset)
        #expect(try await migrated.readVerifiedData(for: "a") == bytes)
        let snapshot = try #require(try await migrated.jobSnapshot(jobID: "j"))
        #expect(snapshot.job == job && snapshot.nodes.map(\.nodeID) == ["one", "two"])
        #expect(snapshot.nodes.allSatisfy { $0.status == .completed && $0.outputAssetID == "a" })
        #expect(snapshot.edges == [.init(jobID: "j", fromNodeID: "one", toNodeID: "two", requiresVerified: true)])
        #expect(try await migrated.listChapters(projectID: "p", sourceDocumentRevision: nil).isEmpty)
        try await migrated.saveSourceDocument(document, chapters: [first])
        try await migrated.saveSegmentApproval(approval)
    }
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.latestSourceDocument(projectID: "p") == document)
    #expect(try await reopened.chapter(projectID: "p", chapterID: "first") == first)
    #expect(try await reopened.segmentApprovals(projectID: "p", chapterID: "first") == [approval])
}

@Test func revisionOrderingAtomicReplacementAndSegmentLookup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    try await store.saveProject(.init(projectID: "p", name: "索引", createdAtISO8601: "t"))
    let old = try chapter("old", number: 1, revision: "a")
    try await store.saveSourceDocument(source("a", at: "2026", count: 1), chapters: [old])
    let doc = source("b", at: "2026", count: 3)
    let a = try chapter("a", number: 2, revision: "b")
    let b = try chapter("b", number: 2, revision: "b")
    let z = try chapter("z", number: 1, revision: "b")
    try await store.saveSourceDocument(doc, chapters: [b,a,z])
    try await store.saveSourceDocument(source("zz", at: "2025", count: 0), chapters: [])
    #expect(try await store.chapter(projectID: "p", chapterID: "old") == nil)
    #expect(try await store.listChapters(projectID: "p", sourceDocumentRevision: "a") == [old])
    await #expect(throws: WorkflowStoreError.self) { try await store.saveSourceDocument(source("b", at: "2027", count: 2), chapters: [a,a]) }
    #expect(try await store.latestSourceDocument(projectID: "p") == doc)
    #expect(try await store.listChapters(projectID: "p", sourceDocumentRevision: nil) == [z,a,b])
    try await store.saveSourceDocument(source("b", at: "2026", count: 1), chapters: [a])
    #expect(try await store.listChapters(projectID: "p", sourceDocumentRevision: nil) == [a])
    for (segment, asset) in [("b","1"),("a","2"),("b","3")] {
        try await store.saveSegmentApproval(.init(projectID: "p", chapterID: "z", segmentID: segment, approvedAssetID: asset,
                                                  reviewerNote: "", approvedAtISO8601: "t"))
    }
    #expect(try await store.segmentApprovals(projectID: "p", chapterID: "z").map(\.approvedAssetID) == ["2","3"])
    for c in [b,a] {
        let segment = ScriptSegment(segmentID: c.chapterID + "_seg_0001", chapterID: c.chapterID, sourceDocumentRevision: "b",
                                    sourceSpan: c.sourceSpan, sourceText: "正文", spokenText: "正文", speakerID: "n",
                                    voiceProfileRevision: "n1", scriptRevision: 1)
        try await store.saveScript(.init(chapterID: c.chapterID, sourceDocumentRevision: "b", scriptRevision: 1, segments: [segment]), projectID: "p")
    }
    #expect(try await store.listScripts(projectID: "p").map(\.chapterID) == ["a","b"])
    #expect(try await store.locateSegment(projectID: "p", segmentID: "b_seg_0001")?.chapterID == "b")
    #expect(try await store.locateSegment(projectID: "p", segmentID: "missing") == nil)
}
