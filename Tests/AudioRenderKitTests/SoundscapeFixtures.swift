import AudioCore
import AudioRenderKit
import CryptoKit
import Foundation

struct SoundFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("soundscape-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func wav(_ path: String, samples: [Float], rate: Int = 8000) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try PCMCodec.writeWAV(samples: samples, sampleRate: rate, to: url)
        return url
    }

    func registry() throws -> SoundLibraryRegistry {
        let manifest = try SoundLibraryRegistry.buildManifest(cc0Directory: directory, sourceAttribution: "test fixture")
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return try SoundLibraryRegistry(rootDirectory: directory)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func scene(_ tag: String, _ preset: SceneAtmospherePreset, chapter: String = "one",
                      first: String = "a", last: String = "a", fade: Int = 100, gain: Double = 0) -> SceneCue {
        SceneCue(cueID: tag, chapterID: chapter, startSegmentID: first, endSegmentID: last, sceneTag: tag,
                 preset: preset, gainDB: gain, crossfadeMs: fade)
    }

    static func point(_ id: String = "door", chapter: String = "one", anchor: String = "a", prompt: String = "door knock",
                      placement: SFXPlacement = .during, offset: Int = 0, duration: Double = 0.025,
                      gain: Double = 0) -> SFXCue {
        SFXCue(cueID: id, chapterID: chapter, anchorSegmentID: anchor, placement: placement, offsetMs: offset,
               soundPrompt: prompt, durationSeconds: duration, gainDB: gain)
    }

    static func plan(_ scenes: [SceneCue] = [], _ points: [SFXCue] = [], chapter: String = "one") -> ChapterSoundscapePlan {
        ChapterSoundscapePlan(chapterID: chapter, scriptRevision: 1, sceneCues: scenes, sfxCues: points,
                              provenance: "unit-test", createdAtISO8601: "2026-01-01")
    }

    static func timeline(rate: Int, count: Int, entries: [(chapter: String, id: String, start: Int, end: Int)],
                         markers: [ChapterMarker] = [], dryHash: String = "dry-v1") throws -> RenderedBookTimeline {
        let span = try SourceSpan(start: 0, endExclusive: 3)
        return RenderedBookTimeline(sampleRate: rate, totalFrames: Int64(count),
                                    totalDurationSeconds: Double(count) / Double(rate), ambientMixed: false,
                                    renderFingerprint: dryHash, chapters: markers, entries: entries.map {
            BookTimelineEntry(chapterID: $0.chapter, segmentID: $0.id, speakerID: "voice", sourceSpan: span,
                              startFrame: Int64($0.start), endFrameExclusive: Int64($0.end),
                              startSeconds: Double($0.start) / Double(rate), endSeconds: Double($0.end) / Double(rate),
                              pauseAfterMs: 0)
        })
    }
}

/// Small file-backed ArtifactStore contract double. A fresh resolver must recover the receipt from
/// committed WAV bytes, just as it would when reopening a workspace.
actor TestSoundStore: ArtifactStoreProtocol {
    let root: URL
    private var records: [String: AssetRecord] = [:]
    init(_ root: URL) { self.root = root }

    func commitBytes(_ data: Data, projectID: String, kind: AssetKind, fileExtension: String,
                     sampleRate: Int?, frameCount: Int?, provenance: AssetProvenance) throws -> AssetRecord {
        let id = UUID().uuidString
        let path = id + "." + fileExtension
        try data.write(to: root.appendingPathComponent(path))
        let record = AssetRecord(assetID: id, projectID: projectID, kind: kind, relativePath: path, fileExtension: fileExtension,
                                 fileSHA256: SoundFixture.hash(data), byteSize: Int64(data.count), sampleRate: sampleRate,
                                 frameCount: frameCount, provenance: provenance, createdAtISO8601: "")
        records[id] = record
        return record
    }

    func asset(id: String) -> AssetRecord? { records[id] }
    func listAssets(projectID: String, kind: AssetKind?) -> [AssetRecord] {
        records.values.filter { $0.projectID == projectID && (kind == nil || $0.kind == kind) }
    }
    func resolveFileURL(for assetID: String) throws -> URL {
        guard let record = records[assetID] else { throw WorkflowStoreError.notFound(assetID) }
        return root.appendingPathComponent(record.relativePath)
    }
    func readVerifiedData(for assetID: String) throws -> Data {
        let data = try Data(contentsOf: resolveFileURL(for: assetID))
        guard SoundFixture.hash(data) == records[assetID]?.fileSHA256 else {
            throw WorkflowStoreError.assetIntegrityFailure(assetID: assetID, reason: "Checksum mismatch")
        }
        return data
    }
    func verifyAssetIntegrity(assetID: String) -> Bool { (try? readVerifiedData(for: assetID)) != nil }
    func runStartupReconciliation() -> OrphanGCReport { .init() }
}
