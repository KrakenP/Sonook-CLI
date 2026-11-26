import Foundation

// MARK: - Persistent DAG Workflow Contracts

public enum TaskPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case interactive = 10

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
    case running
    case verifying
    case completed
    case retrying
    case paused
    case failed
    case cancelled
    case needsReview = "needs_review"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .needsReview: true
        case .pending, .ready, .running, .verifying, .retrying, .paused: false
        }
    }
}

public enum NodeStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
    case running
    case verifying
    case completed
    case retrying
    case paused
    case failed
    case cancelled
    case needsReview = "needs_review"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .needsReview: true
        case .pending, .ready, .running, .verifying, .retrying, .paused: false
        }
    }
}

public struct JobRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let jobID: String
    public let projectID: String
    public let workflowKind: String
    public var status: JobStatus
    public var priority: TaskPriority
    public var cancelRequested: Bool
    public var configJSON: String
    public var summary: String?
    public let createdAtISO8601: String
    public var updatedAtISO8601: String

    public init(
        jobID: String,
        projectID: String,
        workflowKind: String,
        status: JobStatus = .pending,
        priority: TaskPriority = .background,
        cancelRequested: Bool = false,
        configJSON: String = "{}",
        summary: String? = nil,
        createdAtISO8601: String,
        updatedAtISO8601: String? = nil
    ) {
        self.jobID = jobID
        self.projectID = projectID
        self.workflowKind = workflowKind
        self.status = status
        self.priority = priority
        self.cancelRequested = cancelRequested
        self.configJSON = configJSON
        self.summary = summary
        self.createdAtISO8601 = createdAtISO8601
        self.updatedAtISO8601 = updatedAtISO8601 ?? createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case jobID = "job_id"
        case projectID = "project_id"
        case workflowKind = "workflow_kind"
        case status
        case priority
        case cancelRequested = "cancel_requested"
        case configJSON = "config_json"
        case summary
        case createdAtISO8601 = "created_at"
        case updatedAtISO8601 = "updated_at"
    }
}

public struct JobNodeRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let nodeID: String
    public let jobID: String
    public let kind: String
    public var status: NodeStatus
    public var priority: TaskPriority
    public var inputFingerprint: String
    public var payloadJSON: String
    public var attemptCount: Int
    public var maxAttempts: Int
    public var nextRetryAtISO8601: String?
    public var leaseOwner: String?
    public var leaseGeneration: Int
    public var leaseExpiresAtISO8601: String?
    public var outputAssetID: String?
    public var outputPayloadJSON: String?
    public var lastError: String?
    public let createdAtISO8601: String
    public var updatedAtISO8601: String

    public init(
        nodeID: String,
        jobID: String,
        kind: String,
        status: NodeStatus = .pending,
        priority: TaskPriority = .background,
        inputFingerprint: String,
        payloadJSON: String = "{}",
        attemptCount: Int = 0,
        maxAttempts: Int = 3,
        nextRetryAtISO8601: String? = nil,
        leaseOwner: String? = nil,
        leaseGeneration: Int = 0,
        leaseExpiresAtISO8601: String? = nil,
        outputAssetID: String? = nil,
        outputPayloadJSON: String? = nil,
        lastError: String? = nil,
        createdAtISO8601: String,
        updatedAtISO8601: String? = nil
    ) {
        self.nodeID = nodeID
        self.jobID = jobID
        self.kind = kind
        self.status = status
        self.priority = priority
        self.inputFingerprint = inputFingerprint
        self.payloadJSON = payloadJSON
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.nextRetryAtISO8601 = nextRetryAtISO8601
        self.leaseOwner = leaseOwner
        self.leaseGeneration = leaseGeneration
        self.leaseExpiresAtISO8601 = leaseExpiresAtISO8601
        self.outputAssetID = outputAssetID
        self.outputPayloadJSON = outputPayloadJSON
        self.lastError = lastError
        self.createdAtISO8601 = createdAtISO8601
        self.updatedAtISO8601 = updatedAtISO8601 ?? createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case nodeID = "node_id"
        case jobID = "job_id"
        case kind
        case status
        case priority
        case inputFingerprint = "input_fingerprint"
        case payloadJSON = "payload_json"
        case attemptCount = "attempt_count"
        case maxAttempts = "max_attempts"
        case nextRetryAtISO8601 = "next_retry_at"
        case leaseOwner = "lease_owner"
        case leaseGeneration = "lease_generation"
        case leaseExpiresAtISO8601 = "lease_expires_at"
        case outputAssetID = "output_asset_id"
        case outputPayloadJSON = "output_payload_json"
        case lastError = "last_error"
        case createdAtISO8601 = "created_at"
        case updatedAtISO8601 = "updated_at"
    }
}

