import AudioCore
import Foundation
import ModelRuntime
import StorageKit
import WorkflowKit

// MARK: - Persistent Job Configurations

public struct FakeDemoJobConfig: Codable, Equatable, Sendable {
    public let segmentCount: Int
    public let failOnceSegmentIndex: Int?
    public let permanentFailSegmentIndex: Int?
    public let needsReviewSegmentIndex: Int?
    public let stepDelayMs: Int
    public let ambientAudioEnabled: Bool

    public init(
        segmentCount: Int = 4,
        failOnceSegmentIndex: Int? = nil,
        permanentFailSegmentIndex: Int? = nil,
        needsReviewSegmentIndex: Int? = nil,
        stepDelayMs: Int = 20,
        ambientAudioEnabled: Bool = false
    ) {
        self.segmentCount = max(1, segmentCount)
        self.failOnceSegmentIndex = failOnceSegmentIndex
        self.permanentFailSegmentIndex = permanentFailSegmentIndex
        self.needsReviewSegmentIndex = needsReviewSegmentIndex
        self.stepDelayMs = max(0, stepDelayMs)
        self.ambientAudioEnabled = ambientAudioEnabled
    }
}

public struct ChapterMLXJobConfig: Codable, Equatable, Sendable {
    public let sourceAssetID: String
    public let chapterNumber: Int
    public let chapterID: String
    public let maxCharacters: Int
    public let llmModelID: String
    public let auditionTTSModelID: String
    public let mainTTSModelID: String
    public let asrModelID: String
    public let exportDirectory: String?
    public let allowNeedsReviewInRender: Bool
    public let ambientAudioEnabled: Bool
    public let stopAfterCompletedNodes: Int?

    public init(
        sourceAssetID: String,
        chapterNumber: Int,
        chapterID: String,
        maxCharacters: Int,
        llmModelID: String,
        auditionTTSModelID: String,
        mainTTSModelID: String,
        asrModelID: String,
        exportDirectory: String? = nil,
        allowNeedsReviewInRender: Bool = true,
        ambientAudioEnabled: Bool = false,
        stopAfterCompletedNodes: Int? = nil
    ) {
        self.sourceAssetID = sourceAssetID
        self.chapterNumber = chapterNumber
        self.chapterID = chapterID
        self.maxCharacters = maxCharacters
        self.llmModelID = llmModelID
        self.auditionTTSModelID = auditionTTSModelID
        self.mainTTSModelID = mainTTSModelID
        self.asrModelID = asrModelID
        self.exportDirectory = exportDirectory
        self.allowNeedsReviewInRender = allowNeedsReviewInRender
        self.ambientAudioEnabled = ambientAudioEnabled
        self.stopAfterCompletedNodes = stopAfterCompletedNodes
    }
}

// MARK: - Fake Provider Executor (P1 Gate Offline / CI Verification)

