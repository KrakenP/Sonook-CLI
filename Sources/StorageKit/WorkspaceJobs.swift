import AudioCore
import Foundation

private let jobColumns = """
    job_id, project_id, workflow_kind, status, priority, cancel_requested, config_json, summary, created_at, updated_at
    """
private let nodeColumns = """
    job_id, node_id, kind, status, priority, input_fingerprint, payload_json, attempt_count, max_attempts,
    next_retry_at, lease_owner, lease_generation, lease_expires_at, output_asset_id, output_payload_json,
    last_error, created_at, updated_at
    """

private extension SQLiteRow {
    func job() throws -> JobRecord {
        guard let status = JobStatus(rawValue: text(3)), let priority = TaskPriority(rawValue: integer(4)) else {
            throw WorkflowStoreError.storageFailure("Invalid job status or priority")
        }
        return JobRecord(jobID: text(0), projectID: text(1), workflowKind: text(2), status: status, priority: priority,
                         cancelRequested: integer(5) != 0, configJSON: text(6), summary: optionalText(7),
                         createdAtISO8601: text(8), updatedAtISO8601: text(9))
    }

    func node() throws -> JobNodeRecord {
        guard let status = NodeStatus(rawValue: text(3)), let priority = TaskPriority(rawValue: integer(4)) else {
            throw WorkflowStoreError.storageFailure("Invalid node status or priority")
        }
        return JobNodeRecord(nodeID: text(1), jobID: text(0), kind: text(2), status: status, priority: priority,
                             inputFingerprint: text(5), payloadJSON: text(6), attemptCount: integer(7),
                             maxAttempts: integer(8), nextRetryAtISO8601: optionalText(9), leaseOwner: optionalText(10),
                             leaseGeneration: integer(11), leaseExpiresAtISO8601: optionalText(12),
                             outputAssetID: optionalText(13), outputPayloadJSON: optionalText(14), lastError: optionalText(15),
                             createdAtISO8601: text(16), updatedAtISO8601: text(17))
    }
}

