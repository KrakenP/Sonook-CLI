import AudioCore
import Foundation

/// Single source of truth for speaker-attribution review flags produced by `NarrativeKit`.
public enum AttributionReviewFlags: Sendable {
    public static let rawReasonCodes: Set<String> = [
        "unresolved_dialogue_speaker",
        "vocative_speaker_conflict",
        "low_confidence_attribution"
    ]

    public static func extract(from evidence: [String]) -> [String] {
        evidence.filter { $0.hasPrefix("needs_review:") || rawReasonCodes.contains($0) }
    }

    public static func hasUnresolvedFlag(in evidence: [String]) -> Bool {
        !extract(from: evidence).isEmpty
    }

    public static func strippingFlags(from evidence: [String]) -> [String] {
        evidence.filter { !$0.hasPrefix("needs_review:") && !rawReasonCodes.contains($0) }
    }
}

/// Decision outcome for evaluating an automated repair candidate against an existing segment take.
public struct AutoRepairDecision: Equatable, Sendable {
    public let acceptCandidate: Bool
    public let resultingStatus: SegmentStatus
    public let reason: String

    public init(acceptCandidate: Bool, resultingStatus: SegmentStatus, reason: String) {
        self.acceptCandidate = acceptCandidate
        self.resultingStatus = resultingStatus
        self.reason = reason
    }
}

/// Pure, deterministic policy evaluator for post-ASR automated seed-shift repair.
public enum AutoRepairCandidateEvaluator: Sendable {
    /// Returns true if a segment has a recoverable TTS/ASR defect that warrants automated seed-shift re-synthesis.
    /// Segments that are already verified, pure non-verbal pauses, or flagged ONLY for speaker attribution (with passing ASR)
    /// are NOT unnecessarily re-synthesized.
    public static func shouldAutoRepair(
        segment: ScriptSegment,
        latestAudit: SegmentQualityAudit?
    ) -> Bool {
        if SpeechRequestBuilder.isNonVerbalPauseText(segment.spokenText) {
            return false
        }
        switch segment.status {
        case .verified:
            return false
        case .pending, .synthesized, .failed:
            return true
        case .needsReview:
            guard let audit = latestAudit else {
                // No audit recorded yet -> only repair if not purely awaiting attribution review with an existing asset.
                return segment.audioArtifactID == nil || !AttributionReviewFlags.hasUnresolvedFlag(in: segment.attributionEvidence)
            }
            // If ASR already passed and the only reason it stayed needs_review is speaker attribution, TTS retry cannot fix speaker ID.
            if audit.verdictLabel == "passed" && AttributionReviewFlags.hasUnresolvedFlag(in: segment.attributionEvidence) {
                return false
            }
            return audit.verdictLabel != "passed"
        }
    }

    /// Compares a newly synthesized & audited candidate against the segment's previous state.
    /// Hard invariants:
    /// 1. Never overwrites a `.verified` segment.
    /// 2. Never swaps a `.retryableFailure` (broken/silent/truncated audio) over an intact previous take.
    /// 3. Accepts `.passed` immediately (preserving `.needsReview` if an attribution review flag still remains).
    /// 4. If both previous and candidate are `.needsReview`, swaps ONLY if candidate has strictly lower `adjustedCER`
    ///    (or if no previous intact asset/audit existed).
    public static func evaluateCandidate(
        previousStatus: SegmentStatus,
        previousAssetID: String?,
        previousAudit: SegmentQualityAudit?,
        candidateOutcome: ProperNounVerificationOutcome,
        hasAttributionReviewFlag: Bool
    ) -> AutoRepairDecision {
        if previousStatus == .verified {
            return AutoRepairDecision(
                acceptCandidate: false,
                resultingStatus: .verified,
                reason: "already_verified_protected"
            )
        }

        switch candidateOutcome.verdict {
        case .passed:
            let nextStatus: SegmentStatus = hasAttributionReviewFlag ? .needsReview : .verified
            return AutoRepairDecision(
                acceptCandidate: true,
                resultingStatus: nextStatus,
                reason: hasAttributionReviewFlag ? "asr_passed_attribution_review_retained" : "repaired_to_verified"
            )

        case .needsReview:
            if previousAssetID == nil || previousStatus == .pending || previousStatus == .failed {
                return AutoRepairDecision(
                    acceptCandidate: true,
                    resultingStatus: .needsReview,
                    reason: "replaced_missing_or_failed_asset"
                )
            }
            guard let prevAudit = previousAudit else {
                return AutoRepairDecision(
                    acceptCandidate: false,
                    resultingStatus: previousStatus,
                    reason: "kept_existing_without_prior_audit"
                )
            }
            if candidateOutcome.audit.adjustedCER + 0.0001 < prevAudit.adjustedCER {
                return AutoRepairDecision(
                    acceptCandidate: true,
                    resultingStatus: .needsReview,
                    reason: "improved_adjusted_cer"
                )
            }
            return AutoRepairDecision(
                acceptCandidate: false,
                resultingStatus: previousStatus,
                reason: "candidate_not_better_than_existing"
            )

        case .retryableFailure:
            return AutoRepairDecision(
                acceptCandidate: false,
                resultingStatus: previousStatus,
                reason: "rejected_broken_audio_candidate"
            )
        }
    }
}

