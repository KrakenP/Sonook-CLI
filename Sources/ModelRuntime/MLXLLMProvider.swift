import AudioCore
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXRandom
import MLXVLM
import Tokenizers

public actor MLXLocalLLMProvider: LLMProvider {
    public let providerID = "mlx-swift-lm"
    public let modelID: String
    public let modelRevision: String
    public let modelDirectory: URL

    public nonisolated let capabilities = LLMCapabilities(parameters: [
        "system_prompt": .anyValue,
        "max_tokens": .anyValue,
        "temperature": .anyValue,
        "top_p": .anyValue,
        "seed": .anyValue,
        "repetition_penalty": .anyValue,
        "enable_thinking": .oneOf(["true", "false"])
    ])

    private var container: ModelContainer?
    private var lastLoadDurationMs: Double?

    public init(modelDirectory: URL, modelID: String? = nil, modelRevision: String = "local") {
        let resolved = modelDirectory.resolvingSymlinksInPath()
        self.modelDirectory = resolved
        self.modelID = modelID ?? resolved.lastPathComponent
        self.modelRevision = modelRevision
    }

    public var isLoaded: Bool {
        container != nil
    }

    public func load() async throws {
        if container != nil { return }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }
        let t0 = Date()
        container = try await loadModelContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        lastLoadDurationMs = Date().timeIntervalSince(t0) * 1000.0
    }

    public func unload() async {
        container = nil
        MemoryProbe.clearMLXCache()
    }

    public func generateAccepted(prompt: String, parameters: AcceptedParameters) async throws -> LLMResponse {
        guard let container else {
            throw ProviderCapabilityError.modelNotLoaded
        }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }

        let systemPrompt = parameters["system_prompt"] ?? "You are a precise Chinese structured-output assistant."
        let maxTokens = parameters["max_tokens"].flatMap(Int.init) ?? 2048
        let temperature = parameters["temperature"].flatMap(Float.init) ?? 0.0
        let topP = parameters["top_p"].flatMap(Float.init) ?? 0.9
        let enableThinking = (parameters["enable_thinking"] ?? "false") == "true"
        let parsedSeed: UInt64?
        if let seedStr = parameters["seed"] {
            guard let seed = UInt64(seedStr) else {
                throw ProviderCapabilityError.invalidInput("Invalid LLM seed: \(seedStr)")
            }
            MLXRandom.seed(seed)
            parsedSeed = seed
        } else {
            parsedSeed = nil
        }
        let repetitionPenalty: Float?
        if let penaltyStr = parameters["repetition_penalty"] {
            guard let penalty = Float(penaltyStr), penalty.isFinite, penalty > 0 else {
                throw ProviderCapabilityError.invalidInput("Invalid LLM repetition_penalty: \(penaltyStr)")
            }
            repetitionPenalty = penalty
        } else {
            repetitionPenalty = nil
        }

        let genParams = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 64,
            seed: parsedSeed
        )

        let t0 = Date()
        let reply: String = try await {
            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: genParams,
                additionalContext: ["enable_thinking": enableThinking]
            )
            return try await session.respond(to: prompt)
        }()
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0
        let mem = MemoryProbe.currentProcessMemory()
        let loadMs = lastLoadDurationMs
        lastLoadDurationMs = nil

        let metrics = InferenceMetrics(
            providerID: providerID,
            modelID: modelID,
            modelRevision: modelRevision,
            loadDurationMs: loadMs,
            inferenceDurationMs: elapsedMs,
            promptTokens: nil,
            outputTokens: nil,
            audioDurationSeconds: nil,
            peakResidentBytes: max(mem.physFootprint, mem.resident)
        )
        return LLMResponse(text: reply, metrics: metrics)
    }
}
