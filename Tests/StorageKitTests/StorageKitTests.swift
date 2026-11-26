import AudioCore
import Foundation
import SQLite3
import StorageKit
import Testing

private let instant = Date(timeIntervalSince1970: 1_700_000_000)
private let stamp = instant.formatted(.iso8601)
private let projectID = "project"

private struct Workspace {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store: SQLiteWorkspaceStore

    init() async throws {
        store = try SQLiteWorkspaceStore(rootDirectory: root)
        try await store.saveProject(.init(projectID: projectID, name: "工作区", createdAtISO8601: stamp))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func node(_ id: String, job: String = "job", priority: TaskPriority = .background,
                  attempts: Int = 3, created: String = stamp) -> JobNodeRecord {
    JobNodeRecord(nodeID: id, jobID: job, kind: "synthesize", priority: priority, inputFingerprint: "fp-\(id)",
                  maxAttempts: attempts, createdAtISO8601: created)
}

private func job(_ id: String = "job") -> JobRecord {
    JobRecord(jobID: id, projectID: projectID, workflowKind: "book", createdAtISO8601: stamp)
}

private func commit(_ store: SQLiteWorkspaceStore, _ bytes: Data, kind: AssetKind = .segmentWAV,
                    segment: String = "speech") async throws -> AssetRecord {
    try await store.commitBytes(bytes, projectID: projectID, kind: kind, fileExtension: "wav",
                                sampleRate: 24_000, frameCount: bytes.count, provenance: .init(segmentID: segment))
}

func sqlite(_ file: URL, _ sql: String) throws -> [String] {
    var handle: OpaquePointer?
    guard sqlite3_open(file.path, &handle) == SQLITE_OK else { throw WorkflowStoreError.storageFailure("Open failed") }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw WorkflowStoreError.storageFailure("Prepare failed")
    }
    defer { sqlite3_finalize(statement) }
    var values = [String]()
    while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: values.append(String(cString: sqlite3_column_text(statement, 0)))
        case SQLITE_DONE: return values
        default: throw WorkflowStoreError.storageFailure("Query failed")
        }
    }
}

