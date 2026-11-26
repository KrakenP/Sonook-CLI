import CryptoKit
import Foundation

// MARK: - Production Mode & Authorized Adaptation

public enum ProductionMode: String, Codable, CaseIterable, Sendable {
    case audiobookVerbatim = "audiobook_verbatim"
    case audioDramaAdapted = "audio_drama_adapted"
    case privatePodcast = "private_podcast"
}

/// Explicit user authorization required before any adaptation departs from verbatim audiobook narration.
public struct AdaptationAuthorization: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let authorizedByUser: Bool
    public let mode: ProductionMode
    public let allowNarrationCompression: Bool
    public let allowSFXInjection: Bool
    public let auditNote: String
    public let authorizedAtISO8601: String

    public init(
        authorizedByUser: Bool,
        mode: ProductionMode = .audioDramaAdapted,
        allowNarrationCompression: Bool = true,
        allowSFXInjection: Bool = true,
        auditNote: String,
        authorizedAtISO8601: String
    ) {
        self.authorizedByUser = authorizedByUser
        self.mode = mode
        self.allowNarrationCompression = allowNarrationCompression
        self.allowSFXInjection = allowSFXInjection
        self.auditNote = auditNote
        self.authorizedAtISO8601 = authorizedAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case authorizedByUser = "authorized_by_user"
        case mode
        case allowNarrationCompression = "allow_narration_compression"
        case allowSFXInjection = "allow_sfx_injection"
        case auditNote = "audit_note"
        case authorizedAtISO8601 = "authorized_at"
    }
}

/// Preserves exact UTF-8 byte traceability when an audio drama script compresses or adapts source prose.
public struct AdaptedSegmentOrigin: Codable, Equatable, Sendable {
    public let sourceSpan: SourceSpan
    public let sourceText: String
    public let adaptationReason: String

    public init(sourceSpan: SourceSpan, sourceText: String, adaptationReason: String) {
        self.sourceSpan = sourceSpan
        self.sourceText = sourceText
        self.adaptationReason = adaptationReason
    }

    enum CodingKeys: String, CodingKey {
        case sourceSpan = "source_span"
        case sourceText = "source_text"
        case adaptationReason = "adaptation_reason"
    }
}

// MARK: - Story-Aware Soundscapes & Pluggable SFX Contracts

public enum SceneAtmospherePreset: String, Codable, CaseIterable, Sendable {
    case none
    case forestWind = "forest_wind"
    case rainLight = "rain_light"
    case rainHeavy = "rain_heavy"
    case stormThunder = "storm_thunder"
    case campfireHearth = "campfire_hearth"
    case templeQuiet = "temple_quiet"
    case tavernCrowd = "tavern_crowd"
    case streamWater = "stream_water"
    case nightInsects = "night_insects"
    case cityStreet = "city_street"
    case indoorRoom = "indoor_room"
    case custom
}

public struct SceneCue: Codable, Equatable, Sendable {
    public let cueID: String
    public let chapterID: String
    public let startSegmentID: String
    public let endSegmentID: String
    public let sceneTag: String
    public let preset: SceneAtmospherePreset
    public let mood: String
    public let gainDB: Double
    public let crossfadeMs: Int
    public let evidenceExcerpt: String

    public init(
        cueID: String,
        chapterID: String,
        startSegmentID: String,
        endSegmentID: String,
        sceneTag: String,
        preset: SceneAtmospherePreset,
        mood: String = "neutral",
        gainDB: Double = -24.0,
        crossfadeMs: Int = 1800,
        evidenceExcerpt: String = ""
    ) {
        self.cueID = cueID
        self.chapterID = chapterID
        self.startSegmentID = startSegmentID
        self.endSegmentID = endSegmentID
        self.sceneTag = sceneTag
        self.preset = preset
        self.mood = mood
        self.gainDB = gainDB
        self.crossfadeMs = crossfadeMs
        self.evidenceExcerpt = evidenceExcerpt
    }