public struct JobEdgeRecord: Codable, Equatable, Sendable {
    public let jobID: String
    public let fromNodeID: String
    public let toNodeID: String
    /// When true, the downstream node can only run if `fromNodeID` reaches `.completed` (not `.needsReview`).
    public let requiresVerified: Bool

    public init(jobID: String, fromNodeID: String, toNodeID: String, requiresVerified: Bool = true) {
        self.jobID = jobID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.requiresVerified = requiresVerified
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case requiresVerified = "requires_verified"
    }
}

/// Fencing token obtained when a worker atomically claims a ready node.
public struct NodeLease: Codable, Equatable, Sendable {
    public let jobID: String
    public let nodeID: String
    public let owner: String
    public let generation: Int
    public let expiresAtISO8601: String

    public init(jobID: String, nodeID: String, owner: String, generation: Int, expiresAtISO8601: String) {
        self.jobID = jobID
        self.nodeID = nodeID
        self.owner = owner
        self.generation = generation
        self.expiresAtISO8601 = expiresAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case nodeID = "node_id"
        case owner
        case generation
        case expiresAtISO8601 = "expires_at"
    }
}

public struct ClaimedNode: Sendable {
    public let node: JobNodeRecord
    public let lease: NodeLease

    public init(node: JobNodeRecord, lease: NodeLease) {
        self.node = node
        self.lease = lease
    }
}

public enum WorkflowStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case leaseRejected(nodeID: String, expectedOwner: String, generation: Int)
    case invalidStateTransition(String)
    case duplicateID(String)
    case storageFailure(String)
    case assetIntegrityFailure(assetID: String, reason: String)
}

public enum NodeExecutionOutcome: Sendable {
    case completed(outputAssetID: String?, outputPayloadJSON: String?)
    case needsReview(outputAssetID: String?, outputPayloadJSON: String?, reasons: [QualityReason], message: String)
}

public enum NodeExecutionError: Error, Equatable, Sendable {
    case retryable(String)
    case permanent(String)
    case unsupportedCapability(String)
    case cancelled
}

public struct JobSnapshot: Codable, Equatable, Sendable {
    public let job: JobRecord
    public let nodes: [JobNodeRecord]
    public let edges: [JobEdgeRecord]

    public init(job: JobRecord, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) {
        self.job = job
        self.nodes = nodes
        self.edges = edges
    }
}

public struct OrphanGCReport: Codable, Equatable, Sendable {
    public let removedTempFiles: Int
    public let removedOrphanAssets: Int
    public let missingReferencedAssetIDs: [String]
    public let corruptedAssetIDs: [String]

    public init(
        removedTempFiles: Int = 0,
        removedOrphanAssets: Int = 0,
        missingReferencedAssetIDs: [String] = [],
        corruptedAssetIDs: [String] = []
    ) {
        self.removedTempFiles = removedTempFiles
        self.removedOrphanAssets = removedOrphanAssets
        self.missingReferencedAssetIDs = missingReferencedAssetIDs
        self.corruptedAssetIDs = corruptedAssetIDs
    }
}

// MARK: - Storage Protocols (Implemented by StorageKit; Consumed by WorkflowKit / EngineSDK)

public protocol ArtifactStoreProtocol: Sendable {
    /// Atomically writes bytes via a same-volume temp file, verifies SHA-256, moves to content-addressed storage,
    /// and returns the persisted AssetRecord (without committing a job node).
    func commitBytes(
        _ data: Data,
        projectID: String,
        kind: AssetKind,
        fileExtension: String,
        sampleRate: Int?,
        frameCount: Int?,
        provenance: AssetProvenance
    ) async throws -> AssetRecord

    func asset(id: String) async throws -> AssetRecord?
    func listAssets(projectID: String, kind: AssetKind?) async throws -> [AssetRecord]
    func resolveFileURL(for assetID: String) async throws -> URL
    func readVerifiedData(for assetID: String) async throws -> Data
    func verifyAssetIntegrity(assetID: String) async throws -> Bool
    func runStartupReconciliation() async throws -> OrphanGCReport
}

