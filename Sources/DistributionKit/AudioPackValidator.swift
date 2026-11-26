import AudioCore
import AudioRenderKit
import Foundation

/// A validated v1 release. Positions in its transcripts are chapter-relative.
public struct AudioPackReader: Sendable {
    public let root: URL
    public let manifest: AudioPackManifest
    public let metadata: AudioPackMetadata
    public let characters: [AudioPackCharacterSummary]
    public let references: [KnowledgeCitation]
    public let timeline: RenderedBookTimeline
    public let transcripts: [String: AudioPackChapterTranscript]
    public let checksums: AudioPackChecksums

    /// Use the pinned handle when streaming downloads so a later pathname change cannot redirect a read.
    public func openFile(relativePath: String) throws -> FileHandle {
        guard relativePath == "checksums.json" || checksums.files[relativePath] != nil else {
            throw AudioPackError.unsafePath(relativePath)
        }
        return try PackDirectory(root).openFile(relativePath).handle
    }
}

extension AudioPackReader {
    public init(contentsOf root: URL, validator: AudioPackValidator = .init()) throws {
        self = try validator.validate(in: root)
    }
}

public struct AudioPackValidator: Sendable {
    public let maxFileByteSize: Int64
    public let maxTotalByteSize: Int64
    /// Aggregate limit for sidecars decoded into memory. Audio is hashed in chunks.
    public let maxJSONByteSize: Int64

    public init(maxFileByteSize: Int64 = 512 << 20, maxTotalByteSize: Int64 = 16 << 30,
                maxJSONByteSize: Int64 = 32 << 20) {
        self.maxFileByteSize = maxFileByteSize
        self.maxTotalByteSize = maxTotalByteSize
        self.maxJSONByteSize = maxJSONByteSize
    }

    /// Resolve an existing regular file in a published immutable pack.
    public func resolveFileURL(in packRoot: URL, relativePath: String) throws -> URL {
        let file = try PackDirectory(packRoot).openFile(relativePath)
        guard file.size <= min(maxFileByteSize, maxTotalByteSize) else { throw AudioPackError.sizeLimitExceeded }
        return packRoot.appendingPathComponent(relativePath, isDirectory: false)
    }

    public func validate(in packRoot: URL) throws -> AudioPackReader {
        let directory = try PackDirectory(packRoot)
        let decoder = JSONDecoder()
        let manifestSize = try directory.openFile("manifest.json").size
        guard manifestSize <= min(maxJSONByteSize, maxFileByteSize, maxTotalByteSize) else {
            throw AudioPackError.sizeLimitExceeded
        }
        let manifestFile = try directory.read("manifest.json", size: manifestSize, collect: true)
        struct Version: Decodable { let format_version: Int }
        let version = try decoder.decode(Version.self, from: manifestFile.data).format_version
        guard version == AudioPackManifest.currentFormatVersion else { throw AudioPackError.unsupportedFormatVersion(version) }
        let manifest = try decoder.decode(AudioPackManifest.self, from: manifestFile.data)
        let inventory = try directory.fileSizes(maxFile: maxFileByteSize, maxTotal: maxTotalByteSize)
        let jsonBytes = inventory.files.filter { $0.key.hasSuffix(".json") }.values.reduce(0, +)
        guard jsonBytes <= maxJSONByteSize else { throw AudioPackError.sizeLimitExceeded }

        func readJSON(_ path: String) throws -> (data: Data, digest: String) {
            guard let size = inventory.files[path] else { throw AudioPackError.invalidPack("Missing \(path)") }
            return try directory.read(path, size: size, collect: true)
        }
        let checksums = try decoder.decode(AudioPackChecksums.self, from: readJSON("checksums.json").data)
        let chapterPaths = manifest.chapters.flatMap { [$0.audioRelativePath, $0.transcriptRelativePath] }
        let declared = manifest.requiredFiles + manifest.optionalFiles + chapterPaths
        for path in declared { try PackPath.check(path) }
        for path in checksums.files.keys { try PackPath.check(path) }

        let files = Set(inventory.files.keys)
        let required = Set(PackPath.core + manifest.requiredFiles + chapterPaths)
        guard checksums.algorithm == "sha256", Set(checksums.files.keys) == files.subtracting(["checksums.json"]),
              required.isSubset(of: files), files.isSubset(of: required.union(manifest.optionalFiles)),
              Set(chapterPaths).count == chapterPaths.count,
              files.filter({ $0.contains("/") }) == Set(chapterPaths),
              manifest.totalByteSize == inventory.total else {
            throw AudioPackError.invalidPack("Inconsistent file inventory or total byte size")
        }
        func verify(_ path: String, _ digest: String) throws {
            guard checksums.files[path] == digest else { throw AudioPackError.checksumMismatch(path) }
        }
        func decode<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
            let file = try readJSON(path)
            try verify(path, file.digest)
            return try decoder.decode(type, from: file.data)
        }
        try verify("manifest.json", manifestFile.digest)
        let metadata = try decode("metadata.json", as: AudioPackMetadata.self)
        let characterFile = try readJSON("characters.json")
        try verify("characters.json", characterFile.digest)
        let characters = try decoder.decode([AudioPackCharacterSummary].self, from: characterFile.data)
        // Codable ignores unknown keys, but download clients receive the original bytes.
        let publicKeys = Set(["character_id", "canonical_name", "aliases", "persona_summary", "first_appeared_chapter"])
        guard let objects = try JSONSerialization.jsonObject(with: characterFile.data) as? [[String: Any]],
              objects.allSatisfy({ Set($0.keys).isSubset(of: publicKeys) }) else {
            throw AudioPackError.invalidPack("Non-public character fields")
        }
        for character in characters { try character.checkPublicFields() }
        let timeline = try decode("timeline.json", as: RenderedBookTimeline.self)
        let references = files.contains("references.json") ? try decode("references.json", as: [KnowledgeCitation].self) : []
        if let size = inventory.files["artwork.jpg"] {
            try verify("artwork.jpg", directory.read("artwork.jpg", size: size).digest)
        }

