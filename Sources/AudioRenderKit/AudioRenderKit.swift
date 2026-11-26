import AVFoundation
import AudioCore
import Foundation

public enum AudioRenderKitInfo: Sendable {
    public static let mixAlgorithmVersion = "renderkit_mix_v1"
}

public enum AudioRenderError: Error, Equatable, LocalizedError, Sendable {
    case invalidAudioFormat(String)
    case emptyBookExport
    case ambientFileUnreadable(String)
    case m4bEncodingFailed(String)
    case chapterMarkerError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioFormat(let msg): return "Invalid audio format: \(msg)"
        case .emptyBookExport: return "Cannot export audiobook with zero audio frames"
        case .ambientFileUnreadable(let msg): return "Ambient audio file unreadable: \(msg)"
        case .m4bEncodingFailed(let msg): return "M4B encoding failed: \(msg)"
        case .chapterMarkerError(let msg): return "Chapter marker error: \(msg)"
        }
    }
}

public struct BookTimelineEntry: Codable, Equatable, Sendable {
    public let chapterID: String
    public let segmentID: String
    public let speakerID: String
    public let sourceSpan: SourceSpan
    public let startFrame: Int64
    public let endFrameExclusive: Int64
    public let startSeconds: Double
    public let endSeconds: Double
    public let pauseAfterMs: Int

    public init(
        chapterID: String,
        segmentID: String,
        speakerID: String,
        sourceSpan: SourceSpan,
        startFrame: Int64,
        endFrameExclusive: Int64,
        startSeconds: Double,
        endSeconds: Double,
        pauseAfterMs: Int
    ) {
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.sourceSpan = sourceSpan
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.pauseAfterMs = pauseAfterMs
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
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

public struct RenderedBookTimeline: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let totalFrames: Int64
    public let totalDurationSeconds: Double
    public let ambientMixed: Bool
    public let renderFingerprint: String
    public let chapters: [ChapterMarker]
    public let entries: [BookTimelineEntry]

    public init(
        schemaVersion: Int = AudioCoreInfo.currentSchemaVersion,
        sampleRate: Int,
        totalFrames: Int64,
        totalDurationSeconds: Double,
        ambientMixed: Bool,
        renderFingerprint: String,
        chapters: [ChapterMarker],
        entries: [BookTimelineEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.sampleRate = sampleRate
        self.totalFrames = totalFrames
        self.totalDurationSeconds = totalDurationSeconds
        self.ambientMixed = ambientMixed
        self.renderFingerprint = renderFingerprint
        self.chapters = chapters
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sampleRate = "sample_rate"
        case totalFrames = "total_frames"
        case totalDurationSeconds = "total_duration_seconds"
        case ambientMixed = "ambient_mixed"
        case renderFingerprint = "render_fingerprint"
        case chapters
        case entries
    }
}

public struct ChapterAudioInput: Sendable {
    public let chapterID: String
    public let title: String
    public let segments: [(segment: ScriptSegment, samples: [Float], sampleRate: Int)]

    public init(chapterID: String, title: String, segments: [(segment: ScriptSegment, samples: [Float], sampleRate: Int)]) {
        self.chapterID = chapterID
        self.title = title
        self.segments = segments
    }
}

public enum PCMCodec: Sendable {
    /// Applies gentle RMS loudness leveling toward -20 dBFS with conservative peak/gain ceilings
    /// and 12 ms edge fades so sequential segments flow smoothly without splice clicks.
    public static func levelSegment(
        _ samples: [Float],
        sampleRate: Int = 48_000,
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

        let fadeFrames = min(out.count / 4, max(1, Int(Double(sampleRate) * 0.012)))
        for i in 0..<fadeFrames {
            let ramp = Float(i) / Float(fadeFrames)
            out[i] *= ramp
            out[out.count - 1 - i] *= ramp
        }
        return out
    }

    /// Linearly resamples mono PCM from `sourceSampleRate` to `targetSampleRate`.
    public static func resampleLinear(_ samples: [Float], from sourceSampleRate: Int, to targetSampleRate: Int) -> [Float] {
        guard sourceSampleRate > 0, targetSampleRate > 0, !samples.isEmpty else { return [] }
        guard sourceSampleRate != targetSampleRate else { return samples }
        let ratio = Double(sourceSampleRate) / Double(targetSampleRate)
        let outCount = max(1, Int((Double(samples.count) / ratio).rounded()))
        var out = [Float](repeating: 0, count: outCount)
        let lastIdx = samples.count - 1
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let lo = min(lastIdx, Int(srcPos))
            let hi = min(lastIdx, lo + 1)
            let frac = Float(srcPos - Double(lo))
            out[i] = samples[lo] * (1.0 - frac) + samples[hi] * frac
        }
        return out
    }

    /// Reads any AVFoundation-supported audio file (WAV/M4A/AAC/MP3/AIFF) into mono Float32 PCM,
    /// downmixing multi-channel files cleanly and optionally resampling to `targetSampleRate`.
    public static func readMonoSamples(from url: URL, targetSampleRate: Int? = nil) throws -> (samples: [Float], sampleRate: Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioRenderError.ambientFileUnreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let sr = Int(file.processingFormat.sampleRate.rounded())
        let channels = Int(file.processingFormat.channelCount)
        let totalFrames = file.length
        guard sr > 0, channels > 0 else {
            throw AudioRenderError.invalidAudioFormat("Unsupported audio stream in \(url.lastPathComponent)")
        }
        guard totalFrames > 0 else { return ([], targetSampleRate ?? sr) }

        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioRenderError.invalidAudioFormat("Unable to create Float32 read format")
        }

        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkCapacity) else {
            throw AudioRenderError.invalidAudioFormat("Unable to allocate PCM read buffer")
        }

