import AudioCore
import Darwin
import EngineSDK
import EngineServer
import Foundation

extension SonookCLI {
    static func runService(command: String, args: [String], jsonMode: Bool) async throws {
        func engine() throws -> SonookEngine { try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args)) }
        func file(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let rest = args.dropFirst()
        switch (command, args.first) {
        case ("publish", _):
            let opts = try AudioCommandOptions(args[...], options: ["--project", "--chapters", "--out", "--title", "--author",
                "--narrator", "--sound-library", "--sfx-helper", "--sfx-license"], switches: ["--soundscape"])
            let report = try await engine().publishAudioPack(projectID: opts.required("--project"), chapterSpec: opts.values["--chapters"],
                outputURL: opts.values["--out"].map(file), title: opts.values["--title"], author: opts.values["--author"],
                narrator: opts.values["--narrator"], soundscapeEnabled: opts.flags.contains("--soundscape"),
                soundLibraryDirectory: opts.values["--sound-library"].map(file), sfxHelperExecutable: opts.values["--sfx-helper"].map(file),
                sfxLicenseTag: opts.values["--sfx-license"], progress: { stderrWrite($0 + "\n") })
            if jsonMode { try printJSON(report) }
            else { print("Published v\(report.release.releaseVersion) (\(report.release.chapterCount) chapters) to \(report.outputPath)") }

        case ("pack", "verify"):
            let opts = try AudioCommandOptions(rest, options: [], pathCount: 1)
            let summary = try engine().verifyAudioPack(packURL: file(opts.paths[0]))
            if jsonMode { try printJSON(summary) }
            else { print("Verified \(summary.manifest.releaseID) (\(summary.verifiedFileCount) checksums)") }

        case ("releases", "list"):
            let opts = try AudioCommandOptions(rest, options: ["--project"])
            let releases = try await engine().listPublishedReleases(projectID: opts.values["--project"])
            if jsonMode { try printJSON(releases) }
            else { for r in releases { print("\(r.releaseID)\tv\(r.releaseVersion)\t\(r.title)\t\(r.packRelativePath)") } }

        case ("sync", "push"):
            let opts = try AudioCommandOptions(rest, options: ["--file"])
            let events = try JSONDecoder().decode([PlaybackEvent].self, from: Data(contentsOf: file(opts.required("--file"))))
            let report = try await engine().syncPlaybackEvents(events)
            if jsonMode { try printJSON(report) }
            else { print("\(report.acceptedCount) accepted, \(report.duplicateCount) duplicates, \(report.rewindPreservedCount) rewinds") }

        case ("sync", "cursor"):
            let opts = try AudioCommandOptions(rest, options: ["--project"])
            let cursor = try await engine().loadPlaybackCursor(projectID: opts.required("--project"))
            if jsonMode { try printJSON(cursor) }
            else if let cursor { print("\(cursor.releaseID)\t\(cursor.chapterID)\t\(cursor.positionMs) ms") }
            else { print("No playback position saved.") }

        case ("context", "query"):
            let opts = try AudioCommandOptions(rest, options: ["--project", "--chapter", "--segment", "--query", "--llm"],
                                               switches: ["--allow-spoilers", "--lexical-only"])
            guard let number = Int(try opts.required("--chapter")), number >= 0 else {
                throw EngineSDKError.invalidInput("--chapter requires a nonnegative integer")
            }
            let request = try SpoilerSafeContextRequest(projectID: opts.required("--project"), maxChapterNumber: number,
                maxSegmentID: opts.values["--segment"], query: opts.required("--query"), allowSpoilers: opts.flags.contains("--allow-spoilers"))
            let response = try await engine().querySpoilerSafeContext(request, llmModelID: opts.values["--llm"],
                                                                      useLLM: !opts.flags.contains("--lexical-only"))
            if jsonMode { try printJSON(response) } else { print(response.answer) }

        case ("server", "pair-code"):
            let opts = try AudioCommandOptions(rest, options: ["--ttl", "--scopes"])
            guard let ttl = Int(opts.values["--ttl"] ?? "300"), ttl > 0 else {
                throw EngineSDKError.invalidInput("--ttl requires a positive number of seconds")
            }
            let scopes = try opts.values["--scopes"]?.components(separatedBy: ",").map {
                guard let scope = AuthScope(rawValue: $0.trimmingCharacters(in: .whitespaces)) else {
                    throw EngineSDKError.invalidInput("Valid scopes: " + AuthScope.allCases.map(\.rawValue).joined(separator: ", "))
                }
                return scope
            } ?? SonookEngine.defaultPairingScopes
            let pairing = try await engine().createPairingChallenge(scopes: scopes, ttlSeconds: ttl)
            let challenge = pairing.challenge
            struct PairCode: Encodable {
                let schema_version: Int
                let challenge_id, code, expires_at: String
                let scopes: [AuthScope]
            }
            if jsonMode {
                try printJSON(PairCode(schema_version: challenge.schemaVersion, challenge_id: challenge.challengeID, code: pairing.plainCode,
                                       expires_at: challenge.expiresAtISO8601, scopes: challenge.scopes))
            } else {
                print("Challenge \(challenge.challengeID)\nCode \(pairing.plainCode)\nExpires \(challenge.expiresAtISO8601)")
            }

        case ("server", "devices"):
            _ = try AudioCommandOptions(rest, options: [])
            let devices = try await engine().listPairedDevices()
            if jsonMode {
                struct Device: Encodable {
                    let schema_version: Int
                    let device_id, device_name, paired_at: String
                    let last_seen_at, revoked_at: String?
                    let scopes: [AuthScope]
                }
                try printJSON(devices.map { Device(schema_version: $0.schemaVersion, device_id: $0.deviceID, device_name: $0.deviceName,
                    paired_at: $0.pairedAtISO8601, last_seen_at: $0.lastSeenAtISO8601, revoked_at: $0.revokedAtISO8601, scopes: $0.scopes) })
            } else {
                for device in devices { print("\(device.deviceID)\t\(device.deviceName)\t\(device.isRevoked ? "revoked" : "paired")") }
            }

        case ("server", "revoke"):
            let opts = try AudioCommandOptions(rest, options: [], pathCount: 1)
            let revoked = try await engine().revokePairedDevice(deviceID: opts.paths[0])
            if jsonMode { try printJSON(["revoked": revoked]) }
            else { print(revoked ? "Device revoked." : "No active device with that ID.") }

        case ("serve", _):
            let opts = try AudioCommandOptions(args[...], options: ["--host", "--port", "--ready-file", "--llm"],
                                               switches: ["--allow-lan", "--llm-context"])
            guard let port = UInt16(opts.values["--port"] ?? "8765") else { throw EngineSDKError.invalidInput("--port must be 0…65535") }
            let host = opts.values["--host"] ?? "127.0.0.1"
            let server = try engine().makeHTTPServer(config: ServerConfig(host: host, port: port, allowLAN: opts.flags.contains("--allow-lan")),
                                                     useLLMContext: opts.flags.contains("--llm-context"), llmModelID: opts.values["--llm"])
            try await serve(server, host: host, readyFile: opts.values["--ready-file"].map(file), jsonMode: jsonMode)

        default:
            throw EngineSDKError.invalidInput("Unknown \(command) action. See sonook \(command) --help.")
        }
    }

    private static func serve(_ server: SonookHTTPServer, host: String, readyFile: URL?, jsonMode: Bool) async throws {
        let (termination, continuation) = AsyncStream<Void>.makeStream()
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.finish() }
            source.resume()
            return source
        }
        defer { for source in signals { source.cancel() } }

        let port = try await server.start()
        struct Endpoint: Encodable { let host: String, port: UInt16, url: String }
        let address = host.contains(":") ? "[\(host)]" : host
        let endpoint = Endpoint(host: host, port: port, url: "http://\(address):\(port)")
        do {
            if let readyFile { try JSONEncoder().encode(endpoint).write(to: readyFile, options: .atomic) }
            stderrWrite("Listening on \(endpoint.url)\n")
            if jsonMode { try printJSON(endpoint) }
            for await _ in termination {}
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