        guard timeline.schemaVersion == 1, timeline.sampleRate > 0, timeline.totalFrames > 0,
              timeline.totalDurationSeconds == Double(timeline.totalFrames) / Double(timeline.sampleRate),
              manifest.totalDurationSeconds == timeline.totalDurationSeconds,
              !manifest.chapters.isEmpty, timeline.chapters.count == manifest.chapters.count else {
            throw AudioPackError.invalidPack("Inconsistent book timeline")
        }
        var transcripts: [String: AudioPackChapterTranscript] = [:]
        var nextFrame: Int64 = 0
        var previousNumber = 0
        var entries = timeline.entries.makeIterator()
        for (chapter, marker) in zip(manifest.chapters, timeline.chapters) {
            let audio = chapter.audioRelativePath
            guard chapter.audioRelativePath.hasPrefix("chapters/"), chapter.transcriptRelativePath.hasPrefix("transcripts/"),
                  let size = inventory.files[audio], size == chapter.byteSize, size > 0,
                  marker.chapterID == chapter.chapterID, marker.startFrame == nextFrame,
                  marker.endFrameExclusive > nextFrame, marker.endFrameExclusive <= timeline.totalFrames,
                  marker.sampleRate == timeline.sampleRate, chapter.sampleRate == marker.sampleRate,
                  chapter.durationSeconds == marker.durationSeconds, chapter.chapterNumber > previousNumber,
                  transcripts[chapter.chapterID] == nil else { throw AudioPackError.invalidPack("Invalid chapter entry") }
            let digest = try directory.read(audio, size: size).digest
            try verify(audio, digest)
            guard chapter.fileSHA256 == digest else { throw AudioPackError.checksumMismatch(audio) }
            let transcript = try decode(chapter.transcriptRelativePath, as: AudioPackChapterTranscript.self)
            guard transcript.chapterID == chapter.chapterID, transcript.chapterNumber == chapter.chapterNumber,
                  transcript.title == chapter.title, !transcript.segments.isEmpty else {
                throw AudioPackError.invalidPack("Transcript does not match chapter")
            }
            var previousEnd = marker.startFrame
            var segmentIDs = Set<String>()
            for segment in transcript.segments {
                guard let entry = entries.next(), segmentIDs.insert(segment.segmentID).inserted,
                      entry.chapterID == chapter.chapterID, entry.segmentID == segment.segmentID,
                      entry.sourceSpan == segment.sourceSpan, entry.speakerID == segment.speakerID,
                      entry.startFrame >= previousEnd, entry.endFrameExclusive > entry.startFrame,
                      entry.endFrameExclusive <= marker.endFrameExclusive,
                      entry.startSeconds == Double(entry.startFrame) / Double(timeline.sampleRate),
                      entry.endSeconds == Double(entry.endFrameExclusive) / Double(timeline.sampleRate),
                      segment.startMs == (try marker.localMs(entry.startFrame)),
                      segment.endMs == (try marker.localMs(entry.endFrameExclusive)) else {
                    throw AudioPackError.invalidPack("Inconsistent segment timing or identity")
                }
                previousEnd = entry.endFrameExclusive
            }
            transcripts[chapter.chapterID] = transcript
            nextFrame = marker.endFrameExclusive
            previousNumber = chapter.chapterNumber
        }
        guard nextFrame == timeline.totalFrames, entries.next() == nil else {
            throw AudioPackError.invalidPack("Incomplete chapter timeline")
        }
        return AudioPackReader(root: packRoot, manifest: manifest, metadata: metadata, characters: characters,
                               references: references, timeline: timeline, transcripts: transcripts, checksums: checksums)
    }
}

extension AudioPackCharacterSummary {
    func checkPublicFields(excluding privateValues: Set<String> = []) throws {
        let localPath = #"(?:file://|(?:^|[\s"'(（=:：])(?:/|~/|\.\.?/|[A-Za-z]:[\\/]|\\\\)|\bvoice_audition\b|\.wav\b)"#
        for value in [characterID, canonicalName, personaSummary] + aliases {
            guard value.range(of: localPath, options: [.regularExpression, .caseInsensitive]) == nil,
                  !privateValues.contains(where: value.contains) else {
                throw AudioPackError.invalidPack("Private data in public character metadata")
            }
        }
    }
}

extension ChapterMarker {
    func localMs(_ frame: Int64) throws -> Int {
        guard startFrame >= 0, frame >= startFrame, frame <= endFrameExclusive, sampleRate > 0,
              let ms = Int(exactly: (Double(frame - startFrame) * 1000 / Double(sampleRate)).rounded()) else {
            throw AudioPackError.invalidPack("Frame outside chapter or millisecond range")
        }
        return ms
    }
}
