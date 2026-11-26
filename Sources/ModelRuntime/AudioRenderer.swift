import AVFoundation
import AudioCore
import Foundation

public struct TimelineEntry: Codable, Equatable, Sendable {
    public let segmentID: String
    public let speakerID: String
    public let sourceSpan: SourceSpan
    public let startFrame: Int64
    public let endFrameExclusive: Int64
    public let startSeconds: Double
    public let endSeconds: Double
    public let pauseAfterMs: Int

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case speakerID = "speaker_id"
        case sourceSpan = "source_span"
        case startFrame = "start_frame"
        case endFrameExclusive = "end_frame_exclusive"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case pauseAfterMs = "pause_after_ms"
    }
}

public struct RenderedTimeline: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let chapterID: String
    public let sampleRate: Int
    public let totalFrames: Int64
    public let totalDurationSeconds: Double
    public let entries: [TimelineEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case chapterID = "chapter_id"
        case sampleRate = "sample_rate"
        case totalFrames = "total_frames"
        case totalDurationSeconds = "total_duration_seconds"
        case entries
    }
}

public enum NativeAudioRenderer: Sendable {
    /// Applies gentle RMS loudness leveling toward -20 dBFS with a conservative gain cap and edge fades
    /// so sequential narration chunks stay smooth rather than pumping volume up and down.
    public static func levelSegment(
        _ samples: [Float],
        sampleRate: Int = 24_000,
        targetRMSDBFS: Double = -20.0,
        peakCeiling: Float = 0.891,
        maxGain: Float = 1.6
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var sumSq = 0.0
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += Double(s) * Double(s)
        }
        let rms = sqrt(sumSq / Double(samples.count))
        guard rms > 1e-5, peak > 1e-5 else { return samples }

        let targetRMS = pow(10.0, targetRMSDBFS / 20.0)
        let desiredGain = Float(targetRMS / rms)
        let safePeakGain = peakCeiling / peak
        let gain = min(desiredGain, safePeakGain, maxGain)
        var out = samples.map { max(-peakCeiling, min(peakCeiling, $0 * gain)) }

        // Apply subtle 12 ms edge fade-in/out to prevent splice clicks
        let fadeFrames = min(out.count / 4, max(1, Int(Double(sampleRate) * 0.012)))
        for i in 0..<fadeFrames {
            let ramp = Float(i) / Float(fadeFrames)
            out[i] *= ramp
            out[out.count - 1 - i] *= ramp
        }
        return out
    }

    public static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw ProviderCapabilityError.invalidInput("Unable to build WAV AVAudioFormat")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw ProviderCapabilityError.invalidInput("Unable to allocate WAV PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    public static func writeM4A(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw ProviderCapabilityError.invalidInput("Unable to build PCM AVAudioFormat")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw ProviderCapabilityError.invalidInput("Unable to allocate PCM buffer for M4A")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }

        // CoreAudio AAC caps 24 kHz mono below 128 kbps; use 64 kbps for <=24 kHz mono speech.
        let targetBitRate = sampleRate <= 24_000 ? 64_000 : 128_000
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate
        ]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    public static func encodeWAVData(samples: [Float], sampleRate: Int) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeWAV(samples: samples, sampleRate: sampleRate, to: tmp)
        return try Data(contentsOf: tmp)
    }

    public static func encodeM4AData(samples: [Float], sampleRate: Int) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-m4a-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeM4A(samples: samples, sampleRate: sampleRate, to: tmp)
        return try Data(contentsOf: tmp)
    }

    public static func readWAVSamples(from url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let sr = Int(file.processingFormat.sampleRate.rounded())
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else {
            return ([], sr)
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw ProviderCapabilityError.invalidInput("Unable to allocate PCM read buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let ch = buffer.floatChannelData?[0] else {
            throw ProviderCapabilityError.invalidInput("Missing float channel data in \(url.lastPathComponent)")
        }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        return (samples, sr)
    }

    public static func assembleChapterPCM(
        chapterID: String,
        segments: [(segment: ScriptSegment, samples: [Float])],
        sampleRate: Int,
        targetRMSDBFS: Double = -20.0
    ) -> (pcm: [Float], timeline: RenderedTimeline) {
        var combined: [Float] = []
        var entries: [TimelineEntry] = []
        var cursor: Int64 = 0

        for (index, item) in segments.enumerated() {
            let leveled = levelSegment(item.samples, sampleRate: sampleRate, targetRMSDBFS: targetRMSDBFS)
            let start = cursor
            combined.append(contentsOf: leveled)
            cursor += Int64(leveled.count)
            let end = cursor

            let pauseMs = index + 1 < segments.count ? (item.segment.direction.pauseAfterMs ?? 350) : 0
            if pauseMs > 0 {
                let pauseFrames = Int(Double(sampleRate) * Double(pauseMs) / 1000.0)
                if pauseFrames > 0 {
                    combined.append(contentsOf: repeatElement(Float(0), count: pauseFrames))
                    cursor += Int64(pauseFrames)
                }
            }

            entries.append(TimelineEntry(
                segmentID: item.segment.segmentID,
                speakerID: item.segment.speakerID,
                sourceSpan: item.segment.sourceSpan,
                startFrame: start,
                endFrameExclusive: end,
                startSeconds: Double(start) / Double(sampleRate),
                endSeconds: Double(end) / Double(sampleRate),
                pauseAfterMs: pauseMs
            ))
        }

        let timeline = RenderedTimeline(
            schemaVersion: AudioCoreInfo.currentSchemaVersion,
            chapterID: chapterID,
            sampleRate: sampleRate,
            totalFrames: cursor,
            totalDurationSeconds: Double(cursor) / Double(sampleRate),
            entries: entries
        )
        return (combined, timeline)
    }

    public static func renderChapter(
        chapterID: String,
        segments: [(segment: ScriptSegment, samples: [Float])],
        sampleRate: Int,
        wavURL: URL,
        m4aURL: URL
    ) throws -> RenderedTimeline {
        var combined: [Float] = []
        var entries: [TimelineEntry] = []
        var cursor: Int64 = 0

        for (index, item) in segments.enumerated() {
            let leveled = levelSegment(item.samples, sampleRate: sampleRate)
            let start = cursor
            combined.append(contentsOf: leveled)
            cursor += Int64(leveled.count)
            let end = cursor

            let pauseMs = index + 1 < segments.count ? (item.segment.direction.pauseAfterMs ?? 350) : 0
            if pauseMs > 0 {
                let pauseFrames = Int(Double(sampleRate) * Double(pauseMs) / 1000.0)
                if pauseFrames > 0 {
                    combined.append(contentsOf: repeatElement(Float(0), count: pauseFrames))
                    cursor += Int64(pauseFrames)
                }
            }

            entries.append(TimelineEntry(
                segmentID: item.segment.segmentID,
                speakerID: item.segment.speakerID,
                sourceSpan: item.segment.sourceSpan,
                startFrame: start,
                endFrameExclusive: end,
                startSeconds: Double(start) / Double(sampleRate),
                endSeconds: Double(end) / Double(sampleRate),
                pauseAfterMs: pauseMs
            ))
        }

        try writeWAV(samples: combined, sampleRate: sampleRate, to: wavURL)
        try writeM4A(samples: combined, sampleRate: sampleRate, to: m4aURL)

        return RenderedTimeline(
            schemaVersion: AudioCoreInfo.currentSchemaVersion,
            chapterID: chapterID,
            sampleRate: sampleRate,
            totalFrames: cursor,
            totalDurationSeconds: Double(cursor) / Double(sampleRate),
            entries: entries
        )
    }
}
