import AudioCore
import Foundation

public struct SegmentRegenerationRequest: Sendable {
    public let projectID: String
    public let segmentID: String
    public let chapterNumber: Int
    public let providerID: String
    public let modelID: String
    public let modelRevision: String
    public let asrProviderID: String
    public let asrModelID: String
    public let asrModelRevision: String
    public let seed: UInt64
    public let directionOverride: SegmentDirection?
    public let allowNeedsReviewSwap: Bool
    public let thresholds: QualityThresholds
    public let expectedPitchHz: Double?

    public init(
        projectID: String,
        segmentID: String,
        chapterNumber: Int,
        providerID: String,
        modelID: String,
        modelRevision: String = "local",
        asrProviderID: String,
        asrModelID: String,
        asrModelRevision: String = "local",
        seed: UInt64 = 42,
        directionOverride: SegmentDirection? = nil,
        allowNeedsReviewSwap: Bool = false,
        thresholds: QualityThresholds = QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10),
        expectedPitchHz: Double? = nil
    ) {
        self.projectID = projectID
        self.segmentID = segmentID
        self.chapterNumber = chapterNumber
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.asrProviderID = asrProviderID
        self.asrModelID = asrModelID
        self.asrModelRevision = asrModelRevision
        self.seed = seed
        self.directionOverride = directionOverride
        self.allowNeedsReviewSwap = allowNeedsReviewSwap
        self.thresholds = thresholds
        self.expectedPitchHz = expectedPitchHz
    }
}

public struct SegmentRegenerationResult: Codable, Equatable, Sendable {
    public let projectID: String
    public let chapterID: String
    public let segmentID: String
    public let previousAssetID: String?
    public let candidateAssetID: String
    public let auditAssetID: String
    public let swapped: Bool
    public let previousStatus: SegmentStatus
    public let newStatus: SegmentStatus
    public let audit: SegmentQualityAudit

    public init(
        projectID: String,
        chapterID: String,
        segmentID: String,
        previousAssetID: String?,
        candidateAssetID: String,
        auditAssetID: String,
        swapped: Bool,
        previousStatus: SegmentStatus,
        newStatus: SegmentStatus,
        audit: SegmentQualityAudit
    ) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.previousAssetID = previousAssetID
        self.candidateAssetID = candidateAssetID
        self.auditAssetID = auditAssetID
        self.swapped = swapped
        self.previousStatus = previousStatus
        self.newStatus = newStatus
        self.audit = audit
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case previousAssetID = "previous_asset_id"
        case candidateAssetID = "candidate_asset_id"
        case auditAssetID = "audit_asset_id"
        case swapped
        case previousStatus = "previous_status"
        case newStatus = "new_status"
        case audit
    }
}

/// Regenerates a single script segment in isolation without touching any other segment's audio or state.
/// Preserves the previously qualified asset if the regenerated candidate fails audio integrity or QA.
public enum SingleSegmentRegenerator: Sendable {
    public static func regenerate(
        request: SegmentRegenerationRequest,
        store: any WorkspaceStoreProtocol,
        encodeWAV: @Sendable ([Float], Int) throws -> Data,
        synthesize: @Sendable (SpeechRequest) async throws -> SynthesizedAudio,
        transcribe: @Sendable (ASRRequest) async throws -> TranscriptResult
    ) async throws -> SegmentRegenerationResult {
        guard let located = try await store.locateSegment(projectID: request.projectID, segmentID: request.segmentID) else {
            throw SpeechKitError.segmentNotFound(request.segmentID)
        }
        guard var scriptDoc = try await store.loadScript(projectID: request.projectID, chapterID: located.chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == request.segmentID }) else {
            throw SpeechKitError.scriptNotFound(located.chapterID)
        }
        guard let catalog = try await store.loadCatalog(projectID: request.projectID) else {
            throw SpeechKitError.catalogNotFound(request.projectID)
        }

