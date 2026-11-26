import AudioCore
import Foundation

public struct WorkflowEngineConfig: Sendable {
    public let workerID: String
    public let leaseDurationSeconds: TimeInterval
    public let heartbeatIntervalSeconds: TimeInterval
    public let baseRetryDelaySeconds: TimeInterval
    public let maxConcurrency: Int

    public init(
        workerID: String = "worker-\(UUID().uuidString.prefix(8))",
        leaseDurationSeconds: TimeInterval = 30.0,
        heartbeatIntervalSeconds: TimeInterval = 5.0,
        baseRetryDelaySeconds: TimeInterval = 0.25,
        maxConcurrency: Int = 1
    ) {
        self.workerID = workerID
        self.leaseDurationSeconds = leaseDurationSeconds
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.baseRetryDelaySeconds = baseRetryDelaySeconds
        self.maxConcurrency = max(1, maxConcurrency)
    }
}

public struct WorkflowRunReport: Codable, Equatable, Sendable {
    public let jobID: String
    public let finalStatus: JobStatus
    public let executedNodeIDs: [String]
    public let skippedCompletedNodeIDs: [String]
    public let needsReviewNodeIDs: [String]
    public let failedNodeIDs: [String]
    public let cancelled: Bool

    public init(
        jobID: String,
        finalStatus: JobStatus,
        executedNodeIDs: [String],
        skippedCompletedNodeIDs: [String],
        needsReviewNodeIDs: [String],
        failedNodeIDs: [String],
        cancelled: Bool
    ) {
        self.jobID = jobID
        self.finalStatus = finalStatus
        self.executedNodeIDs = executedNodeIDs
        self.skippedCompletedNodeIDs = skippedCompletedNodeIDs
        self.needsReviewNodeIDs = needsReviewNodeIDs
        self.failedNodeIDs = failedNodeIDs
        self.cancelled = cancelled
    }
}

