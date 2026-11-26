import AudioCore
import Foundation
import StorageKit
import Testing
import WorkflowKit

@Suite("Persistent workflow")
struct WorkflowKitTests {
    @Test func exponentialBackoffPersistsDeadlinesAndHeals() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["speech"], maxAttempts: 4)
        let executor = RecordingExecutor { node in
            if node.attemptCount < 4 { throw NodeExecutionError.retryable("暂时不可用") }
            return .completed(outputAssetID: nil, outputPayloadJSON: "42")
        }
        let engine = ws.engine(executor, config: .init(baseRetryDelaySeconds: 0.15))
        let run = Task { try await engine.run(jobID: "job") }
        for (index, expectedDelay) in [0.15, 0.30, 0.60].enumerated() {
            let attempt = index + 1
            let node = try await waitFor("retry \(attempt)") {
                try await ws.snapshot().nodes.first { $0.status == .retrying && $0.attemptCount == attempt }
            }
            let retry = try date(#require(node.nextRetryAtISO8601))
            let delay = retry.timeIntervalSince(try date(node.updatedAtISO8601))
            #expect(abs(delay - expectedDelay) < 0.002)
            #expect(node.leaseOwner == nil && node.lastError == "暂时不可用")
        }
        let report = try await run.value
        #expect(report.executedNodeIDs == ["speech", "speech", "speech", "speech"] && report.finalStatus == .completed)
        let result = try #require(try await ws.snapshot().nodes.first)
        #expect(result.attemptCount == 4 && result.outputPayloadJSON == "42" && result.nextRetryAtISO8601 == nil)
    }

    @Test func attemptsAreBoundedAndPermanentFailuresBlockDescendants() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["retry", "permanent", "ambient", "render"],
                            edges: [("retry", "render", true)], maxAttempts: 2)
        let executor = RecordingExecutor { node in
            switch node.kind {
            case "retry": throw NodeExecutionError.retryable("暂时不可用")
            case "permanent": throw NodeExecutionError.permanent("输入无效")
            case "ambient": throw NodeExecutionError.unsupportedCapability("P1 未支持背景音混音")
            default: throw NodeExecutionError.permanent("Unexpected node")
            }
        }
        let report = try await ws.engine(executor, config: .init(baseRetryDelaySeconds: 0.01)).run(jobID: "job")
        #expect(report.finalStatus == .failed && report.failedNodeIDs == ["ambient", "permanent", "retry"])
        let nodes = try await ws.snapshot().nodes
        #expect(nodes.map(\.attemptCount) == [1, 1, 0, 2])
        #expect(nodes.first { $0.nodeID == "render" }?.status == .pending)
        #expect(nodes.first { $0.nodeID == "ambient" }?.lastError == "P1 未支持背景音混音")
    }

    @Test func reviewBlocksVerifiedEdgesAndKeepsDryAudioAcrossResume() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["dry", "qc", "export", "listen", "archive"],
                            edges: [("dry", "qc", true), ("qc", "export", true), ("qc", "listen", false),
                                    ("export", "archive", false)])
        let dry = try await ws.asset("音频", nodeID: "dry")
        let executor = RecordingExecutor { node in
            switch node.nodeID {
            case "dry": return .completed(outputAssetID: dry.assetID, outputPayloadJSON: nil)
            case "qc": return .needsReview(outputAssetID: dry.assetID, outputPayloadJSON: "{}", reasons: [.highCER], message: "需试听")
            default: return .completed(outputAssetID: nil, outputPayloadJSON: nil)
            }
        }
        let engine = ws.engine(executor)
        let first = try await engine.run(jobID: "job")
        #expect(first.finalStatus == .needsReview && first.needsReviewNodeIDs == ["qc"])
        #expect(first.executedNodeIDs == ["dry", "qc", "listen"])
        let resumed = try await engine.resume(jobID: "job")
        #expect(resumed.executedNodeIDs.isEmpty && resumed.skippedCompletedNodeIDs == ["dry", "listen"])
        #expect(resumed.finalStatus == .needsReview && resumed.needsReviewNodeIDs == ["qc"])
        let nodes = try await ws.snapshot().nodes
        #expect(nodes.filter { $0.status == .pending }.map(\.nodeID) == ["archive", "export"])
        #expect(nodes.first { $0.nodeID == "qc" }?.outputAssetID == dry.assetID)
        #expect(try await ws.store.runStartupReconciliation() == OrphanGCReport())
        #expect(try await ws.store.readVerifiedData(for: dry.assetID) == Data("音频".utf8))
    }

    @Test(arguments: [true, false])
    func cancellationStopsAtCheckpointAndPreservesAssets(cancelThroughEngine: Bool) async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["audition", "speech", "render"], edges: [("audition", "speech", true), ("speech", "render", true)])
        let executor = RecordingExecutor { node in
            if node.nodeID == "audition" {
                return .completed(outputAssetID: try await ws.asset("试听", nodeID: node.nodeID).assetID, outputPayloadJSON: nil)
            }
            try await Task.sleep(for: .seconds(20))
            return .completed(outputAssetID: nil, outputPayloadJSON: nil)
        }
        let engine = ws.engine(executor)
        let run = Task { try await engine.run(jobID: "job") }
        _ = try await waitFor("speech executor") { await executor.calls.contains("speech") ? true : nil }
        let checkpoint = try #require(try await ws.snapshot().nodes.first { $0.nodeID == "audition" })
        if cancelThroughEngine { _ = try await engine.cancel(jobID: "job") }
        else { run.cancel() }
        let report = try await run.value
        #expect(report.finalStatus == .cancelled && report.cancelled && report.executedNodeIDs == ["audition", "speech"])
        let nodes = try await ws.snapshot().nodes
        #expect(nodes.first { $0.nodeID == "audition" } == checkpoint)
        #expect(nodes.first { $0.nodeID == "speech" }?.status == .cancelled)
        #expect(nodes.first { $0.nodeID == "render" }?.status == .cancelled)
        #expect(try await ws.store.readVerifiedData(for: #require(checkpoint.outputAssetID)) == Data("试听".utf8))
        let rest = RecordingExecutor()
        let resume = try await ws.engine(rest).resume(jobID: "job")
        #expect(resume.finalStatus == .completed && resume.executedNodeIDs == ["speech", "render"])
        #expect(resume.skippedCompletedNodeIDs == ["audition"] && !resume.cancelled)
    }

    @Test func cancellationDuringRetryWaitFromAnotherConnection() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["n"])
        let engine = ws.engine(RecordingExecutor { _ in throw NodeExecutionError.retryable("later") },
                               config: .init(baseRetryDelaySeconds: 30))
        let run = Task { try await engine.run(jobID: "job") }
        _ = try await waitFor("retry") { try await ws.snapshot().nodes.first { $0.status == .retrying } }
        let peer = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        let start = ContinuousClock.now
        _ = try await peer.requestCancel(jobID: "job", now: Date())
        let report = try await run.value
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(report.cancelled && report.finalStatus == .cancelled && report.executedNodeIDs == ["n"])
    }

    @Test func expiredLeaseResumeFromReopenedWorkspaceSkipsAllIntactCheckpoints() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        let ids = ["analyze", "audition", "tts_1", "tts_2", "asr_1", "asr_2", "render"]
        let edges = [("analyze", "audition", true), ("audition", "tts_1", true), ("audition", "tts_2", true),
                     ("tts_1", "asr_1", true), ("tts_2", "asr_2", true), ("asr_1", "render", true), ("asr_2", "render", true)]
        try await ws.create(ids: ids, edges: edges)
        let past = Date().addingTimeInterval(-60)
        var checkpoints: [String: AssetRecord] = [:]
        for expected in ["analyze", "audition", "tts_1", "asr_1", "tts_2"] {
            _ = try await ws.store.refreshReadyNodes(jobID: "job", now: past)
            let claim = try #require(try await ws.store.claimNextReadyNode(jobID: "job", workerID: "interrupted",
                                                                           leaseDurationSeconds: 5, now: past))
            #expect(claim.node.nodeID == expected)
            if expected == "tts_2" { break } // Process disappears between claim and checkpoint.
            let record = try await ws.asset(expected, nodeID: expected)
            checkpoints[expected] = record
            try await ws.store.commitNodeResult(lease: claim.lease, status: .completed, outputAssetID: record.assetID,
                                                outputPayloadJSON: nil, lastError: nil, nextRetryAt: nil, now: past)
        }
        let reopened = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        let executor = RecordingExecutor()
        let engine = WorkflowEngine(store: reopened, artifactStore: reopened, executor: executor)
        let report = try await engine.resume(jobID: "job")
        #expect(report.finalStatus == .completed && Set(report.skippedCompletedNodeIDs) == Set(checkpoints.keys))
        #expect(await executor.calls == ["tts_2", "asr_2", "render"])
        let final = try #require(try await reopened.jobSnapshot(jobID: "job"))
        #expect(final.nodes.first { $0.nodeID == "tts_2" }?.leaseGeneration == 2)
        for (id, asset) in checkpoints {
            #expect(final.nodes.first { $0.nodeID == id }?.outputAssetID == asset.assetID)
            #expect(try await reopened.readVerifiedData(for: asset.assetID) == Data(id.utf8))
        }
    }

    @Test(arguments: [true, false])
    func invalidCheckpointFailsBeforeFurtherInference(removeFile: Bool) async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["tts", "asr"], edges: [("tts", "asr", true)])
        let record = try await ws.asset("原声", nodeID: "tts")
        let now = Date()
        _ = try await ws.store.refreshReadyNodes(jobID: "job", now: now)
        let claim = try #require(try await ws.store.claimNextReadyNode(jobID: "job", workerID: "previous",
                                                                       leaseDurationSeconds: 30, now: now))
        try await ws.store.commitNodeResult(lease: claim.lease, status: .completed, outputAssetID: record.assetID,
                                            outputPayloadJSON: nil, lastError: nil, nextRetryAt: nil, now: now)
        let url = try await ws.store.resolveFileURL(for: record.assetID)
        if removeFile { try FileManager.default.removeItem(at: url) }
        else { try Data("失真".utf8).write(to: url) }
        let executor = RecordingExecutor()
        await #expect(throws: WorkflowStoreError.assetIntegrityFailure(assetID: record.assetID, reason: "Invalid checkpoint for node tts")) {
            try await ws.engine(executor).resume(jobID: "job")
        }
        #expect(await executor.calls.isEmpty)
        #expect(try await ws.snapshot().nodes.first { $0.nodeID == "asr" }?.status == .pending)
    }

    @Test func lostHeartbeatStopsExecutorAndPreservesPeerResult() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["speech"])
        let executor = RecordingExecutor { _ in
            try await Task.sleep(for: .seconds(15))
            return .completed(outputAssetID: nil, outputPayloadJSON: "old")
        }
        let engine = ws.engine(executor, config: .init(workerID: "old", leaseDurationSeconds: 2, heartbeatIntervalSeconds: 0.05))
        let run = Task { try await engine.run(jobID: "job") }
        _ = try await waitFor("executor") { await executor.active == 1 ? true : nil }
        let peer = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        let future = Date().addingTimeInterval(10)
        #expect(try await peer.refreshReadyNodes(jobID: "job", now: future) == 1)
        let claim = try #require(try await peer.claimNextReadyNode(jobID: "job", workerID: "peer", leaseDurationSeconds: 5, now: future))
        try await peer.commitNodeResult(lease: claim.lease, status: .completed, outputAssetID: nil, outputPayloadJSON: "new",
                                        lastError: nil, nextRetryAt: nil, now: future)
        await #expect(throws: WorkflowStoreError.leaseRejected(nodeID: "speech", expectedOwner: "old", generation: 1)) {
            try await run.value
        }
        #expect(await executor.active == 0)
        let final = try await ws.snapshot()
        #expect(!final.job.cancelRequested && final.nodes.first?.outputPayloadJSON == "new")
    }

    @Test func executorReportsCancellationAfterPersistedRequest() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["speech"])
        let executor = RecordingExecutor { _ in
            _ = try await ws.store.requestCancel(jobID: "job", now: Date())
            throw NodeExecutionError.cancelled
        }
        let report = try await ws.engine(executor).run(jobID: "job")
        #expect(report.cancelled && report.finalStatus == .cancelled)
        let node = try #require(try await ws.snapshot().nodes.first)
        #expect(node.status == .cancelled && node.attemptCount == 1 && node.leaseOwner == nil)
    }

    @Test func heartbeatKeepsLiveWorkFencedAndSchedulerHonorsConcurrency() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        try await ws.create(ids: ["a", "b", "c", "d"])
        let executor = RecordingExecutor { _ in
            try await Task.sleep(for: .milliseconds(420))
            return .completed(outputAssetID: nil, outputPayloadJSON: nil)
        }
        let engine = ws.engine(executor, config: .init(leaseDurationSeconds: 0.25, heartbeatIntervalSeconds: 0.03, maxConcurrency: 2))
        let run = Task { try await engine.run(jobID: "job") }
        _ = try await waitFor("two active nodes") { await executor.active == 2 ? true : nil }
        let peer = try SQLiteWorkspaceStore(rootDirectory: ws.root)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await peer.refreshReadyNodes(jobID: "job", now: Date()) == 0)
        let report = try await run.value
        #expect(report.finalStatus == .completed && Set(report.executedNodeIDs) == ["a", "b", "c", "d"])
        #expect(await executor.peakActive == 2)
        #expect(try await ws.snapshot().nodes.allSatisfy { $0.leaseGeneration == 1 && $0.leaseExpiresAtISO8601 == nil })
    }
}
