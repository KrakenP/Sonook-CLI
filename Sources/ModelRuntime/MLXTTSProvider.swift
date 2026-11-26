import AudioCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXRandom

public enum Qwen3TTSMode: String, Sendable {
    case customVoice = "custom_voice"
    case voiceDesign = "voice_design"
}

public actor MLXQwen3TTSProvider: TTSProvider {
    public static let providerIdentifier = "qwen3-tts-custom-voice"
    public static let voiceDesignProviderIdentifier = "qwen3-tts-voice-design"
    public static let supportedSpeakers: Set<String> = [
        "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna", "Sohee",
        "vivian", "serena", "uncle_fu", "dylan", "eric", "ryan", "aiden", "ono_anna", "sohee"
    ]

    public let mode: Qwen3TTSMode
    public let providerID: String
    public let modelID: String
    public let modelRevision: String
    public let modelDirectory: URL

    public nonisolated let capabilities: TTSCapabilities

    private var model: Qwen3TTSModel?
    private var stagingDir: URL?
    private var lastLoadDurationMs: Double?

    public init(
        modelDirectory: URL,
        mode: Qwen3TTSMode = .customVoice,
        modelID: String? = nil,
        modelRevision: String = "local"
    ) {
        let resolved = modelDirectory.resolvingSymlinksInPath()
        self.modelDirectory = resolved
        self.mode = mode
        self.providerID = mode == .voiceDesign ? Self.voiceDesignProviderIdentifier : Self.providerIdentifier
        self.modelID = modelID ?? resolved.lastPathComponent
        self.modelRevision = modelRevision
        switch mode {
        case .customVoice:
            self.capabilities = TTSCapabilities(parameters: [
                "speaker": .oneOf(MLXQwen3TTSProvider.supportedSpeakers),
                "instruction": .anyValue,
                "language": .oneOf(["Chinese", "English", "Auto"]),
                "temperature": .anyValue,
                "top_p": .anyValue,
                "repetition_penalty": .anyValue,
                "max_tokens": .anyValue,
                "seed": .anyValue
            ])
        case .voiceDesign:
            self.capabilities = TTSCapabilities(parameters: [
                "voice_design_prompt": .anyValue,
                "language": .oneOf(["Chinese", "English", "Auto"]),
                "temperature": .anyValue,
                "top_p": .anyValue,
                "repetition_penalty": .anyValue,
                "max_tokens": .anyValue,
                "seed": .anyValue
            ])
        }
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
        let stage = try StagingDirectoryHelper.createSymlinkStage(from: modelDirectory, prefix: "sonook-qwen3tts-stage")
        stagingDir = stage
        do {
            model = try await Qwen3TTSModel.fromModelDirectory(stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            stagingDir = nil
            throw error
        }
        lastLoadDurationMs = Date().timeIntervalSince(t0) * 1000.0
    }

    public func unload() async {
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

        let language = parameters["language"] ?? "Chinese"
        let maxTokens = parameters["max_tokens"].flatMap(Int.init) ?? 2048
        let temperature = parameters["temperature"].flatMap(Float.init) ?? 0.5
        let topP = parameters["top_p"].flatMap(Float.init) ?? 0.85
        let repetitionPenalty = parameters["repetition_penalty"].flatMap(Float.init) ?? 1.05
        if let seed = parameters["seed"].flatMap(UInt64.init) {
            MLXRandom.seed(seed)
        }

        let voicePrompt: String?
        switch mode {
        case .customVoice:
            let speaker = parameters["speaker"] ?? "Uncle_Fu"
            let instruction = parameters["instruction"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let instruction, !instruction.isEmpty {
                voicePrompt = "\(speaker), \(instruction)"
            } else {
                voicePrompt = speaker
            }
        case .voiceDesign:
            let design = parameters["voice_design_prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            voicePrompt = (design?.isEmpty == false) ? design : "标准普通话中年男声，声音温厚平稳，语速均匀自然"
        }

        let genParams = MLXAudioCore.GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty
        )

        let t0 = Date()
        let audio = try await model.generate(
            text: text,
            voice: voicePrompt,
            refAudio: nil,
            refText: nil,
            language: language,
            generationParameters: genParams
        )
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0
        let samples = audio.asArray(Float.self)
        let sr = model.sampleRate
        let durationSec = Double(samples.count) / Double(sr)
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
