import Foundation

public enum UnsupportedParameterPolicy: Sendable {
    case strict, degrade
}

public enum ProviderCapabilityError: Error, Equatable, Sendable {
    case unsupportedParameter(String)
    case modelNotLoaded
    case invalidInput(String)
    case cancelled
}

/// Named parameters may accept any backend-validated value or a finite vocabulary
/// (for example available speaker IDs, languages or output sample rates).
public enum ParameterSupport: Equatable, Sendable {
    case anyValue
    case oneOf(Set<String>)

    fileprivate func accepts(_ value: String) -> Bool {
        switch self {
        case .anyValue: true
        case .oneOf(let allowed): allowed.contains(value)
        }
    }
}

public struct LLMCapabilities: Sendable {
    public let parameters: [String: ParameterSupport]
    public init(parameters: [String: ParameterSupport] = [:]) { self.parameters = parameters }
}

public struct TTSCapabilities: Sendable {
    public let parameters: [String: ParameterSupport]
    public init(parameters: [String: ParameterSupport] = [:]) { self.parameters = parameters }
}

public struct ASRCapabilities: Sendable {
    public let parameters: [String: ParameterSupport]
    public init(parameters: [String: ParameterSupport] = [:]) { self.parameters = parameters }
}

public struct DegradationRecord: Codable, Equatable, Sendable {
    public let parameter: String
    public let requestedValue: String
    public let appliedBehavior: String
    public let reason: String

    public init(parameter: String, requestedValue: String, appliedBehavior: String, reason: String) {
        self.parameter = parameter
        self.requestedValue = requestedValue
        self.appliedBehavior = appliedBehavior
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case parameter, requestedValue = "requested_value", appliedBehavior = "applied_behavior", reason
    }
}

public struct InferenceMetrics: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let providerID: String
    public let modelID: String
    public let modelRevision: String
    public let loadDurationMs: Double?
    public let inferenceDurationMs: Double
    public var promptTokens: Int?
    public var outputTokens: Int?
    public let audioDurationSeconds: Double?
    /// Inference time divided by audio duration, excluding model load.
    public let rtf: Double?
    public var peakResidentBytes: UInt64?
    public var degradations: [DegradationRecord]

    public init(providerID: String, modelID: String, modelRevision: String, loadDurationMs: Double? = nil,
                inferenceDurationMs: Double, promptTokens: Int? = nil, outputTokens: Int? = nil,
                audioDurationSeconds: Double? = nil, peakResidentBytes: UInt64? = nil,
                degradations: [DegradationRecord] = []) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.loadDurationMs = loadDurationMs
        self.inferenceDurationMs = inferenceDurationMs
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.audioDurationSeconds = audioDurationSeconds
        self.rtf = audioDurationSeconds.flatMap { $0 > 0 ? inferenceDurationMs / 1000 / $0 : nil }
        self.peakResidentBytes = peakResidentBytes
        self.degradations = degradations
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", providerID = "provider_id", modelID = "model_id", modelRevision = "model_revision"
        case loadDurationMs = "load_duration_ms", inferenceDurationMs = "inference_duration_ms"
        case promptTokens = "prompt_tokens", outputTokens = "output_tokens", audioDurationSeconds = "audio_duration_seconds"
        case rtf, peakResidentBytes = "peak_resident_bytes", degradations
    }
}

public struct LLMRequest: Sendable {
    public let prompt: String
    public var parameters: [String: String]
    public let policy: UnsupportedParameterPolicy

    public init(prompt: String, parameters: [String: String] = [:], policy: UnsupportedParameterPolicy = .strict) {
        self.prompt = prompt
        self.parameters = parameters
        self.policy = policy
    }
}

public struct LLMResponse: Sendable {
    public let text: String
    public var metrics: InferenceMetrics
    public init(text: String, metrics: InferenceMetrics) {
        self.text = text
        self.metrics = metrics
    }
}

public struct SpeechRequest: Sendable {
    public let text: String
    public var parameters: [String: String]
    public let policy: UnsupportedParameterPolicy

    public init(text: String, parameters: [String: String] = [:], policy: UnsupportedParameterPolicy = .strict) {
        self.text = text
        self.parameters = parameters
        self.policy = policy
    }
}

/// Mono PCM. The content digest covers IEEE-754 binary32 samples in little-endian frame order.
public struct SynthesizedAudio: Sendable {
    public let pcmSamples: [Float]
    public let sampleRate: Int
    public var frameCount: Int { pcmSamples.count }
    public let sha256Hex: String
    public var metrics: InferenceMetrics

