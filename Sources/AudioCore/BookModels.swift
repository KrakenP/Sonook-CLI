import Foundation

// MARK: - Book Import & Chapter Index Contracts

public enum SourceFormat: String, Codable, CaseIterable, Sendable {
    case txt
    case markdown
    case epub
}

public struct SourceDocumentRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let sourceDocumentRevision: String
    public let projectID: String
    public let format: SourceFormat
    public let originalFileName: String
    public let rawAssetID: String
    public let rawSHA256: String
    public let normalizedAssetID: String
    public let normalizedSHA256: String
    public let detectedEncoding: String
    public let parserVersion: String
    public let totalUTF8Bytes: Int
    public let chapterCount: Int
    public let importedAtISO8601: String

    public init(
        sourceDocumentRevision: String,
        projectID: String,
        format: SourceFormat,
        originalFileName: String,
        rawAssetID: String,
        rawSHA256: String,
        normalizedAssetID: String,
        normalizedSHA256: String,
        detectedEncoding: String,
        parserVersion: String = "contentkit_v1",
        totalUTF8Bytes: Int,
        chapterCount: Int,
        importedAtISO8601: String
    ) {
        self.sourceDocumentRevision = sourceDocumentRevision
        self.projectID = projectID
        self.format = format
        self.originalFileName = originalFileName
        self.rawAssetID = rawAssetID
        self.rawSHA256 = rawSHA256
        self.normalizedAssetID = normalizedAssetID
        self.normalizedSHA256 = normalizedSHA256
        self.detectedEncoding = detectedEncoding
        self.parserVersion = parserVersion
        self.totalUTF8Bytes = totalUTF8Bytes
        self.chapterCount = chapterCount
        self.importedAtISO8601 = importedAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case sourceDocumentRevision = "source_document_revision"
        case projectID = "project_id"
        case format
        case originalFileName = "original_file_name"
        case rawAssetID = "raw_asset_id"
        case rawSHA256 = "raw_sha256"
        case normalizedAssetID = "normalized_asset_id"
        case normalizedSHA256 = "normalized_sha256"
        case detectedEncoding = "detected_encoding"
        case parserVersion = "parser_version"
        case totalUTF8Bytes = "total_utf8_bytes"
        case chapterCount = "chapter_count"
        case importedAtISO8601 = "imported_at"
    }
}

public struct ChapterRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let sourceDocumentRevision: String
    /// Absolute UTF-8 byte half-open range into the immutable normalized source document.
    public let sourceSpan: SourceSpan
    public let originPath: String?
    public let originAnchor: String?

    public init(
        projectID: String,
        chapterID: String,
        chapterNumber: Int,
        title: String,
        sourceDocumentRevision: String,
        sourceSpan: SourceSpan,
        originPath: String? = nil,
        originAnchor: String? = nil
    ) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.sourceDocumentRevision = sourceDocumentRevision
        self.sourceSpan = sourceSpan
        self.originPath = originPath
        self.originAnchor = originAnchor
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case title
        case sourceDocumentRevision = "source_document_revision"
        case sourceSpan = "source_span"
        case originPath = "origin_path"
        case originAnchor = "origin_anchor"
    }
}

/// Explicit human approval for a `needs_review` segment allowing formal book export
/// without weakening automated ASR quality gates.
public struct SegmentApprovalRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let chapterID: String
    public let segmentID: String
    public let approvedAssetID: String
    public let reviewerNote: String
    public let approvedAtISO8601: String

    public init(
        projectID: String,
        chapterID: String,
        segmentID: String,
        approvedAssetID: String,
        reviewerNote: String,
        approvedAtISO8601: String
    ) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.approvedAssetID = approvedAssetID
        self.reviewerNote = reviewerNote
        self.approvedAtISO8601 = approvedAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case approvedAssetID = "approved_asset_id"
        case reviewerNote = "reviewer_note"
        case approvedAtISO8601 = "approved_at"
    }
}

// MARK: - Proper-Noun Tone-Aware ASR Quality Audit

public struct ProperNounExemption: Codable, Equatable, Sendable {
    public let characterID: String
    public let referenceText: String
    public let hypothesisText: String
    public let tonePinyin: String
    public let charStart: Int
    public let charEndExclusive: Int
    public let ruleVersion: String

    public init(
        characterID: String,
        referenceText: String,
        hypothesisText: String,
        tonePinyin: String,
        charStart: Int,
        charEndExclusive: Int,
        ruleVersion: String = "pinyin_tone_exact_v1"
    ) {
        self.characterID = characterID
        self.referenceText = referenceText
        self.hypothesisText = hypothesisText
        self.tonePinyin = tonePinyin
        self.charStart = charStart
        self.charEndExclusive = charEndExclusive
        self.ruleVersion = ruleVersion
    }

    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case referenceText = "reference_text"
        case hypothesisText = "hypothesis_text"
        case tonePinyin = "tone_pinyin"
        case charStart = "char_start"
        case charEndExclusive = "char_end_exclusive"
        case ruleVersion = "rule_version"
    }
}

