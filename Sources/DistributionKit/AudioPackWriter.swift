import AudioCore
import AudioRenderKit
import CryptoKit
import Foundation

public struct AudioPackChapterInput: Sendable {
    public let chapter: ChapterRecord
    public let script: ScriptDocument
    /// Rendered mono PCM covering this chapter marker, including any rendered pauses.
    public let samples: [Float]
    public let sampleRate: Int

    public init(chapter: ChapterRecord, script: ScriptDocument, samples: [Float], sampleRate: Int) {
        self.chapter = chapter
        self.script = script
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum AudioPackAudioFormat: String, Sendable {
    case m4a, wav
}

public enum AudioPackWriter {
    /// Publishes a new immutable directory. The returned path is relative to its parent.
    public static func write(
        to outputDir: URL, projectID: String, releaseID: String, releaseVersion: Int,
        productionMode: ProductionMode, audioMode: ExportAudioMode = .dry, metadata: AudioPackMetadata,
        chapters: [AudioPackChapterInput], timeline: RenderedBookTimeline, characters: [CharacterVoiceCard] = [],
        references: [KnowledgeCitation] = [], format: AudioPackAudioFormat = .m4a,
        validator: AudioPackValidator = .init()
    ) throws -> PublishedReleaseRecord {
        guard outputDir.isFileURL, !outputDir.path.utf8.contains(0), !projectID.isEmpty, !releaseID.isEmpty, releaseVersion > 0,
              !chapters.isEmpty, chapters.count == timeline.chapters.count else {
            throw AudioPackError.invalidPack("Missing release identity or chapter audio")
        }
        let fm = FileManager.default
        let parent = outputDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".audiopack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for folder in ["chapters", "transcripts"] {
            try fm.createDirectory(at: stage.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        let directory = try PackDirectory(stage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hashes: [String: String] = [:]
        var payloadBytes: Int64 = 0
        func writeJSON(_ value: some Encodable, at path: String) throws {
            let data = try encoder.encode(value)
            try data.write(to: stage.appendingPathComponent(path))
            hashes[path] = packDigest(SHA256.hash(data: data))
            payloadBytes += Int64(data.count)
        }

        var names: [String: String] = [:]
        for card in characters {
            guard names.updateValue(card.canonicalName, forKey: card.characterID) == nil else {
                throw AudioPackError.invalidPack("Duplicate character ID")
            }
        }
        var firstAppearances: [String: Int] = [:]
        var entries: [AudioPackChapterEntry] = []
        var timings = timeline.entries.makeIterator()
        let ordered = chapters.sorted { $0.chapter.chapterNumber < $1.chapter.chapterNumber }
        for (input, marker) in zip(ordered, timeline.chapters) {
            let chapter = input.chapter
            guard chapter.projectID == projectID, chapter.chapterID == marker.chapterID,
                  input.script.chapterID == chapter.chapterID, input.script.sourceDocumentRevision == chapter.sourceDocumentRevision,
                  input.sampleRate > 0, input.sampleRate <= Int(Int32.max), marker.sampleRate == input.sampleRate,
                  input.sampleRate == timeline.sampleRate, input.samples.allSatisfy(\.isFinite),
                  marker.startFrame >= 0, marker.endFrameExclusive > marker.startFrame,
                  marker.endFrameExclusive - marker.startFrame == Int64(input.samples.count),
                  UInt32(exactly: input.samples.count) != nil, chapter.chapterNumber > 0 else {
                throw AudioPackError.invalidPack("Chapter PCM, script and render marker do not match")
            }
            let segments = try input.script.segments.map { segment -> AudioPackTranscriptSegment in
                guard segment.status == .verified, segment.chapterID == chapter.chapterID,
                      segment.sourceDocumentRevision == chapter.sourceDocumentRevision,
                      segment.sourceSpan.start >= chapter.sourceSpan.start,
                      segment.sourceSpan.endExclusive <= chapter.sourceSpan.endExclusive,
                      let timing = timings.next(), timing.segmentID == segment.segmentID,
                      timing.chapterID == chapter.chapterID, timing.sourceSpan == segment.sourceSpan,
                      timing.speakerID == segment.speakerID else {
                    throw AudioPackError.invalidPack("Unverified or mismatched script segment")
                }
                if firstAppearances[segment.speakerID] == nil { firstAppearances[segment.speakerID] = chapter.chapterNumber }
                return try AudioPackTranscriptSegment(
                    segmentID: segment.segmentID, speakerID: segment.speakerID,
                    speakerName: names[segment.speakerID] ?? segment.speakerID, spokenText: segment.spokenText,
                    sourceSpan: segment.sourceSpan, startMs: marker.localMs(timing.startFrame),
                    endMs: marker.localMs(timing.endFrameExclusive)
                )
            }
            let number = String(format: "%03lld", Int64(chapter.chapterNumber))
            let transcript = "transcripts/\(number).json"
            try writeJSON(AudioPackChapterTranscript(chapterID: chapter.chapterID, chapterNumber: chapter.chapterNumber,
                                                     title: chapter.title, segments: segments), at: transcript)
            let audio = "chapters/\(number).\(format.rawValue)"
            let url = stage.appendingPathComponent(audio)
            switch format {
            case .m4a: try PCMCodec.writeM4A(samples: input.samples, sampleRate: input.sampleRate, to: url)
            case .wav: try PCMCodec.writeWAV(samples: input.samples, sampleRate: input.sampleRate, to: url)
            }
            let size = try directory.openFile(audio).size
            let digest = try directory.read(audio, size: size).digest
            hashes[audio] = digest
            payloadBytes += size
            entries.append(AudioPackChapterEntry(
                chapterID: chapter.chapterID, chapterNumber: chapter.chapterNumber, title: chapter.title,
                audioRelativePath: audio, transcriptRelativePath: transcript, durationSeconds: marker.durationSeconds,
                sampleRate: input.sampleRate, byteSize: size, fileSHA256: digest
            ))
        }
        try writeJSON(metadata, at: "metadata.json")
        try writeJSON(timeline, at: "timeline.json")
        let summaries = characters.map { card in
            AudioPackCharacterSummary(characterID: card.characterID, canonicalName: card.canonicalName, aliases: card.aliases,
                                      personaSummary: card.personaSummary, firstAppearedChapter: firstAppearances[card.characterID])
        }
        // Also reject private identifiers or credentials accidentally pasted into a public field.
        var privateValues = Set<String>()
        for card in characters {
            if let anchor = card.timbreAnchor {
                privateValues.formUnion([anchor.assetID, anchor.anchorID, anchor.fileSHA256])
            }
            for binding in card.providerBindings.values {
                for (key, value) in binding.extraParameters {
                    let key = key.lowercased().filter(\.isLetter)
                    if ["token", "secret", "password", "apikey", "authorization"].contains(where: key.contains) {
                        privateValues.insert(value)
                    }
                }
            }
        }
        privateValues.remove("")
        for summary in summaries {
            try summary.checkPublicFields(excluding: privateValues)
        }
        try writeJSON(summaries, at: "characters.json")
        let optional = references.isEmpty ? [] : ["references.json"]
        if !references.isEmpty { try writeJSON(references, at: "references.json") }
        let required = PackPath.core + entries.flatMap { [$0.audioRelativePath, $0.transcriptRelativePath] }

        // checksums.json has a fixed-width manifest hash. Only the decimal width
        // of total_byte_size can change the final size of manifest.json.
        hashes["manifest.json"] = String(repeating: "0", count: 64)
        let fixedBytes = payloadBytes + Int64(try encoder.encode(AudioPackChecksums(files: hashes)).count)
        var totalBytes = fixedBytes
        var manifestData: Data
        while true {
            let manifest = AudioPackManifest(
                releaseID: releaseID, releaseVersion: releaseVersion, projectID: projectID,
                productionMode: productionMode, audioMode: audioMode, totalDurationSeconds: timeline.totalDurationSeconds,
                totalByteSize: totalBytes, chapters: entries, requiredFiles: required, optionalFiles: optional,
                requiredCapabilities: ["audio." + format.rawValue, "sync.v1"], createdAtISO8601: metadata.createdAtISO8601
            )
            manifestData = try encoder.encode(manifest)
            let measured = fixedBytes + Int64(manifestData.count)
            if measured == totalBytes { break }
            totalBytes = measured
        }
        let manifestDigest = packDigest(SHA256.hash(data: manifestData))
        hashes["manifest.json"] = manifestDigest
        try manifestData.write(to: stage.appendingPathComponent("manifest.json"))
        try encoder.encode(AudioPackChecksums(files: hashes)).write(to: stage.appendingPathComponent("checksums.json"))
        _ = try validator.validate(in: stage)
        // Sibling directories share a volume. RENAME_EXCL also protects an existing
        // release when two publishers finish concurrently.
        guard renamex_np(stage.path, outputDir.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return PublishedReleaseRecord(
            releaseID: releaseID, projectID: projectID, releaseVersion: releaseVersion, title: metadata.title,
            packRelativePath: outputDir.lastPathComponent, manifestSHA256: manifestDigest, chapterCount: entries.count,
            totalDurationSeconds: timeline.totalDurationSeconds, totalByteSize: totalBytes, createdAtISO8601: metadata.createdAtISO8601
        )
    }
}