    enum CodingKeys: String, CodingKey {
        case cueID = "cue_id"
        case chapterID = "chapter_id"
        case startSegmentID = "start_segment_id"
        case endSegmentID = "end_segment_id"
        case sceneTag = "scene_tag"
        case preset
        case mood
        case gainDB = "gain_db"
        case crossfadeMs = "crossfade_ms"
        case evidenceExcerpt = "evidence_excerpt"
    }
}

public enum SFXPlacement: String, Codable, CaseIterable, Sendable {
    case before
    case during
    case after
}

public struct SFXCue: Codable, Equatable, Sendable {
    public let cueID: String
    public let chapterID: String
    public let anchorSegmentID: String
    public let placement: SFXPlacement
    public let offsetMs: Int
    public let soundPrompt: String
    public let category: String
    public let durationSeconds: Double
    public let gainDB: Double
    public let evidenceExcerpt: String
    public var resolvedAssetID: String?

    public init(
        cueID: String,
        chapterID: String,
        anchorSegmentID: String,
        placement: SFXPlacement = .during,
        offsetMs: Int = 0,
        soundPrompt: String,
        category: String = "foley",
        durationSeconds: Double = 2.0,
        gainDB: Double = -14.0,
        evidenceExcerpt: String = "",
        resolvedAssetID: String? = nil
    ) {
        self.cueID = cueID
        self.chapterID = chapterID
        self.anchorSegmentID = anchorSegmentID
        self.placement = placement
        self.offsetMs = offsetMs
        self.soundPrompt = soundPrompt
        self.category = category
        self.durationSeconds = durationSeconds
        self.gainDB = gainDB
        self.evidenceExcerpt = evidenceExcerpt
        self.resolvedAssetID = resolvedAssetID
    }

    enum CodingKeys: String, CodingKey {
        case cueID = "cue_id"
        case chapterID = "chapter_id"
        case anchorSegmentID = "anchor_segment_id"
        case placement
        case offsetMs = "offset_ms"
        case soundPrompt = "sound_prompt"
        case category
        case durationSeconds = "duration_seconds"
        case gainDB = "gain_db"
        case evidenceExcerpt = "evidence_excerpt"
        case resolvedAssetID = "resolved_asset_id"
    }
}

public struct ChapterSoundscapePlan: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chapterID: String
    public let scriptRevision: Int
    public var sceneCues: [SceneCue]
    public var sfxCues: [SFXCue]
    public let provenance: String
    public let createdAtISO8601: String

    public init(
        chapterID: String,
        scriptRevision: Int,
        sceneCues: [SceneCue],
        sfxCues: [SFXCue],
        provenance: String,
        createdAtISO8601: String
    ) {
        self.chapterID = chapterID
        self.scriptRevision = scriptRevision
        self.sceneCues = sceneCues
        self.sfxCues = sfxCues
        self.provenance = provenance
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case chapterID = "chapter_id"
        case scriptRevision = "script_revision"
        case sceneCues = "scene_cues"
        case sfxCues = "sfx_cues"
        case provenance
        case createdAtISO8601 = "created_at"
    }

    /// Deterministic hash incorporating only soundscape cues so toggling soundscapes never invalidates dry speech TTS/ASR cache.
    public func soundscapeDigest() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = (try? encoder.encode(self)) ?? Data()
        return sha256Digest(payload)
    }
}

