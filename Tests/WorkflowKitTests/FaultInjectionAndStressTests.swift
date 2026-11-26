import AudioCore
import Darwin
import Foundation
import StorageKit
import Testing
import WorkflowKit

private func synthesize(_ text: String, with provider: SpeechProvider) async throws -> Data {
    let audio = try await provider.synthesize(.init(text: text))
    return wave(Data(audio.pcmSamples.map { UInt8($0 * 128 + 128) }))
}

private func segmentExecutor(store: SQLiteWorkspaceStore, provider: SpeechProvider, segments: [String: ScriptSegment],
                             retryOnce: Set<String> = [], cancelAt: String? = nil) -> RecordingExecutor {
    RecordingExecutor { node in
        if retryOnce.contains(node.nodeID), node.attemptCount == 1 { throw NodeExecutionError.retryable("暂时不可用") }
        let segment = try #require(segments[node.nodeID])
        let bytes = try await synthesize(segment.spokenText, with: provider)
        let asset = try await store.commitBytes(bytes, projectID: "book", kind: .segmentWAV, fileExtension: "wav",
                                               sampleRate: 8000, frameCount: segment.spokenText.utf8.count,
                                               provenance: .init(sourceDocumentRevision: "r1", chapterID: segment.chapterID,
                                                                 segmentID: segment.segmentID, providerID: "fake"))
        if node.nodeID == cancelAt { _ = try await store.requestCancel(jobID: node.jobID, now: Date()) }
        return .completed(outputAssetID: asset.assetID, outputPayloadJSON: nil)
    }
}

// Persist a real chapter index and one ordered synthesis chain per chapter.
private func createBook(_ ws: WorkflowWorkspace, chapters count: Int, segmentsPerChapter: Int) async throws -> [ScriptSegment] {
    var source = Data()
    var chapters = [ChapterRecord]()
    var segments = [ScriptSegment]()
    var edges = [(String, String, Bool)]()
    for number in 1...count {
        let start = source.count
        let chapterID = String(format: "ch_%03ld", number)
        var lines = [ScriptSegment]()
        for index in 1...segmentsPerChapter {
            let id = chapterID + String(format: "_seg_%04ld", index)
            let text = "第\(number)章第\(index)句。"
            let span = try SourceSpan(start: source.count, endExclusive: source.count + text.utf8.count)
            source.append(contentsOf: text.utf8)
            if let previous = lines.last { edges.append((previous.segmentID, id, true)) }
            lines.append(.init(segmentID: id, chapterID: chapterID, sourceDocumentRevision: "r1",
                               sourceSpan: span, sourceText: text, spokenText: text, speakerID: "char_narrator",
                               voiceProfileRevision: "1", scriptRevision: 1))
        }
        try await ws.store.saveScript(.init(chapterID: chapterID, sourceDocumentRevision: "r1", scriptRevision: 1, segments: lines),
                                      projectID: "book")
        segments += lines
        chapters.append(.init(projectID: "book", chapterID: chapterID, chapterNumber: number, title: "第\(number)章",
                              sourceDocumentRevision: "r1", sourceSpan: try .init(start: start, endExclusive: source.count)))
    }
    let raw = try await ws.store.commitBytes(source, projectID: "book", kind: .sourceDocument, fileExtension: "txt",
                                             sampleRate: nil, frameCount: nil, provenance: .init(sourceDocumentRevision: "r1"))
    try await ws.store.saveSourceDocument(.init(sourceDocumentRevision: "r1", projectID: "book", format: .txt,
                                                originalFileName: "sample.txt", rawAssetID: raw.assetID, rawSHA256: raw.fileSHA256,
                                                normalizedAssetID: raw.assetID, normalizedSHA256: raw.fileSHA256, detectedEncoding: "utf-8",
                                                totalUTF8Bytes: source.count, chapterCount: count, importedAtISO8601: ws.stamp), chapters: chapters)
    try await ws.create(ids: segments.map(\.segmentID), edges: edges)
    return segments
}

