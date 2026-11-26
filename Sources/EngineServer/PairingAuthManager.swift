import AudioCore
import CryptoKit
import Darwin
import Foundation

public struct PairingAuthManager: Sendable {
    private let store: any AuthStoreProtocol
    private let tokenTTLSeconds: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any AuthStoreProtocol, tokenTTLSeconds: TimeInterval = 90 * 24 * 3600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.tokenTTLSeconds = tokenTTLSeconds
        self.now = now
    }

    public func createPairingChallenge(
        scopes: [AuthScope], ttlSeconds: TimeInterval = 300
    ) async throws -> (challenge: PairingChallengeRecord, plainCode: String) {
        let created = now()
        let code = String(format: "%06u", UInt32.random(in: 0..<1_000_000))
        let challenge = PairingChallengeRecord(
            challengeID: UUID().uuidString, codeHashSHA256: Self.hash(code), scopes: scopes,
            expiresAtISO8601: Self.timestamp(created.addingTimeInterval(ttlSeconds)),
            createdAtISO8601: Self.timestamp(created)
        )
        try await store.savePairingChallenge(challenge)
        return (challenge, code)
    }

    public func confirmPairing(
        challengeID: String, code: String, deviceName: String
    ) async throws -> (device: PairedDeviceRecord, plainBearerToken: String) {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              let challenge = try await store.pairingChallenge(id: challengeID) else { throw EngineServerError.unauthorized }
        let instant = now()
        guard let expiry = Self.date(challenge.expiresAtISO8601), expiry > instant,
              Self.equalHash(Self.hash(code), challenge.codeHashSHA256)
        else { throw EngineServerError.unauthorized }

        let timestamp = Self.timestamp(instant)
        guard try await store.consumePairingChallenge(id: challengeID, consumedAtISO8601: timestamp)
        else { throw EngineServerError.challengeConsumed }

        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let device = PairedDeviceRecord(
            deviceID: UUID().uuidString, deviceName: deviceName, tokenHashSHA256: Self.hash(token),
            scopes: challenge.scopes, pairedAtISO8601: timestamp
        )
        try await store.savePairedDevice(device)
        return (device, token)
    }

    public func authenticate(
        authorizationHeader: String?, requiredScope: AuthScope
    ) async throws -> PairedDeviceRecord {
        try await authenticate(authorizationHeader: authorizationHeader, anyOf: [requiredScope])
    }

    func authenticate(authorizationHeader: String?, anyOf scopes: [AuthScope]) async throws -> PairedDeviceRecord {
        let fields = authorizationHeader?.split(separator: " ")
        guard let fields, fields.count == 2, fields[0].lowercased() == "bearer"
        else { throw EngineServerError.unauthorized }
        let hash = Self.hash(String(fields[1]))
        guard let device = try await store.pairedDevice(tokenHashSHA256: hash), !device.isRevoked,
              Self.equalHash(hash, device.tokenHashSHA256), let paired = Self.date(device.pairedAtISO8601),
              now() < paired.addingTimeInterval(tokenTTLSeconds)
        else { throw EngineServerError.unauthorized }
        guard scopes.contains(where: device.scopes.contains) else { throw EngineServerError.forbidden }
        return device
    }

    public func revokeDevice(deviceID: String) async throws -> Bool {
        try await store.revokePairedDevice(id: deviceID, revokedAtISO8601: Self.timestamp(now()))
    }

    private static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func equalHash(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == 64, rhs.utf8.count == 64 else { return false }
        return lhs.withCString { left in
            rhs.withCString { right in timingsafe_bcmp(left, right, 64) == 0 }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