public protocol JobStoreProtocol: Sendable {
    func createJob(_ job: JobRecord, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) async throws
    func jobSnapshot(jobID: String) async throws -> JobSnapshot?
    func listJobs(projectID: String?) async throws -> [JobRecord]

    /// Recomputes `pending -> ready` transitions for nodes whose dependencies are satisfied, and reclaims expired leases.
    func refreshReadyNodes(jobID: String, now: Date) async throws -> Int

    /// Atomically claims the highest-priority ready node for `jobID` (or any job if nil), incrementing `lease_generation`.
    func claimNextReadyNode(
        jobID: String?,
        workerID: String,
        leaseDurationSeconds: TimeInterval,
        now: Date
    ) async throws -> ClaimedNode?

    /// Renews an active lease strictly matching `(owner, generation)`. Throws `leaseRejected` if superseded.
    func renewLease(_ lease: NodeLease, leaseDurationSeconds: TimeInterval, now: Date) async throws -> NodeLease

    /// Commits a node transition strictly verifying `(owner, generation)` inside a write transaction.
    func commitNodeResult(
        lease: NodeLease,
        status: NodeStatus,
        outputAssetID: String?,
        outputPayloadJSON: String?,
        lastError: String?,
        nextRetryAt: Date?,
        now: Date
    ) async throws

    /// Persists cancellation request so no new nodes are claimed; in-flight nodes stop at checkpoint without deleting verified assets.
    func requestCancel(jobID: String, now: Date) async throws -> JobRecord

    /// Marks a cancelled/paused/interrupted job ready to resume, resetting expired/cancelled non-completed nodes while keeping all completed nodes intact.
    func prepareResume(jobID: String, now: Date) async throws -> JobRecord

    /// Updates aggregate job status based on its nodes.
    func recomputeJobStatus(jobID: String, now: Date) async throws -> JobRecord
}

public protocol NodeExecutorProtocol: Sendable {
    func execute(node: JobNodeRecord, lease: NodeLease, job: JobRecord) async throws -> NodeExecutionOutcome
}

public protocol ProjectStoreProtocol: Sendable {
    func saveProject(_ project: ProjectRecord) async throws
    func project(id: String) async throws -> ProjectRecord?
    func listProjects() async throws -> [ProjectRecord]
}

public protocol ModelRegistryStoreProtocol: Sendable {
    func upsertModel(_ entry: ModelRegistryEntry) async throws
    func model(id: String) async throws -> ModelRegistryEntry?
    func listModels(kind: ModelKind?) async throws -> [ModelRegistryEntry]
    func updateMeasuredPeakBytes(modelID: String, peakBytes: UInt64) async throws
}

public protocol CatalogStoreProtocol: Sendable {
    func saveCatalog(_ catalog: CharacterVoiceCatalog) async throws
    func loadCatalog(projectID: String) async throws -> CharacterVoiceCatalog?
}

public protocol ScriptStoreProtocol: Sendable {
    func saveScript(_ script: ScriptDocument, projectID: String) async throws
    func loadScript(projectID: String, chapterID: String) async throws -> ScriptDocument?
    func listScripts(projectID: String) async throws -> [ScriptDocument]
    func locateSegment(projectID: String, segmentID: String) async throws -> LocatedSegment?
}

public protocol SourceCatalogStoreProtocol: Sendable {
    func saveSourceDocument(_ document: SourceDocumentRecord, chapters: [ChapterRecord]) async throws
    func latestSourceDocument(projectID: String) async throws -> SourceDocumentRecord?
    func listChapters(projectID: String, sourceDocumentRevision: String?) async throws -> [ChapterRecord]
    func chapter(projectID: String, chapterID: String) async throws -> ChapterRecord?
    func saveSegmentApproval(_ approval: SegmentApprovalRecord) async throws
    func segmentApprovals(projectID: String, chapterID: String) async throws -> [SegmentApprovalRecord]
}

public protocol WorkspaceStoreProtocol: ProjectStoreProtocol, ModelRegistryStoreProtocol, CatalogStoreProtocol, ScriptStoreProtocol, SourceCatalogStoreProtocol, ChapterMemoryStoreProtocol, JobStoreProtocol, ArtifactStoreProtocol {
    var rootDirectory: URL { get }
}
