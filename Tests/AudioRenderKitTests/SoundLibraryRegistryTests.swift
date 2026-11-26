import AudioCore
import AudioRenderKit
import Foundation
import Testing

@Suite struct SoundLibraryRegistryTests {
    @Test func manifestRoundTripChecksRealFilesAndRejectsTampering() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let pcm = [Float](repeating: 0.1, count: 4000)
        let url = try f.wav("rain_light/window.wav", samples: pcm)
        try PCMCodec.writeM4A(samples: pcm, sampleRate: 24000, to: f.directory.appendingPathComponent("street.m4a"))
        let registry = try f.registry()
        #expect(registry.manifest.entries.count == 2)
        let entry = try #require(registry.manifest.entries.first { $0.relativePath.hasSuffix("window.wav") })
        #expect(entry.durationSeconds == 0.5)
        #expect(entry.sampleRate == 8000)
        #expect(entry.fileSHA256 == SoundFixture.hash(try Data(contentsOf: url)))
        let m4a = try #require(registry.manifest.entries.last)
        #expect(m4a.sampleRate == 24000 && abs(m4a.durationSeconds - 1.0 / 6) < 0.05)
        try registry.verifyIntegrity()
        try Data("changed".utf8).write(to: url)
        #expect(throws: SoundLibraryError.digestMismatch(entry.entryID)) { try registry.verifyIntegrity() }
        #expect(throws: SoundLibraryError.digestMismatch(entry.entryID)) {
            try SoundLibraryRegistry(rootDirectory: f.directory, verifyHashes: true)
        }
    }

    @Test func rejectsInvalidManifestVersionsDuplicateIDsAndMalformedDigests() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        try f.wav("sound.wav", samples: [0, 0.1])
        let entry = try #require(f.registry().manifest.entries.first)
        #expect(throws: SoundLibraryError.invalidEntry(entry.entryID)) {
            try SoundLibraryRegistry(rootDirectory: f.directory, manifest: .init(entries: [entry, entry]))
        }
        let bad = SoundLibraryEntry(entryID: "bad", preset: .custom, relativePath: entry.relativePath,
                                    durationSeconds: 1, fileSHA256: "not-a-sha256")
        #expect(throws: SoundLibraryError.invalidEntry("bad")) {
            try SoundLibraryRegistry(rootDirectory: f.directory, manifest: .init(entries: [bad]))
        }
        let manifest = f.directory.appendingPathComponent("manifest.json")
        try Data(#"{"schema_version":2,"library_version":"1","entries":[]}"#.utf8).write(to: manifest)
        #expect(throws: DecodingError.self) { try SoundLibraryRegistry(rootDirectory: f.directory) }
    }

    @Test func rejectsTraversalAbsolutePathsAndSymlinksIncludingAfterLoad() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let outside = try SoundFixture()
        defer { outside.remove() }
        let pcm = [Float](repeating: 0.25, count: 50)
        let secret = try outside.wav("secret.wav", samples: pcm)
        let original = try f.wav("bed.wav", samples: pcm)
        let registry = try f.registry()
        let entry = try #require(registry.manifest.entries.first)
        try FileManager.default.createSymbolicLink(at: f.directory.appendingPathComponent("link"), withDestinationURL: outside.directory)
        for path in ["../secret.wav", secret.path, "link/secret.wav", "foo/../bed.wav", "C:\\secret.wav"] {
            let unsafe = SoundLibraryEntry(entryID: "bad", preset: .custom, relativePath: path, durationSeconds: 1,
                                           fileSHA256: entry.fileSHA256)
            try JSONEncoder().encode(SoundLibraryManifest(entries: [unsafe])).write(to: f.directory.appendingPathComponent("manifest.json"))
            #expect(throws: SoundLibraryError.unsafePath(path)) { try SoundLibraryRegistry(rootDirectory: f.directory) }
        }
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: secret)
        #expect(throws: SoundLibraryError.unsafePath("bed.wav")) { try registry.fileURL(for: entry) }
        #expect(throws: SoundLibraryError.unsafePath("bed.wav")) { try SoundLibraryRegistry.buildManifest(cc0Directory: f.directory) }
    }

    @Test func matchesRelevantBedsAndPointEffectsAndAuditsEveryLicense() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        for path in ["rain_light/window.wav", "forest_wind/leaves.wav", "custom/courtyard.wav", "sfx/door_knock.wav"] {
            try f.wav(path, samples: [0, 0.2, 0])
        }
        let registry = try f.registry()
        #expect(registry.resolveAmbientEntry(for: SoundFixture.scene("leaves", .rainLight))?.preset == .rainLight)
        #expect(registry.resolveAmbientEntry(for: SoundFixture.scene("courtyard", .templeQuiet))?.preset == .custom)
        #expect(registry.resolveAmbientEntry(for: SoundFixture.scene("leaves", .none)) == nil)
        #expect(registry.resolveAmbientEntry(for: SoundFixture.scene("unknown", .custom)) == nil)
        #expect(registry.resolveAmbientEntry(for: SoundFixture.scene("door", .custom)) == nil)
        #expect(registry.resolveSFXEntry(for: SoundFixture.point())?.relativePath == "sfx/door_knock.wav")
        #expect(registry.resolveSFXEntry(for: SoundFixture.point(prompt: "leaves")) == nil)
        let categoryOnly = SFXCue(cueID: "x", chapterID: "one", anchorSegmentID: "a", soundPrompt: "bang", category: "door")
        #expect(registry.resolveSFXEntry(for: categoryOnly)?.relativePath == "sfx/door_knock.wav")

        let cc0 = try #require(registry.manifest.entries.first)
        let entries = ["CC0-1.0", "Public-Domain", "CC-BY-4.0", "restricted", ""].enumerated().map { index, license in
            SoundLibraryEntry(entryID: String(index), preset: index < 2 ? .custom : .templeQuiet,
                              tags: ["sound"], relativePath: cc0.relativePath, license: license, sourceAttribution: "artist",
                              durationSeconds: cc0.durationSeconds, fileSHA256: cc0.fileSHA256)
        }
        let audited = try SoundLibraryRegistry(rootDirectory: f.directory, manifest: .init(entries: entries))
        #expect(audited.licenseAudit().map(\.classification) == [.cc0, .cc0, .permissive, .needsReview, .needsReview])
        #expect(audited.licenseAudit().allSatisfy { $0.attribution == "artist" })
        #expect(audited.resolveAmbientEntry(for: SoundFixture.scene("temple", .templeQuiet)) == nil)
    }
}
