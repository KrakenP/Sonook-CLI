import AudioCore
import AudioRenderKit
import DistributionKit
import Foundation

struct AudioPackFixture {
    let chapters: [AudioPackChapterInput]
    let timeline: RenderedBookTimeline
    static let timestamp = "2026-01-01T00:00:00Z"

    init(extraPauseMs: Int = 0, lastSegmentID: String = "2-b", lastStatus: SegmentStatus = .verified,
         firstChapterLastSegmentID: String = "1-b", secondChapterID: String = "ch-2") throws {
        let rate = 24_000
        let wave = (0..<2400).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) * 0.2 }
        var scripts: [ScriptDocument] = []
        var records: [ChapterRecord] = []
        var inputs: [ChapterAudioInput] = []
        for number in 1...2 {
            let id = number == 2 ? secondChapterID : "ch-1"
            let start = (number - 1) * 6
            let chapter = ChapterRecord(projectID: "book", chapterID: id, chapterNumber: number, title: "第\(number)章",
                                        sourceDocumentRevision: "rev", sourceSpan: try SourceSpan(start: start, endExclusive: start + 6),
                                        originPath: "/private/draft.txt")
            let a = ScriptSegment(segmentID: "\(number)-a", chapterID: id, sourceDocumentRevision: "rev",
                                  sourceSpan: try SourceSpan(start: start, endExclusive: start + 3),
                                  sourceText: "风", spokenText: "风", speakerID: "reader", voiceProfileRevision: "v1",
                                  direction: .init(pauseAfterMs: 50 + (number == 2 ? extraPauseMs : 0)),
                                  scriptRevision: 1, status: .verified)
            let b = ScriptSegment(segmentID: number == 2 ? lastSegmentID : firstChapterLastSegmentID, chapterID: id, sourceDocumentRevision: "rev",
                                  sourceSpan: try SourceSpan(start: start + 3, endExclusive: start + 6),
                                  sourceText: "起", spokenText: "起", speakerID: "reader", voiceProfileRevision: "v1",
                                  scriptRevision: 1, status: number == 2 ? lastStatus : .verified)
            scripts.append(.init(chapterID: id, sourceDocumentRevision: "rev", scriptRevision: 1, segments: [a, b]))
            records.append(chapter)
            inputs.append(.init(chapterID: id, title: chapter.title, segments: [(a, wave, rate), (b, wave, rate)]))
        }
        let render = try PCMCodec.assembleBookPCM(chapters: inputs, sampleRate: rate, chapterGapMs: 100)
        timeline = RenderedBookTimeline(sampleRate: rate, totalFrames: Int64(render.dryPCM.count),
                                        totalDurationSeconds: Double(render.dryPCM.count) / Double(rate), ambientMixed: false,
                                        renderFingerprint: "fixture", chapters: render.markers, entries: render.entries)
        chapters = render.markers.enumerated().map { index, marker in
            AudioPackChapterInput(chapter: records[index], script: scripts[index],
                                  samples: Array(render.dryPCM[Int(marker.startFrame)..<Int(marker.endFrameExclusive)]), sampleRate: rate)
        }
    }

    static var privateCard: CharacterVoiceCard {
        .init(characterID: "reader", canonicalName: "旁白", aliases: ["讲述者"], personaSummary: "平和",
              providerBindings: ["fake": .init(providerID: "fake", speakerID: "reader", extraParameters: ["token": "sample-secret"])],
              timbreAnchor: .init(anchorID: "private-anchor", assetID: "voice_audition/private.wav", fileSHA256: "private-digest",
                                  generatorProviderID: "fake", generatorModelID: "private-model", designPrompt: "private-prompt",
                                  auditionText: "private-audition", sampleRate: 24_000, createdAtISO8601: timestamp))
    }

    func write(to url: URL, version: Int = 1, format: AudioPackAudioFormat = .wav,
               references: [KnowledgeCitation] = [], characters: [CharacterVoiceCard] = [Self.privateCard]) throws -> PublishedReleaseRecord {
        try AudioPackWriter.write(to: url, projectID: "book", releaseID: "release-\(version)", releaseVersion: version,
                                  productionMode: .audiobookVerbatim, metadata: .init(title: "风起", createdAtISO8601: Self.timestamp),
                                  chapters: chapters, timeline: timeline, characters: characters, references: references, format: format)
    }

    func release(in folder: URL, version: Int) throws -> AudioPackReader {
        let root = folder.appendingPathComponent("release-\(version)")
        _ = try write(to: root, version: version)
        return try AudioPackReader(contentsOf: root)
    }
}

func withPackDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
