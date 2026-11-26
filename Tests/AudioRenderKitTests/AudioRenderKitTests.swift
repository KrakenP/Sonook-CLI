import AudioCore
import AudioRenderKit
import Foundation
import Testing

@Suite("AudioRenderKit Assembly, Optional Ambient Ducking & Native M4B Chapters")
struct AudioRenderKitTests {
    private func makeSine(frequency: Double, sampleRate: Int, durationSeconds: Double, amplitude: Float = 0.25) -> [Float] {
        let count = Int((Double(sampleRate) * durationSeconds).rounded())
        return (0..<count).map { i in
            Float(sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate))) * amplitude
        }
    }

    private func makeSegment(id: String, chapterID: String, pauseAfterMs: Int) throws -> ScriptSegment {
        ScriptSegment(
            segmentID: id,
            chapterID: chapterID,
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: 6),
            sourceText: "测试文本",
            spokenText: "测试文本",
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            direction: SegmentDirection(pauseAfterMs: pauseAfterMs),
            scriptRevision: 1,
            status: .verified
        )
    }

    @Test func assembleMultiChapterBookProducesExactNonOverlappingChapterMarkers() throws {
        let sr = 48_000
        let ch1 = ChapterAudioInput(
            chapterID: "ch_001",
            title: "第0001章 山雨欲来",
            segments: [
                (try makeSegment(id: "ch_001_seg_0001", chapterID: "ch_001", pauseAfterMs: 250), makeSine(frequency: 240, sampleRate: sr, durationSeconds: 0.60), sr),
                (try makeSegment(id: "ch_001_seg_0002", chapterID: "ch_001", pauseAfterMs: 300), makeSine(frequency: 310, sampleRate: sr, durationSeconds: 0.40), sr)
            ]
        )
        let ch2 = ChapterAudioInput(
            chapterID: "ch_002",
            title: "第0002章 幽谷棋声",
            segments: [
                (try makeSegment(id: "ch_002_seg_0001", chapterID: "ch_002", pauseAfterMs: 200), makeSine(frequency: 360, sampleRate: sr, durationSeconds: 0.85), sr)
            ]
        )

        let (dryPCM, markers, entries) = try PCMCodec.assembleBookPCM(
            chapters: [ch1, ch2],
            sampleRate: sr,
            chapterGapMs: 500
        )

        #expect(markers.count == 2)
        #expect(entries.count == 3)
        // Chapter 1: 0.60 + 0.25 pause + 0.40 + 0.50 chapter gap = 1.75s
        #expect(markers[0].startFrame == 0)
        #expect(abs(markers[0].durationSeconds - 1.75) < 0.002)
        // Chapter 2 starts exactly where Chapter 1 ends and spans 0.85s
        #expect(markers[1].startFrame == markers[0].endFrameExclusive)
        #expect(abs(markers[1].startSeconds - 1.75) < 0.002)
        #expect(abs(markers[1].durationSeconds - 0.85) < 0.002)
        #expect(markers[1].endFrameExclusive == Int64(dryPCM.count))
    }

    @Test func ambientMixerDefaultOffIsBitExactAndEnabledDucksDuringSpeech() {
        let sr = 24_000
        // 1.0s silence pause + 1.0s active speech + 1.0s silence pause
        let silence = [Float](repeating: 0, count: sr)
        let speech = makeSine(frequency: 320, sampleRate: sr, durationSeconds: 1.0, amplitude: 0.30)
        let dryPCM = silence + speech + silence

        // Default OFF returns dry PCM bit-for-bit identical
        let offOutput = AmbientAudioMixer.mix(drySpeech: dryPCM, sampleRate: sr, ambient: nil)
        #expect(offOutput == dryPCM)

        // Short 0.4s ambient tone looped across 3.0s, mixed at -20 dB with -10 dB speech ducking
        let ambientTone = makeSine(frequency: 110, sampleRate: sr, durationSeconds: 0.4, amplitude: 0.5)
        let spec = AmbientTrackSpec(
            assetID: "ast_amb_rain",
            presetName: "soft_rain",
            gainDB: -20.0,
            duckingDB: -10.0
        )
        let mixed = AmbientAudioMixer.mix(
            drySpeech: dryPCM,
            sampleRate: sr,
            ambient: AmbientMixInput(ambientSamples: ambientTone, ambientSampleRate: sr, spec: spec, fadeInSeconds: 0.05, fadeOutSeconds: 0.05)
        )
        #expect(mixed.count == dryPCM.count)
        #expect(mixed != dryPCM)
        #expect(mixed.allSatisfy { abs($0) <= 0.98 })

        // Compare ambient residual (mixed - dryPCM) RMS during middle of pause vs middle of active speech
        func residualRMS(_ range: Range<Int>) -> Double {
            var sumSq = 0.0
            for i in range {
                let r = Double(mixed[i] - dryPCM[i])
                sumSq += r * r
            }
            return sqrt(sumSq / Double(range.count))
        }

        let pauseRMS = residualRMS(Int(0.3 * Double(sr))..<Int(0.8 * Double(sr)))
        let speechRMS = residualRMS(Int(1.3 * Double(sr))..<Int(1.8 * Double(sr)))
        let recoveredPauseRMS = residualRMS(Int(2.5 * Double(sr))..<Int(2.85 * Double(sr)))

        #expect(pauseRMS > 0.01)
        // Speech region ambient must be clearly ducked (at least 6 dB quieter -> ratio < 0.5)
        #expect(speechRMS < pauseRMS * 0.5)
        // Post-speech pause ambient smoothly recovers back up
        #expect(recoveredPauseRMS > speechRMS * 1.8)
    }

    @Test func nativeM4BExportAndAVURLAssetChapterReadbackWithChineseTitles() async throws {
        let sr = 48_000
        let ch1 = ChapterAudioInput(
            chapterID: "ch_001",
            title: "第0001章 山雨欲来",
            segments: [(try makeSegment(id: "ch_001_seg_0001", chapterID: "ch_001", pauseAfterMs: 0), makeSine(frequency: 260, sampleRate: sr, durationSeconds: 1.05), sr)]
        )
        let ch2 = ChapterAudioInput(
            chapterID: "ch_002",
            title: "第0002章 幽谷棋声",
            segments: [(try makeSegment(id: "ch_002_seg_0001", chapterID: "ch_002", pauseAfterMs: 0), makeSine(frequency: 330, sampleRate: sr, durationSeconds: 0.95), sr)]
        )
        let ch3 = ChapterAudioInput(
            chapterID: "ch_003",
            title: "第0003章 云开见月",
            segments: [(try makeSegment(id: "ch_003_seg_0001", chapterID: "ch_003", pauseAfterMs: 0), makeSine(frequency: 392, sampleRate: sr, durationSeconds: 0.80), sr)]
        )

        let (dryPCM, markers, _) = try PCMCodec.assembleBookPCM(
            chapters: [ch1, ch2, ch3],
            sampleRate: sr,
            chapterGapMs: 200
        )

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-m4b-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m4bURL = dir.appendingPathComponent("audiobook.m4b")
        let wavURL = dir.appendingPathComponent("audiobook.wav")
        let m4aURL = dir.appendingPathComponent("audiobook.m4a")
        let meta = BookExportMetadata(title: "山海听澜测试集", author: "听澜工坊", narrator: "旁白", languageTag: "zh-Hans")

        try await BookExporter.export(samples: dryPCM, sampleRate: sr, format: .m4b, markers: markers, metadata: meta, to: m4bURL)
        try await BookExporter.export(samples: dryPCM, sampleRate: sr, format: .wav, markers: markers, metadata: meta, to: wavURL)
        try await BookExporter.export(samples: dryPCM, sampleRate: sr, format: .m4a, markers: markers, metadata: meta, to: m4aURL)

        #expect(FileManager.default.fileExists(atPath: m4bURL.path))
        #expect(FileManager.default.fileExists(atPath: wavURL.path))
        #expect(FileManager.default.fileExists(atPath: m4aURL.path))

        // Verify M4B chapter markers read back cleanly via Apple AVURLAsset!
        let report = try await M4BChapterReader.inspect(url: m4bURL)
        #expect(report.chapters.count == 3)
        #expect(report.chapters.map(\.title) == ["第0001章 山雨欲来", "第0002章 幽谷棋声", "第0003章 云开见月"])

        // Expected starts: 0.0, 1.25 (1.05+0.20), 2.40 (1.25+0.95+0.20); total ~3.20s
        #expect(abs(report.chapters[0].startSeconds - 0.0) < 0.05)
        #expect(abs(report.chapters[1].startSeconds - 1.25) < 0.05)
        #expect(abs(report.chapters[2].startSeconds - 2.40) < 0.05)
        #expect(abs(report.durationSeconds - 3.20) < 0.15)

        // Verify audio stream inside M4B can be decoded back via AVAudioFile!
        let (decoded, decodedSR) = try PCMCodec.readMonoSamples(from: m4bURL)
        #expect(decodedSR == sr)
        #expect(decoded.count > sr * 2)
    }

    @Test func longMultiChapterM4BExportNeverStallsAVAssetWriterInterleaver() async throws {
        // Chapters > 2 seconds apart (8.0s + 6.5s) ensure sparse tx3g markers and continuous AAC PCM
        // pull independently without stalling AVAssetWriter's multi-track interleaver.
        let sr = 48_000
        let ch1 = ChapterAudioInput(
            chapterID: "ch_001",
            title: "第0001章 长章防死锁测试",
            segments: [(try makeSegment(id: "ch_001_seg_0001", chapterID: "ch_001", pauseAfterMs: 0), makeSine(frequency: 240, sampleRate: sr, durationSeconds: 8.0), sr)]
        )
        let ch2 = ChapterAudioInput(
            chapterID: "ch_002",
            title: "第0002章 跨章平滑衔接",
            segments: [(try makeSegment(id: "ch_002_seg_0001", chapterID: "ch_002", pauseAfterMs: 0), makeSine(frequency: 320, sampleRate: sr, durationSeconds: 6.5), sr)]
        )

        let (dryPCM, markers, _) = try PCMCodec.assembleBookPCM(chapters: [ch1, ch2], sampleRate: sr, chapterGapMs: 500)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonook-m4b-long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m4bURL = dir.appendingPathComponent("long-chapters.m4b")
        try await BookExporter.export(
            samples: dryPCM,
            sampleRate: sr,
            format: .m4b,
            markers: markers,
            metadata: BookExportMetadata(title: "长章测试", author: "听澜", narrator: "旁白", languageTag: "zh-Hans"),
            to: m4bURL
        )

        let report = try await M4BChapterReader.inspect(url: m4bURL)
        #expect(report.chapters.count == 2)
        #expect(report.chapters.map(\.title) == ["第0001章 长章防死锁测试", "第0002章 跨章平滑衔接"])
        #expect(abs(report.chapters[0].startSeconds - 0.0) < 0.05)
        #expect(abs(report.chapters[1].startSeconds - 8.5) < 0.10)
        #expect(abs(report.durationSeconds - 15.0) < 0.20)
    }
}
