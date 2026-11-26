import AudioCore
import AudioRenderKit
import DirectorKit
import Foundation
import KnowledgeKit
import NarrativeKit

public struct SoundscapeChapterSummary: Codable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let scriptRevision: Int
    public let sceneCues: Int
    public let sfxCues: Int
    public let provenance: String

    init(_ chapter: ChapterRecord, _ plan: ChapterSoundscapePlan) {
        chapterID = chapter.chapterID
        chapterNumber = chapter.chapterNumber
        scriptRevision = plan.scriptRevision
        sceneCues = plan.sceneCues.count
        sfxCues = plan.sfxCues.count
        provenance = plan.provenance
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id", chapterNumber = "chapter_number", scriptRevision = "script_revision"
        case sceneCues = "scene_cues", sfxCues = "sfx_cues", provenance
    }
}

public struct SoundscapePlanningReport: Codable, Sendable {
    public let schemaVersion: Int
    public let projectID: String
    public let chapterCount: Int
    public let totalSceneCues: Int
    public let totalSFXCues: Int
    public let chapters: [SoundscapeChapterSummary]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", projectID = "project_id", chapterCount = "chapter_count"
        case totalSceneCues = "total_scene_cues", totalSFXCues = "total_sfx_cues", chapters
    }
}

public struct AudioDramaAdaptationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let projectID: String
    public let chapterCount: Int
    public let chapters: [SoundscapeChapterSummary]
    public let authorization: AdaptationAuthorization

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", projectID = "project_id", chapterCount = "chapter_count", chapters, authorization
    }
}

public struct SoundLibraryScanReport: Codable, Sendable {
    public struct LicenseEntry: Codable, Sendable {
        public let entryID: String
        public let license: String
        public let attribution: String
        public let classification: String
        enum CodingKeys: String, CodingKey { case entryID = "entry_id", license, attribution, classification }
    }
    public let schemaVersion: Int
    public let manifest: SoundLibraryManifest
    public let licenseAudit: [LicenseEntry]
    public let manifestWritten: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", manifest, licenseAudit = "license_audit", manifestWritten = "manifest_written"
    }
}

public struct PodcastPlanReport: Codable, Sendable {
    public let schemaVersion: Int
    public let chapterNumber: Int
    public let plan: PodcastEpisodePlan

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", chapterNumber = "chapter_number", plan }
}

/// Planners share a leased provider. Apply the caller's seed at its negotiated request boundary.
private struct SeededPlanningProvider: LLMProvider {
    let base: any LLMProvider
    let seed: UInt64
    var capabilities: LLMCapabilities { base.capabilities }
    var isLoaded: Bool { get async { await base.isLoaded } }
    func load() async throws { try await base.load() }
    func unload() async { await base.unload() }
    func generateAccepted(prompt: String, parameters: AcceptedParameters) async throws -> LLMResponse {
        var values = parameters.values
        values["seed"] = String(seed)
        return try await base.generate(.init(prompt: prompt, parameters: values))
    }
}

extension SonookEngine {
    private func requireProject(_ projectID: String) async throws -> ProjectRecord {
        guard let project = try await store.project(id: projectID) else { throw EngineSDKError.projectNotFound(projectID) }
        return project
    }

    private func withPlanningProvider<T: Sendable>(
        project: ProjectRecord, llmModelID: String?, useLLM: Bool, seed: UInt64,
        progress: @Sendable (String) -> Void,
        _ body: @Sendable ((any LLMProvider)?) async throws -> T
    ) async throws -> T {
        if useLLM, !(try await store.listModels(kind: .llm)).isEmpty {
            let entry = try await resolveModelEntry(explicitID: llmModelID ?? project.options.preferredLLMModelID, kind: .llm)
            progress("[Plan] Using \(entry.modelID) with seed \(seed).")
            return try await runtime.withLLMLease(entry: entry) { try await body(SeededPlanningProvider(base: $0, seed: seed)) }
        }
        progress("[Plan] Using deterministic planning.")
        return try await body(nil)
    }

