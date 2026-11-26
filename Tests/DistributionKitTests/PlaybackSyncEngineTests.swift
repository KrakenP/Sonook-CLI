import AudioCore
import DistributionKit
import Foundation
import Testing

private actor MemorySyncStore: SyncStoreProtocol {
    private struct Identity: Hashable { let device: String; let event: String }
    private var events: [Identity: PlaybackEvent] = [:]
    private var cursors: [String: PlaybackCursor] = [:]
    private var interruptNextSave = false

    enum Fault: Error { case interrupted }
    func interruptCursorSave() { interruptNextSave = true }

    func appendPlaybackEvent(_ event: PlaybackEvent) async throws -> Bool {
        let key = Identity(device: event.deviceID, event: event.eventID)
        guard events[key] == nil else { return false }
        events[key] = event
        return true
    }

    func listPlaybackEvents(projectID: String, limit: Int) async throws -> [PlaybackEvent] {
        Array(events.values.filter { $0.projectID == projectID }.prefix(limit))
    }

    func loadPlaybackCursor(projectID: String) async throws -> PlaybackCursor? { cursors[projectID] }

    func savePlaybackCursor(_ cursor: PlaybackCursor) async throws {
        if interruptNextSave {
            interruptNextSave = false
            throw Fault.interrupted
        }
        cursors[cursor.projectID] = cursor
    }

    func saveInteraction(_ record: InteractionRecord) async throws {}
    func listInteractions(projectID: String, limit: Int) async throws -> [InteractionRecord] { [] }
}

private func event(_ id: String, _ sequence: Int64, _ type: PlaybackEventType, _ position: Int,
                   time: String = AudioPackFixture.timestamp, device: String = "phone", project: String = "book") -> PlaybackEvent {
    PlaybackEvent(eventID: id, deviceID: device, projectID: project, releaseID: "release-1", chapterID: "ch-2",
                  segmentID: "2-b", positionMs: position, eventType: type, deviceSequence: sequence, occurredAtISO8601: time)
}

@Suite("Offline playback sync")
struct PlaybackSyncEngineTests {
    @Test func reconnectDeduplicatesAndPreservesRewindAndBackwardSeek() async throws {
        let store = MemorySyncStore()
        let engine = PlaybackSyncEngine(store: store)
        let batch = [event("3", 3, .rewind, 180), event("1", 1, .play, 100), event("2", 2, .progress, 800)]
        let first = try await engine.ingest(batch)
        #expect(first.acceptedCount == 3)
        #expect(first.duplicateCount == 0)
        #expect(first.rewindPreservedCount == 1)
        #expect(first.cursor?.positionMs == 180)
        let retry = try await engine.ingest(batch.reversed())
        #expect(retry == SyncMergeReport(acceptedCount: 0, duplicateCount: 3, rewindPreservedCount: 0, cursor: first.cursor))
        let restarted = PlaybackSyncEngine(store: store)
        let seek = try await restarted.ingest([event("4", 4, .seek, 50)])
        #expect(seek.rewindPreservedCount == 1)
        #expect(seek.cursor?.positionMs == 50)
        let stale = try await restarted.ingest([event("late", 100, .progress, 850, time: "2025-12-31T23:59:59Z")])
        #expect(stale.acceptedCount == 1)
        #expect(stale.cursor == seek.cursor)
        // Same durable identity, different payload must never update the original or its cursor.
        let collision = try await restarted.ingest([event("2", 999, .progress, 950)])
        #expect(collision.duplicateCount == 1)
        #expect(collision.cursor == seek.cursor)
        #expect(try await store.listPlaybackEvents(projectID: "book", limit: 100).count == 5)
        #expect(try await store.loadPlaybackCursor(projectID: "book") == seek.cursor)
    }

    @Test func timestampsOffsetsSequenceAndEventIDDefineCausalOrder() async throws {
        let engine = PlaybackSyncEngine(store: MemorySyncStore())
        let batch = [
            event("z", 4, .progress, 500, time: "2026-01-01T01:00:00.123456781+01:00"),
            event("c", 2, .seek, 45, time: "2026-01-01T00:00:00.123456782Z"),
            event("a", 2, .progress, 200, time: "2026-01-01T00:00:00.1234567820Z", device: "tablet"),
            event("z", 1, .rewind, 150, time: "2026-01-01T00:00:00.123456782Z", device: "tablet")
        ]
        let report = try await engine.ingest(batch)
        #expect(report.acceptedCount == 4)
        #expect(report.cursor?.lastEventID == "c")
        #expect(report.cursor?.positionMs == 45)
        #expect(report.rewindPreservedCount == 2)
    }

