import AVFoundation
import AudioCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

public actor MLXQwen3ASRProvider: ASRProvider {
    public let providerID = "qwen3-asr-mlx"
    public let modelID: String
    public let modelRevision: String
    public let modelDirectory: URL

    public nonisolated let capabilities = ASRCapabilities(parameters: [
        "language": .oneOf(["Chinese", "English", "Cantonese", "Auto"])
    ])

    private var model: Qwen3ASRModel?
    private var stagingDir: URL?
    private var lastLoadDurationMs: Double?

    public init(modelDirectory: URL, modelID: String? = nil, modelRevision: String = "local") {
        let resolved = modelDirectory.resolvingSymlinksInPath()
        self.modelDirectory = resolved
        self.modelID = modelID ?? resolved.lastPathComponent
        self.modelRevision = modelRevision
    }

    public var isLoaded: Bool {
        model != nil
    }

    public func load() async throws {
        if model != nil { return }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }
        let t0 = Date()
        let stage = try StagingDirectoryHelper.createSymlinkStage(from: modelDirectory, prefix: "sonook-asr-stage")
        stagingDir = stage
        do {
            model = try await Qwen3ASRModel.fromModelDirectory(stage)
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

    public func transcribeAccepted(
        pcmSamples: [Float],
        sampleRate: Int,
        parameters: AcceptedParameters
    ) async throws -> TranscriptResult {
        guard let model else {
            throw ProviderCapabilityError.modelNotLoaded
        }
        if Task.isCancelled { throw ProviderCapabilityError.cancelled }

        let targetSR = 16_000
        let resampled: [Float]
        if sampleRate == targetSR {
            resampled = pcmSamples
        } else {
            resampled = try AudioResampler.resampleMono(pcmSamples, from: sampleRate, to: targetSR)
        }

        let language = parameters["language"] ?? "Chinese"
        let audioArray = MLXArray(resampled)
        let t0 = Date()
        let output = model.generate(audio: audioArray, language: language)
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0
        let durationSec = Double(pcmSamples.count) / Double(sampleRate)
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
        return TranscriptResult(text: output.text, metrics: metrics)
    }
}

enum AudioResampler {
    static func resampleMono(_ samples: [Float], from sourceSR: Int, to targetSR: Int) throws -> [Float] {
        guard sourceSR > 0, targetSR > 0, !samples.isEmpty else {
            throw ProviderCapabilityError.invalidInput("Invalid audio sample rate or empty PCM")
        }
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceSR), channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSR), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw ProviderCapabilityError.invalidInput("Unable to initialize AVAudioConverter")
        }

        let inputFrames = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inputFrames) else {
            throw ProviderCapabilityError.invalidInput("Unable to allocate input PCM buffer")
        }
        inputBuffer.frameLength = inputFrames
        samples.withUnsafeBufferPointer { src in
            if let dst = inputBuffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }

        let ratio = Double(targetSR) / Double(sourceSR)
        let outputCapacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputCapacity) else {
            throw ProviderCapabilityError.invalidInput("Unable to allocate output PCM buffer")
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error, let error {
            throw error
        }
        let count = Int(outputBuffer.frameLength)
        guard let channelData = outputBuffer.floatChannelData?[0], count > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }
}
