import AudioCore
import AudioRenderKit
import Foundation
import SpeechKit

// MARK: - Chapter Selection Helper

public enum ChapterSelection: Sendable {
    /// Parses specifications like `"1"`, `"1-3"`, `"1,3,5-7"` into sorted unique chapter numbers.
    public static func parse(_ spec: String) throws -> [Int] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result = Set<Int>()
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.contains("-") {
                let bounds = token.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard bounds.count == 2,
                      let lo = Int(bounds[0]),
                      let hi = Int(bounds[1]),
                      lo >= 0, hi >= lo else {
                    throw EngineSDKError.invalidInput("Invalid chapter range '\(token)' in '\(spec)'")
                }
                for n in lo...hi { result.insert(n) }
            } else {
                guard let n = Int(token), n >= 0 else {
                    throw EngineSDKError.invalidInput("Invalid chapter number '\(token)' in '\(spec)'")
                }
                result.insert(n)
            }
        }
        return result.sorted()
    }

    public static func select(from chapters: [ChapterRecord], spec: String?) throws -> [ChapterRecord] {
        let sorted = chapters.sorted {
            if $0.chapterNumber != $1.chapterNumber { return $0.chapterNumber < $1.chapterNumber }
            return $0.chapterID < $1.chapterID
        }
        guard let spec, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let numbered = sorted.filter { $0.chapterNumber >= 1 }
            return numbered.isEmpty ? sorted : numbered
        }
        let requested = Set(try parse(spec))
        let matched = sorted.filter { requested.contains($0.chapterNumber) }
        guard !matched.isEmpty else {
            throw EngineSDKError.invalidInput("No chapters matched selection '\(spec)'")
        }
        return matched
    }
}

// MARK: - P2 Application Service Reports & Configs

public struct BookImportReport: Codable, Equatable, Sendable {
    public let sourceDocument: SourceDocumentRecord
    public let chapters: [ChapterRecord]

    public init(sourceDocument: SourceDocumentRecord, chapters: [ChapterRecord]) {
        self.sourceDocument = sourceDocument
        self.chapters = chapters
    }

    enum CodingKeys: String, CodingKey {
        case sourceDocument = "source_document"
        case chapters
    }
}

public struct ChapterAnalysisSummary: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let segmentCount: Int
    public let dialogueSegmentCount: Int
    public let autoAttributedCount: Int
    public let needsReviewCount: Int
    public let coverageRatio: Double
    public let scriptAssetID: String
    public let proposedStagesCount: Int

    public init(
        chapterID: String,
        chapterNumber: Int,
        title: String,
        segmentCount: Int,
        dialogueSegmentCount: Int,
        autoAttributedCount: Int,
        needsReviewCount: Int,
        coverageRatio: Double,
        scriptAssetID: String,
        proposedStagesCount: Int
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.segmentCount = segmentCount
        self.dialogueSegmentCount = dialogueSegmentCount
        self.autoAttributedCount = autoAttributedCount
        self.needsReviewCount = needsReviewCount
        self.coverageRatio = coverageRatio
        self.scriptAssetID = scriptAssetID
        self.proposedStagesCount = proposedStagesCount
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case title
        case segmentCount = "segment_count"
        case dialogueSegmentCount = "dialogue_segment_count"
        case autoAttributedCount = "auto_attributed_count"
        case needsReviewCount = "needs_review_count"
        case coverageRatio = "coverage_ratio"
        case scriptAssetID = "script_asset_id"
        case proposedStagesCount = "proposed_stages_count"
    }
}

public struct BookAnalysisReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let llmModelID: String
    public let seed: UInt64
    public let catalogRevision: Int
    public let characterCount: Int
    public let chapters: [ChapterAnalysisSummary]

    public init(
        projectID: String,
        llmModelID: String,
        seed: UInt64,
        catalogRevision: Int,
        characterCount: Int,
        chapters: [ChapterAnalysisSummary]
    ) {
        self.projectID = projectID
        self.llmModelID = llmModelID
        self.seed = seed
        self.catalogRevision = catalogRevision
        self.characterCount = characterCount
        self.chapters = chapters
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case llmModelID = "llm_model_id"
        case seed
        case catalogRevision = "catalog_revision"
        case characterCount = "character_count"
        case chapters
    }
}