public actor FakeDemoNodeExecutor: NodeExecutorProtocol {
    private let store: any WorkspaceStoreProtocol
    private var transientFailuresTriggered: Set<String> = []
    private var executionCounts: [String: Int] = [:]

    public init(store: any WorkspaceStoreProtocol) {
        self.store = store
    }

    public func invocationCount(for nodeID: String) -> Int {
        executionCounts[nodeID, default: 0]
    }

    public func execute(node: JobNodeRecord, lease: NodeLease, job: JobRecord) async throws -> NodeExecutionOutcome {
        executionCounts[node.nodeID, default: 0] += 1
        let cfg = (try? JSONDecoder().decode(FakeDemoJobConfig.self, from: Data(job.configJSON.utf8))) ?? FakeDemoJobConfig()

        if cfg.stepDelayMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(cfg.stepDelayMs) * 1_000_000)
        }
        if Task.isCancelled { throw NodeExecutionError.cancelled }

        let payload = (try? JSONSerialization.jsonObject(with: Data(node.payloadJSON.utf8)) as? [String: Any]) ?? [:]
        let segIndex = payload["segment_index"] as? Int

        switch node.kind {
        case "fake_analyze":
            let data = Data("{\"status\":\"analyzed\",\"segments\":\(cfg.segmentCount)}".utf8)
            let asset = try await store.commitBytes(
                data,
                projectID: job.projectID,
                kind: .scriptSnapshot,
                fileExtension: "json",
                sampleRate: nil,
                frameCount: nil,
                provenance: AssetProvenance(providerID: "fake-llm", modelID: "fake-llm-9b", inputFingerprint: node.inputFingerprint)
            )
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"script_asset_id\":\"\(asset.assetID)\"}")

        case "fake_audition":
            let samples = (0..<2400).map { Float(sin(2.0 * .pi * 220.0 * Double($0) / 24_000.0) * 0.2) }
            let wavData = try NativeAudioRenderer.encodeWAVData(samples: samples, sampleRate: 24_000)
            let asset = try await store.commitBytes(
                wavData,
                projectID: job.projectID,
                kind: .voiceAudition,
                fileExtension: "wav",
                sampleRate: 24_000,
                frameCount: samples.count,
                provenance: AssetProvenance(characterID: "char_narrator", providerID: "fake-voice-design", modelID: "fake-vd", inputFingerprint: node.inputFingerprint)
            )
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"anchor_asset_id\":\"\(asset.assetID)\"}")

        case "fake_tts":
            if let idx = segIndex, cfg.permanentFailSegmentIndex == idx {
                throw NodeExecutionError.permanent("Injected permanent TTS error on segment \(idx)")
            }
            if let idx = segIndex, cfg.failOnceSegmentIndex == idx, !transientFailuresTriggered.contains(node.nodeID) {
                transientFailuresTriggered.insert(node.nodeID)
                throw NodeExecutionError.retryable("Injected transient TTS error on segment \(idx)")
            }
            let freq = 260.0 + Double((segIndex ?? 1) * 35)
            let samples = (0..<4800).map { Float(sin(2.0 * .pi * freq * Double($0) / 48_000.0) * 0.18) }
            let wavData = try NativeAudioRenderer.encodeWAVData(samples: samples, sampleRate: 48_000)
            let asset = try await store.commitBytes(
                wavData,
                projectID: job.projectID,
                kind: .segmentWAV,
                fileExtension: "wav",
                sampleRate: 48_000,
                frameCount: samples.count,
                provenance: AssetProvenance(segmentID: "seg_\(segIndex ?? 0)", providerID: "fake-voxcpm2", modelID: "fake-voxcpm2-8bit", inputFingerprint: node.inputFingerprint)
            )
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"wav_asset_id\":\"\(asset.assetID)\"}")

        case "fake_asr":
            if let idx = segIndex, cfg.needsReviewSegmentIndex == idx {
                return .needsReview(
                    outputAssetID: nil,
                    outputPayloadJSON: "{\"cer\":0.08}",
                    reasons: [.highCER],
                    message: "Injected needs_review disagreement on segment \(idx)"
                )
            }
            let report = Data("{\"cer\":0.0,\"verdict\":\"passed\"}".utf8)
            let asset = try await store.commitBytes(
                report,
                projectID: job.projectID,
                kind: .qualityReport,
                fileExtension: "json",
                sampleRate: nil,
                frameCount: nil,
                provenance: AssetProvenance(segmentID: "seg_\(segIndex ?? 0)", providerID: "fake-asr", modelID: "fake-asr", inputFingerprint: node.inputFingerprint)
            )
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"verdict\":\"passed\"}")

        case "fake_render":
            if cfg.ambientAudioEnabled {
                throw NodeExecutionError.unsupportedCapability("Optional ambient audio mixing is reserved for P2/P4 and not enabled in P1.")
            }
            let data = Data("{\"rendered\":true,\"format\":\"m4a\"}".utf8)
            let asset = try await store.commitBytes(
                data,
                projectID: job.projectID,
                kind: .chapterRender,
                fileExtension: "json",
                sampleRate: 48_000,
                frameCount: 4800 * cfg.segmentCount,
                provenance: AssetProvenance(providerID: "fake-renderer", modelID: "native-avfoundation", inputFingerprint: node.inputFingerprint)
            )
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"render_asset_id\":\"\(asset.assetID)\"}")

        default:
            throw NodeExecutionError.permanent("Unknown fake node kind: \(node.kind)")
        }
    }
}