        let originalSegment = scriptDoc.segments[segIdx]
        let previousAssetID = originalSegment.audioArtifactID
        let previousStatus = originalSegment.status

        guard let card = catalog.resolveCharacter(namedOrAliased: originalSegment.speakerID) else {
            throw SpeechKitError.speakerNotFound(originalSegment.speakerID)
        }

        var workingSegment = originalSegment
        if let overrideDir = request.directionOverride {
            workingSegment.direction = overrideDir
        }

        let synthFP = card.synthesisFingerprint(
            chapterIndex: request.chapterNumber,
            spokenText: workingSegment.spokenText,
            direction: workingSegment.direction,
            providerID: request.providerID,
            modelID: request.modelID,
            modelRevision: request.modelRevision
        )

        if SpeechRequestBuilder.isNonVerbalPauseText(workingSegment.spokenText) {
            let pauseSR = 48_000
            let pauseSamples = SpeechRequestBuilder.nonVerbalPauseSamples(
                pauseAfterMs: workingSegment.direction.pauseAfterMs ?? 1_200,
                sampleRate: pauseSR
            )
            let wavData = try encodeWAV(pauseSamples, pauseSR)
            let candidateAsset = try await store.commitBytes(
                wavData,
                projectID: request.projectID,
                kind: .segmentWAV,
                fileExtension: "wav",
                sampleRate: pauseSR,
                frameCount: pauseSamples.count,
                provenance: AssetProvenance(
                    sourceDocumentRevision: workingSegment.sourceDocumentRevision,
                    chapterID: workingSegment.chapterID,
                    segmentID: workingSegment.segmentID,
                    characterID: workingSegment.speakerID,
                    scriptRevision: workingSegment.scriptRevision,
                    providerID: SpeechRequestBuilder.nonVerbalPauseProviderID,
                    modelID: "builtin-pause",
                    modelRevision: "v1",
                    inputFingerprint: synthFP
                )
            )
            let audit = SegmentQualityAudit(
                segmentID: workingSegment.segmentID,
                wavAssetID: candidateAsset.assetID,
                rawTranscript: "",
                rawCER: 0,
                adjustedCER: 0,
                exemptions: [],
                nonExemptSubstitutions: 0,
                deletions: 0,
                insertions: 0,
                rmsDBFS: -120.0,
                verdictLabel: "passed",
                failureReasons: [],
                ruleVersion: SpeechKitInfo.qaRuleVersion
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let auditAsset = try await store.commitBytes(
                try enc.encode(audit),
                projectID: request.projectID,
                kind: .qualityReport,
                fileExtension: "json",
                sampleRate: nil,
                frameCount: nil,
                provenance: AssetProvenance(
                    chapterID: workingSegment.chapterID,
                    segmentID: workingSegment.segmentID,
                    providerID: SpeechRequestBuilder.nonVerbalPauseProviderID,
                    modelID: "builtin-pause",
                    modelRevision: "v1",
                    inputFingerprint: synthFP
                )
            )
            scriptDoc.segments[segIdx].direction = workingSegment.direction
            scriptDoc.segments[segIdx].audioArtifactID = candidateAsset.assetID
            scriptDoc.segments[segIdx].status = .verified
            try await store.saveScript(scriptDoc, projectID: request.projectID)
            return SegmentRegenerationResult(
                projectID: request.projectID,
                chapterID: located.chapterID,
                segmentID: workingSegment.segmentID,
                previousAssetID: previousAssetID,
                candidateAssetID: candidateAsset.assetID,
                auditAssetID: auditAsset.assetID,
                swapped: true,
                previousStatus: previousStatus,
                newStatus: .verified,
                audit: audit
            )
        }

        var verifiedAnchorPath: String?
        if let anchor = card.timbreAnchor {
            let intact = try await store.verifyAssetIntegrity(assetID: anchor.assetID)
            guard intact,
                  let record = try await store.asset(id: anchor.assetID),
                  record.fileSHA256 == anchor.fileSHA256 else {
                throw SpeechKitError.corruptedTimbreAnchor(characterID: card.characterID, assetID: anchor.assetID)
            }
            verifiedAnchorPath = try await store.resolveFileURL(for: anchor.assetID).path
        }

        let speechRequest = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
            segment: workingSegment,
            card: card,
            chapterNumber: request.chapterNumber,
            providerID: request.providerID,
            verifiedAnchorPath: verifiedAnchorPath,
            seed: request.seed
        )