public struct SegmentQualityAudit: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let segmentID: String
    public let wavAssetID: String
    public let rawTranscript: String
    public let rawCER: Double
    public let adjustedCER: Double
    public let exemptions: [ProperNounExemption]
    public let nonExemptSubstitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let rmsDBFS: Double
    public let verdictLabel: String
    public let failureReasons: [String]
    public let ruleVersion: String

    public init(
        segmentID: String,
        wavAssetID: String,
        rawTranscript: String,
        rawCER: Double,
        adjustedCER: Double,
        exemptions: [ProperNounExemption],
        nonExemptSubstitutions: Int,
        deletions: Int,
        insertions: Int,
        rmsDBFS: Double,
        verdictLabel: String,
        failureReasons: [String],
        ruleVersion: String = "speechkit_qa_v1"
    ) {
        self.segmentID = segmentID
        self.wavAssetID = wavAssetID
        self.rawTranscript = rawTranscript
        self.rawCER = rawCER
        self.adjustedCER = adjustedCER
        self.exemptions = exemptions
        self.nonExemptSubstitutions = nonExemptSubstitutions
        self.deletions = deletions
        self.insertions = insertions
        self.rmsDBFS = rmsDBFS
        self.verdictLabel = verdictLabel
        self.failureReasons = failureReasons
        self.ruleVersion = ruleVersion
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case segmentID = "segment_id"
        case wavAssetID = "wav_asset_id"
        case rawTranscript = "raw_transcript"
        case rawCER = "raw_cer"
        case adjustedCER = "adjusted_cer"
        case exemptions
        case nonExemptSubstitutions = "non_exempt_substitutions"
        case deletions
        case insertions
        case rmsDBFS = "rms_dbfs"
        case verdictLabel = "verdict"
        case failureReasons = "failure_reasons"
        case ruleVersion = "rule_version"
    }
}

// MARK: - Audiobook Export Contracts

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case wav
    case m4a
    case m4b
}

public struct ChapterMarker: Codable, Equatable, Sendable {
    public let chapterID: String
    public let title: String
    public let startFrame: Int64
    public let endFrameExclusive: Int64
    public let sampleRate: Int

    public init(chapterID: String, title: String, startFrame: Int64, endFrameExclusive: Int64, sampleRate: Int) {
        self.chapterID = chapterID
        self.title = title
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
        self.sampleRate = sampleRate
    }

    public var startSeconds: Double { Double(startFrame) / Double(sampleRate) }
    public var durationSeconds: Double { Double(max(0, endFrameExclusive - startFrame)) / Double(sampleRate) }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case title
        case startFrame = "start_frame"
        case endFrameExclusive = "end_frame_exclusive"
        case sampleRate = "sample_rate"
    }
}

public struct BookExportMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var author: String?
    public var narrator: String?
    public var languageTag: String

    public init(title: String, author: String? = nil, narrator: String? = nil, languageTag: String = "zh-Hans") {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.languageTag = languageTag
    }

    enum CodingKeys: String, CodingKey {
        case title, author, narrator, languageTag = "language_tag"
    }
}

public struct LocatedSegment: Codable, Equatable, Sendable {
    public let chapterID: String
    public let segment: ScriptSegment

    public init(chapterID: String, segment: ScriptSegment) {
        self.chapterID = chapterID
        self.segment = segment
    }
}

// MARK: - P3 Auto-Repair Policy, Review Queue & Precision Cache Invalidation

/// Bounded, deterministic post-ASR auto-repair configuration for transient TTS defects.
public struct SegmentAutoRepairPolicy: Codable, Equatable, Sendable {
    public let maxRepairRounds: Int
    public let seedStride: UInt64
    public let thresholds: QualityThresholds

    public init(
        maxRepairRounds: Int = 2,
        seedStride: UInt64 = 37,
        thresholds: QualityThresholds = QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10)
    ) {
        self.maxRepairRounds = max(0, maxRepairRounds)
        self.seedStride = max(1, seedStride)
        self.thresholds = thresholds
    }

    /// Derives a deterministic seed for a 1-based repair round (`round >= 1`).
    public func seed(forBaseSeed baseSeed: UInt64, round: Int) -> UInt64 {
        let clampedRound = UInt64(max(1, round))
        return baseSeed &+ (clampedRound &* seedStride)
    }

    enum CodingKeys: String, CodingKey {
        case maxRepairRounds = "max_repair_rounds"
        case seedStride = "seed_stride"
        case thresholds
    }
}

