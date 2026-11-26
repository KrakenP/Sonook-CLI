import Accelerate
import AudioCore
import CryptoKit
import Foundation

public struct SoundscapeRender: Sendable {
    public let samples: [Float]
    public let timeline: RenderedBookTimeline
}

public enum SoundscapeMixer {
    private struct Key: Hashable {
        let chapter: String
        let id: String
        init(_ chapter: String, _ id: String) {
            self.chapter = chapter
            self.id = id
        }
    }

    private struct Scene {
        let cue: SceneCue
        let entry: SoundLibraryEntry?
        let firstSegment: Int
        let lastSegment: Int
        let start: Int
        var end: Int
        var fadeIn: Int
        var fadeOut: Int
    }

    /// Mixes at the dry timeline's sample rate. Cue IDs and segment IDs are chapter-local.
    /// Unresolved cues contribute silence. Only an outgoing scene's transition tail can
    /// extend beyond its last segment, into an adjacent resolved scene in the same chapter.
    public static func mix(drySpeech: [Float], timeline: RenderedBookTimeline, plans: [ChapterSoundscapePlan],
                           library: SoundLibraryRegistry? = nil, sfx: [SFXResolution] = []) throws -> SoundscapeRender {
        let rate = timeline.sampleRate
        guard rate > 0, rate <= Int(Int32.max), !drySpeech.isEmpty, drySpeech.count == timeline.totalFrames,
              drySpeech.allSatisfy(\.isFinite) else { throw invalid("Dry PCM and timeline disagree") }

        var segments: [Key: Int] = [:]
        var previousEnd: Int64 = 0
        for (index, entry) in timeline.entries.enumerated() {
            guard entry.startFrame >= previousEnd, entry.endFrameExclusive >= entry.startFrame,
                  entry.endFrameExclusive <= timeline.totalFrames,
                  segments.updateValue(index, forKey: Key(entry.chapterID, entry.segmentID)) == nil
            else { throw invalid("Invalid or duplicate timeline segment: " + entry.segmentID) }
            previousEnd = entry.endFrameExclusive
        }

        var effects: [Key: SFXResolution] = [:]
        for resolution in sfx {
            let key = Key(resolution.cue.chapterID, resolution.cue.cueID)
            guard effects.updateValue(resolution, forKey: key) == nil else { throw invalid("Duplicate SFX resolution") }
        }
        let plans = plans.sorted { $0.chapterID < $1.chapterID }
        guard Set(plans.map(\.chapterID)).count == plans.count else { throw invalid("Duplicate chapter plan") }

        // The dry render fingerprint already covers the ordered source WAV hashes. Include both
        // that identity and the actual input PCM, timeline and asset bindings in the mix digest.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hash = SHA256()
        hash.update(data: Data("sonook_soundscape_mix_v1".utf8))
        drySpeech.withUnsafeBytes { hash.update(bufferPointer: $0) }
        hash.update(data: try encoder.encode(timeline))
        var active = false
        var mixed = [Float](repeating: 0, count: drySpeech.count)
        var decoded: [String: [Float]] = [:]
        func samples(url: URL, digest: String) throws -> [Float] {
            if let cached = decoded[digest] { return cached }
            guard try SoundFile.digest(url) == digest else { throw SoundLibraryError.digestMismatch(url.lastPathComponent) }
            let (pcm, _) = try PCMCodec.readMonoSamples(from: url, targetSampleRate: rate)
            guard !pcm.isEmpty, pcm.allSatisfy(\.isFinite) else { throw invalid("Invalid soundscape asset") }
            decoded[digest] = pcm
            return pcm
        }
        for plan in plans {
            try Task.checkCancellation()
            hash.update(data: Data(plan.soundscapeDigest().utf8))
            let scenes = try scheduleScenes(plan, timeline: timeline, segments: segments, library: library)
            for scene in scenes {
                guard let entry = scene.entry, let library else { continue }
                let url = try library.fileURL(for: entry, verifyHash: false)
                let digest = entry.fileSHA256.lowercased()
                let pcm = try samples(url: url, digest: digest)
                hash.update(data: try encoder.encode(["bed", scene.cue.cueID, digest]))
                let length = scene.end - scene.start
                let bed = LoopingAmbientBed(source: pcm, totalFrames: length, sampleRate: rate)
                let gain = try linearGain(scene.cue.gainDB)
                for frame in 0..<length {
                    let fade = edgeGain(frame, length: length, attack: scene.fadeIn, release: scene.fadeOut)
                    mixed[scene.start + frame] += bed[frame] * fade * gain
                }
                active = true
            }
        }

        if active {
            var envelope = SpeechDuckingEnvelope(sampleRate: rate, multiplier: Float(pow(10.0, -8.0 / 20)))
            for i in mixed.indices { mixed[i] = drySpeech[i] + mixed[i] * envelope.gain(for: drySpeech[i]) }
        } else {
            mixed = drySpeech
        }
        for plan in plans {
            for cue in plan.sfxCues {
                try Task.checkCancellation()
                guard cue.chapterID == plan.chapterID, cue.durationSeconds.isFinite, cue.durationSeconds > 0, cue.gainDB.isFinite,
                      let index = segments[Key(plan.chapterID, cue.anchorSegmentID)] else {
                    throw invalid("Invalid SFX anchor or duration: " + cue.cueID)
                }
                guard let resolution = effects[Key(plan.chapterID, cue.cueID)], let asset = resolution.asset else { continue }
                guard resolution.cue.soundPrompt == cue.soundPrompt, resolution.cue.category == cue.category,
                      resolution.cue.durationSeconds == cue.durationSeconds else {
                    throw invalid("Stale SFX resolution: " + cue.cueID)
                }
                let pcm = try samples(url: asset.checkedFileURL(), digest: asset.fileSHA256)
                hash.update(data: try encoder.encode(["sfx", plan.chapterID, cue.cueID, asset.fileSHA256]))
                let count = min(pcm.count, try frames(cue.durationSeconds, rate))
                let anchor = timeline.entries[index]
                let base: Int
                switch cue.placement {
                case .before: base = Int(anchor.startFrame) - count
                case .during: base = Int(anchor.startFrame)
                case .after: base = Int(anchor.endFrameExclusive)
                }
                let offset = try frames(Double(cue.offsetMs) / 1000, rate)
                let (start, overflow) = base.addingReportingOverflow(offset)
                guard !overflow, start < mixed.count, start > -count else { continue }
                let from = max(0, start)
                let sourceStart = from - start
                let length = min(mixed.count - from, count - sourceStart)
                let fade = min(length / 2, max(1, rate / 200)) // 5 ms, including clipped book edges
                let gain = try linearGain(cue.gainDB)
                for i in 0..<length {
                    mixed[from + i] += pcm[sourceStart + i] * gain * edgeGain(i, length: length, attack: fade, release: fade)
                }
                active = true
            }
        }

        try limitTruePeak(&mixed, sampleRate: rate)
        let result = RenderedBookTimeline(schemaVersion: timeline.schemaVersion, sampleRate: rate,
                                          totalFrames: timeline.totalFrames, totalDurationSeconds: timeline.totalDurationSeconds,
                                          ambientMixed: active, renderFingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                          chapters: timeline.chapters, entries: timeline.entries)
        return SoundscapeRender(samples: mixed, timeline: result)
    }