    public init(pcmSamples: [Float], sampleRate: Int, metrics: InferenceMetrics) throws {
        guard sampleRate > 0, !pcmSamples.isEmpty, pcmSamples.allSatisfy(\.isFinite) else {
            throw ProviderCapabilityError.invalidInput("Invalid synthesized mono PCM")
        }
        self.pcmSamples = pcmSamples
        self.sampleRate = sampleRate
        let words = pcmSamples.map { $0.bitPattern.littleEndian }
        self.sha256Hex = words.withUnsafeBytes { sha256Digest(Data($0)) }
        self.metrics = metrics
    }
}

public struct ASRRequest: Sendable {
    public let pcmSamples: [Float]
    public let sampleRate: Int
    public var parameters: [String: String]
    public let policy: UnsupportedParameterPolicy

    public init(pcmSamples: [Float], sampleRate: Int, parameters: [String: String] = [:],
                policy: UnsupportedParameterPolicy = .strict) {
        self.pcmSamples = pcmSamples
        self.sampleRate = sampleRate
        self.parameters = parameters
        self.policy = policy
    }
}

public struct TranscriptResult: Sendable {
    public let text: String
    public var metrics: InferenceMetrics
    public init(text: String, metrics: InferenceMetrics) {
        self.text = text
        self.metrics = metrics
    }
}

public protocol ModelLifecycle: Sendable {
    var isLoaded: Bool { get async }
    func load() async throws
    func unload() async
}

/// Only capability negotiation constructs this parameter set for an inference call.
public struct AcceptedParameters: Sendable {
    public let values: [String: String]
    fileprivate init(_ values: [String: String]) { self.values = values }
    public subscript(_ key: String) -> String? { values[key] }
}

// Adapter hooks receive accepted parameters only. Adapters must apply them or
// report an explicit error. Public workflow entry points perform negotiation.
public protocol LLMProvider: ModelLifecycle {
    var capabilities: LLMCapabilities { get }
    func generateAccepted(prompt: String, parameters: AcceptedParameters) async throws -> LLMResponse
}

public protocol TTSProvider: ModelLifecycle {
    var capabilities: TTSCapabilities { get }
    func synthesizeAccepted(text: String, parameters: AcceptedParameters) async throws -> SynthesizedAudio
}

public protocol ASRProvider: ModelLifecycle {
    var capabilities: ASRCapabilities { get }
    func transcribeAccepted(pcmSamples: [Float], sampleRate: Int,
                            parameters: AcceptedParameters) async throws -> TranscriptResult
}

private func negotiate(_ requested: [String: String], supported: [String: ParameterSupport],
                       policy: UnsupportedParameterPolicy) throws -> (AcceptedParameters, [DegradationRecord]) {
    var accepted = requested
    var records: [DegradationRecord] = []
    for (key, value) in requested.sorted(by: { $0.key < $1.key }) {
        if supported[key]?.accepts(value) == true { continue }
        guard policy == .degrade else { throw ProviderCapabilityError.unsupportedParameter(key) }
        accepted.removeValue(forKey: key)
        records.append(.init(parameter: key, requestedValue: value, appliedBehavior: "omitted; provider default",
                             reason: supported[key] == nil ? "unsupported parameter" : "unsupported value"))
    }
    return (AcceptedParameters(accepted), records)
}

extension ModelLifecycle {
    fileprivate func requireLoaded() async throws {
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }
        guard await isLoaded else { throw ProviderCapabilityError.modelNotLoaded }
    }
}

extension LLMProvider {
    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        try await requireLoaded()
        guard !request.prompt.isEmpty else { throw ProviderCapabilityError.invalidInput("Empty prompt") }
        let (parameters, records) = try negotiate(request.parameters, supported: capabilities.parameters, policy: request.policy)
        var result = try await generateAccepted(prompt: request.prompt, parameters: parameters)
        result.metrics.degradations += records
        return result
    }
}

extension TTSProvider {
    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedAudio {
        try await requireLoaded()
        guard !request.text.isEmpty else { throw ProviderCapabilityError.invalidInput("Empty speech text") }
        let (parameters, records) = try negotiate(request.parameters, supported: capabilities.parameters, policy: request.policy)
        var result = try await synthesizeAccepted(text: request.text, parameters: parameters)
        result.metrics.degradations += records
        return result
    }
}

extension ASRProvider {
    public func transcribe(_ request: ASRRequest) async throws -> TranscriptResult {
        try await requireLoaded()
        guard request.sampleRate > 0, !request.pcmSamples.isEmpty, request.pcmSamples.allSatisfy(\.isFinite) else {
            throw ProviderCapabilityError.invalidInput("Invalid ASR mono PCM")
        }
        let (parameters, records) = try negotiate(request.parameters, supported: capabilities.parameters, policy: request.policy)
        var result = try await transcribeAccepted(pcmSamples: request.pcmSamples, sampleRate: request.sampleRate,
                                                 parameters: parameters)
        result.metrics.degradations += records
        return result
    }
}