        var mono: [Float] = []
        mono.reserveCapacity(Int(totalFrames))
        let scale = 1.0 / Float(channels)

        while file.framePosition < totalFrames {
            let remaining = AVAudioFrameCount(min(Int64(chunkCapacity), totalFrames - file.framePosition))
            guard remaining > 0 else { break }
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: remaining)
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == -39 && !mono.isEmpty {
                // Some AAC containers report encoder padding in their length and signal eofErr here.
                break
            } catch {
                throw AudioRenderError.invalidAudioFormat("Failed reading audio \(url.lastPathComponent): \(error.localizedDescription)")
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
            } else {
                for frame in 0..<count {
                    var sum: Float = 0
                    for ch in 0..<channels {
                        sum += channelData[ch][frame]
                    }
                    mono.append(sum * scale)
                }
            }
        }

        if let target = targetSampleRate, target != sr {
            return (resampleLinear(mono, from: sr, to: target), target)
        }
        return (mono, sr)
    }

    public static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard sampleRate > 0, !samples.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioRenderError.invalidAudioFormat("Unable to build WAV format/buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString).wav")
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

    public static func encodeWAVData(samples: [Float], sampleRate: Int) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-render-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeWAV(samples: samples, sampleRate: sampleRate, to: tmp)
        return try Data(contentsOf: tmp)
    }

    public static func writeM4A(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard sampleRate > 0, !samples.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioRenderError.invalidAudioFormat("Unable to build M4A PCM format/buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        let targetBitRate = sampleRate <= 24_000 ? 64_000 : 128_000
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate
        ]
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString).m4a")
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

    public static func encodeM4AData(samples: [Float], sampleRate: Int) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-render-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeM4A(samples: samples, sampleRate: sampleRate, to: tmp)
        return try Data(contentsOf: tmp)
    }

    /// Assembles multiple chapters of dry leveled speech into a continuous master PCM buffer
    /// along with exact frame-accurate `ChapterMarker`s and `BookTimelineEntry`s.
    public static func assembleBookPCM(
        chapters: [ChapterAudioInput],
        sampleRate: Int,
        chapterGapMs: Int = 1200,
        targetRMSDBFS: Double = -20.0
    ) throws -> (dryPCM: [Float], markers: [ChapterMarker], entries: [BookTimelineEntry]) {
        guard sampleRate > 0 else {
            throw AudioRenderError.invalidAudioFormat("Invalid sampleRate \(sampleRate)")
        }
        var combined: [Float] = []
        var markers: [ChapterMarker] = []
        var entries: [BookTimelineEntry] = []
        var cursor: Int64 = 0

        let nonEmptyChapters = chapters.filter { !$0.segments.isEmpty }
        guard !nonEmptyChapters.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }

        for (chIndex, chapter) in nonEmptyChapters.enumerated() {
            let chapterStart = cursor
            for (segIndex, item) in chapter.segments.enumerated() {
                let resampled = item.sampleRate == sampleRate
                    ? item.samples
                    : resampleLinear(item.samples, from: item.sampleRate, to: sampleRate)
                let leveled = levelSegment(resampled, sampleRate: sampleRate, targetRMSDBFS: targetRMSDBFS)
                let segStart = cursor
                combined.append(contentsOf: leveled)
                cursor += Int64(leveled.count)
                let segEnd = cursor

                let isLastSegInChapter = (segIndex + 1 == chapter.segments.count)
                let pauseMs = isLastSegInChapter ? 0 : (item.segment.direction.pauseAfterMs ?? 350)
                if pauseMs > 0 {
                    let pauseFrames = Int(Double(sampleRate) * Double(pauseMs) / 1000.0)
                    if pauseFrames > 0 {
                        combined.append(contentsOf: repeatElement(Float(0), count: pauseFrames))
                        cursor += Int64(pauseFrames)
                    }
                }

                entries.append(BookTimelineEntry(
                    chapterID: chapter.chapterID,
                    segmentID: item.segment.segmentID,
                    speakerID: item.segment.speakerID,
                    sourceSpan: item.segment.sourceSpan,
                    startFrame: segStart,
                    endFrameExclusive: segEnd,
                    startSeconds: Double(segStart) / Double(sampleRate),
                    endSeconds: Double(segEnd) / Double(sampleRate),
                    pauseAfterMs: pauseMs
                ))
            }

            // Include inter-chapter silence inside the ending chapter's span so chapter markers form a clean partition.
            if chIndex + 1 < nonEmptyChapters.count, chapterGapMs > 0 {
                let gapFrames = Int(Double(sampleRate) * Double(chapterGapMs) / 1000.0)
                if gapFrames > 0 {
                    combined.append(contentsOf: repeatElement(Float(0), count: gapFrames))
                    cursor += Int64(gapFrames)
                }
            }

            let chapterEnd = cursor
            markers.append(ChapterMarker(
                chapterID: chapter.chapterID,
                title: chapter.title,
                startFrame: chapterStart,
                endFrameExclusive: chapterEnd,
                sampleRate: sampleRate
            ))
        }

        guard !combined.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }
        return (combined, markers, entries)
    }
}