@Suite("Long-form workflow reliability")
struct FaultInjectionAndStressTests {
    @Test func killedLeaseHolderCannotOverwriteRecoveredWAV() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["speech"])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await ws.store.refreshReadyNodes(jobID: "job", now: now)
        setenv("SONOOK_EXIT_TEST_ROOT", ws.root.path, 1)
        defer { unsetenv("SONOOK_EXIT_TEST_ROOT") }
        try await #require(processExitsWith: .signal(SIGKILL)) {
            let rootPath = try #require(ProcessInfo.processInfo.environment["SONOOK_EXIT_TEST_ROOT"])
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let worker = try SQLiteWorkspaceStore(rootDirectory: root)
            let claim = try #require(try await worker.claimNextReadyNode(jobID: "job", workerID: "A", leaseDurationSeconds: 2, now: now))
            try JSONEncoder().encode(claim.lease).write(to: root.appendingPathComponent("old-lease.json"))
            raise(SIGKILL)
        }
        let old = try JSONDecoder().decode(NodeLease.self, from: Data(contentsOf: ws.root.appendingPathComponent("old-lease.json")))
        let peer = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        #expect(try await peer.refreshReadyNodes(jobID: "job", now: now.addingTimeInterval(1)) == 0)
        let expiry = now.addingTimeInterval(2)
        #expect(try await peer.refreshReadyNodes(jobID: "job", now: expiry) == 1)
        let next = try #require(try await peer.claimNextReadyNode(jobID: "job", workerID: "B", leaseDurationSeconds: 10, now: expiry))
        #expect(next.lease.generation == old.generation + 1)
        let wav = wave(Data("胜出的检查点".utf8))
        let asset = try await peer.commitBytes(wav, projectID: "book", kind: .segmentWAV, fileExtension: "wav",
                                               sampleRate: 8000, frameCount: "胜出的检查点".utf8.count, provenance: .init(segmentID: "speech"))
        try await peer.commitNodeResult(lease: next.lease, status: .completed, outputAssetID: asset.assetID, outputPayloadJSON: nil,
                                        lastError: nil, nextRetryAt: nil, now: expiry)
        let checkpoint = try await ws.snapshot().nodes
        await #expect(throws: WorkflowStoreError.leaseRejected(nodeID: "speech", expectedOwner: "A", generation: old.generation)) {
            try await ws.store.commitNodeResult(lease: old, status: .completed, outputAssetID: nil, outputPayloadJSON: "stale",
                                                lastError: nil, nextRetryAt: nil, now: expiry)
        }
        #expect(checkpoint.first?.outputAssetID == asset.assetID && checkpoint.first?.status == .completed)
        #expect(try await ws.snapshot().nodes == checkpoint)
        #expect(try await peer.readVerifiedData(for: asset.assetID) == wav)
    }

    @Test func sameSizeCorruptionStopsResumeUntilOnlyDamagedWAVIsRegenerated() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        let book = try await createBook(ws, chapters: 2, segmentsPerChapter: 3)
        let segments = Dictionary(uniqueKeysWithValues: book.map { ($0.segmentID, $0) })
        let tts = SpeechProvider()
        await tts.load()
        let first = segmentExecutor(store: ws.store, provider: tts, segments: segments, cancelAt: book[2].segmentID)
        let interrupted = try await ws.engine(first).run(jobID: "job")
        #expect(interrupted.finalStatus == .cancelled)
        let completed = try await ws.snapshot().nodes.filter { $0.status == .completed }
        try #require(completed.count == 3)
        let damaged = completed[1]
        let assetID = try #require(damaged.outputAssetID)
        let url = try await ws.store.resolveFileURL(for: assetID)
        var bytes = try Data(contentsOf: url)
        bytes[44] ^= 0xff // Alter one PCM sample, leaving the WAV header and length intact.
        try bytes.write(to: url)
        #expect(try await ws.store.runStartupReconciliation() == OrphanGCReport(corruptedAssetIDs: [assetID]))
        let resumed = segmentExecutor(store: ws.store, provider: tts, segments: segments)
        let engine = ws.engine(resumed)
        await #expect(throws: WorkflowStoreError.assetIntegrityFailure(assetID: assetID, reason: "Invalid checkpoint for node \(damaged.nodeID)")) {
            try await engine.resume(jobID: "job")
        }
        #expect(await resumed.calls.isEmpty)
        let segment = try #require(segments[damaged.nodeID])
        try await synthesize(segment.spokenText, with: tts).write(to: url, options: .atomic)
        let report = try await engine.resume(jobID: "job")
        #expect(report.finalStatus == .completed && report.skippedCompletedNodeIDs == completed.map(\.nodeID))
        #expect(await resumed.calls == book.suffix(3).map(\.segmentID))
        let final = try await ws.snapshot().nodes
        #expect(Array(final.prefix(3)) == completed)
        #expect(try await ws.store.runStartupReconciliation() == OrphanGCReport())
    }

    @Test func hundredChaptersRecoverEveryCheckpointWithinFifteenSeconds() async throws {
        let start = ContinuousClock.now
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        let book = try await createBook(ws, chapters: 100, segmentsPerChapter: 15)
        let chapters = try await ws.store.listChapters(projectID: "book", sourceDocumentRevision: "r1")
        try #require(chapters.count == 100 && book.count == 1_500)
        for chapter in chapters {
            let prior = try await ws.store.chapterMemoriesUpTo(projectID: "book", maxChapterNumber: chapter.chapterNumber - 1)
            #expect(prior.map(\.chapterNumber) == Array(1..<chapter.chapterNumber))
            try await ws.store.saveChapterMemory(.init(projectID: "book", chapterID: chapter.chapterID, chapterNumber: chapter.chapterNumber,
                                                       sourceDocumentRevision: "r1", summary: chapter.title, activeCharacterIDs: ["char_narrator"],
                                                       createdAtISO8601: ws.stamp))
        }
        let ids = book.map(\.segmentID)
        let segments = Dictionary(uniqueKeysWithValues: book.map { ($0.segmentID, $0) })
        let failures: Set<String> = [ids[37], ids[320], ids[899], ids[1410]]
        let tts = SpeechProvider()
        await tts.load()
        let config = WorkflowEngineConfig(baseRetryDelaySeconds: 0)
        let first = segmentExecutor(store: ws.store, provider: tts, segments: segments, retryOnce: failures, cancelAt: ids[399])
        let stopped = try await ws.engine(first, config: config).run(jobID: "job")
        #expect(stopped.finalStatus == .cancelled)
        let checkpoints = try await ws.snapshot().nodes.filter { $0.status == .completed }
        try #require(checkpoints.map(\.nodeID) == Array(ids.prefix(400)))
        let checkpointIDs = Set(checkpoints.map(\.nodeID))

        let reopened = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        #expect(try await reopened.chapterMemoriesUpTo(projectID: "book", maxChapterNumber: 100).map(\.chapterID) == chapters.map(\.chapterID))
        #expect(try await reopened.chapterMemoriesUpTo(projectID: "book", maxChapterNumber: 27).map(\.chapterNumber) == Array(1...27))
        let rest = segmentExecutor(store: reopened, provider: tts, segments: segments, retryOnce: failures)
        let engine = WorkflowEngine(store: reopened, artifactStore: reopened, executor: rest, config: config)
        let report = try await engine.resume(jobID: "job")
        #expect(report.finalStatus == .completed && report.skippedCompletedNodeIDs == checkpoints.map(\.nodeID))
        #expect(Set(await rest.calls).isDisjoint(with: checkpointIDs))
        let final = try #require(try await reopened.jobSnapshot(jobID: "job")).nodes
        #expect(final.filter { checkpointIDs.contains($0.nodeID) } == checkpoints)
        #expect(final.map(\.nodeID) == ids && final.allSatisfy { $0.status == .completed })
        #expect(final.allSatisfy { $0.attemptCount == (failures.contains($0.nodeID) ? 2 : 1) })
        #expect(stopped.executedNodeIDs.count + report.executedNodeIDs.count == ids.count + failures.count)

        let assets = try await reopened.listAssets(projectID: "book", kind: .segmentWAV)
        #expect(assets.count == 1_500 && Set(assets.map(\.fileSHA256)).count == 1_500)
        let outputs = Dictionary(uniqueKeysWithValues: final.map { ($0.nodeID, $0.outputAssetID) })
        for asset in assets {
            let segmentID = try #require(asset.provenance.segmentID)
            #expect(outputs[segmentID] == asset.assetID && asset.provenance.chapterID == segments[segmentID]?.chapterID)
        }
        // Reconciliation reads every WAV and recomputes its SHA-256 against its persisted record.
        #expect(try await reopened.runStartupReconciliation() == OrphanGCReport())
        #expect(start.duration(to: .now) < .seconds(15))
    }
}