public struct AudiobookMLXJobConfig: Codable, Equatable, Sendable {
    public let chapterIDs: [String]
    public let chapterNumbersByID: [String: Int]
    public let auditionTTSModelID: String
    public let mainTTSModelID: String
    public let asrModelID: String
    public let seed: UInt64
    public let stopAfterCompletedNodes: Int?
    public let maxRepairRounds: Int

    public init(
        chapterIDs: [String],
        chapterNumbersByID: [String: Int],
        auditionTTSModelID: String,
        mainTTSModelID: String,
        asrModelID: String,
        seed: UInt64 = 42,
        stopAfterCompletedNodes: Int? = nil,
        maxRepairRounds: Int = 2
    ) {
        self.chapterIDs = chapterIDs
        self.chapterNumbersByID = chapterNumbersByID
        self.auditionTTSModelID = auditionTTSModelID
        self.mainTTSModelID = mainTTSModelID
        self.asrModelID = asrModelID
        self.seed = seed
        self.stopAfterCompletedNodes = stopAfterCompletedNodes
        self.maxRepairRounds = max(0, maxRepairRounds)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterIDs = try c.decode([String].self, forKey: .chapterIDs)
        chapterNumbersByID = try c.decode([String: Int].self, forKey: .chapterNumbersByID)
        auditionTTSModelID = try c.decode(String.self, forKey: .auditionTTSModelID)
        mainTTSModelID = try c.decode(String.self, forKey: .mainTTSModelID)
        asrModelID = try c.decode(String.self, forKey: .asrModelID)
        seed = try c.decode(UInt64.self, forKey: .seed)
        stopAfterCompletedNodes = try c.decodeIfPresent(Int.self, forKey: .stopAfterCompletedNodes)
        maxRepairRounds = max(0, try c.decodeIfPresent(Int.self, forKey: .maxRepairRounds) ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case chapterIDs = "chapter_ids"
        case chapterNumbersByID = "chapter_numbers_by_id"
        case auditionTTSModelID = "audition_tts_model_id"
        case mainTTSModelID = "main_tts_model_id"
        case asrModelID = "asr_model_id"
        case seed
        case stopAfterCompletedNodes = "stop_after_completed_nodes"
        case maxRepairRounds = "max_repair_rounds"
    }
}

// MARK: - P3 Review, Batch Auto-Repair & Speaker Reassignment Reports

public struct RepairSegmentSummary: Codable, Equatable, Sendable {
    public let chapterID: String
    public let segmentID: String
    public let round: Int
    public let seedUsed: UInt64
    public let swapped: Bool
    public let previousStatus: SegmentStatus
    public let newStatus: SegmentStatus
    public let previousAdjustedCER: Double?
    public let newAdjustedCER: Double
    public let decisionReason: String

    public init(
        chapterID: String,
        segmentID: String,
        round: Int,
        seedUsed: UInt64,
        swapped: Bool,
        previousStatus: SegmentStatus,
        newStatus: SegmentStatus,
        previousAdjustedCER: Double?,
        newAdjustedCER: Double,
        decisionReason: String
    ) {
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.round = round
        self.seedUsed = seedUsed
        self.swapped = swapped
        self.previousStatus = previousStatus
        self.newStatus = newStatus
        self.previousAdjustedCER = previousAdjustedCER
        self.newAdjustedCER = newAdjustedCER
        self.decisionReason = decisionReason
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case round
        case seedUsed = "seed_used"
        case swapped
        case previousStatus = "previous_status"
        case newStatus = "new_status"
        case previousAdjustedCER = "previous_adjusted_cer"
        case newAdjustedCER = "new_adjusted_cer"
        case decisionReason = "decision_reason"
    }
}

public struct BatchRepairReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let roundsExecuted: Int
    public let attemptedSegments: Int
    public let verifiedCount: Int
    public let improvedCount: Int
    public let remainingNeedsReviewCount: Int
    public let details: [RepairSegmentSummary]

