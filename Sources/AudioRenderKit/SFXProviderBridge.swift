import AudioCore
import AVFoundation
import Foundation

public enum SFXBridgeError: Error, Equatable {
    case invalidConfiguration(String)
    case timedOut
    case helperFailed(Int32)
    case invalidOutput(String)
}

#if os(macOS)
/// Local helper protocol v1. argv is always ["--request-json", "request.json"] in a private
/// working directory. The helper writes output.wav and metadata.json (schema_version: 1,
/// optional license). Only request.json contains user text. Model identity is pinned by the caller.
public actor SubprocessSFXProvider: SFXProvider {
    public let providerID: String
    public let capabilities: SFXCapabilities
    private let executable: URL
    private let modelID: String
    private let modelRevision: String
    private let license: String?
    private let timeout: Duration
    private var loaded = false

    public init(executable: URL, providerID: String, modelID: String, modelRevision: String,
                license: String? = nil, capabilities: SFXCapabilities = .init(),
                timeout: Duration = .seconds(120)) {
        self.executable = executable
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.license = license
        self.capabilities = capabilities
        self.timeout = timeout
    }

    public func load() throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path),
              !providerID.isEmpty, !modelID.isEmpty, !modelRevision.isEmpty, timeout > .zero,
              capabilities.maxDurationSeconds.isFinite, capabilities.maxDurationSeconds > 0,
              capabilities.defaultSampleRate > 0 else {
            throw SFXBridgeError.invalidConfiguration("Expected a local executable, model identity and positive limits")
        }
        loaded = true
    }

    public func unload() { loaded = false }

    public func generateSFX(_ request: SFXRequest) async throws -> SFXResult {
        try Task.checkCancellation()
        guard loaded else { throw ProviderCapabilityError.modelNotLoaded }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.durationSeconds.isFinite, request.durationSeconds > 0 else {
            throw ProviderCapabilityError.invalidInput("Expected a prompt and positive finite duration")
        }
        var degradations = [DegradationRecord]()
        var parameters = request.parameters
        for (key, value) in request.parameters.sorted(by: { $0.key < $1.key }) {
            switch capabilities.parameters[key] {
            case .anyValue: continue
            case .oneOf(let allowed) where allowed.contains(value): continue
            default:
                guard request.policy == .degrade else { throw ProviderCapabilityError.unsupportedParameter(key) }
                parameters.removeValue(forKey: key)
                degradations.append(.init(parameter: key, requestedValue: value, appliedBehavior: "omitted",
                                          reason: "unsupported parameter or value"))
            }
        }
        let duration = min(request.durationSeconds, capabilities.maxDurationSeconds)
        if duration != request.durationSeconds {
            guard request.policy == .degrade else { throw ProviderCapabilityError.unsupportedParameter("duration_seconds") }
            degradations.append(.init(parameter: "duration_seconds", requestedValue: String(request.durationSeconds),
                                      appliedBehavior: String(duration), reason: "provider duration limit"))
        }

        struct Input: Encodable {
            let schema_version = 1
            let prompt: String
            let duration_seconds: Double
            let seed: UInt64
            let sample_rate: Int
            let parameters: [String: String]
        }
        struct Output: Decodable {
            let schema_version: Int
            let license: String?
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-sfx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = Input(prompt: request.prompt, duration_seconds: duration, seed: request.seed,
                          sample_rate: capabilities.defaultSampleRate, parameters: parameters)
        try JSONEncoder().encode(input).write(to: dir.appendingPathComponent("request.json"))

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = dir
        process.arguments = ["--request-json", "request.json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let start = ContinuousClock.now
        let deadline = start + timeout
        try process.run()
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw SFXBridgeError.timedOut }
                try await Task.sleep(until: min(deadline, .now + .milliseconds(20)), clock: .continuous)
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                let pid = process.processIdentifier
                // Foundation normally starts a separate process group; include helper workers in that case,
                // and always fall back to direct PID SIGKILL / terminate() in restricted sandboxes.
                if getpgid(pid) == pid {
                    _ = kill(-pid, SIGKILL)
                }
                _ = kill(pid, SIGKILL)
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }
        guard process.terminationStatus == 0 else { throw SFXBridgeError.helperFailed(process.terminationStatus) }
        let metaURL = try SoundFile.checkedURL(root: dir, relativePath: "metadata.json")
        let meta = try JSONDecoder().decode(Output.self, from: Data(contentsOf: metaURL))
        let tag = (meta.license ?? license ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard meta.schema_version == 1, !tag.isEmpty else { throw SFXBridgeError.invalidOutput("Missing version or license") }

        let wav = try SoundFile.checkedURL(root: dir, relativePath: "output.wav")
        let handle = try FileHandle(forReadingFrom: wav)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard SFXWAVMetadata.isWAV(header) else { throw SFXBridgeError.invalidOutput("Expected RIFF/WAVE") }
        let file = try AVAudioFile(forReading: wav)
        guard file.length > 0, Double(file.length) <= ceil(capabilities.maxDurationSeconds * file.processingFormat.sampleRate)
        else { throw SFXBridgeError.invalidOutput("WAV exceeds provider duration limit or is empty") }
        let (samples, rate) = try PCMCodec.readMonoSamples(from: wav)
        guard Int64(samples.count) == file.length else { throw SFXBridgeError.invalidOutput("Incomplete helper WAV") }
        let elapsed = start.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let metrics = InferenceMetrics(providerID: providerID, modelID: modelID, modelRevision: modelRevision,
                                       inferenceDurationMs: ms, audioDurationSeconds: Double(samples.count) / Double(rate),
                                       degradations: degradations)
        let audio = try SynthesizedAudio(pcmSamples: samples, sampleRate: rate, metrics: metrics)
        return SFXResult(audio: audio, licenseTag: tag, metrics: metrics)
    }
}
#endif