public struct AudioDramaScriptDocument: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chapterID: String
    public let sourceDocumentRevision: String
    public let scriptRevision: Int
    public let authorization: AdaptationAuthorization
    public var segments: [ScriptSegment]
    public var adaptationOrigins: [String: AdaptedSegmentOrigin]
    public var soundscape: ChapterSoundscapePlan

    public init(
        chapterID: String,
        sourceDocumentRevision: String,
        scriptRevision: Int,
        authorization: AdaptationAuthorization,
        segments: [ScriptSegment],
        adaptationOrigins: [String: AdaptedSegmentOrigin],
        soundscape: ChapterSoundscapePlan
    ) {
        self.chapterID = chapterID
        self.sourceDocumentRevision = sourceDocumentRevision
        self.scriptRevision = scriptRevision
        self.authorization = authorization
        self.segments = segments
        self.adaptationOrigins = adaptationOrigins
        self.soundscape = soundscape
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case chapterID = "chapter_id"
        case sourceDocumentRevision = "source_document_revision"
        case scriptRevision = "script_revision"
        case authorization
        case segments
        case adaptationOrigins = "adaptation_origins"
        case soundscape
    }

    public func asScriptDocument() -> ScriptDocument {
        ScriptDocument(
            chapterID: chapterID,
            sourceDocumentRevision: sourceDocumentRevision,
            scriptRevision: scriptRevision,
            segments: segments
        )
    }
}

public struct SoundLibraryEntry: Codable, Equatable, Sendable {
    public let entryID: String
    public let preset: SceneAtmospherePreset
    public let tags: [String]
    public let relativePath: String
    public let license: String
    public let sourceAttribution: String
    public let durationSeconds: Double
    public let loopable: Bool
    public let sampleRate: Int
    public let fileSHA256: String

    public init(
        entryID: String,
        preset: SceneAtmospherePreset,
        tags: [String] = [],
        relativePath: String,
        license: String = "CC0-1.0",
        sourceAttribution: String = "",
        durationSeconds: Double,
        loopable: Bool = true,
        sampleRate: Int = 48_000,
        fileSHA256: String
    ) {
        self.entryID = entryID
        self.preset = preset
        self.tags = tags
        self.relativePath = relativePath
        self.license = license
        self.sourceAttribution = sourceAttribution
        self.durationSeconds = durationSeconds
        self.loopable = loopable
        self.sampleRate = sampleRate
        self.fileSHA256 = fileSHA256
    }

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case preset
        case tags
        case relativePath = "relative_path"
        case license
        case sourceAttribution = "source_attribution"
        case durationSeconds = "duration_seconds"
        case loopable
        case sampleRate = "sample_rate"
        case fileSHA256 = "file_sha256"
    }
}

public struct SoundLibraryManifest: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let libraryVersion: String
    public var entries: [SoundLibraryEntry]

    public init(libraryVersion: String = "1.0", entries: [SoundLibraryEntry]) {
        self.libraryVersion = libraryVersion
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case libraryVersion = "library_version"
        case entries
    }
}

// MARK: - Pluggable SFXProvider Contract (Isolates External Local SFX Models)

public struct SFXCapabilities: Sendable {
    public let parameters: [String: ParameterSupport]
    public let maxDurationSeconds: Double
    public let defaultSampleRate: Int

    public init(
        parameters: [String: ParameterSupport] = [:],
        maxDurationSeconds: Double = 10.0,
        defaultSampleRate: Int = 44_100
    ) {
        self.parameters = parameters
        self.maxDurationSeconds = maxDurationSeconds
        self.defaultSampleRate = defaultSampleRate
    }
}

public struct SFXRequest: Sendable {
    public let prompt: String
    public let durationSeconds: Double
    public let seed: UInt64
    public var parameters: [String: String]
    public let policy: UnsupportedParameterPolicy

    public init(
        prompt: String,
        durationSeconds: Double = 2.5,
        seed: UInt64 = 42,
        parameters: [String: String] = [:],
        policy: UnsupportedParameterPolicy = .strict
    ) {
        self.prompt = prompt
        self.durationSeconds = durationSeconds
        self.seed = seed
        self.parameters = parameters
        self.policy = policy
    }

    /// Deterministic cache key for reusing generated point SFX across chapters and projects.
    public func cacheKey(providerID: String, modelRevision: String) -> String {
        let sortedParams = parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: "&")
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = "sfx_v1|\(providerID)|\(modelRevision)|\(normalizedPrompt)|\(String(format: "%.2f", durationSeconds))|\(seed)|\(sortedParams)"
        return sha256Digest(Data(raw.utf8))
    }
}

