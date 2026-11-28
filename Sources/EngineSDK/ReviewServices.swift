import AudioCore
import AudioRenderKit
import Foundation
import ModelRuntime
import SpeechKit
import StorageKit

extension SonookEngine {
    // MARK: - P3 NeedsReview Batch Workflow

    /// Lists segments across selected chapters requiring human review or attention (`.needsReview` / `.failed`),
    /// enriched with playable WAV file paths, attribution flags, and the latest ASR quality audit metrics.
    public func listReviewQueue(
        projectID: String,
        chapterSpec: String? = nil,
        includeApproved: Bool = false
    ) async throws -> [ReviewQueueItem] {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let selectedChapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)
        let catalog = try await store.loadCatalog(projectID: projectID)
        let namesByID = Dictionary(uniqueKeysWithValues: (catalog?.cards ?? []).map { ($0.characterID, $0.canonicalName) })

        let (auditsByAssetID, latestAuditsBySegID) = try await loadQualityAudits(projectID: projectID)
        var items: [ReviewQueueItem] = []

        for ch in selectedChapters {
            guard let script = try await store.loadScript(projectID: projectID, chapterID: ch.chapterID) else { continue }
            let approvals = try await store.segmentApprovals(projectID: projectID, chapterID: ch.chapterID)
            let approvalBySeg = Dictionary(uniqueKeysWithValues: approvals.map { ($0.segmentID, $0) })

            for seg in script.segments {
                guard seg.status == .needsReview || seg.status == .failed else { continue }
                let assetID = seg.audioArtifactID
                var assetIntact = false
                var audioPath: String?
                if let assetID {
                    assetIntact = (try? await store.verifyAssetIntegrity(assetID: assetID)) ?? false
                    audioPath = try? await store.resolveFileURL(for: assetID).path
                }
                let approval = approvalBySeg[seg.segmentID]
                let isApproved = assetIntact && approval != nil && approval?.approvedAssetID == assetID
                if isApproved && !includeApproved {
                    continue
                }
                let audit = assetID.flatMap { auditsByAssetID[$0] } ?? latestAuditsBySegID[seg.segmentID]
                items.append(ReviewQueueItem(
                    chapterID: ch.chapterID,
                    chapterNumber: ch.chapterNumber,
                    chapterTitle: ch.title,
                    segmentID: seg.segmentID,
                    speakerID: seg.speakerID,
                    speakerName: namesByID[seg.speakerID] ?? seg.speakerID,
                    status: seg.status,
                    spokenText: seg.spokenText,
                    audioAssetID: assetID,
                    audioFilePath: audioPath,
                    assetIntact: assetIntact,
                    explicitlyApproved: isApproved,
                    reviewerNote: isApproved ? approval?.reviewerNote : nil,
                    attributionFlags: AttributionReviewFlags.extract(from: seg.attributionEvidence),
                    rawTranscript: audit?.rawTranscript,
                    rawCER: audit?.rawCER,
                    adjustedCER: audit?.adjustedCER,
                    asrFailureReasons: audit?.failureReasons ?? [],
                    exemptionCount: audit?.exemptions.count ?? 0
                ))
            }
        }
        return items
    }

    /// Reassigns a single segment's speaker to another character in the project's catalog, clears speaker-attribution
    /// review flags, bumps `scriptRevision`, and resets status to `.pending` so precision cache invalidates ONLY
    /// this segment while keeping all sibling segments 100% untouched.
    public func reassignSegmentSpeaker(
        projectID: String,
        segmentID: String,
        speakerQuery: String
    ) async throws -> SpeakerReassignmentReport {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let catalog = try await store.loadCatalog(projectID: projectID) else {
            throw EngineSDKError.invalidInput("Character catalog missing for project \(projectID)")
        }
        guard let targetCard = catalog.resolveCharacter(namedOrAliased: speakerQuery) else {
            throw EngineSDKError.invalidInput("Speaker '\(speakerQuery)' not found in project catalog")
        }
        guard let located = try await store.locateSegment(projectID: projectID, segmentID: segmentID),
              let scriptDoc = try await store.loadScript(projectID: projectID, chapterID: located.chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == segmentID }) else {
            throw EngineSDKError.segmentNotFound(segmentID)
        }

        let originalSeg = scriptDoc.segments[segIdx]
        let prevSpeaker = originalSeg.speakerID
        let prevStatus = originalSeg.status
        let clearedFlags = AttributionReviewFlags.extract(from: originalSeg.attributionEvidence)
        var newEvidence = AttributionReviewFlags.strippingFlags(from: originalSeg.attributionEvidence)
        if !newEvidence.contains("[manual:speaker_reassigned]") {
            newEvidence.append("[manual:speaker_reassigned]")
        }

        let nextRevision = scriptDoc.scriptRevision + 1
        // Invalidate ONLY this segment's synthesis status so precision cache triggers re-synthesis with the new voice.
        let nextStatus: SegmentStatus = (prevSpeaker != targetCard.characterID || prevStatus != .verified) ? .pending : prevStatus
        let updatedSeg = ScriptSegment(
            segmentID: originalSeg.segmentID,
            chapterID: originalSeg.chapterID,
            sourceDocumentRevision: originalSeg.sourceDocumentRevision,
            sourceSpan: originalSeg.sourceSpan,
            sourceText: originalSeg.sourceText,
            spokenText: originalSeg.spokenText,
            speakerID: targetCard.characterID,
            voiceProfileRevision: "\(targetCard.characterID)_rev_\(targetCard.revision)",
            direction: originalSeg.direction,
            scriptRevision: nextRevision,
            audioArtifactID: originalSeg.audioArtifactID,
            status: nextStatus,
            attributionConfidence: 1.0,
            attributionEvidence: newEvidence,
            normalizationNote: originalSeg.normalizationNote
        )
        var updatedSegments = scriptDoc.segments
        updatedSegments[segIdx] = updatedSeg
        let updatedDoc = ScriptDocument(
            chapterID: scriptDoc.chapterID,
            sourceDocumentRevision: scriptDoc.sourceDocumentRevision,
            scriptRevision: nextRevision,
            segments: updatedSegments
        )

        try await store.saveScript(updatedDoc, projectID: projectID)

        return SpeakerReassignmentReport(
            projectID: projectID,
            chapterID: located.chapterID,
            segmentID: segmentID,
            previousSpeakerID: prevSpeaker,
            newSpeakerID: targetCard.characterID,
            newSpeakerName: targetCard.canonicalName,
            previousStatus: prevStatus,
            newStatus: nextStatus,
            scriptRevision: nextRevision,
            clearedAttributionFlags: clearedFlags
        )
    }

    /// Batch-approves matching `needs_review` segments with intact WAV assets and optional `maxCER` ceiling.
    public func batchApproveSegments(
        projectID: String,
        chapterSpec: String? = nil,
        note: String,
        maxCER: Double? = nil,
        dryRun: Bool = false
    ) async throws -> BatchApproveReport {
        let queue = try await listReviewQueue(projectID: projectID, chapterSpec: chapterSpec, includeApproved: false)
        var approvedIDs: [String] = []
        var skippedIDs: [String] = []
        let now = ISO8601DateFormatter().string(from: Date())

        for item in queue {
            guard item.assetIntact, let assetID = item.audioAssetID else {
                skippedIDs.append(item.segmentID)
                continue
            }
            if let maxCER, let adj = item.adjustedCER, adj > maxCER + 0.0001 {
                skippedIDs.append(item.segmentID)
                continue
            }
            if !dryRun {
                let record = SegmentApprovalRecord(
                    projectID: projectID,
                    chapterID: item.chapterID,
                    segmentID: item.segmentID,
                    approvedAssetID: assetID,
                    reviewerNote: note,
                    approvedAtISO8601: now
                )
                try await store.saveSegmentApproval(record)
            }
            approvedIDs.append(item.segmentID)
        }

        return BatchApproveReport(
            projectID: projectID,
            dryRun: dryRun,
            approvedSegmentIDs: approvedIDs,
            skippedSegmentIDs: skippedIDs,
            note: note
        )
    }

    /// Staged batch retry for all unresolved ASR-defect segments across selected chapters.
    /// Uses batch TTS -> unload -> batch ASR per round to eliminate model thrashing on Apple Silicon.
    public func batchRetryNeedsReview(
        projectID: String,
        chapterSpec: String? = nil,
        mainTTSModelID: String? = nil,
        asrModelID: String? = nil,
        baseSeed: UInt64 = 42,
        maxRounds: Int = 2,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BatchRepairReport {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let catalog = try await store.loadCatalog(projectID: projectID) else {
            throw EngineSDKError.invalidInput("Character catalog missing for project \(projectID)")
        }

        let selectedChapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)
        let mainEntry = try await resolveModelEntry(
            explicitID: mainTTSModelID ?? project.options.preferredMainTTSModelID,
            kind: .tts,
            preferProviderContaining: "voxcpm2"
        )
        let asrEntry = try await resolveModelEntry(
            explicitID: asrModelID ?? project.options.preferredASRModelID,
            kind: .asr
        )

        let policy = SegmentAutoRepairPolicy(maxRepairRounds: max(1, maxRounds))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var roundsExecuted = 0
        var totalAttempted = 0
        var totalVerified = 0
        var totalImproved = 0
        var details: [RepairSegmentSummary] = []

        for round in 1...policy.maxRepairRounds {
            let (auditsByAssetID, latestAuditsBySegID) = try await loadQualityAudits(projectID: projectID)
            struct Target {
                let chapter: ChapterRecord
                let segment: ScriptSegment
                let card: CharacterVoiceCard
                let previousAudit: SegmentQualityAudit?
            }

            var targets: [Target] = []
            for ch in selectedChapters {
                guard let script = try await store.loadScript(projectID: projectID, chapterID: ch.chapterID) else { continue }
                for seg in script.segments {
                    let audit = seg.audioArtifactID.flatMap { auditsByAssetID[$0] } ?? latestAuditsBySegID[seg.segmentID]
                    guard AutoRepairCandidateEvaluator.shouldAutoRepair(segment: seg, latestAudit: audit),
                          let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) else {
                        continue
                    }
                    targets.append(Target(chapter: ch, segment: seg, card: card, previousAudit: audit))
                }
            }
            if targets.isEmpty { break }

            roundsExecuted += 1
            let repairSeed = policy.seed(forBaseSeed: baseSeed, round: round)
            progress("[ReviewRetry] Round \(round)/\(policy.maxRepairRounds) (seed=\(repairSeed)): synthesizing \(targets.count) segment(s) with \(mainEntry.modelID)...")

            await runtime.unloadAllIdle()
            struct Candidate {
                let target: Target
                let asset: AssetRecord
                let samples: [Float]
                let sampleRate: Int
            }
            var candidates: [Candidate] = []
            for target in targets {
                var verifiedAnchorPath: String?
                if mainEntry.providerID == MLXVoxCPM2Provider.providerIdentifier {
                    let (_, anchorURL) = try await ModelResourceManager.resolveVerifiedTimbreAnchorURL(for: target.card, artifactStore: store)
                    verifiedAnchorPath = anchorURL.path
                }
                let speechReq = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
                    segment: target.segment,
                    card: target.card,
                    chapterNumber: target.chapter.chapterNumber,
                    providerID: mainEntry.providerID,
                    verifiedAnchorPath: verifiedAnchorPath,
                    seed: repairSeed
                )
                let synthFP = target.card.synthesisFingerprint(
                    chapterIndex: target.chapter.chapterNumber,
                    spokenText: target.segment.spokenText,
                    direction: target.segment.direction,
                    providerID: mainEntry.providerID,
                    modelID: mainEntry.modelID,
                    modelRevision: mainEntry.revision
                )
                let audio = try await runtime.withTTSLease(entry: mainEntry, priority: .interactive) { provider in
                    try await provider.synthesize(speechReq)
                }
                let wavData = try PCMCodec.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
                let asset = try await store.commitBytes(
                    wavData,
                    projectID: projectID,
                    kind: .segmentWAV,
                    fileExtension: "wav",
                    sampleRate: audio.sampleRate,
                    frameCount: audio.pcmSamples.count,
                    provenance: AssetProvenance(
                        sourceDocumentRevision: target.segment.sourceDocumentRevision,
                        chapterID: target.chapter.chapterID,
                        segmentID: target.segment.segmentID,
                        characterID: target.segment.speakerID,
                        scriptRevision: target.segment.scriptRevision,
                        providerID: mainEntry.providerID,
                        modelID: mainEntry.modelID,
                        modelRevision: mainEntry.revision,
                        inputFingerprint: synthFP
                    )
                )
                candidates.append(Candidate(target: target, asset: asset, samples: audio.pcmSamples, sampleRate: audio.sampleRate))
            }
            if let peak = await runtime.measuredPeakBytes(for: mainEntry.modelID) {
                try? await store.updateMeasuredPeakBytes(modelID: mainEntry.modelID, peakBytes: peak)
            }

            var narratorAnchorPitchHz: Double?
            if let anchor = catalog.resolveCharacter(namedOrAliased: "char_narrator")?.timbreAnchor,
               let anchorURL = try? await store.resolveFileURL(for: anchor.assetID),
               let (anchorSamples, anchorSR) = try? PCMCodec.readMonoSamples(from: anchorURL) {
                narratorAnchorPitchHz = AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: anchorSamples, sampleRate: anchorSR)
            }

            await runtime.unloadAllIdle()
            progress("[ReviewRetry] Round \(round): verifying \(candidates.count) candidate(s) with \(asrEntry.modelID)...")
            for candidate in candidates {
                totalAttempted += 1
                let integrity = AudioIntegrityChecker.analyze(pcmSamples: candidate.samples, sampleRate: candidate.sampleRate)
                let transcript = try await runtime.withASRLease(entry: asrEntry, priority: .interactive) { provider in
                    try await provider.transcribe(ASRRequest(pcmSamples: candidate.samples, sampleRate: candidate.sampleRate, parameters: ["language": "Chinese"]))
                }
                let expectedPitchHz: Double? = (candidate.target.segment.speakerID == "char_narrator") ? narratorAnchorPitchHz : nil
                let candidatePitchHz: Double? = (expectedPitchHz != nil)
                    ? AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: candidate.samples, sampleRate: candidate.sampleRate)
                    : nil
                let qaOutcome = ProperNounAwareASRVerifier.evaluate(
                    segmentID: candidate.target.segment.segmentID,
                    wavAssetID: candidate.asset.assetID,
                    referenceText: candidate.target.segment.spokenText,
                    hypothesisTranscript: transcript.text,
                    integrity: integrity,
                    catalog: catalog,
                    thresholds: policy.thresholds,
                    expectedPitchHz: expectedPitchHz,
                    candidatePitchHz: candidatePitchHz
                )
                _ = try await store.commitBytes(
                    try enc.encode(qaOutcome.audit),
                    projectID: projectID,
                    kind: .qualityReport,
                    fileExtension: "json",
                    sampleRate: nil,
                    frameCount: nil,
                    provenance: AssetProvenance(
                        chapterID: candidate.target.chapter.chapterID,
                        segmentID: candidate.target.segment.segmentID,
                        providerID: asrEntry.providerID,
                        modelID: asrEntry.modelID,
                        modelRevision: asrEntry.revision,
                        inputFingerprint: "review_retry|\(candidate.target.segment.segmentID)|r\(round)|s\(repairSeed)"
                    )
                )

                let hasAttrFlag = AttributionReviewFlags.hasUnresolvedFlag(in: candidate.target.segment.attributionEvidence)
                let decision = AutoRepairCandidateEvaluator.evaluateCandidate(
                    previousStatus: candidate.target.segment.status,
                    previousAssetID: candidate.target.segment.audioArtifactID,
                    previousAudit: candidate.target.previousAudit,
                    candidateOutcome: qaOutcome,
                    hasAttributionReviewFlag: hasAttrFlag
                )
                if decision.acceptCandidate,
                   var scriptDoc = try await store.loadScript(projectID: projectID, chapterID: candidate.target.chapter.chapterID),
                   let idx = scriptDoc.segments.firstIndex(where: { $0.segmentID == candidate.target.segment.segmentID }) {
                    scriptDoc.segments[idx].audioArtifactID = candidate.asset.assetID
                    scriptDoc.segments[idx].status = decision.resultingStatus
                    try await store.saveScript(scriptDoc, projectID: projectID)
                    if decision.resultingStatus == SegmentStatus.verified {
                        totalVerified += 1
                    } else {
                        totalImproved += 1
                    }
                }
                details.append(RepairSegmentSummary(
                    chapterID: candidate.target.chapter.chapterID,
                    segmentID: candidate.target.segment.segmentID,
                    round: round,
                    seedUsed: repairSeed,
                    swapped: decision.acceptCandidate,
                    previousStatus: candidate.target.segment.status,
                    newStatus: decision.acceptCandidate ? decision.resultingStatus : candidate.target.segment.status,
                    previousAdjustedCER: candidate.target.previousAudit?.adjustedCER,
                    newAdjustedCER: qaOutcome.audit.adjustedCER,
                    decisionReason: decision.reason
                ))
            }
            if let peak = await runtime.measuredPeakBytes(for: asrEntry.modelID) {
                try? await store.updateMeasuredPeakBytes(modelID: asrEntry.modelID, peakBytes: peak)
            }
            await runtime.unloadAllIdle()
        }

        let remaining = try await listReviewQueue(projectID: projectID, chapterSpec: chapterSpec, includeApproved: false).count
        return BatchRepairReport(
            projectID: projectID,
            roundsExecuted: roundsExecuted,
            attemptedSegments: totalAttempted,
            verifiedCount: totalVerified,
            improvedCount: totalImproved,
            remainingNeedsReviewCount: remaining,
            details: details
        )
    }

    // MARK: - P3 Precision Cache Invalidation Plan & Chapter Memory Inspection

    public func planCacheInvalidation(
        projectID: String,
        chapterSpec: String? = nil,
        mainTTSModelID: String? = nil
    ) async throws -> CacheInvalidationPlan {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let catalog = try await store.loadCatalog(projectID: projectID) else {
            throw EngineSDKError.invalidInput("Character catalog missing for project \(projectID)")
        }
        let selectedChapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)
        let mainEntry = try await resolveModelEntry(
            explicitID: mainTTSModelID ?? project.options.preferredMainTTSModelID,
            kind: .tts,
            preferProviderContaining: "voxcpm2"
        )

        var scriptsByChapterID: [String: ScriptDocument] = [:]
        for ch in selectedChapters {
            if let script = try await store.loadScript(projectID: projectID, chapterID: ch.chapterID) {
                scriptsByChapterID[ch.chapterID] = script
            }
        }

        return try await CacheInvalidationPlanner.plan(
            projectID: projectID,
            chapters: selectedChapters,
            scriptsByChapterID: scriptsByChapterID,
            catalog: catalog,
            providerID: mainEntry.providerID,
            modelID: mainEntry.modelID,
            modelRevision: mainEntry.revision,
            store: store
        )
    }

    public func listChapterMemories(projectID: String, maxChapterNumber: Int? = nil) async throws -> [ChapterMemoryRecord] {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        return try await store.chapterMemoriesUpTo(projectID: projectID, maxChapterNumber: maxChapterNumber ?? Int.max)
    }

    func loadQualityAudits(projectID: String, chapterID: String? = nil) async throws -> (byAssetID: [String: SegmentQualityAudit], bySegmentID: [String: SegmentQualityAudit]) {
        let reportAssets = try await store.listAssets(projectID: projectID, kind: .qualityReport)
            .sorted { $0.createdAtISO8601 < $1.createdAtISO8601 }
        var byAsset: [String: SegmentQualityAudit] = [:]
        var bySeg: [String: SegmentQualityAudit] = [:]
        let decoder = JSONDecoder()
        for asset in reportAssets {
            if let chapterID, let recordedChapter = asset.provenance.chapterID, chapterID != recordedChapter { continue }
            if let data = try? await store.readVerifiedData(for: asset.assetID),
               let audit = try? decoder.decode(SegmentQualityAudit.self, from: data) {
                byAsset[audit.wavAssetID] = audit
                bySeg[audit.segmentID] = audit
            }
        }
        return (byAsset, bySeg)
    }
}