// MARK: - Real Native Swift MLX Chapter DAG Executor

public actor RealMLXChapterNodeExecutor: NodeExecutorProtocol {
    private static let narratorCalmPrompt = "标准普通话中年男性有声书旁白，声音温厚克制，语速均匀平稳，呼吸自然，不做戏剧化夸张起伏。"

    private let store: any WorkspaceStoreProtocol
    private let runtime: ModelResourceManager
    private let ignoreStopHook: Bool
    private let stderrLog: @Sendable (String) -> Void
    private var executedThisSession: Int = 0

    public init(
        store: any WorkspaceStoreProtocol,
        runtime: ModelResourceManager,
        ignoreStopHook: Bool = false,
        stderrLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.runtime = runtime
        self.ignoreStopHook = ignoreStopHook
        self.stderrLog = stderrLog
    }

    public func execute(node: JobNodeRecord, lease: NodeLease, job: JobRecord) async throws -> NodeExecutionOutcome {
        guard let cfg = try? JSONDecoder().decode(ChapterMLXJobConfig.self, from: Data(job.configJSON.utf8)) else {
            throw NodeExecutionError.permanent("Invalid ChapterMLXJobConfig JSON on job \(job.jobID)")
        }
        let payload = (try? JSONSerialization.jsonObject(with: Data(node.payloadJSON.utf8)) as? [String: Any]) ?? [:]

        // Optional deterministic stop hook used for automated P1 crash/cancel-and-resume verification on real GPU models.
        if !ignoreStopHook, let limit = cfg.stopAfterCompletedNodes, executedThisSession >= limit {
            _ = try await store.requestCancel(jobID: job.jobID, now: Date())
            throw NodeExecutionError.cancelled
        }

        let outcome: NodeExecutionOutcome
        switch node.kind {
        case "mlx_llm_analyze":
            outcome = try await runLLMAnalyze(node: node, job: job, cfg: cfg)
        case "mlx_audition_cast":
            outcome = try await runAuditionCast(node: node, job: job, cfg: cfg)
        case "mlx_tts_segment":
            let segID = payload["segment_id"] as? String ?? ""
            outcome = try await runTTSSegment(node: node, job: job, cfg: cfg, segmentID: segID)
        case "mlx_stage_barrier":
            await runtime.unloadAllIdle()
            outcome = .completed(outputAssetID: nil, outputPayloadJSON: "{\"barrier\":\"passed\"}")
        case "mlx_asr_segment":
            let segID = payload["segment_id"] as? String ?? ""
            outcome = try await runASRSegment(node: node, job: job, cfg: cfg, segmentID: segID)
        case "mlx_render_chapter":
            outcome = try await runRenderChapter(node: node, job: job, cfg: cfg)
        default:
            throw NodeExecutionError.permanent("Unsupported MLX node kind: \(node.kind)")
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

    private func runLLMAnalyze(node: JobNodeRecord, job: JobRecord, cfg: ChapterMLXJobConfig) async throws -> NodeExecutionOutcome {
        let llmEntry = try await requireModel(id: cfg.llmModelID, kind: .llm)
        let sourceData = try await store.readVerifiedData(for: cfg.sourceAssetID)
        let existingCatalog = try await store.loadCatalog(projectID: job.projectID)

        stderrLog("[DAG][\(node.nodeID)] Acquiring LLM lease for \(llmEntry.modelID)...")
        let log = self.stderrLog
        let projectID = job.projectID
        let chapterNum = cfg.chapterNumber
        let maxChars = cfg.maxCharacters
        let (_, catalog, scriptDoc, coverage) = try await runtime.withLLMLease(entry: llmEntry, priority: node.priority) { provider in
            try await P0PipelineRunner.analyzeChapter(
                sourceData: sourceData,
                projectID: projectID,
                chapterNumber: chapterNum,
                maxCharacters: maxChars,
                existingCatalog: existingCatalog,
                llmProvider: provider,
                stderrLog: log
            )
        }
        if let peak = await runtime.measuredPeakBytes(for: llmEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: llmEntry.modelID, peakBytes: peak)
        }

        guard coverage.isValid else {
            throw NodeExecutionError.permanent("Source coverage validation failed: \(coverage.coverageRatio)")
        }

        try await store.saveCatalog(catalog)
        try await store.saveScript(scriptDoc, projectID: job.projectID)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let scriptBytes = try enc.encode(scriptDoc)
        let asset = try await store.commitBytes(
            scriptBytes,
            projectID: job.projectID,
            kind: .scriptSnapshot,
            fileExtension: "json",
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(
                sourceDocumentRevision: scriptDoc.sourceDocumentRevision,
                chapterID: scriptDoc.chapterID,
                scriptRevision: scriptDoc.scriptRevision,
                providerID: llmEntry.providerID,
                modelID: llmEntry.modelID,
                modelRevision: llmEntry.revision,
                inputFingerprint: node.inputFingerprint
            )
        )
        stderrLog("[DAG][\(node.nodeID)] Analyzed \(scriptDoc.segments.count) segments, \(catalog.cards.count) characters (coverage=100%).")
        return .completed(outputAssetID: asset.assetID, outputPayloadJSON: "{\"characters\":\(catalog.cards.count),\"segments\":\(scriptDoc.segments.count)}")
    }

    private func runAuditionCast(node: JobNodeRecord, job: JobRecord, cfg: ChapterMLXJobConfig) async throws -> NodeExecutionOutcome {
        guard let catalog = try await store.loadCatalog(projectID: job.projectID) else {
            throw NodeExecutionError.permanent("Catalog missing before audition stage")
        }
        let vdEntry = try await requireModel(id: cfg.auditionTTSModelID, kind: .tts)
        let iso = ISO8601DateFormatter()

        var updatedCards: [CharacterVoiceCard] = []
        var generatedCount = 0
        var reusedCount = 0

        for var card in catalog.cards {
            // Reuse existing verified immutable timbre anchor without re-auditioning!
            if let existingAnchor = card.timbreAnchor,
               (try? await store.verifyAssetIntegrity(assetID: existingAnchor.assetID)) == true {
                reusedCount += 1
                updatedCards.append(card)
                continue
            }

            let isNarrator = (card.characterID == "char_narrator")
            let auditionText = isNarrator
                ? "窗外微风拂过树梢，山间石桌上仍摆着半局残棋，一切显得安静而从容。"
                : "今天天气不错，大家先把事情商量清楚，等会儿再一起出发也来得及。"
            let designPrompt = normalizedDesignPrompt(for: card)
            let req = SpeechRequest(
                text: auditionText,
                parameters: [
                    "voice_design_prompt": designPrompt,
                    "language": "Chinese",
                    "temperature": isNarrator ? "0.35" : "0.45",
                    "top_p": "0.80",
                    "seed": "42"
                ]
            )

            stderrLog("[DAG][\(node.nodeID)] Auditioning \(card.characterID) (\(card.canonicalName)) via \(vdEntry.modelID)...")
            let audio = try await runtime.withTTSLease(entry: vdEntry, priority: node.priority) { provider in
                try await provider.synthesize(req)
            }
            let wavData = try NativeAudioRenderer.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
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
        }

        if let peak = await runtime.measuredPeakBytes(for: vdEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: vdEntry.modelID, peakBytes: peak)
        }

        let mergedCatalog = try catalog.merging(incomingCards: updatedCards)
        try await store.saveCatalog(mergedCatalog)
        stderrLog("[DAG][\(node.nodeID)] Cast auditions ready (generated=\(generatedCount), reused=\(reusedCount)).")
        return .completed(outputAssetID: nil, outputPayloadJSON: "{\"generated\":\(generatedCount),\"reused\":\(reusedCount)}")
    }

    private func runTTSSegment(node: JobNodeRecord, job: JobRecord, cfg: ChapterMLXJobConfig, segmentID: String) async throws -> NodeExecutionOutcome {
        guard let catalog = try await store.loadCatalog(projectID: job.projectID),
              var scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: cfg.chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == segmentID }) else {
            throw NodeExecutionError.permanent("Missing catalog or segment \(segmentID)")
        }
        let seg = scriptDoc.segments[segIdx]
        guard let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) else {
            throw NodeExecutionError.permanent("Unknown speaker \(seg.speakerID) for segment \(segmentID)")
        }

        let mainEntry = try await requireModel(id: cfg.mainTTSModelID, kind: .tts)
        let isNarrator = (card.characterID == "char_narrator")

        var params: [String: String] = ["seed": "42"]
        if mainEntry.providerID == MLXVoxCPM2Provider.providerIdentifier {
            // Formal locked-voice path strictly validates the timbre anchor SHA-256 before synthesis (no silent fallback!).
            let (_, anchorURL) = try await ModelResourceManager.resolveVerifiedTimbreAnchorURL(for: card, artifactStore: store)
            params["ref_audio_path"] = anchorURL.path
            if !isNarrator {
                let control = card.effectiveControlInstruction(forChapter: cfg.chapterNumber, direction: seg.direction)
                if !control.isEmpty {
                    params["control_instruction"] = control
                }
            } else if let stage = card.activeDeliveryStage(forChapter: cfg.chapterNumber),
                      !stage.deliveryBaseline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                params["control_instruction"] = stage.deliveryBaseline
            }
            params["max_tokens"] = String(max(220, seg.spokenText.count * 6))
        } else if mainEntry.providerID == MLXQwen3TTSProvider.voiceDesignProviderIdentifier {
            let basePrompt = normalizedDesignPrompt(for: card)
            let control = isNarrator ? "" : card.effectiveControlInstruction(forChapter: cfg.chapterNumber, direction: seg.direction)
            params["voice_design_prompt"] = control.isEmpty ? basePrompt : "\(basePrompt)当前语气：\(control)。"
            params["language"] = "Chinese"
            params["temperature"] = isNarrator ? "0.35" : "0.48"
            params["top_p"] = isNarrator ? "0.80" : "0.85"
        } else {
            throw NodeExecutionError.unsupportedCapability("Unsupported main TTS provider in P1 DAG: \(mainEntry.providerID)")
        }

        let synthFP = card.synthesisFingerprint(
            chapterIndex: cfg.chapterNumber,
            spokenText: seg.spokenText,
            direction: seg.direction,
            providerID: mainEntry.providerID,
            modelID: mainEntry.modelID,
            modelRevision: mainEntry.revision
        )

        let speechReq = SpeechRequest(text: seg.spokenText, parameters: params)
        let audio = try await runtime.withTTSLease(entry: mainEntry, priority: node.priority) { provider in
            try await provider.synthesize(speechReq)
        }
        if let peak = await runtime.measuredPeakBytes(for: mainEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: mainEntry.modelID, peakBytes: peak)
        }

        let integrity = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
        if integrity.isSilent {
            throw NodeExecutionError.retryable("Synthesized segment \(segmentID) is silent")
        }

        let wavData = try NativeAudioRenderer.encodeWAVData(samples: audio.pcmSamples, sampleRate: audio.sampleRate)
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

    private func runASRSegment(node: JobNodeRecord, job: JobRecord, cfg: ChapterMLXJobConfig, segmentID: String) async throws -> NodeExecutionOutcome {
        guard var scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: cfg.chapterID),
              let segIdx = scriptDoc.segments.firstIndex(where: { $0.segmentID == segmentID }),
              let wavAssetID = scriptDoc.segments[segIdx].audioArtifactID else {
            throw NodeExecutionError.permanent("Missing synthesized WAV asset for ASR segment \(segmentID)")
        }

        // Always verify integrity of dry speech WAV before ASR!
        let verified = try await store.verifyAssetIntegrity(assetID: wavAssetID)
        guard verified else {
            throw NodeExecutionError.permanent("Segment WAV asset \(wavAssetID) failed SHA-256 verification before ASR")
        }
        let wavURL = try await store.resolveFileURL(for: wavAssetID)
        let (samples, sr) = try NativeAudioRenderer.readWAVSamples(from: wavURL)
        let integrity = AudioIntegrityChecker.analyze(pcmSamples: samples, sampleRate: sr)

        let asrEntry = try await requireModel(id: cfg.asrModelID, kind: .asr)
        let transcript = try await runtime.withASRLease(entry: asrEntry, priority: node.priority) { provider in
            try await provider.transcribe(ASRRequest(pcmSamples: samples, sampleRate: sr, parameters: ["language": "Chinese"]))
        }
        if let peak = await runtime.measuredPeakBytes(for: asrEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: asrEntry.modelID, peakBytes: peak)
        }

        let seg = scriptDoc.segments[segIdx]
        let cer = ChineseCERCalculator.calculate(reference: seg.spokenText, hypothesis: transcript.text, normalizeNumerals: true)
        let verdict = QualityEvaluator.evaluate(
            cer: cer,
            integrity: integrity,
            thresholds: QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10)
        )

        let reportPayload: [String: Any] = [
            "segment_id": seg.segmentID,
            "wav_asset_id": wavAssetID,
            "cer": cer.cer,
            "rms_dbfs": integrity.rmsDBFS
        ]
        let reportData = try JSONSerialization.data(withJSONObject: reportPayload, options: [.sortedKeys])
        let reportAsset = try await store.commitBytes(
            reportData,
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

        switch verdict {
        case .passed:
            scriptDoc.segments[segIdx].status = .verified
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            stderrLog(String(format: "[DAG][%@] %@ ASR CER=%.2f%% -> passed", node.nodeID, seg.segmentID, cer.cer * 100))
            return .completed(outputAssetID: reportAsset.assetID, outputPayloadJSON: String(decoding: reportData, as: UTF8.self))
        case .needsReview(let reasons):
            scriptDoc.segments[segIdx].status = .needsReview
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            stderrLog(String(format: "[DAG][%@] %@ ASR CER=%.2f%% -> needs_review (%@)", node.nodeID, seg.segmentID, cer.cer * 100, reasons.map(\.rawValue).joined(separator: ",")))
            return .needsReview(
                outputAssetID: reportAsset.assetID,
                outputPayloadJSON: String(decoding: reportData, as: UTF8.self),
                reasons: reasons,
                message: "CER \(String(format: "%.2f%%", cer.cer * 100))"
            )
        case .retryableFailure(let reasons):
            scriptDoc.segments[segIdx].status = .failed
            try await store.saveScript(scriptDoc, projectID: job.projectID)
            throw NodeExecutionError.retryable("Audio integrity failure: \(reasons.map(\.rawValue).joined(separator: ","))")
        }
    }

    private func runRenderChapter(node: JobNodeRecord, job: JobRecord, cfg: ChapterMLXJobConfig) async throws -> NodeExecutionOutcome {
        await runtime.unloadAllIdle()
        if cfg.ambientAudioEnabled {
            throw NodeExecutionError.unsupportedCapability("Optional ambient audio mixing is reserved for P2/P4; disable ambient mode in P1.")
        }
        guard let scriptDoc = try await store.loadScript(projectID: job.projectID, chapterID: cfg.chapterID) else {
            throw NodeExecutionError.permanent("Script missing before chapter render")
        }

        var segmentsPCM: [(segment: ScriptSegment, samples: [Float])] = []
        var sampleRate = 48_000
        var assetHashes: [String] = []

        for seg in scriptDoc.segments {
            guard let assetID = seg.audioArtifactID,
                  let rec = try await store.asset(id: assetID),
                  try await store.verifyAssetIntegrity(assetID: assetID) else {
                throw NodeExecutionError.permanent("Missing or corrupted WAV asset for segment \(seg.segmentID)")
            }
            let url = try await store.resolveFileURL(for: assetID)
            let (samples, sr) = try NativeAudioRenderer.readWAVSamples(from: url)
            sampleRate = sr
            assetHashes.append(rec.fileSHA256)
            segmentsPCM.append((seg, samples))
        }

        let renderConfig = ChapterRenderConfig(chapterID: cfg.chapterID, sampleRate: sampleRate, ambientTrack: nil)
        let renderFP = renderConfig.renderFingerprint(segmentAssetHashes: assetHashes)
        let (combinedPCM, timeline) = NativeAudioRenderer.assembleChapterPCM(
            chapterID: cfg.chapterID,
            segments: segmentsPCM,
            sampleRate: sampleRate,
            targetRMSDBFS: renderConfig.targetRMSDBFS
        )

        let m4aData = try NativeAudioRenderer.encodeM4AData(samples: combinedPCM, sampleRate: sampleRate)
        let m4aAsset = try await store.commitBytes(
            m4aData,
            projectID: job.projectID,
            kind: .chapterRender,
            fileExtension: "m4a",
            sampleRate: sampleRate,
            frameCount: combinedPCM.count,
            provenance: AssetProvenance(
                sourceDocumentRevision: scriptDoc.sourceDocumentRevision,
                chapterID: cfg.chapterID,
                scriptRevision: scriptDoc.scriptRevision,
                providerID: "native-avfoundation",
                modelID: "aac",
                inputFingerprint: renderFP
            )
        )

        if let exportDirPath = cfg.exportDirectory {
            let exportDir = URL(fileURLWithPath: exportDirPath, isDirectory: true)
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            try NativeAudioRenderer.writeWAV(samples: combinedPCM, sampleRate: sampleRate, to: exportDir.appendingPathComponent("preview.wav"))
            try m4aData.write(to: exportDir.appendingPathComponent("preview.m4a"), options: .atomic)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(timeline).write(to: exportDir.appendingPathComponent("timeline.json"), options: .atomic)
            if let catalog = try await store.loadCatalog(projectID: job.projectID) {
                try Data(try catalog.renderMarkdown().utf8).write(to: exportDir.appendingPathComponent("characters.voice-cards.md"), options: .atomic)
            }
        }

        stderrLog(String(format: "[DAG][%@] Rendered %.2fs @ %dHz -> %@", node.nodeID, timeline.totalDurationSeconds, sampleRate, m4aAsset.assetID))
        return .completed(outputAssetID: m4aAsset.assetID, outputPayloadJSON: "{\"m4a_asset_id\":\"\(m4aAsset.assetID)\",\"duration_seconds\":\(timeline.totalDurationSeconds),\"sample_rate\":\(sampleRate)}")
    }

    private func normalizedDesignPrompt(for card: CharacterVoiceCard) -> String {
        if card.characterID == "char_narrator" {
            return Self.narratorCalmPrompt
        }
        let base = card.voiceDesignPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "标准普通话青年男声，吐字清晰自然，语速适中。"
        }
        if base.contains("普通话") || base.contains("方言") {
            return base
        }
        return "标准普通话，\(base)"
    }
}
