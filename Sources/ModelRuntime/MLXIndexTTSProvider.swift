import AudioCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXRandom

public actor MLXIndexTTSProvider: TTSProvider {
    public static let providerIdentifier = "indextts-1.5-mlx"

    public let providerID = MLXIndexTTSProvider.providerIdentifier
    public let modelID: String
    public let modelRevision: String
    public let modelDirectory: URL

    public nonisolated let capabilities = TTSCapabilities(parameters: [
        "ref_audio_path": .anyValue,
        "max_tokens": .anyValue,
        "temperature": .anyValue,
        "top_p": .anyValue,
        "top_k": .anyValue,
        "seed": .anyValue
    ])

    private var model: IndexTTSModel?
    private var stagingDir: URL?
    private var lastLoadDurationMs: Double?
    private var cachedRefAudio: [String: MaterializedArray] = [:]

    public init(modelDirectory: URL, modelID: String? = nil, modelRevision: String = "local") {
        let resolved = modelDirectory.resolvingSymlinksInPath()
        self.modelDirectory = resolved
        self.modelID = modelID ?? resolved.lastPathComponent
        self.modelRevision = modelRevision
    }

    public var isLoaded: Bool {
        model != nil
    }

    public var sampleRate: Int {
        model?.sampleRate ?? 24_000
    }

    public func load() async throws {
        if model != nil { return }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }
        let t0 = Date()
        let stage = try StagingDirectoryHelper.createSymlinkStage(from: modelDirectory, prefix: "sonook-indextts-stage")
        stagingDir = stage
        do {
            model = try await IndexTTSModel.fromModelDirectory(stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            stagingDir = nil
            throw error
        }
        lastLoadDurationMs = Date().timeIntervalSince(t0) * 1000.0
    }

    public func unload() async {
        cachedRefAudio.removeAll()
        model = nil
        if let stage = stagingDir {
            try? FileManager.default.removeItem(at: stage)
            stagingDir = nil
        }
        MemoryProbe.clearMLXCache()
    }

    public func synthesizeAccepted(text: String, parameters: AcceptedParameters) async throws -> SynthesizedAudio {
        guard let model else {
            throw ProviderCapabilityError.modelNotLoaded
        }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }

        if let seed = parameters["seed"].flatMap(UInt64.init) {
            MLXRandom.seed(seed)
        }
        let requestedMax = parameters["max_tokens"].flatMap(Int.init) ?? model.config.gpt.maxMelTokens
        let maxTokens = min(requestedMax, model.config.gpt.maxMelTokens)
        let temperature = parameters["temperature"].flatMap(Float.init) ?? 0.7
        let topP = parameters["top_p"].flatMap(Float.init) ?? 0.85
        let topK = parameters["top_k"].flatMap(Int.init) ?? 30

        guard let refPath = parameters["ref_audio_path"], !refPath.isEmpty else {
            throw ProviderCapabilityError.invalidInput("IndexTTS requires non-empty ref_audio_path")
        }
        let refAudio: MaterializedArray
        if let cached = cachedRefAudio[refPath] {
            refAudio = cached
        } else {
            let (_, loaded) = try loadAudioArray(from: URL(fileURLWithPath: refPath), sampleRate: model.sampleRate)
            cachedRefAudio[refPath] = loaded
            refAudio = loaded
        }

        let genParams = MLXAudioCore.GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK
        )

        let t0 = Date()
        let audio = try await model.generate(
            text: text,
            voice: nil,
            refAudio: refAudio,
            refText: nil,
            language: nil,
            generationParameters: genParams
        )
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0
        let samples = audio.asArray(Float.self)
        let sr = model.sampleRate
        let durationSec = Double(samples.count) / Double(sr)
        // Reclaim transient Metal allocator pool buffers after each segment so long chapters don't balloon phys_footprint.
        MemoryProbe.clearMLXCache()
        let mem = MemoryProbe.currentProcessMemory()
        let loadMs = lastLoadDurationMs
        lastLoadDurationMs = nil

        let metrics = InferenceMetrics(
            providerID: providerID,
            modelID: modelID,
            modelRevision: modelRevision,
            loadDurationMs: loadMs,
            inferenceDurationMs: elapsedMs,
            audioDurationSeconds: durationSec,
            peakResidentBytes: max(mem.physFootprint, mem.resident)
        )
        return try SynthesizedAudio(pcmSamples: samples, sampleRate: sr, metrics: metrics)
    }
}