/// Persistent DAG workflow scheduler supporting fencing-token leases, heartbeats,
/// bounded retries, checkpoint-safe cancellation, and idempotent resume.
public actor WorkflowEngine {
    public let store: any JobStoreProtocol
    public let artifactStore: (any ArtifactStoreProtocol)?
    public let executor: any NodeExecutorProtocol
    public let config: WorkflowEngineConfig

    public init(
        store: any JobStoreProtocol,
        artifactStore: (any ArtifactStoreProtocol)? = nil,
        executor: any NodeExecutorProtocol,
        config: WorkflowEngineConfig = WorkflowEngineConfig()
    ) {
        self.store = store
        self.artifactStore = artifactStore
        self.executor = executor
        self.config = config
    }

    private typealias ExecutionTask = Task<NodeExecutionOutcome, any Error>
    private var activeExecutions: [String: [String: ExecutionTask]] = [:]

    public func run(jobID: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> WorkflowRunReport {
        try await schedule(jobID: jobID, verifyCompleted: false, progress: progress)
    }

    public func resume(jobID: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> WorkflowRunReport {
        _ = try await store.prepareResume(jobID: jobID, now: Date())
        return try await schedule(jobID: jobID, verifyCompleted: true, progress: progress)
    }

    public func cancel(jobID: String) async throws -> JobRecord {
        let job = try await store.requestCancel(jobID: jobID, now: Date())
        activeExecutions[jobID]?.values.forEach { $0.cancel() }
        return job
    }

    private func snapshot(_ jobID: String) async throws -> JobSnapshot {
        guard let snapshot = try await store.jobSnapshot(jobID: jobID) else { throw WorkflowStoreError.notFound(jobID) }
        return snapshot
    }

    private func schedule(jobID: String, verifyCompleted: Bool,
                          progress: (@Sendable (String) -> Void)?) async throws -> WorkflowRunReport {
        guard config.heartbeatIntervalSeconds.isFinite, config.heartbeatIntervalSeconds > 0,
              config.leaseDurationSeconds.isFinite, config.leaseDurationSeconds > 0,
              config.baseRetryDelaySeconds.isFinite, config.baseRetryDelaySeconds >= 0 else {
            throw WorkflowStoreError.invalidStateTransition("Invalid workflow timing configuration")
        }
        if !verifyCompleted { _ = try await store.refreshReadyNodes(jobID: jobID, now: Date()) }
        let initial = try await snapshot(jobID)
        let checkpoints = initial.nodes.filter { $0.status == .completed }
        if verifyCompleted, let artifactStore {
            for node in checkpoints {
                if let assetID = node.outputAssetID, try await !artifactStore.verifyAssetIntegrity(assetID: assetID) {
                    throw WorkflowStoreError.assetIntegrityFailure(assetID: assetID, reason: "Invalid checkpoint for node \(node.nodeID)")
                }
            }
        }

        if verifyCompleted { _ = try await store.refreshReadyNodes(jobID: jobID, now: Date()) }

        var executed: [String] = []
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            do {
                while true {
                    if Task.isCancelled {
                        _ = try await cancel(jobID: jobID)
                    }
                    while !Task.isCancelled && running < config.maxConcurrency {
                        guard let claim = try await store.claimNextReadyNode(jobID: jobID, workerID: config.workerID,
                            leaseDurationSeconds: config.leaseDurationSeconds, now: Date()) else { break }
                        executed.append(claim.node.nodeID)
                        progress?("running \(claim.node.nodeID)")
                        group.addTask { try await self.execute(claim, job: initial.job) }
                        running += 1
                    }
                    if running > 0 {
                        _ = try await group.next()
                        running -= 1
                    } else {
                        let waiting = try await snapshot(jobID)
                        guard !waiting.job.cancelRequested else { break }
                        if !waiting.nodes.contains(where: { $0.status == .ready }) {
                            if let deadline = try nextRetry(in: waiting.nodes) {
                                // Another process can cancel this job during a long backoff.
                                let delay = max(0, min(0.25, deadline.timeIntervalSinceNow))
                                do { try await Task.sleep(for: .seconds(delay)) }
                                catch is CancellationError { continue }
                            } else {
                                // A peer may have committed a prerequisite since our last readiness check.
                                guard try await store.refreshReadyNodes(jobID: jobID, now: Date()) > 0 else { break }
                                continue
                            }
                        }
                    }
                    _ = try await store.refreshReadyNodes(jobID: jobID, now: Date())
                }
            } catch {
                // A storage or fencing failure stops new dispatch. Let other owned nodes reach
                // their checkpoints so a sibling's failure cannot masquerade as a user cancellation.
                while await group.nextResult() != nil {}
                throw error
            }
        }
        _ = try await store.recomputeJobStatus(jobID: jobID, now: Date())
        let final = try await snapshot(jobID)
        return WorkflowRunReport(jobID: jobID, finalStatus: final.job.status, executedNodeIDs: executed,
                                 skippedCompletedNodeIDs: checkpoints.map(\.nodeID),
                                 needsReviewNodeIDs: final.nodes.filter { $0.status == .needsReview }.map(\.nodeID),
                                 failedNodeIDs: final.nodes.filter { $0.status == .failed }.map(\.nodeID),
                                 cancelled: final.job.cancelRequested || final.job.status == .cancelled)
    }

    private func nextRetry(in nodes: [JobNodeRecord]) throws -> Date? {
        try nodes.filter { $0.status == .retrying }.map { node in
            guard let raw = node.nextRetryAtISO8601 else {
                throw WorkflowStoreError.invalidStateTransition("Missing retry time for \(node.nodeID)")
            }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return date }
            return try Date.ISO8601FormatStyle().parse(raw)
        }.min()
    }

    private func execute(_ claim: ClaimedNode, job: JobRecord) async throws {
        let lease = claim.lease
        let work = Task { [executor] in
            try await executor.execute(node: claim.node, lease: lease, job: job)
        }
        // A reclaimed generation can be active in the same engine while the old executor is winding down.
        let taskID = UUID().uuidString
        activeExecutions[job.jobID, default: [:]][taskID] = work
        defer {
            activeExecutions[job.jobID]?[taskID] = nil
            if activeExecutions[job.jobID]?.isEmpty == true { activeExecutions[job.jobID] = nil }
        }

        let heartbeat = Task {
            var current = lease
            do {
                while true {
                    try await Task.sleep(for: .seconds(config.heartbeatIntervalSeconds))
                    current = try await store.renewLease(current, leaseDurationSeconds: config.leaseDurationSeconds, now: Date())
                    if try await snapshot(job.jobID).job.cancelRequested { work.cancel() }
                }
            } catch is CancellationError where Task.isCancelled {
                return current
            } catch {
                work.cancel()
                throw error
            }
        }
        let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
        heartbeat.cancel()
        let currentLease = try await heartbeat.value

        var status: NodeStatus
        var output: String?
        var payload: String?
        var message: String?
        var retry: Date?
        let now = Date()
        switch result {
        case .success(.completed(let asset, let json)):
            status = .completed
            output = asset
            payload = json
        case .success(.needsReview(let asset, let json, let reasons, let detail)):
            status = .needsReview
            output = asset
            payload = json
            message = ([detail] + reasons.map(\.rawValue)).filter { !$0.isEmpty }.joined(separator: ", ")
        case .failure(NodeExecutionError.retryable(let detail)):
            status = claim.node.attemptCount < claim.node.maxAttempts ? .retrying : .failed
            message = detail
            if status == .retrying {
                let delay = config.baseRetryDelaySeconds * pow(2, Double(claim.node.attemptCount - 1))
                retry = now.addingTimeInterval(delay)
            }
        case .failure(NodeExecutionError.permanent(let detail)), .failure(NodeExecutionError.unsupportedCapability(let detail)):
            status = .failed
            message = detail
        case .failure(NodeExecutionError.cancelled), .failure(is CancellationError):
            if Task.isCancelled { _ = try await store.requestCancel(jobID: job.jobID, now: now) }
            status = try await snapshot(job.jobID).job.cancelRequested ? .cancelled : .paused
        case .failure:
            status = .failed
            message = "Unexpected executor error"
        }
        try await store.commitNodeResult(lease: currentLease, status: status, outputAssetID: output,
                                         outputPayloadJSON: payload, lastError: message, nextRetryAt: retry, now: Date())
    }
}