public enum CacheInvalidationReason: String, Codable, Equatable, Sendable {
    case intactCacheHit = "intact_cache_hit"
    case missingAudioAsset = "missing_audio_asset"
    case corruptedAudioAsset = "corrupted_audio_asset"
    case fingerprintChanged = "fingerprint_changed"
    case statusRequiresSynthesis = "status_requires_synthesis"
    case speakerReassigned = "speaker_reassigned"
    case missingSpeakerCard = "missing_speaker_card"
}

public struct CacheInvalidationEntry: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let segmentID: String
    public let speakerID: String
    public let needsResynthesis: Bool
    public let reason: CacheInvalidationReason
    public let existingAssetID: String?
    public let expectedFingerprint: String?

    public init(
        chapterID: String,
        chapterNumber: Int,
        segmentID: String,
        speakerID: String,
        needsResynthesis: Bool,
        reason: CacheInvalidationReason,
        existingAssetID: String? = nil,
        expectedFingerprint: String? = nil
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.needsResynthesis = needsResynthesis
        self.reason = reason
        self.existingAssetID = existingAssetID
        self.expectedFingerprint = expectedFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case segmentID = "segment_id"
        case speakerID = "speaker_id"
        case needsResynthesis = "needs_resynthesis"
        case reason
        case existingAssetID = "existing_asset_id"
        case expectedFingerprint = "expected_fingerprint"
    }
}

public struct CacheInvalidationPlan: Codable, Equatable, Sendable {
    public let projectID: String
    public let providerID: String
    public let modelID: String
    public let totalSegments: Int
    public let reusableSegments: Int
    public let invalidatedSegments: Int
    public let entries: [CacheInvalidationEntry]

    public init(
        projectID: String,
        providerID: String,
        modelID: String,
        totalSegments: Int,
        reusableSegments: Int,
        invalidatedSegments: Int,
        entries: [CacheInvalidationEntry]
    ) {
        self.projectID = projectID
        self.providerID = providerID
        self.modelID = modelID
        self.totalSegments = totalSegments
        self.reusableSegments = reusableSegments
        self.invalidatedSegments = invalidatedSegments
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case providerID = "provider_id"
        case modelID = "model_id"
        case totalSegments = "total_segments"
        case reusableSegments = "reusable_segments"
        case invalidatedSegments = "invalidated_segments"
        case entries
    }
}

public struct ReviewQueueItem: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let chapterTitle: String
    public let segmentID: String
    public let speakerID: String
    public let speakerName: String
    public let status: SegmentStatus
    public let spokenText: String
    public let audioAssetID: String?
    public let audioFilePath: String?
    public let assetIntact: Bool
    public let explicitlyApproved: Bool
    public let reviewerNote: String?
    public let attributionFlags: [String]
    public let rawTranscript: String?
    public let rawCER: Double?
    public let adjustedCER: Double?
    public let asrFailureReasons: [String]
    public let exemptionCount: Int

    public init(
        chapterID: String,
        chapterNumber: Int,
        chapterTitle: String,
        segmentID: String,
        speakerID: String,
        speakerName: String,
        status: SegmentStatus,
        spokenText: String,
        audioAssetID: String?,
        audioFilePath: String?,
        assetIntact: Bool,
        explicitlyApproved: Bool,
        reviewerNote: String?,
        attributionFlags: [String],
        rawTranscript: String?,
        rawCER: Double?,
        adjustedCER: Double?,
        asrFailureReasons: [String],
        exemptionCount: Int
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.chapterTitle = chapterTitle
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.status = status
        self.spokenText = spokenText
        self.audioAssetID = audioAssetID
        self.audioFilePath = audioFilePath
        self.assetIntact = assetIntact
        self.explicitlyApproved = explicitlyApproved
        self.reviewerNote = reviewerNote
        self.attributionFlags = attributionFlags
        self.rawTranscript = rawTranscript
        self.rawCER = rawCER
        self.adjustedCER = adjustedCER
        self.asrFailureReasons = asrFailureReasons
        self.exemptionCount = exemptionCount
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case chapterTitle = "chapter_title"
        case segmentID = "segment_id"
        case speakerID = "speaker_id"
        case speakerName = "speaker_name"
        case status
        case spokenText = "spoken_text"
        case audioAssetID = "audio_asset_id"
        case audioFilePath = "audio_file_path"
        case assetIntact = "asset_intact"
        case explicitlyApproved = "explicitly_approved"
        case reviewerNote = "reviewer_note"
        case attributionFlags = "attribution_flags"
        case rawTranscript = "raw_transcript"
        case rawCER = "raw_cer"
        case adjustedCER = "adjusted_cer"
        case asrFailureReasons = "asr_failure_reasons"
        case exemptionCount = "exemption_count"
    }
}
