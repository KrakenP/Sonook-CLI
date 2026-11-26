import Foundation

// MARK: - Project & Production Configuration

public enum ProjectType: String, Codable, CaseIterable, Sendable {
    case audiobook
    case audioDrama = "audio_drama"
    case podcast
}

/// Optional background/ambient sound configuration reserved for P2/P4 multi-track rendering.
/// Ambient parameters hash ONLY into the chapter render fingerprint and never invalidate dry speech TTS or ASR.
public struct AmbientTrackSpec: Codable, Equatable, Sendable {
    public var assetID: String?
    public var presetName: String?
    public var gainDB: Double
    public var duckingDB: Double
    public var startFrame: Int?
    public var endFrameExclusive: Int?

    public init(
        assetID: String? = nil,
        presetName: String? = nil,
        gainDB: Double = -24.0,
        duckingDB: Double = -8.0,
        startFrame: Int? = nil,
        endFrameExclusive: Int? = nil
    ) {
        self.assetID = assetID
        self.presetName = presetName
        self.gainDB = gainDB
        self.duckingDB = duckingDB
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
    }

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case presetName = "preset_name"
        case gainDB = "gain_db"
        case duckingDB = "ducking_db"
        case startFrame = "start_frame"
        case endFrameExclusive = "end_frame_exclusive"
    }
}

public struct ProductionOptions: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public var ambientAudioEnabled: Bool
    public var ambientTrack: AmbientTrackSpec?
    public var preferredLLMModelID: String?
    public var preferredAuditionTTSModelID: String?
    public var preferredMainTTSModelID: String?
    public var preferredASRModelID: String?

    public init(
        ambientAudioEnabled: Bool = false,
        ambientTrack: AmbientTrackSpec? = nil,
        preferredLLMModelID: String? = nil,
        preferredAuditionTTSModelID: String? = nil,
        preferredMainTTSModelID: String? = nil,
        preferredASRModelID: String? = nil
    ) {
        self.ambientAudioEnabled = ambientAudioEnabled
        self.ambientTrack = ambientTrack
        self.preferredLLMModelID = preferredLLMModelID
        self.preferredAuditionTTSModelID = preferredAuditionTTSModelID
        self.preferredMainTTSModelID = preferredMainTTSModelID
        self.preferredASRModelID = preferredASRModelID
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case ambientAudioEnabled = "ambient_audio_enabled"
        case ambientTrack = "ambient_track"
        case preferredLLMModelID = "preferred_llm_model_id"
        case preferredAuditionTTSModelID = "preferred_audition_tts_model_id"
        case preferredMainTTSModelID = "preferred_main_tts_model_id"
        case preferredASRModelID = "preferred_asr_model_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decodeIfPresent(SchemaVersion.self, forKey: .version) ?? .v1
        self.ambientAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientAudioEnabled) ?? false
        self.ambientTrack = try c.decodeIfPresent(AmbientTrackSpec.self, forKey: .ambientTrack)
        self.preferredLLMModelID = try c.decodeIfPresent(String.self, forKey: .preferredLLMModelID)
        self.preferredAuditionTTSModelID = try c.decodeIfPresent(String.self, forKey: .preferredAuditionTTSModelID)
        self.preferredMainTTSModelID = try c.decodeIfPresent(String.self, forKey: .preferredMainTTSModelID)
        self.preferredASRModelID = try c.decodeIfPresent(String.self, forKey: .preferredASRModelID)
    }
}

public struct ProjectRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public var name: String
    public let projectType: ProjectType
    public var options: ProductionOptions
    public let createdAtISO8601: String
    public var updatedAtISO8601: String

    public init(
        projectID: String,
        name: String,
        projectType: ProjectType = .audiobook,
        options: ProductionOptions = ProductionOptions(),
        createdAtISO8601: String,
        updatedAtISO8601: String? = nil
    ) {
        self.projectID = projectID
        self.name = name
        self.projectType = projectType
        self.options = options
        self.createdAtISO8601 = createdAtISO8601
        self.updatedAtISO8601 = updatedAtISO8601 ?? createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case name
        case projectType = "project_type"
        case options
        case createdAtISO8601 = "created_at"
        case updatedAtISO8601 = "updated_at"
    }
}

// MARK: - Character Timbre Anchor & Vocal Growth Progression

