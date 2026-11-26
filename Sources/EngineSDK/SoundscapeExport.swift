import AudioCore
import AudioRenderKit
import CryptoKit
import Foundation

extension SonookEngine {
    func renderSoundscape(projectID: String, drySpeech: [Float], timeline: RenderedBookTimeline,
                          chapters: [(ChapterSoundscapePlan, ScriptDocument)], libraryDirectory: URL?,
                          helperExecutable: URL?, license: String?,
                          progress: @Sendable (String) -> Void) async throws -> SoundscapeRender {
        let library = try libraryDirectory.map(Self.soundLibrary)
        let providerID = "sonook-local-sfx"
        var backends: [SFXAssetResolver.Backend] = []
        var helper: (any SFXProvider)?
        if let executable = helperExecutable {
            #if os(macOS)
            let url = executable.resolvingSymlinksInPath()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw EngineSDKError.invalidInput("SFX helper must be a local executable file")
            }
            let revision = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            let provider = SubprocessSFXProvider(executable: url, providerID: providerID, modelID: url.lastPathComponent,
                                                 modelRevision: revision, license: license)
            try await provider.load()
            helper = provider
            backends = [.provider(provider, modelRevision: revision)]
            #else
            throw EngineSDKError.invalidInput("Subprocess SFX helpers require macOS")
            #endif
        } else if chapters.contains(where: { !$0.0.sfxCues.isEmpty }) {
            // Receipts pin each cache entry to its helper revision. A later export can reuse it offline.
            let assets = try await store.listAssets(projectID: projectID, kind: .sfxAudio)
            var seen = Set<String>()
            for asset in assets.sorted(by: { $0.createdAtISO8601 > $1.createdAtISO8601 })
                where asset.provenance.providerID == providerID {
                if let revision = asset.provenance.modelRevision, seen.insert(revision).inserted {
                    backends.append(.cacheOnly(providerID: providerID, modelRevision: revision))
                }
            }
        }

        var resolved: [SFXResolution] = []
        do {
            for (plan, script) in chapters {
                let libraryResolver = SFXAssetResolver(store: store, projectID: projectID, library: library)
                var batch = try await libraryResolver.resolve(plan.sfxCues)
                for backend in backends {
                    let missing = batch.filter { $0.asset == nil }.map(\.cue)
                    guard !missing.isEmpty else { break }
                    let resolver = SFXAssetResolver(store: store, projectID: projectID, backend: backend)
                    batch.removeAll { $0.asset == nil }
                    batch += try await resolver.resolve(missing, scriptRevision: script.scriptRevision,
                                                        sourceDocumentRevision: script.sourceDocumentRevision)
                }
                resolved += batch
            }
        } catch {
            try? await helper?.unload()
            throw error
        }
        try await helper?.unload()
        let found = resolved.filter { $0.asset != nil }.count
        progress("[Export] Mixing \(chapters.count) chapter(s), \(found)/\(resolved.count) point effects resolved.")
        return try SoundscapeMixer.mix(drySpeech: drySpeech, timeline: timeline, plans: chapters.map(\.0), library: library, sfx: resolved)
    }
}
