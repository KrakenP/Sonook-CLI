import AudioCore
import CryptoKit
@testable import EngineServer
import Foundation
import Testing

@Suite("EngineServer real HTTP/1.1 clients")
struct EngineServerTests {
    @Test func bindingPolicy() async throws {
        let config = ServerConfig()
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8765)
        #expect(!config.allowLAN && config.requireTLSForLAN && !config.tlsConfigured)
        let dependencies = HTTPFixture.dependencies(store: MemoryStores(), root: .temporaryDirectory, bus: ServerEventBus())
        for host in ["0.0.0.0", "::", "192.0.2.1", "127.0.0.2"] {
            let forbidden = SonookHTTPServer(config: ServerConfig(host: host, port: 0), dependencies: dependencies)
            await #expect(throws: EngineServerError.lanBindingForbidden) { try await forbidden.start() }
            let insecure = SonookHTTPServer(config: ServerConfig(host: host, port: 0, allowLAN: true), dependencies: dependencies)
            await #expect(throws: EngineServerError.tlsRequiredForLAN) { try await insecure.start() }
        }
    }

    @Test(arguments: ["127.0.0.1", "localhost", "::1"])
    func minimalHealth(host: String) async throws {
        try await HTTPFixture.run(host: host) { fixture in
            let health = try await fixture.send("/v1/health")
            #expect(health.status == 200)
            let json = try #require(try JSONSerialization.jsonObject(with: health.data) as? [String: Any])
            #expect(Set(json.keys) == ["status", "engine_version", "schema_version", "host_mode"])
            #expect(json["status"] as? String == "ok")
            #expect(json["host_mode"] as? String == "loopback")
            #expect(json["engine_version"] as? String == "1.0.0")
            #expect(json["schema_version"] as? Int == 1)
        }
    }

    @Test func fixedPortAndExplicitInsecureTestBinding() async throws {
        try await HTTPFixture.run { fixture in
            let port = try #require(fixture.base.port.flatMap(UInt16.init(exactly:)))
            await fixture.server.stop()
            // This alternate IPv6 spelling is outside the exact loopback allowlist but
            // still exercises the LAN policy without exposing a test listener on the LAN.
            let config = ServerConfig(host: "0:0:0:0:0:0:0:1", port: port,
                                      allowLAN: true, allowInsecureLANForTesting: true)
            let server = SonookHTTPServer(config: config, dependencies: HTTPFixture.dependencies(
                store: fixture.store, root: fixture.root, bus: fixture.bus
            ))
            do {
                let actual = try await server.start()
                try #require(actual == port)
                let endpoint = URL(string: "http://[::1]:\(port)/v1/health")!
                let (body, _) = try await fixture.session.data(from: endpoint)
                let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["host_mode"] as? String == "lan")
                await #expect(throws: URLError.self) { try await fixture.send("/v1/health") }
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    @Test func streamedPairConfirmation() async throws {
        try await HTTPFixture.run { fixture in
            let (challenge, code) = try await fixture.server.authManager.createPairingChallenge(scopes: [.readCatalog])
            let body = try JSONEncoder().encode(["challenge_id": challenge.challengeID, "code": code, "device_name": "Stream"])
            var request = fixture.request("/v1/pair/confirm", method: "POST")
            request.httpBodyStream = InputStream(data: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("100-continue", forHTTPHeaderField: "Expect")
            let (data, response) = try await fixture.session.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let receipt = try JSONDecoder().decode(HTTPFixture.Receipt.self, from: data)
            #expect(try await fixture.send("/v1/projects", token: receipt.bearer_token).status == 200)
        }
    }

    @Test func pairingScopesAndRevocation() async throws {
        try await HTTPFixture.run { fixture in
            let (challenge, code) = try await fixture.server.authManager.createPairingChallenge(scopes: [.readCatalog])
            #expect(code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) })
            let stored = await fixture.store.pairingChallenge(id: challenge.challengeID)
            #expect(stored?.codeHashSHA256 == digest(Data(code.utf8)))
            let incorrect = code == "000000" ? "000001" : "000000"
            #expect(try await fixture.confirm(id: challenge.challengeID, code: incorrect).status == 401)

            async let first = fixture.confirm(id: challenge.challengeID, code: code)
            async let second = fixture.confirm(id: challenge.challengeID, code: code)
            let confirmations = try await [first, second]
            #expect(confirmations.map(\.status).sorted() == [200, 409])
            let receipt = try #require(confirmations.first { $0.status == 200 }).decode(HTTPFixture.Receipt.self)
            let deviceID = receipt.device.device_id
            let token = receipt.bearer_token
            let persisted = await fixture.store.pairedDevice(id: deviceID)
            #expect(persisted?.tokenHashSHA256 == digest(Data(token.utf8)))
            #expect(Data(base64Encoded: token)?.count == 32)
            #expect(try await fixture.send("/v1/projects", token: token).status == 200)
            #expect(try await fixture.send("/v1/projects").status == 401)
            #expect(try await fixture.send("/v1/projects", token: "invalid").status == 401)
            #expect(try await fixture.send("/v1/devices", token: token).status == 403)
            #expect(try await fixture.send("/v1/sync/events", method: "POST", token: token).status == 403)
            #expect(try await fixture.send("/v1/context/query", method: "POST", token: token).status == 403)
            #expect(try await fixture.send("/v1/releases/r/files/a", token: token).status == 403)
            let admin = try await fixture.pair([.admin]).bearer_token
            let list = try await fixture.send("/v1/devices", token: admin)
            #expect(list.status == 200)
            let visible = try list.decode([HTTPFixture.Device].self)
            #expect(visible.contains { $0.device_id == deviceID })
            #expect(!String(decoding: list.data, as: UTF8.self).contains("token_hash"))
            #expect(try await fixture.send("/v1/devices/\(deviceID)", method: "DELETE", token: admin).status == 204)
            #expect(try await fixture.send("/v1/projects", token: token).status == 401)
        }
    }

    @Test func expiredCredentialsAtHTTPBoundary() async throws {
        try await HTTPFixture.run { fixture in
            let clock = PairingAuthManager(store: fixture.store, now: { Date(timeIntervalSince1970: 1_000) })
            let expired = try await clock.createPairingChallenge(scopes: [.admin])
            #expect(try await fixture.confirm(id: expired.challenge.challengeID, code: expired.plainCode).status == 401)
            let (_, token) = try await clock.confirmPairing(challengeID: expired.challenge.challengeID,
                                                           code: expired.plainCode, deviceName: "Old reader")
            #expect(try await fixture.send("/v1/devices", token: token).status == 401)
        }
    }

    @Test func catalogManifestAndJobScopes() async throws {
        try await HTTPFixture.run { fixture in
            let project = ProjectRecord(projectID: "book", name: "Book", createdAtISO8601: Date().ISO8601Format())
            let job = JobRecord(jobID: "job", projectID: "book", workflowKind: "publish", createdAtISO8601: project.createdAtISO8601)
            await fixture.store.saveProject(project)
            await fixture.store.createJob(job, nodes: [], edges: [])
            let release = await fixture.register()
            let pack = fixture.root.appendingPathComponent(release.packRelativePath)
            try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            let manifest = Data(#"{"format_version":1}"#.utf8)
            try manifest.write(to: pack.appendingPathComponent("manifest.json"))
            let token = try await fixture.pair([.readCatalog]).bearer_token
            #expect(try await fixture.send("/v1/projects", token: token).decode([ProjectRecord].self) == [project])
            #expect(try await fixture.send("/v1/releases", token: token).decode([PublishedReleaseRecord].self) == [release])
            #expect(try await fixture.send("/v1/releases?project_id=other", token: token).decode([PublishedReleaseRecord].self).isEmpty)
            #expect(try await fixture.send("/v1/releases/release/manifest", token: token).data == manifest)
            #expect(try await fixture.send("/v1/jobs", token: token).decode([JobRecord].self) == [job])
            let jobs = try await fixture.pair([.manageJobs]).bearer_token
            #expect(try await fixture.send("/v1/jobs", token: jobs).decode([JobRecord].self) == [job])
            #expect(try await fixture.send("/v1/events", token: jobs).status == 403)
            #expect(try await fixture.send("/v1/releases", token: jobs).status == 403)
        }
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