public struct SFXResult: Sendable {
    public let audio: SynthesizedAudio
    public let licenseTag: String
    public var metrics: InferenceMetrics

    public init(audio: SynthesizedAudio, licenseTag: String, metrics: InferenceMetrics) {
        self.audio = audio
        self.licenseTag = licenseTag
        self.metrics = metrics
    }
}

public protocol SFXProvider: Sendable {
    var providerID: String { get }
    var capabilities: SFXCapabilities { get }
    func load() async throws
    func unload() async throws
    func generateSFX(_ request: SFXRequest) async throws -> SFXResult
}

// MARK: - KnowledgeKit & Private Podcast Contracts

public struct KnowledgeSourceRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let sourceID: String
    public let projectID: String
    public let title: String
    public let sourceURI: String
    public let contentSHA256: String
    public let ingestedAtISO8601: String
    public let chunkCount: Int
    public var metadata: [String: String]

    public init(
        sourceID: String,
        projectID: String,
        title: String,
        sourceURI: String,
        contentSHA256: String,
        ingestedAtISO8601: String,
        chunkCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.sourceID = sourceID
        self.projectID = projectID
        self.title = title
        self.sourceURI = sourceURI
        self.contentSHA256 = contentSHA256
        self.ingestedAtISO8601 = ingestedAtISO8601
        self.chunkCount = chunkCount
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case sourceID = "source_id"
        case projectID = "project_id"
        case title
        case sourceURI = "source_uri"
        case contentSHA256 = "content_sha256"
        case ingestedAtISO8601 = "ingested_at"
        case chunkCount = "chunk_count"
        case metadata
    }
}

public struct KnowledgeChunk: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chunkID: String
    public let sourceID: String
    public let projectID: String
    public let sequenceIndex: Int
    public let text: String
    public let sourceSpan: SourceSpan
    public let sectionHeading: String?
    public let tokenEstimate: Int

    public init(
        chunkID: String,
        sourceID: String,
        projectID: String,
        sequenceIndex: Int,
        text: String,
        sourceSpan: SourceSpan,
        sectionHeading: String? = nil,
        tokenEstimate: Int
    ) {
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.projectID = projectID
        self.sequenceIndex = sequenceIndex
        self.text = text
        self.sourceSpan = sourceSpan
        self.sectionHeading = sectionHeading
        self.tokenEstimate = tokenEstimate
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case chunkID = "chunk_id"
        case sourceID = "source_id"
        case projectID = "project_id"
        case sequenceIndex = "sequence_index"
        case text
        case sourceSpan = "source_span"
        case sectionHeading = "section_heading"
        case tokenEstimate = "token_estimate"
    }
}

public struct KnowledgeCitation: Codable, Equatable, Sendable {
    public let citationID: String
    public let sourceID: String
    public let sourceTitle: String
    public let chunkID: String
    public let sourceSpan: SourceSpan
    public let quotedExcerpt: String
    public let ingestedAtISO8601: String
    public let isInference: Bool

    public init(
        citationID: String,
        sourceID: String,
        sourceTitle: String,
        chunkID: String,
        sourceSpan: SourceSpan,
        quotedExcerpt: String,
        ingestedAtISO8601: String,
        isInference: Bool = false
    ) {
        self.citationID = citationID
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.chunkID = chunkID
        self.sourceSpan = sourceSpan
        self.quotedExcerpt = quotedExcerpt
        self.ingestedAtISO8601 = ingestedAtISO8601
        self.isInference = isInference
    }

    enum CodingKeys: String, CodingKey {
        case citationID = "citation_id"
        case sourceID = "source_id"
        case sourceTitle = "source_title"
        case chunkID = "chunk_id"
        case sourceSpan = "source_span"
        case quotedExcerpt = "quoted_excerpt"
        case ingestedAtISO8601 = "ingested_at"
        case isInference = "is_inference"
    }
}