@Suite("SQLite workspace")
struct StorageKitTests {
    @Test func migrationsAndDocumentsSurviveReopening() async throws {
        let workspace = try await Workspace()
        defer { workspace.remove() }
        let store = workspace.store
        let file = workspace.root.appendingPathComponent("sonook.sqlite")
        #expect(try sqlite(file, "PRAGMA journal_mode") == ["wal"])
        #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == ["1", "2", "3", "4", "5"])
        #expect(Set(try sqlite(file, "SELECT name FROM pragma_table_list WHERE schema='main' AND type IN ('table','virtual') AND name NOT LIKE 'sqlite_%'")) == [
            "schema_migrations", "projects", "models", "voice_catalogs", "scripts", "assets", "jobs", "job_nodes", "job_edges",
            "source_documents", "chapters", "segment_approvals", "chapter_memories",
            "soundscape_plans", "knowledge_sources", "knowledge_chunks", "knowledge_chunks_fts", "podcast_plans",
            "published_releases", "pairing_challenges", "paired_devices", "playback_events", "playback_cursors", "interactions"
        ])
        let project = ProjectRecord(projectID: projectID, name: "录音室 '一'\u{0}号", projectType: .audioDrama,
                                    options: .init(ambientAudioEnabled: true, ambientTrack: .init(presetName: "rain")),
                                    createdAtISO8601: stamp)
        try await store.saveProject(project)
        var model = ModelRegistryEntry(modelID: "声模", kind: .tts, providerID: "test", localPath: "models/speech",
                                       revision: "r2", license: "test", estimatedPeakBytes: 4096, registeredAtISO8601: stamp)
        try await store.upsertModel(model)
        try await store.updateMeasuredPeakBytes(modelID: model.modelID, peakBytes: UInt64.max)
        model.measuredPeakBytes = UInt64.max
        let audition = try await commit(store, Data([1, 2]), kind: .voiceAudition)
        let anchor = VoiceTimbreAnchor(anchorID: "anchor", assetID: audition.assetID, fileSHA256: audition.fileSHA256,
                                      generatorProviderID: "fake", generatorModelID: model.modelID, designPrompt: "轻声",
                                      auditionText: "走吧。", sampleRate: 24_000, createdAtISO8601: stamp)
        let stage = VoiceDeliveryStage(stageID: "later", effectiveFromChapter: 20, stageLabel: "沉稳",
                                       deliveryBaseline: "放慢语速", speakingRate: 0.94, evidence: "第二十章")
        let catalog = CharacterVoiceCatalog(projectID: projectID, cards: [
            .init(characterID: "hero", canonicalName: "阿沐", aliases: ["小沐"], timbreAnchor: anchor, deliveryStages: [stage])
        ])
        try await store.saveCatalog(catalog)
        let speech = "走吧。"
        let segment = ScriptSegment(segmentID: "s1", chapterID: "c1", sourceDocumentRevision: "r2",
                                    sourceSpan: try SourceSpan(start: 0, endExclusive: speech.utf8.count),
                                    sourceText: speech, spokenText: speech, speakerID: "hero", voiceProfileRevision: "1",
                                    scriptRevision: 4, attributionEvidence: ["说话人自述"])
        let script = ScriptDocument(chapterID: "c1", sourceDocumentRevision: "r2", scriptRevision: 4, segments: [segment])
        try await store.saveScript(script, projectID: projectID)
        try await store.createJob(job(), nodes: [node("n")], edges: [])
        let reopened = try SQLiteWorkspaceStore(rootDirectory: workspace.root)
        #expect(try await reopened.project(id: projectID) == project)
        #expect(try await reopened.listProjects() == [project])
        #expect(try await reopened.model(id: model.modelID) == model)
        #expect(try await reopened.listModels(kind: .asr).isEmpty)
        #expect(try await reopened.listModels(kind: nil) == [model])
        #expect(try await reopened.loadCatalog(projectID: projectID) == catalog)
        #expect(try await reopened.loadScript(projectID: projectID, chapterID: "c1") == script)
        #expect(try await reopened.asset(id: audition.assetID) == audition)
        #expect(try await reopened.listJobs(projectID: projectID) == [job()])
        #expect(try await reopened.jobSnapshot(jobID: "job")?.nodes == [node("n")])
        #expect(try sqlite(file, "SELECT version FROM schema_migrations ORDER BY version") == ["1", "2", "3", "4", "5"])
    }

    @Test func sharedBytesKeepSeparateProvenanceAndReconciliationPreservesEveryReference() async throws {
        let workspace = try await Workspace()
        defer { workspace.remove() }
        let store = workspace.store
        let bytes = Data("abc".utf8)
        let speech = try await commit(store, bytes)
        let duplicate = try await commit(store, bytes, segment: "second")
        #expect(speech.fileSHA256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(speech.relativePath == "assets/segment_wav/\(speech.fileSHA256).wav")
        #expect(speech.assetID != duplicate.assetID && duplicate.relativePath == speech.relativePath)
        #expect(speech.provenance != duplicate.provenance && speech.byteSize == 3)
        let audition = try await commit(store, Data([4]), kind: .voiceAudition)
        let review = try await commit(store, Data([5]))
        var goodNode = node("verified")
        goodNode.status = .completed
        goodNode.outputAssetID = speech.assetID
        var reviewNode = node("review")
        reviewNode.status = .needsReview
        reviewNode.outputAssetID = review.assetID
        try await store.createJob(job(), nodes: [goodNode, reviewNode], edges: [])
        let bad = try await commit(store, Data([9]))
        let absent = try await commit(store, Data([8]))
        try Data([7]).write(to: try await store.resolveFileURL(for: bad.assetID))
        try FileManager.default.removeItem(at: try await store.resolveFileURL(for: absent.assetID))
        for record in [bad, absent] {
            #expect(try await !store.verifyAssetIntegrity(assetID: record.assetID))
            await #expect(throws: WorkflowStoreError.assetIntegrityFailure(assetID: record.assetID, reason: "Missing or damaged asset")) {
                try await store.readVerifiedData(for: record.assetID)
            }
        }
        await #expect(throws: WorkflowStoreError.self) { try await commit(store, Data([9])) }
        await #expect(throws: WorkflowStoreError.self) {
            try await store.commitBytes(bytes, projectID: projectID, kind: .segmentWAV, fileExtension: "../escape",
                                        sampleRate: nil, frameCount: nil, provenance: .init())
        }
        let orphan = workspace.root.appendingPathComponent("assets/segment_wav/.orphan")
        // Inject failure after atomic publish and before the database gains a reference.
        await #expect(throws: WorkflowStoreError.self) {
            try await store.commitBytes(Data([6]), projectID: "absent-project", kind: .qualityReport, fileExtension: "bin",
                                        sampleRate: nil, frameCount: nil, provenance: .init())
        }
        let temp = workspace.root.appendingPathComponent(".tmp/interrupted.tmp")
        try bytes.write(to: orphan)
        try bytes.write(to: temp)
        let outside = workspace.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("assets/alias"), withDestinationURL: outside)
        let report = try await store.runStartupReconciliation()
        #expect(report == OrphanGCReport(removedTempFiles: 1, removedOrphanAssets: 3,
                                        missingReferencedAssetIDs: [absent.assetID], corruptedAssetIDs: [bad.assetID]))
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        for record in [speech, duplicate, review, audition] {
            #expect(try await store.verifyAssetIntegrity(assetID: record.assetID))
        }
        #expect(try await store.readVerifiedData(for: duplicate.assetID) == bytes)
        #expect(try await store.runStartupReconciliation().removedOrphanAssets == 0)
    }

    @Test func simultaneousPublicationAndGCWithIndependentConnections() async throws {
        let workspace = try await Workspace()
        defer { workspace.remove() }
        let second = try SQLiteWorkspaceStore(rootDirectory: workspace.root)
        let gc = try SQLiteWorkspaceStore(rootDirectory: workspace.root)
        let bytes = Data(repeating: 7, count: 131_072)
        let records = try await withThrowingTaskGroup(of: AssetRecord?.self) { group in
            for index in 0..<8 {
                let writer = index.isMultiple(of: 2) ? workspace.store : second
                group.addTask { try await commit(writer, bytes, segment: String(index)) }
                group.addTask {
                    let report = try await gc.runStartupReconciliation()
                    #expect(report == OrphanGCReport())
                    return nil
                }
            }
            var records = [AssetRecord]()
            for try await result in group { if let result { records.append(result) } }
            return records
        }
        #expect(Set(records.map(\.assetID)).count == 8 && Set(records.map(\.relativePath)).count == 1)
        for record in records { #expect(try await second.readVerifiedData(for: record.assetID) == bytes) }
    }

    @Test func competingWorkersAndExpiredGenerations() async throws {
        let workspace = try await Workspace()
        defer { workspace.remove() }
        let first = workspace.store
        let second = try SQLiteWorkspaceStore(rootDirectory: workspace.root)
        try await first.createJob(job(), nodes: [node("only", attempts: 2)], edges: [])
        #expect(try await first.refreshReadyNodes(jobID: "job", now: instant) == 1)
        async let a = first.claimNextReadyNode(jobID: "job", workerID: "A", leaseDurationSeconds: 4, now: instant)
        async let b = second.claimNextReadyNode(jobID: "job", workerID: "B", leaseDurationSeconds: 4, now: instant)
        let winners = try await [a, b].compactMap { $0 }
        #expect(winners.count == 1)
        let old = try #require(winners.first?.lease)
        #expect(old.generation == 1)
        let renewed = try await second.renewLease(old, leaseDurationSeconds: 5, now: instant.addingTimeInterval(1))
        #expect(renewed.generation == 1 && renewed.expiresAtISO8601 != old.expiresAtISO8601)
        #expect(try await first.refreshReadyNodes(jobID: "job", now: instant.addingTimeInterval(4)) == 0)
        let expiry = instant.addingTimeInterval(6)
        #expect(try await first.refreshReadyNodes(jobID: "job", now: expiry) == 1)
        let next = try #require(try await second.claimNextReadyNode(jobID: nil, workerID: old.owner,
                                                                    leaseDurationSeconds: 1, now: expiry))
        #expect(next.lease.generation == 2 && next.node.attemptCount == 2)
        let rejected = WorkflowStoreError.leaseRejected(nodeID: "only", expectedOwner: old.owner, generation: 1)
        await #expect(throws: rejected) { try await first.renewLease(old, leaseDurationSeconds: 5, now: expiry) }
        await #expect(throws: rejected) {
            try await first.commitNodeResult(lease: old, status: .completed, outputAssetID: nil, outputPayloadJSON: nil,
                                             lastError: nil, nextRetryAt: nil, now: expiry)
        }
        #expect(try await first.refreshReadyNodes(jobID: "job", now: expiry.addingTimeInterval(1)) == 0)
        let failed = try #require(try await first.jobSnapshot(jobID: "job")?.nodes.first)
        #expect(failed.status == .failed && failed.leaseGeneration == 2 && failed.leaseOwner == nil)
        #expect(try await first.recomputeJobStatus(jobID: "job", now: expiry).status == .failed)
    }

    @Test func cancellationAndResumeRespectVerifyingLeasesAndExistingCheckpoints() async throws {
        let ws = try await Workspace()
        defer { ws.remove() }
        var verifying = node("quality")
        verifying.status = .verifying
        verifying.leaseGeneration = 3
        verifying.leaseOwner = "previous"
        verifying.leaseExpiresAtISO8601 = instant.addingTimeInterval(5).formatted(.iso8601)
        verifying.attemptCount = 1
        var paused = node("paused")
        paused.status = .paused
        let record = try await commit(ws.store, Data([1, 2]))
        var review = node("listen")
        review.status = .needsReview
        review.outputAssetID = record.assetID
        try await ws.store.createJob(job(), nodes: [verifying, review, paused, node("later")], edges: [])
        #expect(try await ws.store.requestCancel(jobID: "job", now: instant).status == .running)
        #expect(try await ws.store.claimNextReadyNode(jobID: nil, workerID: "other", leaseDurationSeconds: 2, now: instant) == nil)
        let cancelled = try #require(try await ws.store.jobSnapshot(jobID: "job"))
        #expect(cancelled.nodes.first { $0.nodeID == "quality" } == verifying)
        #expect(cancelled.nodes.first { $0.nodeID == "listen" } == review)
        #expect(cancelled.nodes.first { $0.nodeID == "later" }?.status == .cancelled)
        let resumed = try await ws.store.prepareResume(jobID: "job", now: instant)
        #expect(!resumed.cancelRequested && resumed.status == .ready)
        let active = try #require(try await ws.store.jobSnapshot(jobID: "job"))
        #expect(active.nodes.first { $0.nodeID == "quality" } == verifying)
        #expect(active.nodes.first { $0.nodeID == "paused" }?.status == .pending)
        let expiry = instant.addingTimeInterval(5)
        #expect(try await ws.store.refreshReadyNodes(jobID: "job", now: expiry) == 3)
        #expect(try await ws.store.requestCancel(jobID: "job", now: expiry).status == .cancelled)
        #expect(try await ws.store.verifyAssetIntegrity(assetID: record.assetID))
        #expect(try await ws.store.jobSnapshot(jobID: "job")?.nodes.first { $0.nodeID == "listen" } == review)
    }

    @Test func atomicDAGInsertionAndGlobalClaimOrdering() async throws {
        let workspace = try await Workspace()
        defer { workspace.remove() }
        let store = workspace.store
        let edge = JobEdgeRecord(jobID: "job", fromNodeID: "a", toNodeID: "b")
        await #expect(throws: WorkflowStoreError.self) {
            try await store.createJob(job(), nodes: [node("a"), node("b")], edges: [edge, edge])
        }
        #expect(try await store.jobSnapshot(jobID: "job") == nil)
        let later = instant.addingTimeInterval(1).formatted(.iso8601)
        let localNodes = [node("b"), node("a"), node("c", priority: .interactive, created: later),
                          node("e", created: "2024-01-01T00:00:00.000101Z"), node("d", created: "2024-01-01T00:00:00.000102Z")]
        try await store.createJob(job(), nodes: localNodes, edges: [])
        try await store.createJob(job("other"), nodes: [node("z", job: "other", priority: .interactive)], edges: [])
        for id in ["job", "other"] { _ = try await store.refreshReadyNodes(jobID: id, now: instant) }
        var order = [String]()
        for _ in 0..<6 {
            let claim = try #require(try await store.claimNextReadyNode(jobID: nil, workerID: "worker",
                                                                        leaseDurationSeconds: 30, now: instant))
            order.append(claim.node.nodeID)
        }
        #expect(order == ["z", "c", "a", "b", "e", "d"])
    }
}
