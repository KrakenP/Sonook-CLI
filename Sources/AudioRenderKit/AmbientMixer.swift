import AudioCore
import Foundation

public struct AmbientMixInput: Sendable {
    public let ambientSamples: [Float]
    public let ambientSampleRate: Int
    public let spec: AmbientTrackSpec
    public let fadeInSeconds: Double
    public let fadeOutSeconds: Double

    public init(
        ambientSamples: [Float],
        ambientSampleRate: Int,
        spec: AmbientTrackSpec,
        fadeInSeconds: Double = 1.5,
        fadeOutSeconds: Double = 2.0
    ) {
        self.ambientSamples = ambientSamples
        self.ambientSampleRate = ambientSampleRate
        self.spec = spec
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }
}

/// Post-ASR render-only optional ambient/background bed mixer.
///
/// Architectural guarantees:
/// - Default OFF (`ambient == nil` returns `drySpeech` verbatim with zero alteration).
/// - When ON, applies subtle base gain (default `-24 dB`) + smooth speech-triggered ducking
///   (default `-8 dB` while voice is active, rising smoothly during pauses/chapter gaps),
///   loop crossfades, and book edge fade-in/out.
/// - Never alters dry speech segment WAVs or ASR verification inputs; hashes ONLY into render fingerprint.
public enum AmbientAudioMixer: Sendable {
    public static func mix(
        drySpeech: [Float],
        sampleRate: Int,
        ambient: AmbientMixInput?,
        peakCeiling: Float = 0.97
    ) -> [Float] {
        guard !drySpeech.isEmpty else { return [] }
        guard let ambient, !ambient.ambientSamples.isEmpty, sampleRate > 0 else {
            return drySpeech
        }

        let resampledBed = ambient.ambientSampleRate == sampleRate
            ? ambient.ambientSamples
            : PCMCodec.resampleLinear(ambient.ambientSamples, from: ambient.ambientSampleRate, to: sampleRate)
        guard !resampledBed.isEmpty else { return drySpeech }

        let totalFrames = drySpeech.count
        let bed = LoopingAmbientBed(source: resampledBed, totalFrames: totalFrames, sampleRate: sampleRate)

        let baseGain = Float(pow(10.0, ambient.spec.gainDB / 20.0))
        let clampedDuckDB = min(0.0, ambient.spec.duckingDB)
        let duckMultiplier = Float(pow(10.0, clampedDuckDB / 20.0)) // e.g. -8 dB -> ~0.398

        var envelope = SpeechDuckingEnvelope(sampleRate: sampleRate, multiplier: duckMultiplier)

        let fadeInFrames = min(totalFrames / 4, max(0, Int(Double(sampleRate) * max(0.0, ambient.fadeInSeconds))))
        let fadeOutFrames = min(totalFrames / 4, max(0, Int(Double(sampleRate) * max(0.0, ambient.fadeOutSeconds))))

        var out = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            let dry = drySpeech[i]
            let currentDuckFactor = envelope.gain(for: dry)

            var edgeGain: Float = 1.0
            if fadeInFrames > 0 && i < fadeInFrames {
                edgeGain = min(edgeGain, Float(i) / Float(fadeInFrames))
            }
            if fadeOutFrames > 0 && i >= totalFrames - fadeOutFrames {
                let remaining = totalFrames - 1 - i
                edgeGain = min(edgeGain, Float(max(0, remaining)) / Float(fadeOutFrames))
            }

            let mixed = dry + bed[i] * baseGain * currentDuckFactor * edgeGain
            out[i] = max(-peakCeiling, min(peakCeiling, mixed))
        }

        return out
    }
}

// Index the source directly so a long scene needs no scene-length scratch buffer.
struct LoopingAmbientBed {
    private let source: [Float]
    private let overlap: Int
    private let stride: Int

    init(source: [Float], totalFrames: Int, sampleRate: Int) {
        self.source = source
        overlap = source.count < totalFrames ? min(source.count / 4, sampleRate / 10) : 0
        stride = source.count - overlap
    }

    subscript(frame: Int) -> Float {
        if frame < stride { return source[frame] }
        let index = frame % stride
        if index >= overlap { return source[index] }
        let weight = Float(index) / Float(overlap)
        return source[stride + index] * (1 - weight) + source[index] * weight
    }
}

/// The detector follows syllables (15/60 ms); a slower gain envelope (30/160 ms) restores
/// ambience during a pause. Carry one follower across scene boundaries.
struct SpeechDuckingEnvelope {
    private let attack, release, gainAttack, gainRelease, multiplier: Float
    private var envelope: Float = 0
    private var currentGain: Float = 1

    init(sampleRate: Int, multiplier: Float) {
        func coefficient(_ seconds: Double) -> Float { Float(exp(-1 / max(1, Double(sampleRate) * seconds))) }
        attack = coefficient(0.015)
        release = coefficient(0.060)
        gainAttack = coefficient(0.030)
        gainRelease = coefficient(0.160)
        self.multiplier = multiplier
    }

    mutating func gain(for sample: Float) -> Float {
        let magnitude = abs(sample)
        let detector = magnitude > envelope ? attack : release
        envelope = detector * envelope + (1 - detector) * magnitude
        let activity = min(1, max(0, (envelope - 0.005) / 0.020))
        let target = 1 - activity * (1 - multiplier)
        let smoothing = target < currentGain ? gainAttack : gainRelease
        currentGain = smoothing * currentGain + (1 - smoothing) * target
        return currentGain
    }
}
