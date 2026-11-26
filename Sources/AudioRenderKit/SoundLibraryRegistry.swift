import AudioCore
import AVFoundation
import CryptoKit
import Foundation

public enum SoundLibraryError: Error, Equatable {
    case unsafePath(String)
    case invalidEntry(String)
    case digestMismatch(String)
}

public struct SoundLicenseAudit: Sendable {
    public enum Classification: Sendable { case cc0, permissive, needsReview }
    public let entryID: String
    public let license: String
    public let attribution: String
    public let classification: Classification

    fileprivate static func classify(_ license: String) -> Classification {
        switch license.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cc0", "cc0-1.0", "public-domain", "public domain", "pd": .cc0
        case "cc-by-4.0", "cc-by-3.0", "mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause": .permissive
        default: .needsReview
        }
    }
}

enum SoundFile {
    static func checkedURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.components(separatedBy: "/")
        guard root.isFileURL, !relativePath.contains("\0"), !relativePath.contains("\\"),
              !relativePath.hasPrefix("~"), !relativePath.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SoundLibraryError.unsafePath(relativePath)
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathComponents.starts(with: root.pathComponents),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SoundLibraryError.unsafePath(relativePath)
        }
        return url
    }

    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SoundLibraryRegistry: Sendable {
    public let rootDirectory: URL
    public let manifest: SoundLibraryManifest

    public init(rootDirectory: URL, manifestFilename: String = "manifest.json", verifyHashes: Bool = false) throws {
        let manifestURL = try SoundFile.checkedURL(root: rootDirectory, relativePath: manifestFilename)
        let manifest = try JSONDecoder().decode(SoundLibraryManifest.self, from: Data(contentsOf: manifestURL))
        try self.init(rootDirectory: rootDirectory, manifest: manifest, verifyHashes: verifyHashes)
    }

    public init(rootDirectory: URL, manifest: SoundLibraryManifest, verifyHashes: Bool = false) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = manifest
        var ids = Set<String>()
        guard !manifest.libraryVersion.isEmpty else { throw SoundLibraryError.invalidEntry("library_version") }
        for entry in manifest.entries {
            guard !entry.entryID.isEmpty, ids.insert(entry.entryID).inserted,
                  entry.sampleRate > 0, entry.durationSeconds.isFinite, entry.durationSeconds > 0,
                  entry.fileSHA256.utf8.count == 64, entry.fileSHA256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
                  }) else { throw SoundLibraryError.invalidEntry(entry.entryID) }
            _ = try fileURL(for: entry, verifyHash: verifyHashes)
        }
    }

    public func fileURL(for entry: SoundLibraryEntry, verifyHash: Bool = true) throws -> URL {
        let url = try SoundFile.checkedURL(root: rootDirectory, relativePath: entry.relativePath)
        if verifyHash, try SoundFile.digest(url) != entry.fileSHA256.lowercased() {
            throw SoundLibraryError.digestMismatch(entry.entryID)
        }
        return url
    }

    public func verifyIntegrity() throws {
        for entry in manifest.entries { _ = try fileURL(for: entry) }
    }

    public func licenseAudit() -> [SoundLicenseAudit] {
        manifest.entries.map {
            SoundLicenseAudit(entryID: $0.entryID, license: $0.license, attribution: $0.sourceAttribution,
                              classification: SoundLicenseAudit.classify($0.license))
        }
    }

    /// Automatic selection uses only CC0 assets. A custom preset requires matching tags.
    public func resolveAmbientEntry(for cue: SceneCue) -> SoundLibraryEntry? {
        guard cue.preset != .none else { return nil }
        let query = Self.words(cue.sceneTag + " " + cue.preset.rawValue)
        return bestMatch { entry in
            guard entry.loopable, !Self.isPointEffect(entry) else { return (0, 0) }
            let exact = entry.preset == cue.preset && cue.preset != .custom
            return (exact ? 1 : 0, Self.overlap(tags: entry.tags, query: query))
        }
    }

    public func resolveSFXEntry(for cue: SFXCue) -> SoundLibraryEntry? {
        let prompt = Self.words(cue.soundPrompt)
        let category = Self.words(cue.category)
        return bestMatch { entry in
            guard Self.isPointEffect(entry) else { return (0, 0) }
            return (Self.overlap(tags: entry.tags, query: prompt), Self.overlap(tags: entry.tags, query: category))
        }
    }

    private static func isPointEffect(_ entry: SoundLibraryEntry) -> Bool {
        entry.preset == .none || !entry.loopable || entry.tags.contains { $0.lowercased() == "sfx" }
    }

    private func bestMatch(score: (SoundLibraryEntry) -> (Int, Int)) -> SoundLibraryEntry? {
        var best: SoundLibraryEntry?
        var high = (0, 0)
        for entry in manifest.entries where SoundLicenseAudit.classify(entry.license) == .cc0 {
            let rank = score(entry)
            if rank > high || (rank == high && best.map { entry.entryID < $0.entryID } == true) {
                best = entry
                high = rank
            }
        }
        return best
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["a", "an", "the", "of", "sfx", "ambient", "custom", "foley"])
    }

    private static func overlap(tags: [String], query: Set<String>) -> Int {
        let tags = words(tags.joined(separator: " "))
        return tags.filter { tag in
            query.contains(tag) || (tag.count >= 2 && tag.unicodeScalars.allSatisfy { $0.value >= 0x3400 }
                && query.contains { $0.contains(tag) })
        }.count
    }

    /// Scans a caller-curated CC0 directory. Put point effects under sfx/; use preset names
    /// (e.g. rain_light/) for beds. Other filename and directory words become searchable tags.
    public static func buildManifest(cc0Directory root: URL, libraryVersion: String = "1.0",
                                     sourceAttribution: String = "") throws -> SoundLibraryManifest {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var entries: [SoundLibraryEntry] = []
        func scan(_ directory: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles]) {
                let path = prefix + url.lastPathComponent
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true && values.isSymbolicLink != true {
                    try scan(url, prefix: path + "/")
                    continue
                }
                guard ["wav", "m4a"].contains(url.pathExtension.lowercased()) else { continue }
                let checked = try SoundFile.checkedURL(root: root, relativePath: path)
                let file = try AVAudioFile(forReading: checked)
                let rate = file.processingFormat.sampleRate
                let name = (path as NSString).deletingPathExtension.lowercased()
                let tokens = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                let tags = Array(Set(tokens)).sorted()
                let isSFX = tags.contains("sfx")
                let paddedName = "_" + tokens.joined(separator: "_") + "_"
                let preset = SceneAtmospherePreset.allCases.first {
                    $0 != .none && $0 != .custom && paddedName.contains("_" + $0.rawValue + "_")
                } ?? .custom
                guard rate.isFinite, rate > 0, file.length > 0 else { throw SoundLibraryError.invalidEntry(path) }
                entries.append(.init(entryID: path, preset: isSFX ? .none : preset,
                                     tags: tags, relativePath: path, sourceAttribution: sourceAttribution,
                                     durationSeconds: Double(file.length) / rate, loopable: !isSFX,
                                     sampleRate: Int(rate.rounded()), fileSHA256: try SoundFile.digest(checked)))
            }
        }
        try scan(root, prefix: "")
        let manifest = SoundLibraryManifest(libraryVersion: libraryVersion, entries: entries.sorted { $0.entryID < $1.entryID })
        return try Self(rootDirectory: root, manifest: manifest).manifest
    }
}