    public init(
        projectID: String,
        roundsExecuted: Int,
        attemptedSegments: Int,
        verifiedCount: Int,
        improvedCount: Int,
        remainingNeedsReviewCount: Int,
        details: [RepairSegmentSummary]
    ) {
        self.projectID = projectID
        self.roundsExecuted = roundsExecuted
        self.attemptedSegments = attemptedSegments
        self.verifiedCount = verifiedCount
        self.improvedCount = improvedCount
        self.remainingNeedsReviewCount = remainingNeedsReviewCount
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case roundsExecuted = "rounds_executed"
        case attemptedSegments = "attempted_segments"
        case verifiedCount = "verified_count"
        case improvedCount = "improved_count"
        case remainingNeedsReviewCount = "remaining_needs_review_count"
        case details
    }
}

public struct BatchApproveReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let dryRun: Bool
    public let approvedSegmentIDs: [String]
    public let skippedSegmentIDs: [String]
    public let note: String

    public init(
        projectID: String,
        dryRun: Bool,
        approvedSegmentIDs: [String],
        skippedSegmentIDs: [String],
        note: String
    ) {
        self.projectID = projectID
        self.dryRun = dryRun
        self.approvedSegmentIDs = approvedSegmentIDs
        self.skippedSegmentIDs = skippedSegmentIDs
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case dryRun = "dry_run"
        case approvedSegmentIDs = "approved_segment_ids"
        case skippedSegmentIDs = "skipped_segment_ids"
        case note
    }
}

public struct SpeakerReassignmentReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let chapterID: String
    public let segmentID: String
    public let previousSpeakerID: String
    public let newSpeakerID: String
    public let newSpeakerName: String
    public let previousStatus: SegmentStatus
    public let newStatus: SegmentStatus
    public let scriptRevision: Int
    public let clearedAttributionFlags: [String]

    public init(
        projectID: String,
        chapterID: String,
        segmentID: String,
        previousSpeakerID: String,
        newSpeakerID: String,
        newSpeakerName: String,
        previousStatus: SegmentStatus,
        newStatus: SegmentStatus,
        scriptRevision: Int,
        clearedAttributionFlags: [String]
    ) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.previousSpeakerID = previousSpeakerID
        self.newSpeakerID = newSpeakerID
        self.newSpeakerName = newSpeakerName
        self.previousStatus = previousStatus
        self.newStatus = newStatus
        self.scriptRevision = scriptRevision
        self.clearedAttributionFlags = clearedAttributionFlags
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case previousSpeakerID = "previous_speaker_id"
        case newSpeakerID = "new_speaker_id"
        case newSpeakerName = "new_speaker_name"
        case previousStatus = "previous_status"
        case newStatus = "new_status"
        case scriptRevision = "script_revision"
        case clearedAttributionFlags = "cleared_attribution_flags"
    }
}

public struct SegmentVerificationEntry: Codable, Equatable, Sendable {
    public let segmentID: String
    public let speakerID: String
    public let status: SegmentStatus
    public let audioAssetID: String?
    public let assetIntact: Bool
    public let explicitlyApproved: Bool
    public let exportEligible: Bool

    public init(
        segmentID: String,
        speakerID: String,
        status: SegmentStatus,
        audioAssetID: String?,
        assetIntact: Bool,
        explicitlyApproved: Bool,
        exportEligible: Bool
    ) {
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.status = status
        self.audioAssetID = audioAssetID
        self.assetIntact = assetIntact
        self.explicitlyApproved = explicitlyApproved
        self.exportEligible = exportEligible
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case speakerID = "speaker_id"
        case status
        case audioAssetID = "audio_asset_id"
        case assetIntact = "asset_intact"
        case explicitlyApproved = "explicitly_approved"
        case exportEligible = "export_eligible"
    }
}