    @Test func interruptedAppendIsProjectedFromDurableOriginalOnRetry() async throws {
        let store = MemorySyncStore()
        let engine = PlaybackSyncEngine(store: store)
        _ = try await engine.ingest([event("a", 1, .progress, 900)])
        await store.interruptCursorSave()
        await #expect(throws: MemorySyncStore.Fault.interrupted) {
            try await engine.ingest([event("b", 2, .rewind, 185)])
        }
        let retry = try await engine.ingest([event("b", 3, .progress, 999)])
        #expect(retry.duplicateCount == 1)
        #expect(retry.cursor?.positionMs == 185)
        #expect(retry.cursor?.lastEventType == .rewind)
        #expect(try await store.loadPlaybackCursor(projectID: "book") == retry.cursor)
    }

    @Test func concurrentReconnectsAndIndependentProjects() async throws {
        let store = MemorySyncStore()
        let engine = PlaybackSyncEngine(store: store)
        let otherEngine = PlaybackSyncEngine(store: store)
        let accepted = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let receiver = i < 20 ? engine : otherEngine
                    return try await receiver.ingest([event("\(i % 20)", Int64(i % 20), .progress, i % 20)]).acceptedCount
                }
            }
            var count = 0
            for try await result in group { count += result }
            return count
        }
        #expect(accepted == 20)
        let report = try await engine.ingest([event("j", 1, .progress, 5, project: "other"), event("old", 0, .play, 0)])
        #expect(report.cursor?.projectID == "other")
        #expect(try await store.loadPlaybackCursor(projectID: "book")?.positionMs == 19)
        #expect(try await store.loadPlaybackCursor(projectID: "other")?.positionMs == 5)
    }

    @Test func segmentMigrationMovesByFiveSecondsAndRemovedSegmentFallsBack() throws {
        try withPackDirectory { folder in
            let old = try AudioPackFixture().release(in: folder, version: 1)
            let updated = try AudioPackFixture(extraPauseMs: 5000).release(in: folder, version: 2)
            let removed = try AudioPackFixture(lastSegmentID: "replacement").release(in: folder, version: 3)
            let cursor = PlaybackCursor(projectID: "book", releaseID: "release-1", chapterID: "ch-2", segmentID: "2-b",
                                        positionMs: 187, lastEventID: "r", lastDeviceID: "phone", lastDeviceSequence: 7,
                                        lastEventType: .rewind, updatedAtISO8601: AudioPackFixture.timestamp)
            let migrated = try PlaybackSyncEngine.migrateCursor(cursor, from: old, to: updated)
            #expect(migrated.releaseID == "release-2")
            #expect(migrated.chapterID == cursor.chapterID)
            #expect(migrated.segmentID == cursor.segmentID)
            #expect(migrated.positionMs == 5187)
            #expect(migrated.lastEventID == cursor.lastEventID)
            #expect(migrated.lastEventType == .rewind)
            let fallback = try PlaybackSyncEngine.migrateCursor(migrated, from: updated, to: removed)
            #expect(fallback.chapterID == cursor.chapterID)
            #expect(fallback.positionMs == 250)
            #expect(fallback.segmentID == nil)
            let restructured = try AudioPackFixture(extraPauseMs: 1000, secondChapterID: "new-chapter").release(in: folder, version: 4)
            let moved = try PlaybackSyncEngine.migrateCursor(cursor, from: old, to: restructured)
            #expect(moved.chapterID == "new-chapter")
            #expect(moved.positionMs == 1187)
        }
    }

    @Test func chapterLocalSegmentIDsDoNotMoveCursorToAnUnrelatedChapter() throws {
        try withPackDirectory { folder in
            let old = try AudioPackFixture(firstChapterLastSegmentID: "2-b").release(in: folder, version: 1)
            let updated = try AudioPackFixture(extraPauseMs: 5000, firstChapterLastSegmentID: "2-b").release(in: folder, version: 2)
            let cursor = PlaybackCursor(projectID: "book", releaseID: "release-1", chapterID: "ch-2", segmentID: "2-b",
                                        positionMs: 187, lastEventID: "r", lastDeviceID: "phone", lastDeviceSequence: 7,
                                        lastEventType: .rewind, updatedAtISO8601: AudioPackFixture.timestamp)
            let mapped = try PlaybackSyncEngine.migrateCursor(cursor, from: old, to: updated)
            #expect(mapped.chapterID == "ch-2")
            #expect(mapped.positionMs == 5187)
            let removed = try AudioPackFixture(lastSegmentID: "replacement", firstChapterLastSegmentID: "2-b").release(in: folder, version: 3)
            let fallback = try PlaybackSyncEngine.migrateCursor(mapped, from: updated, to: removed)
            #expect(fallback.chapterID == "ch-2")
            #expect(fallback.positionMs == 250)
        }
    }
}
