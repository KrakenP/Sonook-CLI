import Foundation

public struct SegmentDirection: Codable, Equatable, Sendable {
    public var emotion: String?
    public var rate: Double?
    public var pauseAfterMs: Int?
    public var styleInstruction: String?

    public init(emotion: String? = nil, rate: Double? = nil, pauseAfterMs: Int? = nil,
                styleInstruction: String? = nil) {
        self.emotion = emotion
        self.rate = rate
        self.pauseAfterMs = pauseAfterMs
        self.styleInstruction = styleInstruction
    }

    enum CodingKeys: String, CodingKey {
        case emotion, rate, pauseAfterMs = "pause_after_ms", styleInstruction = "style_instruction"
    }
}

public enum SegmentStatus: String, Codable, CaseIterable, Sendable {
    case pending, synthesized, verified, needsReview = "needs_review", failed
}

public struct ScriptSegment: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let segmentID: String
    public let chapterID: String
    public let sourceDocumentRevision: String
    public var sourceSpan: SourceSpan
    public var sourceText: String
    public var spokenText: String
    public var speakerID: String
    public var voiceProfileRevision: String
    public var direction: SegmentDirection
    public let scriptRevision: Int
    public var audioArtifactID: String?
    public var status: SegmentStatus
    public var attributionConfidence: Double?
    public var attributionEvidence: [String]
    public var normalizationNote: String?

    public init(segmentID: String, chapterID: String, sourceDocumentRevision: String, sourceSpan: SourceSpan,
                sourceText: String, spokenText: String, speakerID: String, voiceProfileRevision: String,
                direction: SegmentDirection = .init(), scriptRevision: Int, audioArtifactID: String? = nil,
                status: SegmentStatus = .pending, attributionConfidence: Double? = nil,
                attributionEvidence: [String] = [], normalizationNote: String? = nil) {
        self.segmentID = segmentID
        self.chapterID = chapterID
        self.sourceDocumentRevision = sourceDocumentRevision
        self.sourceSpan = sourceSpan
        self.sourceText = sourceText
        self.spokenText = spokenText
        self.speakerID = speakerID
        self.voiceProfileRevision = voiceProfileRevision
        self.direction = direction
        self.scriptRevision = scriptRevision
        self.audioArtifactID = audioArtifactID
        self.status = status
        self.attributionConfidence = attributionConfidence
        self.attributionEvidence = attributionEvidence
        self.normalizationNote = normalizationNote
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", segmentID = "segment_id", chapterID = "chapter_id"
        case sourceDocumentRevision = "source_document_revision", sourceSpan = "source_span"
        case sourceText = "source_text", spokenText = "spoken_text", speakerID = "speaker_id"
        case voiceProfileRevision = "voice_profile_revision", direction, scriptRevision = "script_revision"
        case audioArtifactID = "audio_artifact_id", status, attributionConfidence = "attribution_confidence"
        case attributionEvidence = "attribution_evidence", normalizationNote = "normalization_note"
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version)
        try fields.encode(segmentID, forKey: .segmentID)
        try fields.encode(chapterID, forKey: .chapterID)
        try fields.encode(sourceDocumentRevision, forKey: .sourceDocumentRevision)
        try fields.encode(sourceSpan, forKey: .sourceSpan)
        try fields.encode(sourceText, forKey: .sourceText)
        try fields.encode(spokenText, forKey: .spokenText)
        try fields.encode(speakerID, forKey: .speakerID)
        try fields.encode(voiceProfileRevision, forKey: .voiceProfileRevision)
        try fields.encode(direction, forKey: .direction)
        try fields.encode(scriptRevision, forKey: .scriptRevision)
        try fields.encode(audioArtifactID, forKey: .audioArtifactID)
        try fields.encode(status, forKey: .status)
        try fields.encodeIfPresent(attributionConfidence, forKey: .attributionConfidence)
        try fields.encode(attributionEvidence, forKey: .attributionEvidence)
        try fields.encodeIfPresent(normalizationNote, forKey: .normalizationNote)
    }

    public init(from decoder: any Decoder) throws {
        let f = try decoder.container(keyedBy: CodingKeys.self)
        _ = try f.decode(SchemaVersion.self, forKey: .version)
        try self.init(segmentID: f.decode(String.self, forKey: .segmentID),
                      chapterID: f.decode(String.self, forKey: .chapterID),
                      sourceDocumentRevision: f.decode(String.self, forKey: .sourceDocumentRevision),
                      sourceSpan: f.decode(SourceSpan.self, forKey: .sourceSpan),
                      sourceText: f.decode(String.self, forKey: .sourceText),
                      spokenText: f.decode(String.self, forKey: .spokenText),
                      speakerID: f.decode(String.self, forKey: .speakerID),
                      voiceProfileRevision: f.decode(String.self, forKey: .voiceProfileRevision),
                      direction: f.decode(SegmentDirection.self, forKey: .direction),
                      scriptRevision: f.decode(Int.self, forKey: .scriptRevision),
                      audioArtifactID: f.decodeIfPresent(String.self, forKey: .audioArtifactID),
                      status: f.decode(SegmentStatus.self, forKey: .status),
                      attributionConfidence: f.decodeIfPresent(Double.self, forKey: .attributionConfidence),
                      attributionEvidence: f.decodeIfPresent([String].self, forKey: .attributionEvidence) ?? [],
                      normalizationNote: f.decodeIfPresent(String.self, forKey: .normalizationNote))
    }
}

public struct ScriptDocument: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chapterID: String
    public let sourceDocumentRevision: String
    public let scriptRevision: Int
    public var segments: [ScriptSegment]

    public init(chapterID: String, sourceDocumentRevision: String, scriptRevision: Int, segments: [ScriptSegment]) {
        self.chapterID = chapterID
        self.sourceDocumentRevision = sourceDocumentRevision
        self.scriptRevision = scriptRevision
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", chapterID = "chapter_id", sourceDocumentRevision = "source_document_revision"
        case scriptRevision = "script_revision", segments
    }
}
