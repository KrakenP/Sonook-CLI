import AudioCore
import Foundation
import StorageKit
import Testing
import WorkflowKit

struct WorkflowWorkspace {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store: SQLiteWorkspaceStore
    let stamp = Date().formatted(.iso8601)

    init() async throws {
        store = try SQLiteWorkspaceStore(rootDirectory: root)
        try await store.saveProject(ProjectRecord(projectID: "book", name: "样本", createdAtISO8601: stamp))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func create(job: String = "job", ids: [String], edges: [(String, String, Bool)] = [], maxAttempts: Int = 3) async throws {
        try await store.createJob(.init(jobID: job, projectID: "book", workflowKind: "audiobook", createdAtISO8601: stamp),
                                  nodes: ids.map { .init(nodeID: $0, jobID: job, kind: $0, inputFingerprint: "fp-\($0)",
                                                        maxAttempts: maxAttempts, createdAtISO8601: stamp) },
                                  edges: edges.map { .init(jobID: job, fromNodeID: $0.0, toNodeID: $0.1, requiresVerified: $0.2) })
    }

    func asset(_ text: String, nodeID: String) async throws -> AssetRecord {
        try await store.commitBytes(Data(text.utf8), projectID: "book", kind: .segmentWAV, fileExtension: "bin",
                                    sampleRate: nil, frameCount: nil, provenance: .init(segmentID: nodeID))
    }

    func snapshot(_ jobID: String = "job") async throws -> JobSnapshot {
        try #require(try await store.jobSnapshot(jobID: jobID))
    }

    func engine(_ executor: any NodeExecutorProtocol, config: WorkflowEngineConfig = .init()) -> WorkflowEngine {
        WorkflowEngine(store: store, artifactStore: store, executor: executor, config: config)
    }
}

actor RecordingExecutor: NodeExecutorProtocol {
    typealias Handler = @Sendable (JobNodeRecord) async throws -> NodeExecutionOutcome
    private let handler: Handler
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var peakActive = 0

    init(_ handler: @escaping Handler = { _ in .completed(outputAssetID: nil, outputPayloadJSON: nil) }) {
        self.handler = handler
    }

    func execute(node: JobNodeRecord, lease: NodeLease, job: JobRecord) async throws -> NodeExecutionOutcome {
        calls.append(node.nodeID)
        active += 1
        peakActive = max(peakActive, active)
        defer { active -= 1 }
        return try await handler(node)
    }
}

func waitFor<T>(_ description: String, _ read: () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    repeat {
        if let value = try await read() { return value }
        try await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    throw WorkflowStoreError.storageFailure("Timed out waiting for \(description)")
}

func date(_ timestamp: String) throws -> Date {
    try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
}
