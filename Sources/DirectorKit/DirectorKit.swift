import AudioCore
import Foundation

public struct DirectedUnit: Codable, Equatable, Sendable {
    public let index: Int
    public let segmentID: String
    public let chapterID: String
    public let span: SourceSpan
    public let sourceText: String
    public let spokenText: String
    public let isQuotedDialogue: Bool

    public init(
        index: Int,
        segmentID: String,
        chapterID: String,
        span: SourceSpan,
        sourceText: String,
        spokenText: String,
        isQuotedDialogue: Bool
    ) {
        self.index = index
        self.segmentID = segmentID
        self.chapterID = chapterID
        self.span = span
        self.sourceText = sourceText
        self.spokenText = spokenText
        self.isQuotedDialogue = isQuotedDialogue
    }
}

public struct AttributedUnit: Codable, Equatable, Sendable {
    public let index: Int
    public let speakerID: String
    public let emotion: String
    public let styleInstruction: String
    public let pauseAfterMs: Int
    public let confidence: Double
    public let evidence: [String]
    public let needsReviewReason: String?

    public init(
        index: Int,
        speakerID: String,
        emotion: String,
        styleInstruction: String,
        pauseAfterMs: Int,
        confidence: Double,
        evidence: [String],
        needsReviewReason: String? = nil
    ) {
        self.index = index
        self.speakerID = speakerID
        self.emotion = emotion
        self.styleInstruction = styleInstruction
        self.pauseAfterMs = pauseAfterMs
        self.confidence = confidence
        self.evidence = evidence
        self.needsReviewReason = needsReviewReason
    }
}

public struct NarrativeAnalysisResult: Codable, Equatable, Sendable {
    public let catalog: CharacterVoiceCatalog
    public let attributions: [AttributedUnit]
    public let proposedStages: [String: [VoiceDeliveryStage]]
    public let autoAttributedCount: Int
    public let needsReviewCount: Int

    public init(
        catalog: CharacterVoiceCatalog,
        attributions: [AttributedUnit],
        proposedStages: [String: [VoiceDeliveryStage]] = [:],
        autoAttributedCount: Int,
        needsReviewCount: Int
    ) {
        self.catalog = catalog
        self.attributions = attributions
        self.proposedStages = proposedStages
        self.autoAttributedCount = autoAttributedCount
        self.needsReviewCount = needsReviewCount
    }
}
