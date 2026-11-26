import AudioCore
import Foundation
import Network

public actor SonookHTTPServer {
    public nonisolated let authManager: PairingAuthManager
    private let config: ServerConfig
    private let router: Router
    private let queue = DispatchQueue(label: "sonook.http")
    private var listener: NWListener?
    private var listenerEnded: AsyncStream<Void>?
    private var clients: [ObjectIdentifier: (NWConnection, Task<Void, Never>)] = [:]

    public init(config: ServerConfig = ServerConfig(), dependencies: EngineServerDependencies) {
        self.config = config
        authManager = PairingAuthManager(store: dependencies.authStore)
        router = Router(dependencies: dependencies, auth: authManager, loopback: config.isLoopback)
    }

    /// Returns the actual port after the listener is ready, including when port zero was requested.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw EngineServerError.alreadyListening }
        let candidate = try config.listener()
        listener = candidate
        let (states, continuation) = AsyncStream<NWListener.State>.makeStream()
        let (ended, ending) = AsyncStream<Void>.makeStream()
        listenerEnded = ended
        candidate.stateUpdateHandler = { state in
            continuation.yield(state)
            switch state {
            case .failed, .cancelled:
                ending.finish()
                continuation.finish()
            case .ready: continuation.finish()
            default: break
            }
        }
        candidate.newConnectionHandler = { [weak self, weak candidate] connection in
            Task {
                guard let self, let candidate else {
                    connection.cancel()
                    return
                }
                await self.accept(connection, from: candidate)
            }
        }
        candidate.start(queue: queue)
        do {
            for await state in states {
                try Task.checkCancellation()
                switch state {
                case .ready:
                    guard listener === candidate, let port = candidate.port else { throw CancellationError() }
                    return port.rawValue
                case let .failed(error), let .waiting(error): throw error
                case .cancelled: throw CancellationError()
                default: continue
                }
            }
            throw CancellationError()
        } catch {
            candidate.cancel()
            if listener === candidate {
                listener = nil
                listenerEnded = nil
            }
            throw error
        }
    }

    public func stop() async {
        let ended = listenerEnded
        listener?.cancel()
        listener = nil
        listenerEnded = nil
        let active = clients.values
        for (connection, task) in active {
            task.cancel()
            connection.cancel()
        }
        for (_, task) in active { await task.value }
        if let ended { for await _ in ended {} }
    }

    deinit {
        listener?.cancel()
        for (connection, task) in clients.values {
            task.cancel()
            connection.cancel()
        }
    }

    private func finished(_ id: ObjectIdentifier) {
        clients.removeValue(forKey: id)
    }

    private func accept(_ connection: NWConnection, from source: NWListener) {
        guard listener === source else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connection.start(queue: queue)
        let task = Task { [weak self, router] in
            await router.serve(connection)
            connection.cancel()
            await self?.finished(id)
        }
        clients[id] = (connection, task)
    }
}

private struct Router: Sendable {
    let dependencies: EngineServerDependencies
    let auth: PairingAuthManager
    let loopback: Bool