public struct KnowledgeSearchHit: Codable, Equatable, Sendable {
    public let chunk: KnowledgeChunk
    public let sourceTitle: String
    public let ingestedAtISO8601: String
    public let score: Double
    public let snippet: String

    public init(
        chunk: KnowledgeChunk,
        sourceTitle: String,
        ingestedAtISO8601: String,
        score: Double,
        snippet: String
    ) {
        self.chunk = chunk
        self.sourceTitle = sourceTitle
        self.ingestedAtISO8601 = ingestedAtISO8601
        self.score = score
        self.snippet = snippet
    }

    enum CodingKeys: String, CodingKey {
        case chunk
        case sourceTitle = "source_title"
        case ingestedAtISO8601 = "ingested_at"
        case score
        case snippet
    }
}

public enum PodcastFormat: String, Codable, CaseIterable, Sendable {
    case soloExplainer = "solo_explainer"
    case dualHostDiscussion = "dual_host_discussion"
}

public struct PodcastOutlineItem: Codable, Equatable, Sendable {
    public let itemID: String
    public let topic: String
    public let keyPoints: [String]
    public let citations: [KnowledgeCitation]

    public init(itemID: String, topic: String, keyPoints: [String], citations: [KnowledgeCitation]) {
        self.itemID = itemID
        self.topic = topic
        self.keyPoints = keyPoints
        self.citations = citations
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case topic
        case keyPoints = "key_points"
        case citations
    }
}

public struct PodcastEpisodePlan: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let episodeID: String
    public let title: String
    public let topicQuery: String
    public let format: PodcastFormat
    public let hostSpeakerIDs: [String]
    public let outline: [PodcastOutlineItem]
    public let citations: [KnowledgeCitation]
    public var scriptDocument: ScriptDocument
    public let createdAtISO8601: String

    public init(
        projectID: String,
        episodeID: String,
        title: String,
        topicQuery: String,
        format: PodcastFormat,
        hostSpeakerIDs: [String],
        outline: [PodcastOutlineItem],
        citations: [KnowledgeCitation],
        scriptDocument: ScriptDocument,
        createdAtISO8601: String
    ) {
        self.projectID = projectID
        self.episodeID = episodeID
        self.title = title
        self.topicQuery = topicQuery
        self.format = format
        self.hostSpeakerIDs = hostSpeakerIDs
        self.outline = outline
        self.citations = citations
        self.scriptDocument = scriptDocument
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case episodeID = "episode_id"
        case title
        case topicQuery = "topic_query"
        case format
        case hostSpeakerIDs = "host_speaker_ids"
        case outline
        case citations
        case scriptDocument = "script_document"
        case createdAtISO8601 = "created_at"
    }
}

// MARK: - Store Protocols for P4 Soundscapes & KnowledgeKit

public protocol SoundscapeStoreProtocol: Sendable {
    func saveSoundscapePlan(_ plan: ChapterSoundscapePlan, projectID: String) async throws
    func loadSoundscapePlan(projectID: String, chapterID: String) async throws -> ChapterSoundscapePlan?
    func listSoundscapePlans(projectID: String) async throws -> [ChapterSoundscapePlan]
}

public protocol KnowledgeStoreProtocol: Sendable {
    func upsertKnowledgeSource(_ source: KnowledgeSourceRecord, chunks: [KnowledgeChunk]) async throws
    func listKnowledgeSources(projectID: String) async throws -> [KnowledgeSourceRecord]
    func loadKnowledgeChunks(projectID: String, sourceID: String?) async throws -> [KnowledgeChunk]
    func searchKnowledge(projectID: String, query: String, limit: Int) async throws -> [KnowledgeSearchHit]
    func savePodcastPlan(_ plan: PodcastEpisodePlan) async throws
    func loadPodcastPlan(projectID: String, episodeID: String) async throws -> PodcastEpisodePlan?
    func listPodcastPlans(projectID: String) async throws -> [PodcastEpisodePlan]
}