        let audio = try await synthesize(speechRequest)
        let wavData = try encodeWAV(audio.pcmSamples, audio.sampleRate)
        let candidateAsset = try await store.commitBytes(
            wavData,
            projectID: request.projectID,
            kind: .segmentWAV,
            fileExtension: "wav",
            sampleRate: audio.sampleRate,
            frameCount: audio.pcmSamples.count,
            provenance: AssetProvenance(
                sourceDocumentRevision: workingSegment.sourceDocumentRevision,
                chapterID: workingSegment.chapterID,
                segmentID: workingSegment.segmentID,
                characterID: workingSegment.speakerID,
                scriptRevision: workingSegment.scriptRevision,
                providerID: request.providerID,
                modelID: request.modelID,
                modelRevision: request.modelRevision,
                inputFingerprint: synthFP
            )
        )

        let integrity = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
        let transcript = try await transcribe(ASRRequest(
            pcmSamples: audio.pcmSamples,
            sampleRate: audio.sampleRate,
            parameters: ["language": "Chinese"]
        ))

        let candidatePitchHz: Double? = (request.expectedPitchHz != nil)
            ? AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
            : nil
        let qaOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: workingSegment.segmentID,
            wavAssetID: candidateAsset.assetID,
            referenceText: workingSegment.spokenText,
            hypothesisTranscript: transcript.text,
            integrity: integrity,
            catalog: catalog,
            thresholds: request.thresholds,
            expectedPitchHz: request.expectedPitchHz,
            candidatePitchHz: candidatePitchHz
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let auditBytes = try enc.encode(qaOutcome.audit)
        let auditAsset = try await store.commitBytes(
            auditBytes,
            projectID: request.projectID,
            kind: .qualityReport,
            fileExtension: "json",
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(
                chapterID: workingSegment.chapterID,
                segmentID: workingSegment.segmentID,
                providerID: request.asrProviderID,
                modelID: request.asrModelID,
                modelRevision: request.asrModelRevision,
                inputFingerprint: synthFP
            )
        )

        let shouldSwap: Bool
        let candidateStatus: SegmentStatus
        switch qaOutcome.verdict {
        case .passed:
            shouldSwap = true
            candidateStatus = .verified
        case .needsReview:
            // Preserve existing qualified/reviewable asset unless no valid asset existed yet or caller explicitly opted in.
            shouldSwap = request.allowNeedsReviewSwap || previousAssetID == nil || previousStatus == .pending || previousStatus == .failed
            candidateStatus = .needsReview
        case .retryableFailure:
            // Never overwrite a previously qualified asset with broken/silent/truncated audio!
            shouldSwap = false
            candidateStatus = previousStatus
        }

        if shouldSwap {
            scriptDoc.segments[segIdx].direction = workingSegment.direction
            scriptDoc.segments[segIdx].audioArtifactID = candidateAsset.assetID
            scriptDoc.segments[segIdx].status = candidateStatus
            try await store.saveScript(scriptDoc, projectID: request.projectID)
        }

        return SegmentRegenerationResult(
            projectID: request.projectID,
            chapterID: located.chapterID,
            segmentID: workingSegment.segmentID,
            previousAssetID: previousAssetID,
            candidateAssetID: candidateAsset.assetID,
            auditAssetID: auditAsset.assetID,
            swapped: shouldSwap,
            previousStatus: previousStatus,
            newStatus: shouldSwap ? candidateStatus : previousStatus,
            audit: qaOutcome.audit
        )
    }
}
