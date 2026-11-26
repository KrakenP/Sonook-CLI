import AudioCore
import EngineServer
import Foundation
import Testing

struct HTTPFixture {
    struct Device: Decodable { let device_id: String }
    struct Receipt: Decodable {
        let device: Device
        let bearer_token: String
    }

    let store: MemoryStores
    let root: URL
    let bus: ServerEventBus
    let server: SonookHTTPServer
    let session: URLSession
    let base: URL

    static func dependencies(store: MemoryStores, root: URL, bus: ServerEventBus) -> EngineServerDependencies {
        EngineServerDependencies(
            authStore: store, distributionStore: store, projectStore: store, jobStore: store,
            syncStore: store, workspaceRoot: root,
            syncEventsHandler: { events in
                var accepted = 0
                var cursor: PlaybackCursor?
                for event in events where await store.appendPlaybackEvent(event) {
                    accepted += 1
                    cursor = PlaybackCursor(projectID: event.projectID, releaseID: event.releaseID,
                                            chapterID: event.chapterID, positionMs: event.positionMs,
                                            lastEventID: event.eventID, lastDeviceID: event.deviceID,
                                            lastDeviceSequence: event.deviceSequence, lastEventType: event.eventType,
                                            updatedAtISO8601: event.occurredAtISO8601)
                }
                if let cursor { await store.savePlaybackCursor(cursor) }
                return SyncMergeReport(acceptedCount: accepted, duplicateCount: events.count - accepted,
                                       rewindPreservedCount: 0, cursor: cursor)
            },
            contextQueryHandler: { request in
                SpoilerSafeContextResponse(
                    interactionID: "interaction", projectID: request.projectID, maxChapterNumber: request.maxChapterNumber,
                    allowSpoilers: request.allowSpoilers, answer: "Chapter \(request.maxChapterNumber)",
                    spoilerFilterTriggered: true, withheldFutureChapters: 2, knownCharacters: [], evidence: [],
                    resumeAnchor: await store.loadPlaybackCursor(projectID: request.projectID),
                    createdAtISO8601: Date().ISO8601Format()
                )
            }, eventStream: bus
        )
    }

    static func run(host: String = "127.0.0.1", _ test: (Self) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStores()
        let bus = ServerEventBus()
        let server = SonookHTTPServer(config: ServerConfig(host: host, port: 0),
                                      dependencies: dependencies(store: store, root: root, bus: bus))
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let address = host == "::1" ? "[::1]" : "127.0.0.1"
        let fixture = Self(store: store, root: root, bus: bus, server: server, session: session,
                           base: URL(string: "http://\(address):\(port)")!)
        do {
            try await test(fixture)
        } catch {
            session.invalidateAndCancel()
            await server.stop()
            throw error
        }
        session.invalidateAndCancel()
        await server.stop()
    }

    func request(_ path: String, method: String = "GET", token: String? = nil,
                 body: Data? = nil, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    struct Result {
        let data: Data
        let response: HTTPURLResponse
        var status: Int { response.statusCode }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data) }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    func send(_ path: String, method: String = "GET", token: String? = nil,
              body: Data? = nil, range: String? = nil) async throws -> Result {
        let (data, response) = try await session.data(for: request(path, method: method, token: token, body: body, range: range))
        return Result(data: data, response: try #require(response as? HTTPURLResponse))
    }

    func confirm(id: String, code: String) async throws -> Result {
        let data = try JSONEncoder().encode(["challenge_id": id, "code": code, "device_name": "Test reader"])
        return try await send("/v1/pair/confirm", method: "POST", body: data)
    }

    func pair(_ scopes: [AuthScope]) async throws -> Receipt {
        let (challenge, code) = try await server.authManager.createPairingChallenge(scopes: scopes)
        let response = try await confirm(id: challenge.challengeID, code: code)
        try #require(response.status == 200)
        #expect(!String(decoding: response.data, as: UTF8.self).contains("token_hash"))
        return try response.decode(Receipt.self)
    }

    @discardableResult
    func register(pack: String = "published/book.audiopack", id: String = "release") async -> PublishedReleaseRecord {
        let release = PublishedReleaseRecord(
            releaseID: id, projectID: "book", releaseVersion: 1, title: "Book", packRelativePath: pack,
            manifestSHA256: "", chapterCount: 1, totalDurationSeconds: 1, totalByteSize: 1,
            createdAtISO8601: Date().ISO8601Format()
        )
        await store.savePublishedRelease(release)
        return release
    }
}
