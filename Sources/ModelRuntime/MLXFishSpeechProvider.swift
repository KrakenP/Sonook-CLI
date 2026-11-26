import AudioCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXRandom

public actor MLXFishSpeechProvider: TTSProvider {
    public static let providerIdentifier = "fish-audio-s2-pro-mlx"

    public let providerID = MLXFishSpeechProvider.providerIdentifier
    public let modelID: String
    public let modelRevision: String
    public let modelDirectory: URL

    public nonisolated let capabilities = TTSCapabilities(parameters: [
        "ref_audio_path": .anyValue,
        "ref_text": .anyValue,
        "inline_tag": .anyValue,
        "max_tokens": .anyValue,
        "temperature": .anyValue,
        "top_p": .anyValue,
        "seed": .anyValue
    ])

    private var model: FishSpeechModel?
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
        model?.sampleRate ?? 44_100
    }

    public func load() async throws {
        if model != nil { return }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }
        let t0 = Date()
        let stage = try StagingDirectoryHelper.createSymlinkStage(from: modelDirectory, prefix: "sonook-fishs2-stage")
        stagingDir = stage
        do {
            model = try await FishSpeechModel.fromModelDirectory(stage)
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
        let maxTokens = parameters["max_tokens"].flatMap(Int.init) ?? 2048
        let temperature = parameters["temperature"].flatMap(Float.init) ?? 0.6
        let topP = parameters["top_p"].flatMap(Float.init) ?? 0.8

        var refAudio: MaterializedArray?
        if let refPath = parameters["ref_audio_path"], !refPath.isEmpty {
            if let cached = cachedRefAudio[refPath] {
                refAudio = cached
            } else {
                let (_, loaded) = try loadAudioArray(from: URL(fileURLWithPath: refPath), sampleRate: model.sampleRate)
                cachedRefAudio[refPath] = loaded
                refAudio = loaded
            }
        }
        let refText = parameters["ref_text"]

        let effectiveText: String
        if let tag = parameters["inline_tag"]?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            effectiveText = "[\(tag)] \(text)"
        } else {
            effectiveText = text
        }

        let genParams = MLXAudioCore.GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )

        let t0 = Date()
        let audio = try await model.generate(
            text: effectiveText,
            voice: nil,
            refAudio: refAudio,
            refText: refText,
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