extension SQLiteWorkspaceStore {
    public func createJob(_ job: JobRecord, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) async throws {
        try validateGraph(jobID: job.jobID, nodes: nodes, edges: edges)
        try db.transaction {
            guard try readJob(job.jobID) == nil else { throw WorkflowStoreError.duplicateID(job.jobID) }
            try db.execute("INSERT INTO jobs(\(jobColumns)) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                job.jobID, job.projectID, job.workflowKind, job.status.rawValue, String(job.priority.rawValue),
                job.cancelRequested ? "1" : "0", job.configJSON, job.summary, job.createdAtISO8601, job.updatedAtISO8601
            ])
            for node in nodes {
                try db.execute("INSERT INTO job_nodes(\(nodeColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    node.jobID, node.nodeID, node.kind, node.status.rawValue, String(node.priority.rawValue),
                    node.inputFingerprint, node.payloadJSON, String(node.attemptCount), String(node.maxAttempts),
                    node.nextRetryAtISO8601, node.leaseOwner, String(node.leaseGeneration), node.leaseExpiresAtISO8601,
                    node.outputAssetID, node.outputPayloadJSON, node.lastError, node.createdAtISO8601, node.updatedAtISO8601
                ])
            }
            for edge in edges {
                try db.execute("INSERT INTO job_edges(job_id, from_node_id, to_node_id, requires_verified) VALUES (?,?,?,?)",
                               [edge.jobID, edge.fromNodeID, edge.toNodeID, edge.requiresVerified ? "1" : "0"])
            }
        }
    }

    private func validateGraph(jobID: String, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) throws {
        var incoming: [String: Int] = [:]
        var children: [String: [String]] = [:]
        for node in nodes {
            guard node.jobID == jobID, node.maxAttempts > 0, node.attemptCount >= 0 else {
                throw WorkflowStoreError.invalidStateTransition("Invalid job node")
            }
            guard incoming.updateValue(0, forKey: node.nodeID) == nil else { throw WorkflowStoreError.duplicateID(node.nodeID) }
        }
        for edge in edges {
            guard edge.jobID == jobID, incoming[edge.fromNodeID] != nil, incoming[edge.toNodeID] != nil else {
                throw WorkflowStoreError.invalidStateTransition("Edge references an unknown node")
            }
            incoming[edge.toNodeID, default: 0] += 1
            children[edge.fromNodeID, default: []].append(edge.toNodeID)
        }
        var roots = incoming.compactMap { $0.value == 0 ? $0.key : nil }
        var visited = 0
        while let root = roots.popLast() {
            visited += 1
            for child in children[root, default: []] {
                incoming[child, default: 0] -= 1
                if incoming[child] == 0 { roots.append(child) }
            }
        }
        guard visited == nodes.count else { throw WorkflowStoreError.invalidStateTransition("Cyclic job graph") }
    }

    private func readJob(_ id: String) throws -> JobRecord? {
        try db.query("SELECT \(jobColumns) FROM jobs WHERE job_id=?", [id]) { try $0.job() }.first
    }

    private func requireJob(_ id: String) throws -> JobRecord {
        guard let job = try readJob(id) else { throw WorkflowStoreError.notFound(id) }
        return job
    }

    public func jobSnapshot(jobID: String) async throws -> JobSnapshot? {
        try db.transaction(readOnly: true) {
            guard let job = try readJob(jobID) else { return nil }
            let nodes = try db.query("SELECT \(nodeColumns) FROM job_nodes WHERE job_id=? ORDER BY created_at, node_id", [jobID]) {
                try $0.node()
            }
            let edges = try db.query("""
                SELECT from_node_id, to_node_id, requires_verified FROM job_edges WHERE job_id=? ORDER BY from_node_id, to_node_id
                """, [jobID]) {
                JobEdgeRecord(jobID: jobID, fromNodeID: $0.text(0), toNodeID: $0.text(1), requiresVerified: $0.integer(2) != 0)
            }
            return JobSnapshot(job: job, nodes: nodes, edges: edges)
        }
    }

    public func listJobs(projectID: String?) async throws -> [JobRecord] {
        try db.query("SELECT \(jobColumns) FROM jobs WHERE (?1 IS NULL OR project_id=?1) ORDER BY created_at, job_id",
                     [projectID]) { try $0.job() }
    }

    // In both readiness and aggregation, a pending descendant of a failed/review checkpoint is blocked.
    private static let dependenciesSatisfied = """
        NOT EXISTS (
            SELECT 1 FROM job_edges e JOIN job_nodes p ON p.job_id=e.job_id AND p.node_id=e.from_node_id
            WHERE e.job_id=job_nodes.job_id AND e.to_node_id=job_nodes.node_id
              AND p.status <> 'completed' AND (e.requires_verified=1 OR p.status <> 'needs_review')
        )
        """

    public func refreshReadyNodes(jobID: String, now: Date) async throws -> Int {
        try db.transaction {
            let job = try requireJob(jobID)
            let values = [timestamp(now), jobID]
            let expired = """
                job_id=?2 AND status IN ('running','verifying') AND julianday(lease_expires_at)<=julianday(?1)
                """
            if job.cancelRequested {
                try db.execute("""
                    UPDATE job_nodes SET status='cancelled', updated_at=?1, lease_owner=NULL, lease_expires_at=NULL,
                        next_retry_at=NULL WHERE \(expired) OR (job_id=?2 AND status IN ('pending','ready','retrying'))
                    """, values)
                return 0
            }
            try db.execute("""
                UPDATE job_nodes SET status='failed', last_error='Lease expired at attempt limit', updated_at=?1,
                    lease_owner=NULL, lease_expires_at=NULL WHERE \(expired) AND attempt_count>=max_attempts
                """, values)
            var ready = try db.execute("""
                UPDATE job_nodes SET status='ready', lease_owner=NULL, lease_expires_at=NULL, next_retry_at=NULL, updated_at=?1
                WHERE \(expired) OR (job_id=?2 AND status='retrying' AND julianday(next_retry_at)<=julianday(?1))
                """, values)
            ready += try db.execute("""
                UPDATE job_nodes SET status='ready', updated_at=?1 WHERE job_id=?2 AND status='pending' AND \(Self.dependenciesSatisfied)
                """, values)
            return ready
        }
    }

    public func claimNextReadyNode(jobID: String?, workerID: String, leaseDurationSeconds: TimeInterval,
                                   now: Date) async throws -> ClaimedNode? {
        try db.transaction {
            guard let candidate = try db.query("""
                SELECT job_id, node_id FROM job_nodes WHERE (?1 IS NULL OR job_id=?1) AND status='ready'
                    AND EXISTS (SELECT 1 FROM jobs WHERE jobs.job_id=job_nodes.job_id AND cancel_requested=0)
                ORDER BY priority DESC, created_at ASC, node_id ASC, job_id ASC LIMIT 1
                """, [jobID], { (jobID: $0.text(0), nodeID: $0.text(1)) }).first else { return nil }
            let expires = timestamp(now.addingTimeInterval(leaseDurationSeconds))
            let time = timestamp(now)
            let nodes = try db.query("""
                UPDATE job_nodes SET status='running', lease_owner=?, lease_generation=lease_generation+1,
                    lease_expires_at=?, attempt_count=attempt_count+1, updated_at=?
                WHERE job_id=? AND node_id=? AND status='ready' RETURNING \(nodeColumns)
                """, [workerID, expires, time, candidate.jobID, candidate.nodeID]) { try $0.node() }
            guard let node = nodes.first else { throw WorkflowStoreError.invalidStateTransition("Claim lost inside transaction") }
            try db.execute("UPDATE jobs SET status='running', updated_at=? WHERE job_id=?", [time, node.jobID])
            return ClaimedNode(node: node, lease: NodeLease(jobID: node.jobID, nodeID: node.nodeID, owner: workerID,
                                                            generation: node.leaseGeneration, expiresAtISO8601: expires))
        }
    }

    private static let activeLease = """
        job_id=? AND node_id=? AND lease_owner=? AND lease_generation=? AND status IN ('running','verifying')
            AND julianday(lease_expires_at)>julianday(?)
        """

    private func checkLease(_ changes: Int, _ lease: NodeLease) throws {
        guard changes == 1 else {
            throw WorkflowStoreError.leaseRejected(nodeID: lease.nodeID, expectedOwner: lease.owner, generation: lease.generation)
        }
    }

    public func renewLease(_ lease: NodeLease, leaseDurationSeconds: TimeInterval, now: Date) async throws -> NodeLease {
        try db.transaction {
            let expires = timestamp(now.addingTimeInterval(leaseDurationSeconds))
            let time = timestamp(now)
            try checkLease(db.execute("UPDATE job_nodes SET lease_expires_at=?, updated_at=? WHERE \(Self.activeLease)",
                                      [expires, time, lease.jobID, lease.nodeID, lease.owner, String(lease.generation), time]), lease)
            return NodeLease(jobID: lease.jobID, nodeID: lease.nodeID, owner: lease.owner,
                             generation: lease.generation, expiresAtISO8601: expires)
        }
    }

    public func commitNodeResult(lease: NodeLease, status: NodeStatus, outputAssetID: String?, outputPayloadJSON: String?,
                                 lastError: String?, nextRetryAt: Date?, now: Date) async throws {
        guard [.completed, .needsReview, .failed, .cancelled, .paused, .retrying].contains(status),
              status != .retrying || nextRetryAt != nil else {
            throw WorkflowStoreError.invalidStateTransition("Invalid node result or missing retry time")
        }
        try db.transaction {
            let time = timestamp(now)
            // Cancellation may be requested while the executor is classifying a retry.
            let cancelRetry = try status == .retrying && readJob(lease.jobID)?.cancelRequested == true
            let changes = try db.execute("""
                UPDATE job_nodes SET status=?, output_asset_id=?, output_payload_json=?, last_error=?, next_retry_at=?,
                    updated_at=?, lease_owner=NULL, lease_expires_at=NULL WHERE \(Self.activeLease)
                """, [cancelRetry ? "cancelled" : status.rawValue, outputAssetID, outputPayloadJSON, lastError,
                      status == .retrying && !cancelRetry ? nextRetryAt.map(timestamp) : nil, time,
                      lease.jobID, lease.nodeID, lease.owner, String(lease.generation), time])
            try checkLease(changes, lease)
        }
    }

    public func requestCancel(jobID: String, now: Date) async throws -> JobRecord {
        try db.transaction {
            let values = [timestamp(now), jobID]
            try db.execute("""
                UPDATE jobs SET cancel_requested=1, updated_at=?1, status=CASE WHEN EXISTS (
                    SELECT 1 FROM job_nodes WHERE job_id=?2 AND status IN ('running','verifying')
                ) THEN 'running' ELSE 'cancelled' END WHERE job_id=?2
                """, values)
            try db.execute("""
                UPDATE job_nodes SET status='cancelled', next_retry_at=NULL, updated_at=?1
                WHERE job_id=?2 AND status IN ('pending','ready','retrying')
                """, values)
            return try requireJob(jobID)
        }
    }

    public func prepareResume(jobID: String, now: Date) async throws -> JobRecord {
        try db.transaction {
            let values = [timestamp(now), jobID]
            try db.execute("UPDATE jobs SET status='ready', cancel_requested=0, updated_at=?1 WHERE job_id=?2", values)
            try db.execute("""
                UPDATE job_nodes SET status='pending', lease_owner=NULL, lease_expires_at=NULL, next_retry_at=NULL, updated_at=?1
                WHERE job_id=?2 AND (status IN ('cancelled','paused') OR
                    (status IN ('running','verifying') AND julianday(lease_expires_at)<=julianday(?1)))
                """, values)
            return try requireJob(jobID)
        }
    }

    public func recomputeJobStatus(jobID: String, now: Date) async throws -> JobRecord {
        try db.transaction {
            let job = try requireJob(jobID)
            let states = Set(try db.query("SELECT DISTINCT status FROM job_nodes WHERE job_id=?", [jobID]) { $0.text(0) })
            let status: JobStatus
            if states == ["completed"] { status = .completed }
            else if !states.isDisjoint(with: ["running", "verifying"]) { status = .running }
            else if job.cancelRequested { status = .cancelled }
            else if !states.isDisjoint(with: ["ready", "retrying"]) { status = .ready }
            else if states.contains("pending"), try !db.query("""
                SELECT 1 FROM job_nodes WHERE job_id=? AND status='pending' AND \(Self.dependenciesSatisfied) LIMIT 1
                """, [jobID], { $0.integer(0) }).isEmpty { status = .ready }
            else if states.contains("failed") { status = .failed }
            else if states.contains("needs_review") { status = .needsReview }
            else if states.contains("paused") { status = .paused }
            else if states.contains("cancelled") { status = .cancelled }
            else { status = .completed }
            try db.execute("UPDATE jobs SET status=?, updated_at=? WHERE job_id=?", [status.rawValue, timestamp(now), jobID])
            return try requireJob(jobID)
        }
    }
}