    func productionScript(_ chapter: ChapterRecord) async throws -> ScriptDocument {
        guard let script = try await store.loadScript(projectID: chapter.projectID, chapterID: chapter.chapterID),
              script.sourceDocumentRevision == chapter.sourceDocumentRevision else {
            throw EngineSDKError.scriptNotAnalyzed(chapter.chapterID)
        }
        return script
    }

    func soundscape(for chapter: ChapterRecord, script: ScriptDocument, llm: (any LLMProvider)? = nil) async throws -> ChapterSoundscapePlan {
        if let saved = try await store.loadSoundscapePlan(projectID: chapter.projectID, chapterID: chapter.chapterID),
           saved.scriptRevision == script.scriptRevision { return saved }
        let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, llm: llm)
        try await store.saveSoundscapePlan(plan, projectID: chapter.projectID)
        return plan
    }

    public func planSoundscapes(projectID: String, chapterSpec: String? = nil, llmModelID: String? = nil,
                                useLLM: Bool = true, seed: UInt64 = 42,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SoundscapePlanningReport {
        let project = try await requireProject(projectID)
        let chapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)
        let summaries = try await withPlanningProvider(project: project, llmModelID: llmModelID, useLLM: useLLM,
                                                      seed: seed, progress: progress) { llm in
            var summaries: [SoundscapeChapterSummary] = []
            for chapter in chapters {
                try Task.checkCancellation()
                progress("[Soundscape] Planning chapter \(chapter.chapterNumber).")
                let script = try await productionScript(chapter)
                let plan = try await SoundscapePlanner.plan(chapter: chapter, script: script, llm: llm)
                try await store.saveSoundscapePlan(plan, projectID: projectID)
                summaries.append(.init(chapter, plan))
            }
            return summaries
        }
        return .init(schemaVersion: 1, projectID: projectID, chapterCount: summaries.count,
                     totalSceneCues: summaries.reduce(0) { $0 + $1.sceneCues },
                     totalSFXCues: summaries.reduce(0) { $0 + $1.sfxCues }, chapters: summaries)
    }

    public func listSoundscapes(projectID: String) async throws -> [ChapterSoundscapePlan] {
        _ = try await requireProject(projectID)
        return try await store.listSoundscapePlans(projectID: projectID)
    }

    static func soundLibrary(at directory: URL) throws -> SoundLibraryRegistry {
        // A dangling manifest symlink is an invalid manifest, never a reason to start a fresh scan.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if names.contains("manifest.json") {
            return try SoundLibraryRegistry(rootDirectory: directory, verifyHashes: true)
        }
        return try SoundLibraryRegistry(rootDirectory: directory, manifest: SoundLibraryRegistry.buildManifest(cc0Directory: directory))
    }

    public func scanSoundLibrary(directory: URL, writeManifest: Bool = false) throws -> SoundLibraryScanReport {
        let library = try Self.soundLibrary(at: directory)
        let audit = library.licenseAudit().map { row in
            let classification = switch row.classification {
            case .cc0: "cc0"
            case .permissive: "permissive"
            case .needsReview: "needs_review"
            }
            return SoundLibraryScanReport.LicenseEntry(entryID: row.entryID, license: row.license,
                                                      attribution: row.attribution, classification: classification)
        }
        if writeManifest {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(library.manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
        return .init(schemaVersion: 1, manifest: library.manifest, licenseAudit: audit, manifestWritten: writeManifest)
    }

    public func adaptAudioDrama(projectID: String, chapterSpec: String? = nil, authorization: AdaptationAuthorization,
                                llmModelID: String? = nil, useLLM: Bool = true, seed: UInt64 = 42,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> AudioDramaAdaptationReport {
        guard authorization.authorizedByUser, authorization.mode == .audioDramaAdapted else {
            throw AudioDramaAdapterError.adaptationNotAuthorized
        }
        let project = try await requireProject(projectID)
        let chapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)
        let summaries = try await withPlanningProvider(project: project, llmModelID: llmModelID, useLLM: useLLM,
                                                      seed: seed, progress: progress) { llm in
            var summaries: [SoundscapeChapterSummary] = []
            for chapter in chapters {
                try Task.checkCancellation()
                progress("[Drama] Adapting chapter \(chapter.chapterNumber).")
                let script = try await productionScript(chapter)
                let plan = try await soundscape(for: chapter, script: script, llm: llm)
                let adapted = try await AudioDramaAdapter.adapt(script: script, soundscape: plan, authorization: authorization, llm: llm)
                // The production script carries the speech. Keep the signed-off instructions and source mapping in the snapshot.
                _ = try await store.commitBytes(JSONEncoder().encode(adapted), projectID: projectID, kind: .scriptSnapshot,
                    fileExtension: "json", sampleRate: nil, frameCount: nil,
                    provenance: .init(sourceDocumentRevision: script.sourceDocumentRevision, chapterID: chapter.chapterID,
                                      scriptRevision: adapted.scriptRevision))
                try await store.saveSoundscapePlan(adapted.soundscape, projectID: projectID)
                try await store.saveScript(adapted.asScriptDocument(), projectID: projectID)
                summaries.append(.init(chapter, adapted.soundscape))
            }
            return summaries
        }
        return .init(schemaVersion: 1, projectID: projectID, chapterCount: summaries.count, chapters: summaries, authorization: authorization)
    }

    public func ingestKnowledge(projectID: String, fileURL: URL, title: String? = nil,
                                maxChars: Int = 600, overlapChars: Int = 80) async throws -> KnowledgeSourceRecord {
        _ = try await requireProject(projectID)
        return try await KnowledgeIngestor(store: store, maxChars: maxChars, overlap: overlapChars)
            .ingest(file: fileURL, projectID: projectID, title: title)
    }

    public func listKnowledgeSources(projectID: String) async throws -> [KnowledgeSourceRecord] {
        _ = try await requireProject(projectID)
        return try await store.listKnowledgeSources(projectID: projectID)
    }

    public func searchKnowledge(projectID: String, query: String, limit: Int = 8) async throws -> [KnowledgeSearchHit] {
        _ = try await requireProject(projectID)
        return try await KnowledgeRetriever(store: store).search(projectID: projectID, query: query, limit: limit)
    }

    public func planPodcastEpisode(projectID: String, episodeID: String = "ep_" + UUID().uuidString.lowercased(),
                                   title: String? = nil, topicQuery: String, format: PodcastFormat = .soloExplainer,
                                   limit: Int = 8, llmModelID: String? = nil, useLLM: Bool = true, seed: UInt64 = 42,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PodcastPlanReport {
        let project = try await requireProject(projectID)
        let hits = try await KnowledgeRetriever(store: store).search(projectID: projectID, query: topicQuery, limit: limit)
        guard !hits.isEmpty else { throw KnowledgeError.noEvidence }
        let catalog = try await store.loadCatalog(projectID: projectID)
        let draft = try await withPlanningProvider(project: project, llmModelID: llmModelID, useLLM: useLLM,
                                                  seed: seed, progress: progress) { llm in
            try await PodcastScriptPlanner(llm: llm).plan(projectID: projectID, episodeID: episodeID, topicQuery: topicQuery,
                                                          format: format, hits: hits, catalog: catalog)
        }
        return try await publishEpisode(draft, title: title ?? draft.title)
    }

    // A replan with identical speech keeps completed synthesis. A new script must invalidate old cue anchors.
    private func revisionForPublication(_ draft: ScriptDocument, previous: ScriptDocument?,
                                        active: ScriptDocument?) throws -> ScriptDocument {
        guard let previous else { return draft }
        func revised(_ revision: Int) -> ScriptDocument {
            let segments = draft.segments.map { segment in
                ScriptSegment(segmentID: segment.segmentID, chapterID: segment.chapterID,
                              sourceDocumentRevision: draft.sourceDocumentRevision, sourceSpan: segment.sourceSpan,
                              sourceText: segment.sourceText, spokenText: segment.spokenText, speakerID: segment.speakerID,
                              voiceProfileRevision: segment.voiceProfileRevision, direction: segment.direction,
                              scriptRevision: revision, attributionConfidence: segment.attributionConfidence,
                              attributionEvidence: segment.attributionEvidence, normalizationNote: segment.normalizationNote)
            }
            return ScriptDocument(chapterID: draft.chapterID, sourceDocumentRevision: draft.sourceDocumentRevision,
                                  scriptRevision: revision, segments: segments)
        }
        if revised(previous.scriptRevision) == previous { return previous }
        let lastRevision = max(previous.scriptRevision, active?.scriptRevision ?? 0)
        guard lastRevision < Int.max else { throw EngineSDKError.invalidInput("Episode script revision overflow") }
        return revised(lastRevision + 1)
    }

    private func saveEpisodeSource(_ script: ScriptDocument, projectID: String, number: Int, title: String, createdAt: String) async throws {
        let episodeID = script.chapterID
        let revision = script.sourceDocumentRevision
        let transcript = Data(script.segments.map(\.sourceText).joined(separator: "\n").utf8)
        let asset = try await store.commitBytes(transcript, projectID: projectID, kind: .sourceDocument, fileExtension: "txt",
            sampleRate: nil, frameCount: nil, provenance: .init(sourceDocumentRevision: revision, chapterID: episodeID))
        let chapter = ChapterRecord(projectID: projectID, chapterID: episodeID, chapterNumber: number, title: title,
                                   sourceDocumentRevision: revision, sourceSpan: try .init(start: 0, endExclusive: transcript.count))
        // The planner identifies immutable transcripts by digest. Identical transcripts may belong to different episodes.
        var siblings = try await store.listChapters(projectID: projectID, sourceDocumentRevision: revision)
        siblings.removeAll { $0.chapterID == episodeID }
        siblings.append(chapter)
        let document = SourceDocumentRecord(sourceDocumentRevision: revision, projectID: projectID, format: .txt,
            originalFileName: "\(revision).txt", rawAssetID: asset.assetID, rawSHA256: asset.fileSHA256,
            normalizedAssetID: asset.assetID, normalizedSHA256: asset.fileSHA256, detectedEncoding: "utf-8",
            parserVersion: Self.podcastParser, totalUTF8Bytes: transcript.count, chapterCount: siblings.count,
            importedAtISO8601: createdAt)
        try await store.saveSourceDocument(document, chapters: siblings)
    }

    private func publishEpisode(_ draft: PodcastEpisodePlan, title: String) async throws -> PodcastPlanReport {
        let lock = try await lockChapterPublication()
        defer { lock.closeFile() }
        let projectID = draft.projectID
        let episodeID = draft.episodeID
        let previous = try await store.loadPodcastPlan(projectID: projectID, episodeID: episodeID)
        let chapters = try productionChapters(projectID: projectID)
        let existing = chapters.first { $0.chapterID == episodeID }
        if existing != nil && previous == nil { throw EngineSDKError.invalidInput("Episode ID belongs to an imported chapter") }
        let number = existing?.chapterNumber ?? ((chapters.map(\.chapterNumber).max() ?? 0) + 1)
        let activeScript = try await store.loadScript(projectID: projectID, chapterID: episodeID)
        let script = try revisionForPublication(draft.scriptDocument, previous: previous?.scriptDocument, active: activeScript)
        if existing?.sourceDocumentRevision != script.sourceDocumentRevision || existing?.title != title {
            try await saveEpisodeSource(script, projectID: projectID, number: number, title: title, createdAt: draft.createdAtISO8601)
        }
        let latestCatalog = try await store.loadCatalog(projectID: projectID)
        let merged = try PodcastCatalogBuilder.build(projectID: projectID, format: draft.format, existing: latestCatalog)
        let plan = PodcastEpisodePlan(projectID: projectID, episodeID: episodeID, title: title, topicQuery: draft.topicQuery,
            format: draft.format, hostSpeakerIDs: draft.hostSpeakerIDs, outline: draft.outline, citations: draft.citations,
            scriptDocument: script, createdAtISO8601: draft.createdAtISO8601)
        if merged != latestCatalog { try await store.saveCatalog(merged) }
        if previous?.scriptDocument != script || activeScript == nil {
            try await store.saveScript(script, projectID: projectID)
        }
        try await store.savePodcastPlan(plan)
        return .init(schemaVersion: 1, chapterNumber: number, plan: plan)
    }
}