/// A single immutable workspace asset contains the audio and its generation receipt. RIFF readers
/// skip the ancillary snFX chunk. Its size and padding follow the same rules as the PCM data chunk.
struct SFXWAVMetadata: Codable {
    let schemaVersion: Int
    let license: String
    let cueID: String
    let prompt: String
    let durationSeconds: Double
    let seed: UInt64
    let cacheKey: String
    let metrics: InferenceMetrics

    static func isWAV(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4).elementsEqual("RIFF".utf8) && data[8..<12].elementsEqual("WAVE".utf8)
    }

    func embed(in wav: inout Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        guard Self.isWAV(wav), let size = UInt32(exactly: json.count),
              let riffSize = UInt32(exactly: wav.count + json.count + (json.count % 2)) else {
            throw SFXBridgeError.invalidOutput("Invalid WAV or RIFF size")
        }
        wav.append(contentsOf: "snFX".utf8)
        withUnsafeBytes(of: size.littleEndian) { wav.append(contentsOf: $0) }
        wav.append(json)
        if !json.count.isMultiple(of: 2) { wav.append(0) }
        withUnsafeBytes(of: riffSize.littleEndian) { wav.replaceSubrange(4..<8, with: $0) }
    }

    static func read(_ wav: Data) throws -> Self {
        guard isWAV(wav) else { throw SFXBridgeError.invalidOutput("Invalid cached WAV") }
        var offset = 12
        while offset + 8 <= wav.count {
            let size = wav.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))) }
            let start = offset + 8
            guard start + size <= wav.count else { break }
            if wav[offset..<offset + 4].elementsEqual("snFX".utf8) {
                let receipt = try JSONDecoder().decode(Self.self, from: wav[start..<start + size])
                guard receipt.schemaVersion == 1, !receipt.license.isEmpty else { break }
                return receipt
            }
            offset = start + size + size % 2
        }
        throw SFXBridgeError.invalidOutput("Missing or malformed SFX generation receipt")
    }
}

public struct ResolvedSoundAsset: Sendable {
    public let assetID: String
    public let fileURL: URL
    public let fileSHA256: String
    public let license: String

    private let libraryPath: (root: URL, relative: String)?

    init(entry: SoundLibraryEntry, library: SoundLibraryRegistry) throws {
        self.libraryPath = (library.rootDirectory, entry.relativePath)
        self.assetID = entry.entryID
        self.fileURL = try library.fileURL(for: entry)
        self.fileSHA256 = entry.fileSHA256.lowercased()
        self.license = entry.license
    }

    fileprivate init(record: AssetRecord, url: URL, license: String) {
        self.libraryPath = nil
        self.assetID = record.assetID
        self.fileURL = url
        self.fileSHA256 = record.fileSHA256
        self.license = license
    }

    func checkedFileURL() throws -> URL {
        if let libraryPath { return try SoundFile.checkedURL(root: libraryPath.root, relativePath: libraryPath.relative) }
        return fileURL
    }
}

public struct SFXResolution: Sendable {
    public enum Source: Sendable { case library, cache, generated, unresolved }
    public let cue: SFXCue
    public let source: Source
    public let asset: ResolvedSoundAsset?