public struct ChapterVerificationReport: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let totalSegments: Int
    public let verifiedCount: Int
    public let approvedCount: Int
    public let needsReviewCount: Int
    public let pendingOrFailedCount: Int
    public let exportReady: Bool
    public let blockingSegmentIDs: [String]
    public let segments: [SegmentVerificationEntry]

    public init(
        chapterID: String,
        chapterNumber: Int,
        title: String,
        totalSegments: Int,
        verifiedCount: Int,
        approvedCount: Int,
        needsReviewCount: Int,
        pendingOrFailedCount: Int,
        exportReady: Bool,
        blockingSegmentIDs: [String],
        segments: [SegmentVerificationEntry]
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.totalSegments = totalSegments
        self.verifiedCount = verifiedCount
        self.approvedCount = approvedCount
        self.needsReviewCount = needsReviewCount
        self.pendingOrFailedCount = pendingOrFailedCount
        self.exportReady = exportReady
        self.blockingSegmentIDs = blockingSegmentIDs
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case title
        case totalSegments = "total_segments"
        case verifiedCount = "verified_count"
        case approvedCount = "approved_count"
        case needsReviewCount = "needs_review_count"
        case pendingOrFailedCount = "pending_or_failed_count"
        case exportReady = "export_ready"
        case blockingSegmentIDs = "blocking_segment_ids"
        case segments
    }
}

public struct ProjectVerificationReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let exportReady: Bool
    public let totalSegments: Int
    public let verifiedSegments: Int
    public let approvedSegments: Int
    public let blockingSegmentIDs: [String]
    public let chapters: [ChapterVerificationReport]
    public let inspectedM4B: M4BVerificationReport?

    public init(
        projectID: String,
        exportReady: Bool,
        totalSegments: Int,
        verifiedSegments: Int,
        approvedSegments: Int,
        blockingSegmentIDs: [String],
        chapters: [ChapterVerificationReport],
        inspectedM4B: M4BVerificationReport? = nil
    ) {
        self.projectID = projectID
        self.exportReady = exportReady
        self.totalSegments = totalSegments
        self.verifiedSegments = verifiedSegments
        self.approvedSegments = approvedSegments
        self.blockingSegmentIDs = blockingSegmentIDs
        self.chapters = chapters
        self.inspectedM4B = inspectedM4B
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case exportReady = "export_ready"
        case totalSegments = "total_segments"
        case verifiedSegments = "verified_segments"
        case approvedSegments = "approved_segments"
        case blockingSegmentIDs = "blocking_segment_ids"
        case chapters
        case inspectedM4B = "inspected_m4b"
    }
}

public struct BookExportReport: Codable, Equatable, Sendable {
    public let projectID: String
    public let format: ExportFormat
    public let outputPath: String
    public let timelinePath: String
    public let sampleRate: Int
    public let durationSeconds: Double
    public let chapterCount: Int
    public let segmentCount: Int
    public let ambientMixed: Bool
    public let ambientAssetID: String?
    public let renderFingerprint: String
    public let drySegmentAssetSHA256s: [String: String]
    public let verifiedM4B: M4BVerificationReport?

    public init(
        projectID: String,
        format: ExportFormat,
        outputPath: String,
        timelinePath: String,
        sampleRate: Int,
        durationSeconds: Double,
        chapterCount: Int,
        segmentCount: Int,
        ambientMixed: Bool,
        ambientAssetID: String?,
        renderFingerprint: String,
        drySegmentAssetSHA256s: [String: String],
        verifiedM4B: M4BVerificationReport?
    ) {
        self.projectID = projectID
        self.format = format
        self.outputPath = outputPath
        self.timelinePath = timelinePath
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
        self.segmentCount = segmentCount
        self.ambientMixed = ambientMixed
        self.ambientAssetID = ambientAssetID
        self.renderFingerprint = renderFingerprint
        self.drySegmentAssetSHA256s = drySegmentAssetSHA256s
        self.verifiedM4B = verifiedM4B
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case format
        case outputPath = "output_path"
        case timelinePath = "timeline_path"
        case sampleRate = "sample_rate"
        case durationSeconds = "duration_seconds"
        case chapterCount = "chapter_count"
        case segmentCount = "segment_count"
        case ambientMixed = "ambient_mixed"
        case ambientAssetID = "ambient_asset_id"
        case renderFingerprint = "render_fingerprint"
        case drySegmentAssetSHA256s = "dry_segment_asset_sha256s"
        case verifiedM4B = "verified_m4b"
    }
}