/// Immutable reference timbre anchor produced once during character auditioning (e.g. via VoiceDesign).
/// Keeps a character's core timbre continuous across hundreds of chapters.
public struct VoiceTimbreAnchor: Codable, Equatable, Sendable {
    public let anchorID: String
    public let assetID: String
    public let fileSHA256: String
    public let generatorProviderID: String
    public let generatorModelID: String
    public let designPrompt: String
    public let auditionText: String
    public let sampleRate: Int
    public let createdAtISO8601: String

    public init(
        anchorID: String,
        assetID: String,
        fileSHA256: String,
        generatorProviderID: String,
        generatorModelID: String,
        designPrompt: String,
        auditionText: String,
        sampleRate: Int,
        createdAtISO8601: String
    ) {
        self.anchorID = anchorID
        self.assetID = assetID
        self.fileSHA256 = fileSHA256
        self.generatorProviderID = generatorProviderID
        self.generatorModelID = generatorModelID
        self.designPrompt = designPrompt
        self.auditionText = auditionText
        self.sampleRate = sampleRate
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case anchorID = "anchor_id"
        case assetID = "asset_id"
        case fileSHA256 = "file_sha256"
        case generatorProviderID = "generator_provider_id"
        case generatorModelID = "generator_model_id"
        case designPrompt = "design_prompt"
        case auditionText = "audition_text"
        case sampleRate = "sample_rate"
        case createdAtISO8601 = "created_at"
    }
}

/// Chapter-indexed delivery baseline describing how a character's tone, composure, or pacing evolves
/// as the story progresses while staying locked to the same immutable VoiceTimbreAnchor.
public struct VoiceDeliveryStage: Codable, Equatable, Sendable {
    public let stageID: String
    public let effectiveFromChapter: Int
    public var revision: Int
    public var stageLabel: String
    public var deliveryBaseline: String
    public var speakingRate: Double?
    public var evidence: String?

    public init(
        stageID: String,
        effectiveFromChapter: Int,
        revision: Int = 1,
        stageLabel: String,
        deliveryBaseline: String,
        speakingRate: Double? = nil,
        evidence: String? = nil
    ) {
        self.stageID = stageID
        self.effectiveFromChapter = effectiveFromChapter
        self.revision = revision
        self.stageLabel = stageLabel
        self.deliveryBaseline = deliveryBaseline
        self.speakingRate = speakingRate
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case stageID = "stage_id"
        case effectiveFromChapter = "effective_from_chapter"
        case revision
        case stageLabel = "stage_label"
        case deliveryBaseline = "delivery_baseline"
        case speakingRate = "speaking_rate"
        case evidence
    }
}

// MARK: - Content-Addressed Assets & Render Timeline

public enum AssetKind: String, Codable, CaseIterable, Sendable {
    case sourceDocument = "source_document"
    case voiceAudition = "voice_audition"
    case segmentWAV = "segment_wav"
    case chapterRender = "chapter_render"
    case ambientBed = "ambient_bed"
    case sfxAudio = "sfx_audio"
    case soundscapePlan = "soundscape_plan"
    case podcastPlan = "podcast_plan"
    case qualityReport = "quality_report"
    case scriptSnapshot = "script_snapshot"
}

public struct AssetProvenance: Codable, Equatable, Sendable {
    public var sourceDocumentRevision: String?
    public var chapterID: String?
    public var segmentID: String?
    public var characterID: String?
    public var scriptRevision: Int?
    public var providerID: String?
    public var modelID: String?
    public var modelRevision: String?
    public var inputFingerprint: String?

    public init(
        sourceDocumentRevision: String? = nil,
        chapterID: String? = nil,
        segmentID: String? = nil,
        characterID: String? = nil,
        scriptRevision: Int? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        modelRevision: String? = nil,
        inputFingerprint: String? = nil
    ) {
        self.sourceDocumentRevision = sourceDocumentRevision
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.characterID = characterID
        self.scriptRevision = scriptRevision
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.inputFingerprint = inputFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case sourceDocumentRevision = "source_document_revision"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case characterID = "character_id"
        case scriptRevision = "script_revision"
        case providerID = "provider_id"
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case inputFingerprint = "input_fingerprint"
    }
}