    func serve(_ connection: NWConnection) async {
        let response: HTTPResponse
        do {
            let request = try await HTTPRequest.read(from: connection)
            response = try await route(request)
        } catch {
            response = .failure(error)
        }
        // After headers are committed a transport/file error must terminate the response.
        try? await response.write(to: connection)
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.path
        let authorization = request.headers["authorization"]
        func require(_ scope: AuthScope) async throws {
            _ = try await auth.authenticate(authorizationHeader: authorization, requiredScope: scope)
        }
        let projectID = request.query.first { $0.name == "project_id" }?.value
        switch (request.method, path) {
        case ("GET", ["v1", "health"]):
            struct Health: Encodable {
                let engine_version = EngineServerInfo.version
                let schema_version = 1
                let status = "ok"
                let host_mode: String
            }
            return try .json(Health(host_mode: loopback ? "loopback" : "lan"))

        case ("POST", ["v1", "pair", "confirm"]):
            struct Confirmation: Decodable { let challenge_id, code, device_name: String }
            struct Receipt: Encodable {
                let device: PublicDevice
                let bearer_token: String
            }
            let input = try request.decode(Confirmation.self)
            let (device, token) = try await auth.confirmPairing(
                challengeID: input.challenge_id, code: input.code, deviceName: input.device_name
            )
            return try .json(Receipt(device: PublicDevice(device), bearer_token: token))

        case ("GET", ["v1", "devices"]):
            try await require(.admin)
            return try await .json(dependencies.authStore.listPairedDevices().map(PublicDevice.init))

        case ("DELETE", _) where path.count == 3 && path.starts(with: ["v1", "devices"]):
            try await require(.admin)
            guard try await auth.revokeDevice(deviceID: path[2]) else { throw HTTPStatus.notFound }
            return HTTPResponse(status: .noContent)

        case ("GET", ["v1", "projects"]):
            try await require(.readCatalog)
            return try await .json(dependencies.projectStore.listProjects())

        case ("GET", ["v1", "releases"]):
            try await require(.readCatalog)
            return try await .json(dependencies.distributionStore.listPublishedReleases(projectID: projectID))

        case ("GET", _) where path.count >= 4 && path.starts(with: ["v1", "releases"]):
            let filePath: [String]
            if path.count == 4 && path[3] == "manifest" {
                try await require(.readCatalog)
                filePath = ["manifest.json"]
            } else if path.count >= 5 && path[3] == "files" {
                try await require(.downloadMedia)
                filePath = Array(path.dropFirst(4))
            } else {
                throw HTTPStatus.notFound
            }
            guard let release = try await dependencies.distributionStore.publishedRelease(id: path[2])
            else { throw HTTPStatus.notFound }
            return try ReleaseMedia.response(workspace: dependencies.workspaceRoot, release: release,
                                             path: filePath, range: request.headers["range"], ifRange: request.headers["if-range"])

        case ("POST", ["v1", "sync", "events"]):
            let device = try await auth.authenticate(authorizationHeader: authorization, requiredScope: .syncPlayback)
            let events = try request.decode([PlaybackEvent].self)
            guard events.allSatisfy({ $0.deviceID == device.deviceID }) else { throw HTTPStatus.forbidden }
            let report = try await dependencies.syncEventsHandler(events)
            await dependencies.eventStream.publish(eventType: "playback_synced",
                                                  payloadJSON: "{\"accepted_count\":\(report.acceptedCount)}")
            return try .json(report)

        case ("GET", ["v1", "sync", "cursor"]):
            try await require(.syncPlayback)
            guard let projectID, !projectID.isEmpty else { throw HTTPStatus.badRequest }
            guard let cursor = try await dependencies.syncStore.loadPlaybackCursor(projectID: projectID)
            else { throw HTTPStatus.notFound }
            return try .json(cursor)

        case ("POST", ["v1", "context", "query"]):
            try await require(.queryContext)
            return try await .json(dependencies.contextQueryHandler(request.decode(SpoilerSafeContextRequest.self)))

        case ("GET", ["v1", "jobs"]):
            _ = try await auth.authenticate(authorizationHeader: authorization, anyOf: [.readCatalog, .manageJobs])
            return try await .json(dependencies.jobStore.listJobs(projectID: projectID))

        case ("GET", ["v1", "events"]):
            try await require(.readCatalog)
            let events = await dependencies.eventStream.subscribe()
            return HTTPResponse(headers: ["Content-Type": "text/event-stream"], body: .events(events) {
                _ = try await auth.authenticate(authorizationHeader: authorization, requiredScope: .readCatalog)
            })

        default: throw HTTPStatus.notFound
        }
    }
}

// Only this projection crosses the wire. AuthStore keeps the credential verifier private.
private struct PublicDevice: Encodable {
    let schema_version: Int
    let device_id: String
    let device_name: String
    let scopes: [AuthScope]
    let paired_at: String
    let last_seen_at: String?
    let revoked_at: String?

    init(_ record: PairedDeviceRecord) {
        schema_version = record.schemaVersion
        device_id = record.deviceID
        device_name = record.deviceName
        scopes = record.scopes
        paired_at = record.pairedAtISO8601
        last_seen_at = record.lastSeenAtISO8601
        revoked_at = record.revokedAtISO8601
    }
}