/// Computes minimal precision cache invalidation blast radius across chapters and characters.
/// Proves that editing one character's stage from chapter K, or reassigning a single segment's speaker,
/// invalidates ONLY affected segments while preserving 100% of unaffected verified assets.
public enum CacheInvalidationPlanner: Sendable {
    public static func plan(
        projectID: String,
        chapters: [ChapterRecord],
        scriptsByChapterID: [String: ScriptDocument],
        catalog: CharacterVoiceCatalog,
        providerID: String,
        modelID: String,
        modelRevision: String,
        store: any ArtifactStoreProtocol
    ) async throws -> CacheInvalidationPlan {
        var entries: [CacheInvalidationEntry] = []
        var reusable = 0
        var invalidated = 0

        for chapter in chapters {
            guard let script = scriptsByChapterID[chapter.chapterID] else { continue }
            for seg in script.segments {
                guard let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) else {
                    invalidated += 1
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: true,
                        reason: .missingSpeakerCard,
                        existingAssetID: seg.audioArtifactID,
                        expectedFingerprint: nil
                    ))
                    continue
                }

                let expectedFP = card.synthesisFingerprint(
                    chapterIndex: chapter.chapterNumber,
                    spokenText: seg.spokenText,
                    direction: seg.direction,
                    providerID: providerID,
                    modelID: modelID,
                    modelRevision: modelRevision
                )

                guard seg.status == .verified else {
                    invalidated += 1
                    let reason: CacheInvalidationReason = seg.attributionEvidence.contains("[manual:speaker_reassigned]")
                        ? .speakerReassigned
                        : .statusRequiresSynthesis
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: true,
                        reason: reason,
                        existingAssetID: seg.audioArtifactID,
                        expectedFingerprint: expectedFP
                    ))
                    continue
                }

                guard let existingAssetID = seg.audioArtifactID,
                      let existingAsset = try await store.asset(id: existingAssetID) else {
                    invalidated += 1
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: true,
                        reason: .missingAudioAsset,
                        existingAssetID: seg.audioArtifactID,
                        expectedFingerprint: expectedFP
                    ))
                    continue
                }

                let intact = try await store.verifyAssetIntegrity(assetID: existingAssetID)
                guard intact else {
                    invalidated += 1
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: true,
                        reason: .corruptedAudioAsset,
                        existingAssetID: existingAssetID,
                        expectedFingerprint: expectedFP
                    ))
                    continue
                }

                if existingAsset.provenance.inputFingerprint == expectedFP {
                    reusable += 1
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: false,
                        reason: .intactCacheHit,
                        existingAssetID: existingAssetID,
                        expectedFingerprint: expectedFP
                    ))
                } else {
                    invalidated += 1
                    entries.append(CacheInvalidationEntry(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        segmentID: seg.segmentID,
                        speakerID: seg.speakerID,
                        needsResynthesis: true,
                        reason: .fingerprintChanged,
                        existingAssetID: existingAssetID,
                        expectedFingerprint: expectedFP
                    ))
                }
            }
        }

        return CacheInvalidationPlan(
            projectID: projectID,
            providerID: providerID,
            modelID: modelID,
            totalSegments: entries.count,
            reusableSegments: reusable,
            invalidatedSegments: invalidated,
            entries: entries
        )
    }
}
