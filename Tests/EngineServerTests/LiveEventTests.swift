import AudioCore
@testable import EngineServer
import Foundation
import Testing

@Suite("Live playback sync and SSE")
struct LiveEventTests {
    @Test func offlineBatchPublishesLiveEventAndContextResumesAtCursor() async throws {
        try await HTTPFixture.run { fixture in
            let receipt = try await fixture.pair([.syncPlayback, .readCatalog, .queryContext])
            let token = receipt.bearer_token
            let streamRequest = fixture.request("/v1/events", token: token)
            let (bytes, response) = try await fixture.session.bytes(for: streamRequest)
            defer { bytes.task.cancel() }
            #expect(response.mimeType == "text/event-stream")
            var iterator = bytes.makeAsyncIterator()
            let connected = try await frame(&iterator)
            #expect(connected == ": connected\n\n")
            #expect(try await fixture.send("/v1/sync/cursor?project_id=book", token: token).status == 404)

            let event = PlaybackEvent(eventID: "offline", deviceID: receipt.device.device_id, projectID: "book",
                                      releaseID: "release", chapterID: "chapter", positionMs: 1200,
                                      eventType: .pause, deviceSequence: 9, occurredAtISO8601: Date().ISO8601Format())
            let batch = try JSONEncoder().encode([event])
            let sync = try await fixture.send("/v1/sync/events", method: "POST", token: token, body: batch)
            let report = try sync.decode(SyncMergeReport.self)
            #expect(report.acceptedCount == 1 && report.duplicateCount == 0)
            #expect(try await frame(&iterator) == "event: playback_synced\ndata: {\"accepted_count\":1}\n\n")
            let replay = try await fixture.send("/v1/sync/events", method: "POST", token: token, body: batch)
            #expect(try replay.decode(SyncMergeReport.self).duplicateCount == 1)
            let other = try await fixture.pair([.syncPlayback])
            #expect(try await fixture.send("/v1/sync/events", method: "POST", token: other.bearer_token, body: batch).status == 403)
            let cursor = try await fixture.send("/v1/sync/cursor?project_id=book", token: token).decode(PlaybackCursor.self)
            #expect(cursor == report.cursor && cursor.positionMs == 1200 && cursor.lastEventID == event.eventID)
            let request = SpoilerSafeContextRequest(projectID: "book", maxChapterNumber: 3, query: "Recap?")
            let query = try await fixture.send("/v1/context/query", method: "POST", token: token, body: JSONEncoder().encode(request))
            let context = try query.decode(SpoilerSafeContextResponse.self)
            #expect(context.spoilerFilterTriggered && !context.allowSpoilers)
            #expect(context.answer == "Chapter 3" && context.resumeAnchor == cursor)
            bytes.task.cancel()
            try await expectDisconnected(fixture.bus)
        }
    }

    @Test func revokedSubscriberCannotReadLaterEvents() async throws {
        try await HTTPFixture.run { fixture in
            let receipt = try await fixture.pair([.readCatalog])
            let (bytes, _) = try await fixture.session.bytes(for: fixture.request("/v1/events", token: receipt.bearer_token))
            var iterator = bytes.makeAsyncIterator()
            #expect(try await frame(&iterator) == ": connected\n\n")
            await fixture.bus.publish(eventType: "job_updated", payloadJSON: "{\n\"ready\":true\n}")
            #expect(try await frame(&iterator) == "event: job_updated\ndata: {\ndata: \"ready\":true\ndata: }\n\n")
            try #require(try await fixture.server.authManager.revokeDevice(deviceID: receipt.device.device_id))
            await fixture.bus.publish(eventType: "job_updated", payloadJSON: "{}")
            let next = try? await iterator.next()
            #expect(next == nil)
            try await expectDisconnected(fixture.bus)
        }
    }

    @Test func serverShutdownClosesIdleSubscription() async throws {
        try await HTTPFixture.run { fixture in
            let token = try await fixture.pair([.readCatalog]).bearer_token
            let (bytes, _) = try await fixture.session.bytes(for: fixture.request("/v1/events", token: token))
            var iterator = bytes.makeAsyncIterator()
            #expect(try await frame(&iterator) == ": connected\n\n")
            await fixture.server.stop()
            try await expectDisconnected(fixture.bus)
            let next = try? await iterator.next()
            #expect(next == nil)
        }
    }

    private func expectDisconnected(_ bus: ServerEventBus) async throws {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while await bus.subscriberCount > 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await bus.subscriberCount == 0)
    }

    private func frame(_ iterator: inout URLSession.AsyncBytes.AsyncIterator) async throws -> String {
        var data = [UInt8]()
        while let byte = try await iterator.next() {
            data.append(byte)
            if data.suffix(2) == [10, 10] || data.count > 512 { break }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