    private static func scheduleScenes(_ plan: ChapterSoundscapePlan, timeline: RenderedBookTimeline,
                                       segments: [Key: Int], library: SoundLibraryRegistry?) throws -> [Scene] {
        let rate = timeline.sampleRate
        var scenes: [Scene] = []
        for cue in plan.sceneCues {
            guard cue.chapterID == plan.chapterID, cue.crossfadeMs >= 0, cue.gainDB.isFinite,
                  let first = segments[Key(plan.chapterID, cue.startSegmentID)],
                  let last = segments[Key(plan.chapterID, cue.endSegmentID)], first <= last else {
                throw invalid("Invalid scene anchors: " + cue.cueID)
            }
            let start = Int(timeline.entries[first].startFrame)
            let end = Int(timeline.entries[last].endFrameExclusive)
            let requested = try frames(Double(cue.crossfadeMs) / 1000, rate)
            let fade = min((end - start) / 2, requested == 0 ? max(1, rate / 200) : requested)
            scenes.append(Scene(cue: cue, entry: library?.resolveAmbientEntry(for: cue), firstSegment: first,
                                lastSegment: last, start: start, end: end, fadeIn: fade, fadeOut: fade))
        }
        scenes.sort { $0.start == $1.start ? $0.cue.cueID < $1.cue.cueID : $0.start < $1.start }

        for i in scenes.indices.dropFirst() {
            let prev = scenes[i - 1]
            let next = scenes[i]
            guard prev.entry != nil, next.entry != nil, prev.cue.crossfadeMs > 0, next.cue.crossfadeMs > 0,
                  next.firstSegment <= prev.lastSegment + 1 else { continue }
            let overlap = min(prev.fadeOut, next.fadeIn)
            guard overlap > 0 else { continue }
            scenes[i - 1].end = next.start + overlap
            scenes[i - 1].fadeOut = overlap
            scenes[i].fadeIn = overlap
        }
        return scenes
    }

