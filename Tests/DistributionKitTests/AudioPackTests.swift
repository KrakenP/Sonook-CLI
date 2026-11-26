import AudioCore
import AudioRenderKit
import CryptoKit
import DistributionKit
import Foundation
import Testing

@Suite("Version 1 audio packs")
struct AudioPackTests {
    let validator = AudioPackValidator()

    @Test func twoChapterM4ARoundTrip() throws {
        try withPackDirectory { folder in
            let root = folder.appendingPathComponent("book.audiopack")
            let fixture = try AudioPackFixture()
            let citation = KnowledgeCitation(citationID: "c", sourceID: "s", sourceTitle: "风", chunkID: "chunk",
                                            sourceSpan: try SourceSpan(start: 0, endExclusive: 3), quotedExcerpt: "风",
                                            ingestedAtISO8601: AudioPackFixture.timestamp)
            let record = try fixture.write(to: root, format: .m4a, references: [citation])
            let reader = try AudioPackReader(contentsOf: root)
            #expect(reader.references == [citation])
            #expect(reader.manifest.optionalFiles == ["references.json"])
            #expect(reader.manifest.requiredCapabilities.contains("audio.m4a"))
            #expect(reader.metadata.title == "风起")
            #expect(reader.timeline == fixture.timeline)
            #expect(record.chapterCount == 2)
            #expect(record.totalDurationSeconds == 0.6)
            #expect(record.packRelativePath == "book.audiopack")
            #expect(record.manifestSHA256 == reader.checksums.files["manifest.json"])
            let expectedFiles = Set(["manifest.json", "metadata.json", "characters.json", "timeline.json", "references.json",
                                     "chapters/001.m4a", "chapters/002.m4a", "transcripts/001.json", "transcripts/002.json"])
            #expect(Set(reader.checksums.files.keys) == expectedFiles)
            var bytes: Int64 = 0
            for path in expectedFiles.union(["checksums.json"]) {
                let data = try Data(contentsOf: root.appendingPathComponent(path))
                bytes += Int64(data.count)
                if path != "checksums.json" {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    #expect(digest == reader.checksums.files[path])
                }
            }
            #expect(bytes == record.totalByteSize)
            #expect(bytes == reader.manifest.totalByteSize)
            for chapter in reader.manifest.chapters {
                let url = try validator.resolveFileURL(in: root, relativePath: chapter.audioRelativePath)
                let pcm = try PCMCodec.readMonoSamples(from: url)
                #expect(pcm.sampleRate == 24_000)
                #expect(pcm.samples.contains { abs($0) > 0.01 })
                let transcript = try #require(reader.transcripts[chapter.chapterID])
                #expect(transcript.segments.map(\.startMs) == [0, 150])
                #expect(transcript.segments.map(\.endMs) == [100, 250])
                #expect(transcript.segments.map(\.sourceSpan) == fixture.chapters[chapter.chapterNumber - 1].script.segments.map(\.sourceSpan))
                #expect(transcript.segments.last?.speakerName == "旁白")
            }
            let contents = try reader.openFile(relativePath: "characters.json").readToEnd()
            let publicBytes = try #require(contents)
            let objects = try #require(JSONSerialization.jsonObject(with: publicBytes) as? [[String: Any]])
            #expect(objects.count == 1)
            #expect(Set(objects[0].keys) == Set(["character_id", "canonical_name", "aliases", "persona_summary", "first_appeared_chapter"]))
            #expect(reader.characters == [.init(characterID: "reader", canonicalName: "旁白", aliases: ["讲述者"],
                                                 personaSummary: "平和", firstAppearedChapter: 1)])
            for secret in ["private", "voice_audition", ".wav", "secret", "anchor", "token"] {
                #expect(!String(decoding: publicBytes, as: UTF8.self).contains(secret))
            }
            let audio = root.appendingPathComponent("chapters/001.m4a")
            var encoded = try Data(contentsOf: audio)
            encoded[encoded.count / 2] ^= 1
            try encoded.write(to: audio)
            #expect(throws: AudioPackError.checksumMismatch("chapters/001.m4a")) { try validator.validate(in: root) }
        }
    }

    @Test func unknownVersionAndUnsafeDeclarations() throws {
        try withPackDirectory { folder in
            let root = folder.appendingPathComponent("book")
            _ = try AudioPackFixture().write(to: root)
            let manifest = root.appendingPathComponent("manifest.json")
            let original = try Data(contentsOf: manifest)
            try Data(#"{"format_version":99}"#.utf8).write(to: manifest)
            #expect(throws: AudioPackError.unsupportedFormatVersion(99)) { try validator.validate(in: root) }
            for key in ["audio_relative_path", "transcript_relative_path", "required_files", "optional_files"] {
                var fields = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
                if key.hasSuffix("_path") {
                    var chapters = try #require(fields["chapters"] as? [[String: Any]])
                    chapters[1][key] = "../secret"
                    fields["chapters"] = chapters
                } else {
                    fields[key] = ["../secret"]
                }
                try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
                #expect(throws: AudioPackError.unsafePath("../secret")) { try validator.validate(in: root) }
            }
            try original.write(to: manifest)
            let checksumURL = root.appendingPathComponent("checksums.json")
            var checksums = try JSONDecoder().decode(AudioPackChecksums.self, from: Data(contentsOf: checksumURL))
            for path in ["/private/data", "chapters/..\\secret", "chapters/a\0b.m4a", "C:/data"] {
                checksums.files[path] = "x"
                try JSONEncoder().encode(checksums).write(to: checksumURL)
                #expect(throws: AudioPackError.unsafePath(path)) { try validator.validate(in: root) }
                #expect(throws: AudioPackError.unsafePath(path)) { try validator.resolveFileURL(in: root, relativePath: path) }
                checksums.files[path] = nil
            }
            checksums.files["metadata.json"] = nil
            try JSONEncoder().encode(checksums).write(to: checksumURL)
            #expect(throws: AudioPackError.self) { try validator.validate(in: root) }
        }
    }

    @Test func limitsMissingFilesAndPrivateArtifacts() throws {
        try withPackDirectory { folder in
            let root = folder.appendingPathComponent("book")
            let record = try AudioPackFixture().write(to: root)
            let reader = try validator.validate(in: root)
            #expect(reader.references.isEmpty)
            #expect(reader.manifest.optionalFiles.isEmpty)
            #expect(reader.manifest.requiredCapabilities.contains("audio.wav"))
            #expect(throws: AudioPackError.sizeLimitExceeded) {
                try AudioPackValidator(maxFileByteSize: reader.manifest.chapters[0].byteSize - 1).validate(in: root)
            }
            #expect(throws: AudioPackError.sizeLimitExceeded) {
                try AudioPackValidator(maxTotalByteSize: record.totalByteSize - 1).validate(in: root)
            }
            for path in ["local.sqlite", "chapters/voice_audition.wav", "model.safetensors", "secret.key", "cert.pem", ".hidden"] {
                let file = root.appendingPathComponent(path)
                try Data().write(to: file)
                #expect(throws: AudioPackError.unsafePath(path)) { try validator.validate(in: root) }
                try FileManager.default.removeItem(at: file)
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("metadata.json"))
            #expect(throws: AudioPackError.self) { try validator.validate(in: root) }
        }
    }

    @Test func fileAndDirectorySymlinksCannotEscape() throws {
        try withPackDirectory { folder in
            let fm = FileManager.default
            let root = folder.appendingPathComponent("book")
            _ = try AudioPackFixture().write(to: root)
            let reader = try validator.validate(in: root)
            let name = "chapters/001.wav"
            for path in [name, "chapters"] {
                let original = root.appendingPathComponent(path)
                let outside = folder.appendingPathComponent("outside")
                try fm.moveItem(at: original, to: outside)
                try fm.createSymbolicLink(at: original, withDestinationURL: outside)
                #expect(throws: AudioPackError.self) { try validator.validate(in: root) }
                #expect(throws: AudioPackError.self) { try validator.resolveFileURL(in: root, relativePath: name) }
                #expect(throws: AudioPackError.self) { try reader.openFile(relativePath: name) }
                try fm.removeItem(at: original)
                try fm.moveItem(at: outside, to: original)
            }
            let alias = folder.appendingPathComponent("alias", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: root)
            #expect(throws: AudioPackError.self) { try validator.resolveFileURL(in: alias, relativePath: name) }
        }
    }

    @Test func failedPublicationLeavesNoPartialPackOrOverwrite() throws {
        try withPackDirectory { folder in
            let fm = FileManager.default
            let root = folder.appendingPathComponent("book")
            let invalid = try AudioPackFixture(lastStatus: .needsReview)
            #expect(throws: AudioPackError.self) { try invalid.write(to: root) }
            #expect(try fm.contentsOfDirectory(atPath: folder.path).isEmpty)
            let valid = try AudioPackFixture()
            let release = try valid.write(to: root)
            #expect(throws: (any Error).self) { try valid.write(to: root, version: 2) }
            #expect(try fm.contentsOfDirectory(atPath: folder.path) == ["book"])
            #expect(try validator.validate(in: root).checksums.files["manifest.json"] == release.manifestSHA256)
        }
    }

    @Test func privateValuesCopiedIntoPublicCharacterFieldsBlockPublication() throws {
        try withPackDirectory { folder in
            let fixture = try AudioPackFixture()
            let root = folder.appendingPathComponent("book")
            for leak in ["private-anchor", "sample-secret", "/private/recordings", "voice_audition/private.wav"] {
                var card = AudioPackFixture.privateCard
                card.personaSummary = "备注：" + leak
                #expect(throws: AudioPackError.invalidPack("Private data in public character metadata")) {
                    try fixture.write(to: root, characters: [card])
                }
                #expect(!FileManager.default.fileExists(atPath: root.path))
            }
        }
    }
}
