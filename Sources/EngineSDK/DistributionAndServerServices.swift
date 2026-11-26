import AudioCore
import Darwin
import DistributionKit
import EngineServer
import Foundation
import KnowledgeKit

public struct PublishAudioPackReport: Encodable, Sendable {
    public let schemaVersion = 1
    public let release: PublishedReleaseRecord
    public let outputPath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", release, outputPath = "output_path"
    }
}

public struct AudioPackVerificationSummary: Encodable, Sendable {
    public let schemaVersion = 1
    public let manifest: AudioPackManifest
    public let verifiedFileCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", manifest, verifiedFileCount = "verified_file_count"
    }
}

public struct CreatedPairingChallenge: Sendable {
    public let challenge: PairingChallengeRecord
    public let plainCode: String
}

extension SonookEngine {
    public func publishAudioPack(
        projectID: String, chapterSpec: String? = nil, outputURL: URL? = nil,
        title: String? = nil, author: String? = nil, narrator: String? = nil,
        soundscapeEnabled: Bool = false, soundLibraryDirectory: URL? = nil,
        sfxHelperExecutable: URL? = nil, sfxLicenseTag: String? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PublishAudioPackReport {
        guard let project = try await store.project(id: projectID) else { throw EngineSDKError.projectNotFound(projectID) }
        let render = try await renderBook(projectID: projectID, chapterSpec: chapterSpec, chapterGapMs: 0,
            soundscapeEnabled: soundscapeEnabled, soundLibraryDirectory: soundLibraryDirectory,
            sfxHelperExecutable: sfxHelperExecutable, sfxLicenseTag: sfxLicenseTag, progress: progress)
        let inputs = zip(render.chapters, render.timeline.chapters).map { chapter, marker in
            AudioPackChapterInput(chapter: chapter.chapter, script: chapter.script,
                samples: Array(render.samples[Int(marker.startFrame)..<Int(marker.endFrameExclusive)]),
                sampleRate: render.timeline.sampleRate)
        }
        let mode: ProductionMode = switch project.projectType {
        case .audiobook: .audiobookVerbatim
        case .audioDrama: .audioDramaAdapted
        case .podcast: .privatePodcast
        }
        var references: [KnowledgeCitation] = []
        if project.projectType == .podcast {
            let plans = try await store.listPodcastPlans(projectID: projectID)
            references = plans.max { $0.createdAtISO8601 < $1.createdAtISO8601 }?.citations ?? []
        }
        let cast = try await store.loadCatalog(projectID: projectID)?.cards ?? []
        let metadata = AudioPackMetadata(title: title ?? project.name, author: author, narrator: narrator,
                                         createdAtISO8601: Date().ISO8601Format())

        // Allocate and publish under the same workspace lock used by production publishers in other CLI processes.
        let lock = try await lockChapterPublication()
        defer { lock.closeFile() }
        let previous = try await listPublishedReleases(projectID: projectID).map(\.releaseVersion).max() ?? 0
        guard previous < Int.max else { throw EngineSDKError.invalidInput("Release version overflow") }
        let version = previous + 1
        let safeTitle = SonookWorkspaceLayout.sanitizeFileNameComponent(metadata.title)
        let defaultURL = SonookWorkspaceLayout.projectOutputDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent("\(safeTitle)_v\(version).audiopack", isDirectory: true)
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let destination = try packDestination(outputURL ?? defaultURL)
        let managed = relativePath(destination, in: root) != nil ? destination : try packDestination(defaultURL)
        guard let path = relativePath(managed, in: root),
              !path.contains("\\"), !path.utf8.contains(0) else {
            throw EngineSDKError.invalidInput("The served release must be inside the workspace")
        }

        try Task.checkCancellation()
        progress("[Publish] Writing and verifying release v\(version)...")
        let written = try AudioPackWriter.write(to: managed, projectID: projectID, releaseID: UUID().uuidString,
            releaseVersion: version, productionMode: mode, audioMode: render.audioMode, metadata: metadata,
            chapters: inputs, timeline: render.timeline, characters: cast, references: references)
        let release = PublishedReleaseRecord(releaseID: written.releaseID, projectID: projectID, releaseVersion: version,
            title: written.title, packRelativePath: path, manifestSHA256: written.manifestSHA256,
            chapterCount: written.chapterCount, totalDurationSeconds: written.totalDurationSeconds,
            totalByteSize: written.totalByteSize, createdAtISO8601: written.createdAtISO8601)
        var copied = false
        do {
            if destination.path != managed.path {
                try copyPack(from: managed, to: destination)
                copied = true
            }
            try await store.savePublishedRelease(release)
        } catch {
            if copied { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.removeItem(at: managed)
            throw error
        }
        return .init(release: release, outputPath: destination.path)
    }

    private func relativePath(_ url: URL, in root: URL) -> String? {
        let components = url.pathComponents
        let prefix = root.pathComponents
        guard components.count > prefix.count, components.starts(with: prefix) else { return nil }
        return components.dropFirst(prefix.count).joined(separator: "/")
    }

    private func packDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.utf8.contains(0), url.pathExtension.lowercased() == "audiopack" else {
            throw EngineSDKError.invalidInput("Expected a local .audiopack directory")
        }
        // Foundation only resolves symlinks when the entire input already exists.
        // Resolve the existing ancestor before appending any as-yet-uncreated release folders.
        var ancestor = url.deletingLastPathComponent().standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let parent = missing.reversed().reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let assets = workspaceRoot.appendingPathComponent(SonookWorkspaceLayout.assetsFolderName)
            .resolvingSymlinksInPath().standardizedFileURL
        let caseSensitive = try workspaceRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames == true
        let insideAssets = parent.pathComponents.starts(with: assets.pathComponents) {
            caseSensitive ? $0 == $1 : $0.caseInsensitiveCompare($1) == .orderedSame
        }
        guard !insideAssets, !parent.pathComponents.contains(where: { $0.lowercased().hasSuffix(".audiopack") }) else {
            throw EngineSDKError.invalidInput("Cannot publish inside immutable assets or another release")
        }
        return parent.appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    // An export on a different volume still gets an atomic, exclusive rename on that volume.
    private func copyPack(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".audiopack-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        _ = try AudioPackValidator().validate(in: stage)
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func verifyAudioPack(packURL: URL) throws -> AudioPackVerificationSummary {
        let pack = try AudioPackValidator().validate(in: packURL)
        return .init(manifest: pack.manifest, verifiedFileCount: pack.checksums.files.count)
    }

    public func listPublishedReleases(projectID: String? = nil) async throws -> [PublishedReleaseRecord] {
        try await store.listPublishedReleases(projectID: projectID)
    }

    public func syncPlaybackEvents(_ events: [PlaybackEvent]) async throws -> SyncMergeReport {
        let lock = try await lockChapterPublication()
        defer { lock.closeFile() }
        return try await playbackSync.ingest(events)
    }

    public func loadPlaybackCursor(projectID: String) async throws -> PlaybackCursor? {
        try await store.loadPlaybackCursor(projectID: projectID)
    }

    public func migratePlaybackCursor(projectID: String, fromReleaseID: String, toReleaseID: String) async throws -> PlaybackCursor {
        let old = try await validatedRelease(id: fromReleaseID, projectID: projectID)
        let new = try await validatedRelease(id: toReleaseID, projectID: projectID)
        let lock = try await lockChapterPublication()
        defer { lock.closeFile() }
        guard let current = try await loadPlaybackCursor(projectID: projectID) else {
            throw EngineSDKError.invalidInput("No playback cursor for this project")
        }
        let cursor = try PlaybackSyncEngine.migrateCursor(current, from: old, to: new)
        try await store.savePlaybackCursor(cursor)
        return cursor
    }

    private func validatedRelease(id: String, projectID: String) async throws -> AudioPackReader {
        guard let record = try await store.publishedRelease(id: id), record.projectID == projectID else {
            throw PlaybackSyncError.releaseMismatch
        }
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(record.packRelativePath).resolvingSymlinksInPath().standardizedFileURL
        guard relativePath(url, in: root) == record.packRelativePath else { throw AudioPackError.unsafePath(record.packRelativePath) }
        let pack = try AudioPackValidator().validate(in: url)
        guard pack.manifest.projectID == projectID, pack.manifest.releaseID == id,
              pack.manifest.releaseVersion == record.releaseVersion,
              pack.checksums.files["manifest.json"] == record.manifestSHA256 else { throw PlaybackSyncError.releaseMismatch }
        return pack
    }

    public func querySpoilerSafeContext(_ request: SpoilerSafeContextRequest, llmModelID: String? = nil,
                                        useLLM: Bool = true) async throws -> SpoilerSafeContextResponse {
        guard let project = try await store.project(id: request.projectID) else { throw EngineSDKError.projectNotFound(request.projectID) }
        if useLLM, !(try await store.listModels(kind: .llm)).isEmpty {
            let entry = try await resolveModelEntry(explicitID: llmModelID ?? project.options.preferredLLMModelID, kind: .llm)
            return try await runtime.withLLMLease(entry: entry) { [store] llm in
                try await SpoilerSafeContextResolver(store: store, llm: llm).resolve(request)
            }
        }
        return try await SpoilerSafeContextResolver(store: store).resolve(request)
    }

    public static let defaultPairingScopes: [AuthScope] = [.readCatalog, .downloadMedia, .syncPlayback, .queryContext]

    public func createPairingChallenge(scopes: [AuthScope] = SonookEngine.defaultPairingScopes,
                                       ttlSeconds: Int = 300) async throws -> CreatedPairingChallenge {
        guard ttlSeconds > 0, !scopes.isEmpty else { throw EngineSDKError.invalidInput("Expected positive TTL and nonempty scopes") }
        let result = try await PairingAuthManager(store: store).createPairingChallenge(scopes: scopes, ttlSeconds: Double(ttlSeconds))
        return .init(challenge: result.challenge, plainCode: result.plainCode)
    }

    public func listPairedDevices() async throws -> [PairedDeviceRecord] { try await store.listPairedDevices() }

    public func revokePairedDevice(deviceID: String) async throws -> Bool {
        try await PairingAuthManager(store: store).revokeDevice(deviceID: deviceID)
    }

    public func makeHTTPServer(config: ServerConfig = ServerConfig(), useLLMContext: Bool = false,
                               llmModelID: String? = nil) throws -> SonookHTTPServer {
        SonookHTTPServer(config: config, dependencies: EngineServerDependencies(authStore: store, distributionStore: store,
            projectStore: store, jobStore: store, syncStore: store, workspaceRoot: workspaceRoot,
            syncEventsHandler: { try await self.syncPlaybackEvents($0) },
            contextQueryHandler: { try await self.querySpoilerSafeContext($0, llmModelID: llmModelID, useLLM: useLLMContext) },
            eventStream: ServerEventBus()))
    }
}