    private static func invalid(_ message: String) -> AudioRenderError { .invalidAudioFormat(message) }

    private static func frames(_ seconds: Double, _ rate: Int) throws -> Int {
        guard let result = Int(exactly: (seconds * Double(rate)).rounded()) else { throw invalid("Cue time exceeds frame range") }
        return result
    }

    private static func linearGain(_ db: Double) throws -> Float {
        let gain = Float(pow(10, db / 20))
        guard db.isFinite, gain.isFinite else { throw invalid("Invalid cue gain") }
        return gain
    }

    private static func edgeGain(_ frame: Int, length: Int, attack: Int, release: Int) -> Float {
        let remaining = length - 1 - frame
        if attack > 0 && frame < attack { return sin(.pi / 2 * Float(frame) / Float(max(1, attack - 1))) }
        if release > 0 && remaining < release { return sin(.pi / 2 * Float(remaining) / Float(max(1, release - 1))) }
        return 1
    }

    // Four-times oversampled true-peak detector. The integer phase is the original PCM;
    // the three fractional phases use DC-normalized, 32-tap Blackman-windowed sinc filters.
    private static let phases: [[Float]] = (1...3).map { phase in
        let taps = (0..<32).map { tap -> Double in
            let x = Double(tap - 15) - Double(phase) / 4
            let window = 0.42 + 0.5 * cos(.pi * x / 16) + 0.08 * cos(2 * .pi * x / 16)
            return sin(.pi * x) / (.pi * x) * window
        }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }

    private static func truePeaks(_ samples: [Float], blockSize: Int) throws -> [Float] {
        var input = [Float](repeating: 0, count: blockSize + 31)
        var output = [Float](repeating: 0, count: blockSize)
        var peaks: [Float] = []
        for start in stride(from: 0, to: samples.count, by: blockSize) {
            try Task.checkCancellation()
            let count = min(blockSize, samples.count - start)
            for i in 0..<(count + 31) {
                let source = start + i - 15
                input[i] = samples.indices.contains(source) ? samples[source] : 0
            }
            var peak: Float = 0
            input.withUnsafeBufferPointer { buffer in
                vDSP_maxmgv(buffer.baseAddress! + 15, 1, &peak, vDSP_Length(count))
            }
            for taps in phases {
                vDSP_conv(input, 1, taps, 1, &output, 1, vDSP_Length(count), 32)
                var fractionalPeak: Float = 0
                vDSP_maxmgv(output, 1, &fractionalPeak, vDSP_Length(count))
                peak = max(peak, fractionalPeak)
            }
            peaks.append(peak)
        }
        return peaks
    }

    /// Look ahead one 5 ms block, ramp down before the transient, then release over
    /// 80 ms. Remeasure after gain modulation to catch any new inter-sample overshoot.
    private static func limitTruePeak(_ samples: inout [Float], sampleRate: Int) throws {
        guard samples.allSatisfy(\.isFinite) else { throw invalid("Non-finite multi-track sum") }
        let ceiling: Float = 0.891
        let knee: Float = 0.80
        let blockSize = min(16_384, max(1, sampleRate / 200))
        let peaks = try truePeaks(samples, blockSize: blockSize)
        guard peaks.contains(where: { $0 > knee }) else { return }
        let gains = peaks.map { peak -> Float in
            guard peak > knee else { return 1 }
            let width = ceiling - knee
            return (knee + width * tanh((peak - knee) / width)) / peak
        }
        var gain = gains[0]
        for block in gains.indices {
            let start = block * blockSize
            let count = min(blockSize, samples.count - start)
            let target = min(gains[block], gains[min(block + 1, gains.count - 1)])
            let release = Float(exp(-Double(count) / (0.08 * Double(sampleRate))))
            let endGain = target < gain ? target : target + (gain - target) * release
            let slope = (endGain - gain) / Float(count)
            for i in 0..<count { samples[start + i] *= gain + Float(i) * slope }
            gain = endGain
        }
        if let measured = try truePeaks(samples, blockSize: blockSize).max(), measured > ceiling {
            let trim = ceiling / measured
            for i in samples.indices { samples[i] *= trim }
        }
    }
}
