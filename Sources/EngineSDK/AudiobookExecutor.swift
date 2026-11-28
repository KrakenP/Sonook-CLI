import AudioCore
import AudioRenderKit
import Foundation
import ModelRuntime
import SpeechKit
import StorageKit
import WorkflowKit

/// Multi-chapter formal P2 audiobook DAG executor (`workflowKind == "audiobook-mlx"`).
/// Coordinates VoiceDesign anchor auditioning, 48 kHz locked-timbre VoxCPM2 synthesis
/// (layering chapter-indexed `VoiceDeliveryStage`s), and proper-noun tone-aware dry-speech ASR QA.
public actor AudiobookMLXNodeExecutor: NodeExecutorProtocol {
    private let store: any WorkspaceStoreProtocol
    private let runtime: ModelResourceManager
    private let ignoreStopHook: Bool
    private let stderrLog: @Sendable (String) -> Void
    private let onEvent: (@Sendable (BuildProgressEvent) -> Void)?
    private struct SegmentProgress {
        let total: Int
        var completed: Set<String>

        init(nodes: [JobNodeRecord], kind: String) {
            let segments = nodes.filter { $0.kind == kind }
            total = segments.count
            completed = Set(segments.filter { $0.status == .completed || $0.status == .needsReview }.map(\.nodeID))
        }
    }
    private var ttsProgress: SegmentProgress
    private var asrProgress: SegmentProgress
    private var executedThisSession: Int = 0
    private var cachedAnchorPitchHz: [String: Double] = [:]

    public init(
        store: any WorkspaceStoreProtocol,
        runtime: ModelResourceManager,
        ignoreStopHook: Bool = false,
        stderrLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(store: store, runtime: runtime, ignoreStopHook: ignoreStopHook, stderrLog: stderrLog,
                  nodes: [], onEvent: nil)
    }

    init(
        store: any WorkspaceStoreProtocol, runtime: ModelResourceManager, ignoreStopHook: Bool,
        stderrLog: @escaping @Sendable (String) -> Void,
        nodes: [JobNodeRecord], onEvent: (@Sendable (BuildProgressEvent) -> Void)?
    ) {
        self.store = store
        self.runtime = runtime
        self.ignoreStopHook = ignoreStopHook
        self.stderrLog = stderrLog
        self.onEvent = onEvent
        let countedNodes = onEvent == nil ? [] : nodes
        ttsProgress = SegmentProgress(nodes: countedNodes, kind: "mlx_book_tts_segment")
        asrProgress = SegmentProgress(nodes: countedNodes, kind: "mlx_book_asr_segment")
    }

    public func execute(node: JobNodeRecord, lease: NodeLease, job: JobRecord) async throws -> NodeExecutionOutcome {
        guard let cfg = try? JSONDecoder().decode(AudiobookMLXJobConfig.self, from: Data(job.configJSON.utf8)) else {
            throw NodeExecutionError.permanent("Invalid AudiobookMLXJobConfig JSON on job \(job.jobID)")
        }
        let payload = (try? JSONSerialization.jsonObject(with: Data(node.payloadJSON.utf8)) as? [String: Any]) ?? [:]

        if !ignoreStopHook, let limit = cfg.stopAfterCompletedNodes, executedThisSession >= limit {
            _ = try await store.requestCancel(jobID: job.jobID, now: Date())
            throw NodeExecutionError.cancelled
        }

        let outcome: NodeExecutionOutcome
        switch node.kind {
        case "mlx_book_audition_cast":
            outcome = try await runAuditionCast(node: node, job: job, cfg: cfg)
        case "mlx_book_tts_segment", "mlx_book_asr_segment":
            let chapterID = payload["chapter_id"] as? String ?? ""
            let segmentID = payload["segment_id"] as? String ?? ""
            let isTTS = node.kind == "mlx_book_tts_segment"
            let phase = isTTS ? "tts" : "asr"
            let label = isTTS ? "TTS 合成" : "ASR 质检"
            func emitSegment(_ counts: SegmentProgress, message: String) {
                onEvent?(.init(stage: .synthesizing, subphase: phase, completed: counts.completed.count,
                               total: counts.total, message: "\(label) · \(segmentID) \(message)"))
            }
            emitSegment(isTTS ? ttsProgress : asrProgress, message: "开始")
            if isTTS {
                outcome = try await runTTSSegment(node: node, job: job, cfg: cfg, chapterID: chapterID, segmentID: segmentID)
                if onEvent != nil { ttsProgress.completed.insert(node.nodeID) }
                emitSegment(ttsProgress, message: "完成")
            } else {
                outcome = try await runASRSegment(node: node, job: job, cfg: cfg, chapterID: chapterID, segmentID: segmentID)
                if onEvent != nil { asrProgress.completed.insert(node.nodeID) }
                emitSegment(asrProgress, message: "完成")
            }
        case "mlx_stage_barrier":
            await runtime.unloadAllIdle()
            outcome = .completed(outputAssetID: nil, outputPayloadJSON: "{\"barrier\":\"passed\"}")
        case "mlx_book_auto_repair_round":
            let round = payload["round"] as? Int ?? 1
            outcome = try await runAutoRepairRound(node: node, job: job, cfg: cfg, round: round)
        default:
            throw NodeExecutionError.permanent("Unsupported audiobook-mlx node kind: \(node.kind)")
        }

        executedThisSession += 1
        return outcome
    }

    private func requireModel(id: String, kind: ModelKind) async throws -> ModelRegistryEntry {
        guard let entry = try await store.model(id: id) else {
            throw NodeExecutionError.permanent("Model '\(id)' is not registered. Register it via `sonook model register`.")
        }
        guard entry.kind == kind else {
            throw NodeExecutionError.permanent("Model '\(id)' has kind \(entry.kind.rawValue), expected \(kind.rawValue)")
        }
        return entry
    }

    private func runAuditionCast(node: JobNodeRecord, job: JobRecord, cfg: AudiobookMLXJobConfig) async throws -> NodeExecutionOutcome {
        guard let catalog = try await store.loadCatalog(projectID: job.projectID) else {
            throw NodeExecutionError.permanent("Character voice catalog missing; run `sonook analyze` first.")
        }
        let vdEntry = try await requireModel(id: cfg.auditionTTSModelID, kind: .tts)
        let iso = ISO8601DateFormatter()

        var updatedCards: [CharacterVoiceCard] = []
        var generatedCount = 0
        var reusedCount = 0

        for var card in catalog.cards {
            func auditionProgress(_ message: String) {
                onEvent?(.init(stage: .auditioning, completed: updatedCards.count, total: catalog.cards.count,
                               message: "\(card.canonicalName) · \(message)"))
            }
            auditionProgress("开始试音")
            if let existingAnchor = card.timbreAnchor,
               (try? await store.verifyAssetIntegrity(assetID: existingAnchor.assetID)) == true,
               let rec = try? await store.asset(id: existingAnchor.assetID),
               rec.fileSHA256 == existingAnchor.fileSHA256 {
                reusedCount += 1
                updatedCards.append(card)
                auditionProgress("已复用试音")
                continue
            }

            let (req, auditionText, designPrompt) = SpeechRequestBuilder.buildAuditionRequest(for: card, seed: cfg.seed)
            stderrLog("[DAG][\(node.nodeID)] Auditioning \(card.characterID) (\(card.canonicalName)) via \(vdEntry.modelID)...")
            let audio = try await runtime.withTTSLease(entry: vdEntry, priority: node.priority) { provider in
                try await provider.synthesize(req)
            }
            let wavData = try PCMCodec.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
            let asset = try await store.commitBytes(
                wavData,
                projectID: job.projectID,
                kind: .voiceAudition,
                fileExtension: "wav",
                sampleRate: audio.sampleRate,
                frameCount: audio.pcmSamples.count,
                provenance: AssetProvenance(
                    characterID: card.characterID,
                    providerID: vdEntry.providerID,
                    modelID: vdEntry.modelID,
                    modelRevision: vdEntry.revision,
                    inputFingerprint: node.inputFingerprint
                )
            )
            card.timbreAnchor = VoiceTimbreAnchor(
                anchorID: "anc_\(card.characterID)_v1",
                assetID: asset.assetID,
                fileSHA256: asset.fileSHA256,
                generatorProviderID: vdEntry.providerID,
                generatorModelID: vdEntry.modelID,
                designPrompt: designPrompt,
                auditionText: auditionText,
                sampleRate: audio.sampleRate,
                createdAtISO8601: iso.string(from: Date())
            )
            generatedCount += 1
            updatedCards.append(card)
            auditionProgress("试音完成")
        }

        if let peak = await runtime.measuredPeakBytes(for: vdEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: vdEntry.modelID, peakBytes: peak)
        }

        let mergedCatalog = try catalog.merging(incomingCards: updatedCards)
        try await store.saveCatalog(mergedCatalog)
        stderrLog("[DAG][\(node.nodeID)] Voice anchors ready (generated=\(generatedCount), reused=\(reusedCount)).")
        return .completed(outputAssetID: nil, outputPayloadJSON: "{\"generated\":\(generatedCount),\"reused\":\(reusedCount)}")
    }

    private func runTTSSegment(
        node: JobNodeRecord,
        job: JobRecord,
        cfg: AudiobookMLXJobConfig,
        chapterID: String,
        segmentID: String
    ) async throws -> NodeExecutionOutcome {
        guard let catalog = try await store.loadCatalog(projectID: job.projectID),
              var scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == segmentID }) else {
            throw NodeExecutionError.permanent("Missing catalog or script segment \(segmentID) in \(chapterID)")
        }
        let seg = scriptDoc.segments[segIdx]
        guard let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) else {
            throw NodeExecutionError.permanent("Unknown speaker \(seg.speakerID) for segment \(segmentID)")
        }

        let mainEntry = try await requireModel(id: cfg.mainTTSModelID, kind: .tts)
        let chapterNum = cfg.chapterNumbersByID[chapterID] ?? 1

        let synthFP = card.synthesisFingerprint(
            chapterIndex: chapterNum,
            spokenText: seg.spokenText,
            direction: seg.direction,
            providerID: mainEntry.providerID,
            modelID: mainEntry.modelID,
            modelRevision: mainEntry.revision
        )

        // Reuse existing intact WAV if synthesis fingerprint matches (verified, already synthesized, or regenerated needs_review).
        if (seg.status == .verified || seg.status == .synthesized || seg.status == .needsReview),
           let existingAssetID = seg.audioArtifactID,
           let existingAsset = try await store.asset(id: existingAssetID),
           existingAsset.provenance.inputFingerprint == synthFP,
           try await store.verifyAssetIntegrity(assetID: existingAssetID) {
            stderrLog("[DAG][\(node.nodeID)] Reusing cached WAV (\(seg.status.rawValue)) for \(segmentID) -> \(existingAssetID)")
            return .completed(outputAssetID: existingAssetID, outputPayloadJSON: "{\"asset_id\":\"\(existingAssetID)\",\"reused\":true}")
        }

        // Pure punctuation / scene-break lines (e.g. "……" or "***") become deterministic silent pause WAVs instead of sending punctuation to TTS.
        if SpeechRequestBuilder.isNonVerbalPauseText(seg.spokenText) {
            let pauseSR = 48_000
            let pauseSamples = SpeechRequestBuilder.nonVerbalPauseSamples(
                pauseAfterMs: seg.direction.pauseAfterMs ?? 1_200,
                sampleRate: pauseSR
            )
            let wavData = try PCMCodec.encodeWAVData(samples: pauseSamples, sampleRate: pauseSR)
            let asset = try await store.commitBytes(
                wavData,
                projectID: job.projectID,
                kind: .segmentWAV,
                fileExtension: "wav",
                sampleRate: pauseSR,
                frameCount: pauseSamples.count,
                provenance: AssetProvenance(
                    sourceDocumentRevision: seg.sourceDocumentRevision,
                    chapterID: seg.chapterID,
                    segmentID: seg.segmentID,
                    characterID: seg.speakerID,
                    scriptRevision: seg.scriptRevision,
                    providerID: SpeechRequestBuilder.nonVerbalPauseProviderID,
                    modelID: "builtin-pause",
                    modelRevision: "v1",
                    inputFingerprint: synthFP
                )
            )
            scriptDoc.segments[segIdx].audioArtifactID = asset.assetID
            scriptDoc.segments[segIdx].status = .synthesized
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            let dur = Double(pauseSamples.count) / Double(pauseSR)
            stderrLog(String(format: "[DAG][%@] %@ non-verbal pause %.2fs @ %dHz -> %@", node.nodeID, seg.segmentID, dur, pauseSR, asset.assetID))
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"asset_id\":\"\(asset.assetID)\",\"duration\":\(dur),\"non_verbal_pause\":true}")
        }

        var verifiedAnchorPath: String?
        if mainEntry.providerID == MLXVoxCPM2Provider.providerIdentifier {
            let (_, anchorURL) = try await ModelResourceManager.resolveVerifiedTimbreAnchorURL(for: card, artifactStore: store)
            verifiedAnchorPath = anchorURL.path
        }

        let attemptSeed = cfg.seed &+ UInt64(max(0, node.attemptCount - 1))
        let speechReq: SpeechRequest
        do {
            speechReq = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
                segment: seg,
                card: card,
                chapterNumber: chapterNum,
                providerID: mainEntry.providerID,
                verifiedAnchorPath: verifiedAnchorPath,
                seed: attemptSeed
            )
        } catch {
            throw NodeExecutionError.unsupportedCapability(error.localizedDescription)
        }

        let audio = try await runtime.withTTSLease(entry: mainEntry, priority: node.priority) { provider in
            try await provider.synthesize(speechReq)
        }
        if let peak = await runtime.measuredPeakBytes(for: mainEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: mainEntry.modelID, peakBytes: peak)
        }

        let integrity = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
        if integrity.isSilent || integrity.isTruncated {
            throw NodeExecutionError.retryable("Synthesized segment \(segmentID) failed basic integrity check")
        }

        let wavData = try PCMCodec.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
        let asset = try await store.commitBytes(
            wavData,
            projectID: job.projectID,
            kind: .segmentWAV,
            fileExtension: "wav",
            sampleRate: audio.sampleRate,
            frameCount: audio.pcmSamples.count,
            provenance: AssetProvenance(
                sourceDocumentRevision: seg.sourceDocumentRevision,
                chapterID: seg.chapterID,
                segmentID: seg.segmentID,
                characterID: seg.speakerID,
                scriptRevision: seg.scriptRevision,
                providerID: mainEntry.providerID,
                modelID: mainEntry.modelID,
                modelRevision: mainEntry.revision,
                inputFingerprint: synthFP
            )
        )

        scriptDoc.segments[segIdx].audioArtifactID = asset.assetID
        scriptDoc.segments[segIdx].status = .synthesized
        try await store.saveScript(scriptDoc, projectID: job.projectID)

        let dur = Double(audio.pcmSamples.count) / Double(audio.sampleRate)
        stderrLog(String(format: "[DAG][%@] %@ (%@) %.2fs @ %dHz RTF=%.2f -> %@", node.nodeID, seg.segmentID, card.canonicalName, dur, audio.sampleRate, audio.metrics.rtf ?? 0, asset.assetID))
        return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"asset_id\":\"\(asset.assetID)\",\"duration\":\(dur),\"rtf\":\(audio.metrics.rtf ?? 0)}")
    }

    private func runASRSegment(
        node: JobNodeRecord,
        job: JobRecord,
        cfg: AudiobookMLXJobConfig,
        chapterID: String,
        segmentID: String
    ) async throws -> NodeExecutionOutcome {
        guard var scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == segmentID }),
              let wavAssetID = scriptDoc.segments[segIdx].audioArtifactID else {
            throw NodeExecutionError.permanent("Missing synthesized WAV asset for ASR segment \(segmentID)")
        }
        let catalog = try await store.loadCatalog(projectID: job.projectID)

        guard try await store.verifyAssetIntegrity(assetID: wavAssetID) else {
            throw NodeExecutionError.permanent("Segment WAV asset \(wavAssetID) failed SHA-256 verification before ASR")
        }
        let seg = scriptDoc.segments[segIdx]
        let reviewReasons: Set<String> = ["unresolved_dialogue_speaker", "vocative_speaker_conflict", "low_confidence_attribution"]
        let hasAttributionReviewFlag = seg.attributionEvidence.contains {
            $0.hasPrefix("needs_review:") || reviewReasons.contains($0)
        }

        // If TTS reused an already-verified intact WAV with no unresolved attribution review flag, skip redundant ASR!
        if seg.status == .verified && !hasAttributionReviewFlag {
            stderrLog("[DAG][\(node.nodeID)] Reusing already-verified segment \(seg.segmentID) -> \(wavAssetID)")
            let payload = try JSONSerialization.data(withJSONObject: ["segment_id": seg.segmentID, "reused": true, "verdict": "passed"])
            return .completed(outputAssetID: wavAssetID, outputPayloadJSON: String(decoding: payload, as: UTF8.self))
        }

        // Non-verbal pause WAVs generated by builtin pause synth do not require ASR.
        if SpeechRequestBuilder.isNonVerbalPauseText(seg.spokenText),
           let wavAsset = try await store.asset(id: wavAssetID),
           wavAsset.provenance.providerID == SpeechRequestBuilder.nonVerbalPauseProviderID {
            let audit = SegmentQualityAudit(
                segmentID: seg.segmentID,
                wavAssetID: wavAssetID,
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
            let auditBytes = try enc.encode(audit)
            let auditAsset = try await store.commitBytes(
                auditBytes,
                projectID: job.projectID,
                kind: .qualityReport,
                fileExtension: "json",
                sampleRate: nil,
                frameCount: nil,
                provenance: AssetProvenance(
                    chapterID: seg.chapterID,
                    segmentID: seg.segmentID,
                    providerID: SpeechRequestBuilder.nonVerbalPauseProviderID,
                    modelID: "builtin-pause",
                    modelRevision: "v1",
                    inputFingerprint: node.inputFingerprint
                )
            )
            scriptDoc.segments[segIdx].status = .verified
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            stderrLog("[DAG][\(node.nodeID)] \(seg.segmentID) non-verbal pause verified (skipped ASR)")
            return .completed(outputAssetID: auditAsset.assetID, outputPayloadJSON: String(decoding: auditBytes, as: UTF8.self))
        }

        let wavURL = try await store.resolveFileURL(for: wavAssetID)
        let (samples, sr) = try PCMCodec.readMonoSamples(from: wavURL)
        let integrity = AudioIntegrityChecker.analyze(pcmSamples: samples, sampleRate: sr)

        let asrEntry = try await requireModel(id: cfg.asrModelID, kind: .asr)
        let transcript = try await runtime.withASRLease(entry: asrEntry, priority: node.priority) { provider in
            try await provider.transcribe(ASRRequest(pcmSamples: samples, sampleRate: sr, parameters: ["language": "Chinese"]))
        }
        if let peak = await runtime.measuredPeakBytes(for: asrEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: asrEntry.modelID, peakBytes: peak)
        }

        let expectedPitchHz: Double? = (seg.speakerID == "char_narrator")
            ? await resolveNarratorAnchorPitchHz(catalog: catalog)
            : nil
        let candidatePitchHz: Double? = (expectedPitchHz != nil)
            ? AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: samples, sampleRate: sr)
            : nil

        let qaOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: seg.segmentID,
            wavAssetID: wavAssetID,
            referenceText: seg.spokenText,
            hypothesisTranscript: transcript.text,
            integrity: integrity,
            catalog: catalog,
            expectedPitchHz: expectedPitchHz,
            candidatePitchHz: candidatePitchHz
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let auditBytes = try enc.encode(qaOutcome.audit)
        let auditAsset = try await store.commitBytes(
            auditBytes,
            projectID: job.projectID,
            kind: .qualityReport,
            fileExtension: "json",
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(
                chapterID: seg.chapterID,
                segmentID: seg.segmentID,
                providerID: asrEntry.providerID,
                modelID: asrEntry.modelID,
                modelRevision: asrEntry.revision,
                inputFingerprint: node.inputFingerprint
            )
        )

        let exemptNote = qaOutcome.audit.exemptions.isEmpty ? "" : " (exempt=\(qaOutcome.audit.exemptions.count))"
        switch qaOutcome.verdict {
        case .passed:
            if hasAttributionReviewFlag {
                scriptDoc.segments[segIdx].status = .needsReview
                try await store.saveScript(scriptDoc, projectID: job.projectID)
                stderrLog(String(format: "[DAG][%@] %@ ASR passed (adj=%.2f%%) but kept needs_review due to speaker attribution flag", node.nodeID, seg.segmentID, qaOutcome.audit.adjustedCER * 100))
                return .needsReview(
                    outputAssetID: auditAsset.assetID,
                    outputPayloadJSON: String(decoding: auditBytes, as: UTF8.self),
                    reasons: [],
                    message: "Unresolved speaker attribution review required"
                )
            }
            scriptDoc.segments[segIdx].status = .verified
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            stderrLog(String(format: "[DAG][%@] %@ ASR raw=%.2f%% adj=%.2f%%%@ -> passed", node.nodeID, seg.segmentID, qaOutcome.audit.rawCER * 100, qaOutcome.audit.adjustedCER * 100, exemptNote))
            return .completed(outputAssetID: auditAsset.assetID, outputPayloadJSON: String(decoding: auditBytes, as: UTF8.self))
        case .needsReview(let reasons):
            scriptDoc.segments[segIdx].status = .needsReview
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            stderrLog(String(format: "[DAG][%@] %@ ASR raw=%.2f%% adj=%.2f%%%@ -> needs_review (%@)", node.nodeID, seg.segmentID, qaOutcome.audit.rawCER * 100, qaOutcome.audit.adjustedCER * 100, exemptNote, reasons.map(\.rawValue).joined(separator: ",")))
            return .needsReview(
                outputAssetID: auditAsset.assetID,
                outputPayloadJSON: String(decoding: auditBytes, as: UTF8.self),
                reasons: reasons,
                message: String(format: "adjusted CER %.2f%% (%@)", qaOutcome.audit.adjustedCER * 100, reasons.map(\.rawValue).joined(separator: ","))
            )
        case .retryableFailure(let reasons):
            scriptDoc.segments[segIdx].status = .failed
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            throw NodeExecutionError.retryable("Audio integrity failure: \(reasons.map(\.rawValue).joined(separator: ","))")
        }
    }

    /// Stage 4 Post-ASR Batch Auto-Repair:
    /// Unloads ASR, synthesizes ONLY segments with recoverable ASR/audio defects using deterministic shifted seeds,
    /// unloads TTS, loads ASR once to verify those candidates, and promotes verified/strictly-better takes without
    /// ever touching already-verified segments or overwriting intact audio with broken takes.
    private func runAutoRepairRound(
        node: JobNodeRecord,
        job: JobRecord,
        cfg: AudiobookMLXJobConfig,
        round: Int
    ) async throws -> NodeExecutionOutcome {
        guard let catalog = try await store.loadCatalog(projectID: job.projectID) else {
            throw NodeExecutionError.permanent("Character voice catalog missing during auto-repair")
        }
        let policy = SegmentAutoRepairPolicy(maxRepairRounds: max(1, cfg.maxRepairRounds))
        let repairSeed = policy.seed(forBaseSeed: cfg.seed, round: round)

        // Index quality audits by active wavAssetID (with segmentID fallback) so rejected repair takes never shadow the active WAV's audit.
        let (auditsByAssetID, latestAuditsBySegID) = try await loadQualityAudits(projectID: job.projectID)

        struct RepairTarget {
            let chapterID: String
            let chapterNumber: Int
            let segment: ScriptSegment
            let card: CharacterVoiceCard
            let previousAudit: SegmentQualityAudit?
        }

        var targets: [RepairTarget] = []
        for chapterID in cfg.chapterIDs {
            guard let script = try await store.loadScript(projectID: job.projectID, chapterID: chapterID) else { continue }
            let chapterNum = cfg.chapterNumbersByID[chapterID] ?? 1
            for seg in script.segments {
                let audit = seg.audioArtifactID.flatMap { auditsByAssetID[$0] } ?? latestAuditsBySegID[seg.segmentID]
                guard AutoRepairCandidateEvaluator.shouldAutoRepair(segment: seg, latestAudit: audit),
                      let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) else {
                    continue
                }
                targets.append(RepairTarget(
                    chapterID: chapterID,
                    chapterNumber: chapterNum,
                    segment: seg,
                    card: card,
                    previousAudit: audit
                ))
            }
        }

        func repairProgress(completed: Int, message: String) {
            onEvent?(.init(stage: .synthesizing, subphase: "repair", completed: completed, total: cfg.maxRepairRounds,
                           message: "修复第 \(round)/\(cfg.maxRepairRounds) 轮 · \(targets.count) 个片段 · \(message)"))
        }
        repairProgress(completed: round - 1, message: "开始")
        if targets.isEmpty {
            repairProgress(completed: round, message: "无需修复")
            stderrLog("[DAG][\(node.nodeID)] Auto-repair round \(round): 0 segments need ASR repair (skipped model loads).")
            return .completed(outputAssetID: nil, outputPayloadJSON: "{\"round\":\(round),\"attempted\":0,\"repaired\":0,\"improved\":0}")
        }

        // Phase A: Unload ASR and synthesize ONLY failing targets in one batch with main TTS.
        await runtime.unloadAllIdle()
        let mainEntry = try await requireModel(id: cfg.mainTTSModelID, kind: .tts)
        stderrLog("[DAG][\(node.nodeID)] Auto-repair round \(round) (seed=\(repairSeed)): synthesizing \(targets.count) segment(s) with \(mainEntry.modelID)...")

        struct SynthesizedCandidate {
            let target: RepairTarget
            let asset: AssetRecord
            let samples: [Float]
            let sampleRate: Int
        }

        var candidates: [SynthesizedCandidate] = []
        for target in targets {
            var verifiedAnchorPath: String?
            if mainEntry.providerID == MLXVoxCPM2Provider.providerIdentifier {
                let (_, anchorURL) = try await ModelResourceManager.resolveVerifiedTimbreAnchorURL(for: target.card, artifactStore: store)
                verifiedAnchorPath = anchorURL.path
            }
            let speechReq = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
                segment: target.segment,
                card: target.card,
                chapterNumber: target.chapterNumber,
                providerID: mainEntry.providerID,
                verifiedAnchorPath: verifiedAnchorPath,
                seed: repairSeed
            )
            let synthFP = target.card.synthesisFingerprint(
                chapterIndex: target.chapterNumber,
                spokenText: target.segment.spokenText,
                direction: target.segment.direction,
                providerID: mainEntry.providerID,
                modelID: mainEntry.modelID,
                modelRevision: mainEntry.revision
            )
            let audio = try await runtime.withTTSLease(entry: mainEntry, priority: node.priority) { provider in
                try await provider.synthesize(speechReq)
            }
            let wavData = try PCMCodec.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
            let candidateAsset = try await store.commitBytes(
                wavData,
                projectID: job.projectID,
                kind: .segmentWAV,
                fileExtension: "wav",
                sampleRate: audio.sampleRate,
                frameCount: audio.pcmSamples.count,
                provenance: AssetProvenance(
                    sourceDocumentRevision: target.segment.sourceDocumentRevision,
                    chapterID: target.chapterID,
                    segmentID: target.segment.segmentID,
                    characterID: target.segment.speakerID,
                    scriptRevision: target.segment.scriptRevision,
                    providerID: mainEntry.providerID,
                    modelID: mainEntry.modelID,
                    modelRevision: mainEntry.revision,
                    inputFingerprint: synthFP
                )
            )
            candidates.append(SynthesizedCandidate(
                target: target,
                asset: candidateAsset,
                samples: audio.pcmSamples,
                sampleRate: audio.sampleRate
            ))
        }
        if let peak = await runtime.measuredPeakBytes(for: mainEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: mainEntry.modelID, peakBytes: peak)
        }

        // Phase B: Unload TTS, load ASR once, verify all repair candidates and promote strictly better / verified takes.
        await runtime.unloadAllIdle()
        let asrEntry = try await requireModel(id: cfg.asrModelID, kind: .asr)
        var verifiedCount = 0
        var improvedCount = 0
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for candidate in candidates {
            let integrity = AudioIntegrityChecker.analyze(pcmSamples: candidate.samples, sampleRate: candidate.sampleRate)
            let transcript = try await runtime.withASRLease(entry: asrEntry, priority: node.priority) { provider in
                try await provider.transcribe(ASRRequest(pcmSamples: candidate.samples, sampleRate: candidate.sampleRate, parameters: ["language": "Chinese"]))
            }
            let expectedPitchHz: Double? = (candidate.target.segment.speakerID == "char_narrator")
                ? await resolveNarratorAnchorPitchHz(catalog: catalog)
                : nil
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
            let auditBytes = try enc.encode(qaOutcome.audit)
            _ = try await store.commitBytes(
                auditBytes,
                projectID: job.projectID,
                kind: .qualityReport,
                fileExtension: "json",
                sampleRate: nil,
                frameCount: nil,
                provenance: AssetProvenance(
                    chapterID: candidate.target.chapterID,
                    segmentID: candidate.target.segment.segmentID,
                    providerID: asrEntry.providerID,
                    modelID: asrEntry.modelID,
                    modelRevision: asrEntry.revision,
                    inputFingerprint: "\(node.inputFingerprint)|\(candidate.target.segment.segmentID)|r\(round)"
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
               var scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: candidate.target.chapterID),
               let idx = scriptDoc.segments.firstIndex(where: { $0.segmentID == candidate.target.segment.segmentID }) {
                scriptDoc.segments[idx].audioArtifactID = candidate.asset.assetID
                scriptDoc.segments[idx].status = decision.resultingStatus
                try await store.saveScript(scriptDoc, projectID: job.projectID)
                if decision.resultingStatus == .verified {
                    verifiedCount += 1
                } else {
                    improvedCount += 1
                }
            }
            stderrLog(String(
                format: "[DAG][%@] Repair r%d %@: swap=%@ %@->%@ adjCER=%.2f%% (%@)",
                node.nodeID, round, candidate.target.segment.segmentID, String(decision.acceptCandidate),
                candidate.target.segment.status.rawValue, decision.resultingStatus.rawValue,
                qaOutcome.audit.adjustedCER * 100, decision.reason
            ))
        }
        if let peak = await runtime.measuredPeakBytes(for: asrEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: asrEntry.modelID, peakBytes: peak)
        }
        await runtime.unloadAllIdle()

        repairProgress(completed: round, message: "已修好 \(verifiedCount) 个")
        return .completed(
            outputAssetID: nil,
            outputPayloadJSON: "{\"round\":\(round),\"seed\":\(repairSeed),\"attempted\":\(candidates.count),\"repaired\":\(verifiedCount),\"improved\":\(improvedCount)}"
        )
    }

    private func resolveNarratorAnchorPitchHz(catalog: CharacterVoiceCatalog?) async -> Double? {
        guard let anchor = catalog?.resolveCharacter(namedOrAliased: "char_narrator")?.timbreAnchor else { return nil }
        if let cached = cachedAnchorPitchHz[anchor.assetID] { return cached }
        guard let url = try? await store.resolveFileURL(for: anchor.assetID),
              let (samples, sr) = try? PCMCodec.readMonoSamples(from: url),
              let f0 = AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: samples, sampleRate: sr) else {
            return nil
        }
        cachedAnchorPitchHz[anchor.assetID] = f0
        return f0
    }

    private func loadQualityAudits(projectID: String) async throws -> (byAssetID: [String: SegmentQualityAudit], bySegmentID: [String: SegmentQualityAudit]) {
        let reportAssets = try await store.listAssets(projectID: projectID, kind: .qualityReport)
            .sorted { $0.createdAtISO8601 < $1.createdAtISO8601 }
        var byAsset: [String: SegmentQualityAudit] = [:]
        var bySeg: [String: SegmentQualityAudit] = [:]
        let decoder = JSONDecoder()
        for asset in reportAssets {
            if let data = try? await store.readVerifiedData(for: asset.assetID),
               let audit = try? decoder.decode(SegmentQualityAudit.self, from: data) {
                byAsset[audit.wavAssetID] = audit
                bySeg[audit.segmentID] = audit
            }
        }
        return (byAsset, bySeg)
    }
}
