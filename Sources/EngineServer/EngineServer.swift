import AudioCore
import Foundation
import Network
import Security

public enum EngineServerInfo: Sendable {
    public static let version = AudioCoreInfo.version
}

public enum EngineServerError: Error, Equatable, Sendable {
    case lanBindingForbidden
    case tlsRequiredForLAN
    case alreadyListening
    case unauthorized
    case forbidden
    case challengeConsumed
}

public struct ServerConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var allowLAN: Bool
    public var requireTLSForLAN: Bool { !allowInsecureLANForTesting }
    public var allowInsecureLANForTesting: Bool
    private let tlsOptions: NWProtocolTLS.Options?
    public var tlsConfigured: Bool { tlsOptions != nil }

    public init(
        host: String = "127.0.0.1", port: UInt16 = 8765,
        allowLAN: Bool = false,
        allowInsecureLANForTesting: Bool = false, tlsIdentity: sec_identity_t? = nil
    ) {
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.allowInsecureLANForTesting = allowInsecureLANForTesting
        self.tlsOptions = tlsIdentity.map { identity in
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            return options
        }
    }

    var isLoopback: Bool { ["127.0.0.1", "::1", "localhost"].contains(host) }

    func listener() throws -> NWListener {
        if !isLoopback {
            guard allowLAN else { throw EngineServerError.lanBindingForbidden }
            guard tlsConfigured || !requireTLSForLAN else { throw EngineServerError.tlsRequiredForLAN }
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let address = NWEndpoint.Host(host == "localhost" ? "127.0.0.1" : host)
        parameters.requiredLocalEndpoint = .hostPort(host: address, port: NWEndpoint.Port(rawValue: port)!)
        return try NWListener(using: parameters)
    }
}

public struct EngineServerDependencies: Sendable {
    public let authStore: any AuthStoreProtocol
    public let distributionStore: any DistributionStoreProtocol
    public let projectStore: any ProjectStoreProtocol
    public let jobStore: any JobStoreProtocol
    public let syncStore: any SyncStoreProtocol
    public let workspaceRoot: URL
    public let syncEventsHandler: @Sendable ([PlaybackEvent]) async throws -> SyncMergeReport
    public let contextQueryHandler: @Sendable (SpoilerSafeContextRequest) async throws -> SpoilerSafeContextResponse
    public let eventStream: ServerEventBus

    public init(
        authStore: any AuthStoreProtocol, distributionStore: any DistributionStoreProtocol,
        projectStore: any ProjectStoreProtocol, jobStore: any JobStoreProtocol,
        syncStore: any SyncStoreProtocol, workspaceRoot: URL,
        syncEventsHandler: @escaping @Sendable ([PlaybackEvent]) async throws -> SyncMergeReport,
        contextQueryHandler: @escaping @Sendable (SpoilerSafeContextRequest) async throws -> SpoilerSafeContextResponse,
        eventStream: ServerEventBus = ServerEventBus()
    ) {
        self.authStore = authStore
        self.distributionStore = distributionStore
        self.projectStore = projectStore
        self.jobStore = jobStore
        self.syncStore = syncStore
        self.workspaceRoot = workspaceRoot
        self.syncEventsHandler = syncEventsHandler
        self.contextQueryHandler = contextQueryHandler
        self.eventStream = eventStream
    }
}
