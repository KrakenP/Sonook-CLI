import AudioCore
import Foundation
import StorageKit
import Testing

private let now = "2026-01-01T00:00:00Z"
private let later = "2026-01-01T00:05:00Z"

private func race(_ stores: [SQLiteWorkspaceStore],
                  _ operation: @escaping @Sendable (SQLiteWorkspaceStore) async throws -> Bool) async throws -> Int {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        for store in stores { group.addTask { try await operation(store) } }
        var wins = 0
        for try await won in group where won { wins += 1 }
        return wins
    }
}

@Test func pairingChallengeHasExactlyOneWinnerAcrossConnections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stores = try (0..<8).map { _ in try SQLiteWorkspaceStore(rootDirectory: root) }
    let auth: any AuthStoreProtocol = stores[0]
    var challenge = PairingChallengeRecord(challengeID: "challenge", codeHashSHA256: "hash", scopes: [.syncPlayback],
                                          expiresAtISO8601: later, createdAtISO8601: now)
    try await auth.savePairingChallenge(challenge)
    #expect(try await auth.pairingChallenge(id: "challenge") == challenge)
    #expect(try await !auth.consumePairingChallenge(id: "challenge", consumedAtISO8601: later))
    #expect(try await race(stores) { try await $0.consumePairingChallenge(id: "challenge", consumedAtISO8601: now) } == 1)
    try await auth.savePairingChallenge(challenge) // A stale copy must not reopen the challenge.
    challenge.consumedAtISO8601 = now
    #expect(try await auth.pairingChallenge(id: "challenge") == challenge)
    #expect(try await !auth.consumePairingChallenge(id: "missing", consumedAtISO8601: now))
}

@Test func tokenLookupIncludesRevokedDevicesAndEnforcesUniqueHashes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let auth: any AuthStoreProtocol = try SQLiteWorkspaceStore(rootDirectory: root)
    var device = PairedDeviceRecord(deviceID: "phone", deviceName: "手机", tokenHashSHA256: "digest",
                                    scopes: [.readCatalog], pairedAtISO8601: now)
    try await auth.savePairedDevice(device)
    #expect(try await auth.pairedDevice(tokenHashSHA256: "digest") == device)
    #expect(try await auth.pairedDevice(tokenHashSHA256: "unknown") == nil)
    await #expect(throws: WorkflowStoreError.self) {
        try await auth.savePairedDevice(.init(deviceID: "other", deviceName: "other", tokenHashSHA256: "digest",
                                               scopes: [], pairedAtISO8601: now))
    }
    #expect(try await auth.revokePairedDevice(id: "phone", revokedAtISO8601: later))
    #expect(try await !auth.revokePairedDevice(id: "phone", revokedAtISO8601: now))
    try await auth.savePairedDevice(device)
    device.revokedAtISO8601 = later
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.pairedDevice(id: "phone") == device)
    #expect(try await reopened.pairedDevice(tokenHashSHA256: "digest") == device)
    #expect(try await reopened.listPairedDevices() == [device])
}

@Test func offlineEventsDeduplicateByDeviceAndEventAndNeverOverwriteOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stores = try (0..<6).map { _ in try SQLiteWorkspaceStore(rootDirectory: root) }
    let sync: any SyncStoreProtocol = stores[0]
    func event(_ device: String, _ sequence: Int64, project: String = "p") -> PlaybackEvent {
        .init(eventID: "event", deviceID: device, projectID: project, releaseID: "release", chapterID: "c",
              positionMs: 123, eventType: .progress, deviceSequence: sequence, occurredAtISO8601: now)
    }
    let original = event("a", 1), second = event("b", 2), other = event("c", 3, project: "other")
    #expect(try await race(stores) { try await $0.appendPlaybackEvent(original) } == 1)
    #expect(try await !sync.appendPlaybackEvent(event("a", 9, project: "other")))
    #expect(try await sync.appendPlaybackEvent(second))
    #expect(try await sync.appendPlaybackEvent(other))
    #expect(try await sync.listPlaybackEvents(projectID: "p", limit: 5) == [original, second])
    #expect(try await sync.listPlaybackEvents(projectID: "other", limit: 1) == [other])
    #expect(try await sync.listPlaybackEvents(projectID: "p", limit: 0).isEmpty)
}

@Test func publishedReleasesPlaybackCursorsAndInteractionsSurviveReopening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    let distribution: any DistributionStoreProtocol = store
    func release(_ id: String, _ project: String, _ version: Int) -> PublishedReleaseRecord {
        .init(releaseID: id, projectID: project, releaseVersion: version, title: "书", packRelativePath: "packs/r",
              manifestSHA256: "digest", chapterCount: 3, totalDurationSeconds: 43.5, totalByteSize: 4000, createdAtISO8601: now)
    }
    let first = release("r1", "p", 1), second = release("r2", "p", 2), other = release("r3", "q", 1)
    for item in [other, second, first] { try await distribution.savePublishedRelease(item) }
    let cursor = PlaybackCursor(projectID: "p", releaseID: "r1", chapterID: "c", segmentID: "s", positionMs: 400,
                                lastEventID: "e", lastDeviceID: "d", lastDeviceSequence: 7, lastEventType: .rewind, updatedAtISO8601: later)
    try await store.savePlaybackCursor(cursor)
    func interaction(_ id: String, _ project: String, _ date: String) -> InteractionRecord {
        .init(interactionID: id, projectID: project, query: "问题", answer: "摘录", maxChapterNumber: 2, allowSpoilers: false,
              spoilerFilterTriggered: true, resumeReleaseID: "r1", resumeChapterID: "c", resumeSegmentID: "s",
              resumePositionMs: 400, createdAtISO8601: date)
    }
    let earlier = interaction("one", "p", now), latest = interaction("two", "p", later)
    for item in [latest, earlier, interaction("three", "q", later)] { try await store.saveInteraction(item) }
    let reopened = try SQLiteWorkspaceStore(rootDirectory: root)
    #expect(try await reopened.publishedRelease(id: "r1") == first)
    #expect(try await reopened.listPublishedReleases(projectID: "p") == [second, first])
    #expect(try await reopened.listPublishedReleases(projectID: nil) == [second, first, other])
    #expect(try await reopened.loadPlaybackCursor(projectID: "p") == cursor)
    #expect(try await reopened.loadPlaybackCursor(projectID: "q") == nil)
    #expect(try await reopened.listInteractions(projectID: "p", limit: 1) == [latest])
    #expect(try await reopened.listInteractions(projectID: "p", limit: 9) == [latest, earlier])
}

@Test func contextChapterIndexReadsOnlyFutureTitlesFromTheLatestRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteWorkspaceStore(rootDirectory: root)
    try await store.saveProject(.init(projectID: "p", name: "book", createdAtISO8601: now))
    try await store.saveSourceDocument(source("old", at: now, count: 1), chapters: [chapter("stale", number: 9, revision: "old")])
    let heard = try chapter("heard", number: 1, revision: "new")
    try await store.saveSourceDocument(source("new", at: later, count: 2), chapters: [heard, chapter("future", number: 3, revision: "new")])
    // The future row has enough metadata to guard the output, but cannot decode as a ChapterRecord.
    _ = try sqlite(root.appendingPathComponent("sonook.sqlite"), """
        UPDATE chapters SET document='{"title":"later title"}' WHERE chapter_id='future'
        """)
    let index = try await store.contextChapters(projectID: "p", maxChapterNumber: 2)
    #expect(index.allowed == [heard] && index.futureTitles == ["later title"])
}
