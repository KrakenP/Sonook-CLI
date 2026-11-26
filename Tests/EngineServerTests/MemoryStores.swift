import AudioCore
import Foundation

/// Each server fixture owns a fresh actor. Challenge consumption has the same compare-and-set
/// semantics as the persistent store, including when two confirmations interleave.
actor MemoryStores: AuthStoreProtocol, ProjectStoreProtocol, DistributionStoreProtocol, JobStoreProtocol, SyncStoreProtocol {
    private var challenges: [String: PairingChallengeRecord] = [:]
    private var devices: [String: PairedDeviceRecord] = [:]
    private var projects: [String: ProjectRecord] = [:]
    private var releases: [String: PublishedReleaseRecord] = [:]
    private var jobs: [String: JobSnapshot] = [:]
    private var cursors: [String: PlaybackCursor] = [:]
    private var events: [PlaybackEvent] = []
    private var interactions: [InteractionRecord] = []

    func savePairingChallenge(_ challenge: PairingChallengeRecord) { challenges[challenge.challengeID] = challenge }
    func pairingChallenge(id: String) -> PairingChallengeRecord? { challenges[id] }
    func consumePairingChallenge(id: String, consumedAtISO8601: String) -> Bool {
        guard let challenge = challenges[id], challenge.consumedAtISO8601 == nil else { return false }
        challenges[id]?.consumedAtISO8601 = consumedAtISO8601
        return true
    }

    func savePairedDevice(_ device: PairedDeviceRecord) { devices[device.deviceID] = device }
    func pairedDevice(id: String) -> PairedDeviceRecord? { devices[id] }
    func pairedDevice(tokenHashSHA256: String) -> PairedDeviceRecord? {
        devices.values.first { $0.tokenHashSHA256 == tokenHashSHA256 }
    }
    func listPairedDevices() -> [PairedDeviceRecord] { Array(devices.values) }
    func revokePairedDevice(id: String, revokedAtISO8601: String) -> Bool {
        guard devices[id] != nil else { return false }
        devices[id]?.revokedAtISO8601 = revokedAtISO8601
        return true
    }

    func saveProject(_ project: ProjectRecord) { projects[project.projectID] = project }
    func project(id: String) -> ProjectRecord? { projects[id] }
    func listProjects() -> [ProjectRecord] { Array(projects.values) }
    func savePublishedRelease(_ release: PublishedReleaseRecord) { releases[release.releaseID] = release }
    func publishedRelease(id: String) -> PublishedReleaseRecord? { releases[id] }
    func listPublishedReleases(projectID: String?) -> [PublishedReleaseRecord] {
        releases.values.filter { projectID == nil || $0.projectID == projectID }
    }
    func createJob(_ job: JobRecord, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) {
        jobs[job.jobID] = JobSnapshot(job: job, nodes: nodes, edges: edges)
    }
    func jobSnapshot(jobID: String) -> JobSnapshot? { jobs[jobID] }
    func listJobs(projectID: String?) -> [JobRecord] {
        jobs.values.map(\.job).filter { projectID == nil || $0.projectID == projectID }
    }

    func savePlaybackCursor(_ cursor: PlaybackCursor) { cursors[cursor.projectID] = cursor }
    func loadPlaybackCursor(projectID: String) -> PlaybackCursor? { cursors[projectID] }
    func appendPlaybackEvent(_ event: PlaybackEvent) -> Bool {
        guard !events.contains(where: { $0.eventID == event.eventID && $0.deviceID == event.deviceID })
        else { return false }
        events.append(event)
        return true
    }
    func listPlaybackEvents(projectID: String, limit: Int) -> [PlaybackEvent] {
        Array(events.filter { $0.projectID == projectID }.prefix(limit))
    }
    func saveInteraction(_ record: InteractionRecord) { interactions.append(record) }
    func listInteractions(projectID: String, limit: Int) -> [InteractionRecord] {
        Array(interactions.filter { $0.projectID == projectID }.prefix(limit))
    }

    // Job execution is outside the HTTP surface. Fail if a listing ever tries to mutate a job.
    private struct UnexpectedJobMutation: Error {}
    func refreshReadyNodes(jobID: String, now: Date) throws -> Int { throw UnexpectedJobMutation() }
    func claimNextReadyNode(jobID: String?, workerID: String, leaseDurationSeconds: TimeInterval,
                           now: Date) throws -> ClaimedNode? { throw UnexpectedJobMutation() }
    func renewLease(_ lease: NodeLease, leaseDurationSeconds: TimeInterval, now: Date) throws -> NodeLease {
        throw UnexpectedJobMutation()
    }
    func commitNodeResult(lease: NodeLease, status: NodeStatus, outputAssetID: String?, outputPayloadJSON: String?,
                          lastError: String?, nextRetryAt: Date?, now: Date) throws { throw UnexpectedJobMutation() }
    func requestCancel(jobID: String, now: Date) throws -> JobRecord { throw UnexpectedJobMutation() }
    func prepareResume(jobID: String, now: Date) throws -> JobRecord { throw UnexpectedJobMutation() }
    func recomputeJobStatus(jobID: String, now: Date) throws -> JobRecord { throw UnexpectedJobMutation() }
}