    fileprivate init(_ cue: SFXCue, _ source: Source, _ asset: ResolvedSoundAsset? = nil) {
        var cue = cue
        cue.resolvedAssetID = asset?.assetID
        self.cue = cue
        self.source = source
        self.asset = asset
    }
}

public struct SFXAssetResolver: Sendable {
    /// The caller owns the provider's load/unload lifecycle. Cache-only mode works after a restart
    /// without having the helper or model installed.
    public enum Backend: Sendable {
        case provider(any SFXProvider, modelRevision: String)
        case cacheOnly(providerID: String, modelRevision: String)

        fileprivate var identity: (id: String, revision: String) {
            switch self {
            case .provider(let provider, let revision): (provider.providerID, revision)
            case .cacheOnly(let id, let revision): (id, revision)
            }
        }
    }

    private let store: any ArtifactStoreProtocol
    private let projectID: String
    private let library: SoundLibraryRegistry?
    private let backend: Backend?

    public init(store: any ArtifactStoreProtocol, projectID: String, library: SoundLibraryRegistry? = nil,
                backend: Backend? = nil) {
        self.store = store
        self.projectID = projectID
        self.library = library
        self.backend = backend
    }

    public func resolve(_ cues: [SFXCue], scriptRevision: Int? = nil,
                        sourceDocumentRevision: String? = nil) async throws -> [SFXResolution] {
        var resolutions: [SFXResolution] = []
        var index: [String: AssetRecord]?
        for cue in cues {
            try Task.checkCancellation()
            if let library, let entry = library.resolveSFXEntry(for: cue) {
                resolutions.append(try SFXResolution(cue, .library, ResolvedSoundAsset(entry: entry, library: library)))
                continue
            }
            guard let backend else {
                resolutions.append(.init(cue, .unresolved))
                continue
            }
            let request = SFXRequest(prompt: cue.soundPrompt, durationSeconds: cue.durationSeconds)
            let identity = backend.identity
            let key = request.cacheKey(providerID: identity.id, modelRevision: identity.revision)
            if index == nil {
                let records = try await store.listAssets(projectID: projectID, kind: .sfxAudio)
                index = [:]
                for record in records where record.provenance.providerID == identity.id && record.provenance.modelRevision == identity.revision {
                    if let key = record.provenance.inputFingerprint { index?[key] = record }
                }
            }
            if let record = index?[key] {
                let wav = try await store.readVerifiedData(for: record.assetID)
                let receipt = try SFXWAVMetadata.read(wav)
                guard receipt.cacheKey == key, receipt.metrics.providerID == identity.id,
                      receipt.metrics.modelRevision == identity.revision else {
                    throw SFXBridgeError.invalidOutput("Cached SFX provenance mismatch")
                }
                let url = try await store.resolveFileURL(for: record.assetID)
                resolutions.append(.init(cue, .cache, .init(record: record, url: url, license: receipt.license)))
                continue
            }
            guard case .provider(let provider, _) = backend else {
                resolutions.append(.init(cue, .unresolved))
                continue
            }
            let result = try await provider.generateSFX(request)
            let metrics = result.metrics
            guard metrics.providerID == identity.id, metrics.modelRevision == identity.revision, !metrics.modelID.isEmpty,
                  !result.licenseTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SFXBridgeError.invalidOutput("Missing license or incompatible provider/model identity")
            }
            let audio = result.audio
            var wav = try PCMCodec.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
            let receipt = SFXWAVMetadata(schemaVersion: 1, license: result.licenseTag, cueID: cue.cueID,
                                         prompt: request.prompt, durationSeconds: request.durationSeconds,
                                         seed: request.seed, cacheKey: key, metrics: metrics)
            try receipt.embed(in: &wav)
            let provenance = AssetProvenance(sourceDocumentRevision: sourceDocumentRevision, chapterID: cue.chapterID,
                                             segmentID: cue.anchorSegmentID, scriptRevision: scriptRevision,
                                             providerID: identity.id, modelID: metrics.modelID,
                                             modelRevision: identity.revision, inputFingerprint: key)
            try Task.checkCancellation()
            let record = try await store.commitBytes(wav, projectID: projectID, kind: .sfxAudio, fileExtension: "wav",
                                                     sampleRate: audio.sampleRate, frameCount: audio.frameCount, provenance: provenance)
            index?[key] = record
            let url = try await store.resolveFileURL(for: record.assetID)
            resolutions.append(.init(cue, .generated, .init(record: record, url: url, license: result.licenseTag)))
        }
        return resolutions
    }
}