public struct AssetRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let assetID: String
    public let projectID: String
    public let kind: AssetKind
    public let relativePath: String
    public let fileExtension: String
    public let fileSHA256: String
    public let byteSize: Int64
    public var sampleRate: Int?
    public var frameCount: Int?
    public var provenance: AssetProvenance
    public let createdAtISO8601: String

    public init(
        assetID: String,
        projectID: String,
        kind: AssetKind,
        relativePath: String,
        fileExtension: String,
        fileSHA256: String,
        byteSize: Int64,
        sampleRate: Int? = nil,
        frameCount: Int? = nil,
        provenance: AssetProvenance = AssetProvenance(),
        createdAtISO8601: String
    ) {
        self.assetID = assetID
        self.projectID = projectID
        self.kind = kind
        self.relativePath = relativePath
        self.fileExtension = fileExtension
        self.fileSHA256 = fileSHA256
        self.byteSize = byteSize
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.provenance = provenance
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case assetID = "asset_id"
        case projectID = "project_id"
        case kind
        case relativePath = "relative_path"
        case fileExtension = "file_extension"
        case fileSHA256 = "file_sha256"
        case byteSize = "byte_size"
        case sampleRate = "sample_rate"
        case frameCount = "frame_count"
        case provenance
        case createdAtISO8601 = "created_at"
    }
}

public struct ChapterRenderConfig: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chapterID: String
    public let sampleRate: Int
    public var targetRMSDBFS: Double
    public var ambientTrack: AmbientTrackSpec?

    public init(
        chapterID: String,
        sampleRate: Int,
        targetRMSDBFS: Double = -20.0,
        ambientTrack: AmbientTrackSpec? = nil
    ) {
        self.chapterID = chapterID
        self.sampleRate = sampleRate
        self.targetRMSDBFS = targetRMSDBFS
        self.ambientTrack = ambientTrack
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case chapterID = "chapter_id"
        case sampleRate = "sample_rate"
        case targetRMSDBFS = "target_rms_dbfs"
        case ambientTrack = "ambient_track"
    }

    /// Computes a deterministic render fingerprint incorporating dry segment asset hashes plus optional ambient track settings.
    public func renderFingerprint(segmentAssetHashes: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ambientPart = (try? ambientTrack.map { try String(decoding: encoder.encode($0), as: UTF8.self) }) ?? "none"
        let payload = "render_v1|\(chapterID)|\(sampleRate)|\(targetRMSDBFS)|\(segmentAssetHashes.joined(separator: ","))|\(ambientPart)"
        return sha256Digest(Data(payload.utf8))
    }
}

// MARK: - Model Registry

public enum ModelKind: String, Codable, CaseIterable, Sendable {
    case llm
    case tts
    case asr
    case sfx
}

public struct ModelRegistryEntry: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let modelID: String
    public let kind: ModelKind
    public let providerID: String
    public let localPath: String
    public let revision: String
    public let license: String
    public var quantization: String?
    public var estimatedPeakBytes: UInt64
    public var measuredPeakBytes: UInt64?
    public var notes: String?
    public let registeredAtISO8601: String

    public init(
        modelID: String,
        kind: ModelKind,
        providerID: String,
        localPath: String,
        revision: String = "local",
        license: String = "unknown",
        quantization: String? = nil,
        estimatedPeakBytes: UInt64,
        measuredPeakBytes: UInt64? = nil,
        notes: String? = nil,
        registeredAtISO8601: String
    ) {
        self.modelID = modelID
        self.kind = kind
        self.providerID = providerID
        self.localPath = localPath
        self.revision = revision
        self.license = license
        self.quantization = quantization
        self.estimatedPeakBytes = estimatedPeakBytes
        self.measuredPeakBytes = measuredPeakBytes
        self.notes = notes
        self.registeredAtISO8601 = registeredAtISO8601
    }

    public var effectiveBudgetBytes: UInt64 {
        measuredPeakBytes ?? estimatedPeakBytes
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case modelID = "model_id"
        case kind
        case providerID = "provider_id"
        case localPath = "local_path"
        case revision
        case license
        case quantization
        case estimatedPeakBytes = "estimated_peak_bytes"
        case measuredPeakBytes = "measured_peak_bytes"
        case notes
        case registeredAtISO8601 = "registered_at"
    }
}
