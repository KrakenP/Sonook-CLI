import AudioCore
import Foundation
import SpeechKit
import Testing

@Suite("P3 Auto-Repair & Precision Cache Invalidation")
struct AutoRepairAndCacheTests {
    private func makeIntegrity(silent: Bool = false) -> AudioIntegrityReport {
        let samples: [Float] = silent
            ? Array(repeating: 0, count: 24_000)
            : (0..<24_000).map { Float(sin(2.0 * .pi * 260.0 * Double($0) / 24_000.0) * 0.2) }
        return AudioIntegrityChecker.analyze(pcmSamples: samples, sampleRate: 24_000)
    }

    @Test("Attribution-only needs_review with passing ASR is excluded from TTS auto-repair")
    func attributionOnlyExcludedFromAutoRepair() throws {
        let seg = ScriptSegment(
            segmentID: "ch_001_seg_0016",
            chapterID: "ch_001",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: 12),
            sourceText: "快点过来。",
            spokenText: "快点过来。",
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            scriptRevision: 1,
            audioArtifactID: "ast_ok",
            status: .needsReview,
            attributionEvidence: ["unresolved_dialogue_speaker"]
        )
        let passedAudit = SegmentQualityAudit(
            segmentID: seg.segmentID,
            wavAssetID: "ast_ok",
            rawTranscript: "快点过来",
            rawCER: 0.0,
            adjustedCER: 0.0,
            exemptions: [],
            nonExemptSubstitutions: 0,
            deletions: 0,
            insertions: 0,
            rmsDBFS: -20,
            verdictLabel: "passed",
            failureReasons: []
        )
        #expect(AutoRepairCandidateEvaluator.shouldAutoRepair(segment: seg, latestAudit: passedAudit) == false)

        let badAudit = SegmentQualityAudit(
            segmentID: seg.segmentID,
            wavAssetID: "ast_ok",
            rawTranscript: "快过来",
            rawCER: 0.25,
            adjustedCER: 0.25,
            exemptions: [],
            nonExemptSubstitutions: 0,
            deletions: 1,
            insertions: 0,
            rmsDBFS: -20,
            verdictLabel: "needs_review",
            failureReasons: ["highCER"]
        )
        #expect(AutoRepairCandidateEvaluator.shouldAutoRepair(segment: seg, latestAudit: badAudit) == true)
    }

    @Test("Auto-repair protects verified and intact takes, accepts strict CER improvements and passing fixes")
    func bestCandidateSelectionAndProtection() {
        let catalog = CharacterVoiceCatalog(projectID: "proj_p3", cards: [
            CharacterVoiceCard(characterID: "char_001", canonicalName: "顾辰", voiceDesignPrompt: "青年男声")
        ])

        let prevAudit = SegmentQualityAudit(
            segmentID: "ch_002_seg_0005",
            wavAssetID: "ast_prev",
            rawTranscript: "只是这一切孤辰看不到了",
            rawCER: 0.18,
            adjustedCER: 0.18,
            exemptions: [],
            nonExemptSubstitutions: 1,
            deletions: 0,
            insertions: 0,
            rmsDBFS: -20,
            verdictLabel: "needs_review",
            failureReasons: ["highCER"]
        )

        // 1. Broken silent candidate MUST NEVER overwrite intact existing take.
        let silentOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_002_seg_0005",
            wavAssetID: "ast_silent",
            referenceText: "只是这一切顾辰看不到了。",
            hypothesisTranscript: "",
            integrity: makeIntegrity(silent: true),
            catalog: catalog
        )
        let d1 = AutoRepairCandidateEvaluator.evaluateCandidate(
            previousStatus: .needsReview,
            previousAssetID: "ast_prev",
            previousAudit: prevAudit,
            candidateOutcome: silentOutcome,
            hasAttributionReviewFlag: false
        )
        #expect(d1.acceptCandidate == false)
        #expect(d1.resultingStatus == .needsReview)

        // 2. Worse CER candidate MUST be rejected.
        let worseOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_002_seg_0005",
            wavAssetID: "ast_worse",
            referenceText: "只是这一切顾辰看不到了。",
            hypothesisTranscript: "只是这些看不到了",
            integrity: makeIntegrity(),
            catalog: catalog
        )
        let d2 = AutoRepairCandidateEvaluator.evaluateCandidate(
            previousStatus: .needsReview,
            previousAssetID: "ast_prev",
            previousAudit: prevAudit,
            candidateOutcome: worseOutcome,
            hasAttributionReviewFlag: false
        )
        #expect(d2.acceptCandidate == false)

        // 3. Strictly better CER candidate (still needs_review, e.g. 9.09% < 18%) IS accepted.
        let betterOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_002_seg_0005",
            wavAssetID: "ast_better",
            referenceText: "只是这一切顾辰看不到了。",
            hypothesisTranscript: "只是这一切古辰看不到了",
            integrity: makeIntegrity(),
            catalog: catalog
        )
        let d3 = AutoRepairCandidateEvaluator.evaluateCandidate(
            previousStatus: .needsReview,
            previousAssetID: "ast_prev",
            previousAudit: prevAudit,
            candidateOutcome: betterOutcome,
            hasAttributionReviewFlag: false
        )
        #expect(d3.acceptCandidate == true)
        #expect(d3.resultingStatus == .needsReview)

        // 4. Passing candidate (via exact-tone homophone "故尘") promotes directly to .verified!
        let passingOutcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_002_seg_0005",
            wavAssetID: "ast_pass",
            referenceText: "只是这一切顾辰看不到了。",
            hypothesisTranscript: "只是这一切故尘看不到了。",
            integrity: makeIntegrity(),
            catalog: catalog
        )
        let d4 = AutoRepairCandidateEvaluator.evaluateCandidate(
            previousStatus: .needsReview,
            previousAssetID: "ast_prev",
            previousAudit: prevAudit,
            candidateOutcome: passingOutcome,
            hasAttributionReviewFlag: false
        )
        #expect(d4.acceptCandidate == true)
        #expect(d4.resultingStatus == .verified)

        // 5. Verified segment is NEVER overwritten.
        let d5 = AutoRepairCandidateEvaluator.evaluateCandidate(
            previousStatus: .verified,
            previousAssetID: "ast_pass",
            previousAudit: passingOutcome.audit,
            candidateOutcome: passingOutcome,
            hasAttributionReviewFlag: false
        )
        #expect(d5.acceptCandidate == false)
        #expect(d5.resultingStatus == .verified)
    }

    @Test("Precision cache invalidation isolates VoiceDeliveryStage change to affected character and chapter >= K")
    func precisionCacheInvalidationAcrossChapters() async throws {
        let anchorA = VoiceTimbreAnchor(
            anchorID: "anc_a",
            assetID: "ast_anc_a",
            fileSHA256: String(repeating: "a", count: 64),
            generatorProviderID: "qwen3-tts-voice-design",
            generatorModelID: "qwen3-vd",
            designPrompt: "青年男声",
            auditionText: "测试",
            sampleRate: 24_000,
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )
        let anchorN = VoiceTimbreAnchor(
            anchorID: "anc_n",
            assetID: "ast_anc_n",
            fileSHA256: String(repeating: "b", count: 64),
            generatorProviderID: "qwen3-tts-voice-design",
            generatorModelID: "qwen3-vd",
            designPrompt: "旁白",
            auditionText: "测试",
            sampleRate: 24_000,
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )

        let cardN = CharacterVoiceCard(characterID: "char_narrator", canonicalName: "旁白", voiceDesignPrompt: "旁白", timbreAnchor: anchorN)
        var cardA = CharacterVoiceCard(characterID: "char_001", canonicalName: "顾辰", voiceDesignPrompt: "青年男声", timbreAnchor: anchorA)
        let initialCatalog = CharacterVoiceCatalog(projectID: "proj_cache", cards: [cardN, cardA])

        let store = CacheTestArtifactStore()
        var chapters: [ChapterRecord] = []
        var scripts: [String: ScriptDocument] = [:]

        // Build 6 chapters, 2 segments each (1 narrator + 1 char_001) = 12 verified segments.
        for chNum in 1...6 {
            let chID = String(format: "ch_%03d", chNum)
            chapters.append(ChapterRecord(
                projectID: "proj_cache",
                chapterID: chID,
                chapterNumber: chNum,
                title: "第\(chNum)章",
                sourceDocumentRevision: "rev_1",
                sourceSpan: try SourceSpan(start: (chNum - 1) * 100, endExclusive: chNum * 100)
            ))

            var segs: [ScriptSegment] = []
            for (idx, speakerCard) in [cardN, cardA].enumerated() {
                let segID = "\(chID)_seg_000\(idx + 1)"
                let spoken = "第\(chNum)章台词\(idx + 1)。"
                let dir = SegmentDirection(emotion: "calm", pauseAfterMs: 360)
                let fp = speakerCard.synthesisFingerprint(
                    chapterIndex: chNum,
                    spokenText: spoken,
                    direction: dir,
                    providerID: "voxcpm2-mlx",
                    modelID: "voxcpm2-8bit",
                    modelRevision: "local"
                )
                let asset = try await store.commitBytes(
                    Data("WAV_\(segID)".utf8),
                    projectID: "proj_cache",
                    kind: .segmentWAV,
                    fileExtension: "wav",
                    sampleRate: 48_000,
                    frameCount: 48_000,
                    provenance: AssetProvenance(
                        chapterID: chID,
                        segmentID: segID,
                        characterID: speakerCard.characterID,
                        providerID: "voxcpm2-mlx",
                        modelID: "voxcpm2-8bit",
                        modelRevision: "local",
                        inputFingerprint: fp
                    )
                )
                segs.append(ScriptSegment(
                    segmentID: segID,
                    chapterID: chID,
                    sourceDocumentRevision: "rev_1",
                    sourceSpan: try SourceSpan(start: 0, endExclusive: 12),
                    sourceText: spoken,
                    spokenText: spoken,
                    speakerID: speakerCard.characterID,
                    voiceProfileRevision: "\(speakerCard.characterID)_rev_1",
                    direction: dir,
                    scriptRevision: 1,
                    audioArtifactID: asset.assetID,
                    status: .verified
                ))
            }
            scripts[chID] = ScriptDocument(chapterID: chID, sourceDocumentRevision: "rev_1", scriptRevision: 1, segments: segs)
        }

        // Baseline: 12/12 cache hits!
        let baselinePlan = try await CacheInvalidationPlanner.plan(
            projectID: "proj_cache",
            chapters: chapters,
            scriptsByChapterID: scripts,
            catalog: initialCatalog,
            providerID: "voxcpm2-mlx",
            modelID: "voxcpm2-8bit",
            modelRevision: "local",
            store: store
        )
        #expect(baselinePlan.totalSegments == 12)
        #expect(baselinePlan.reusableSegments == 12)
        #expect(baselinePlan.invalidatedSegments == 0)

        // Add VoiceDeliveryStage for char_001 starting at Chapter 5 -> ONLY ch_005_seg_0002 & ch_006_seg_0002 invalidated!
        cardA.deliveryStages = [
            VoiceDeliveryStage(
                stageID: "stg_mature",
                effectiveFromChapter: 5,
                stageLabel: "历经风霜",
                deliveryBaseline: "语速放缓，语气更加沉静内敛",
                evidence: "第5章台词2。"
            )
        ]
        let evolvedCatalog = CharacterVoiceCatalog(projectID: "proj_cache", cards: [cardN, cardA])

        let stagePlan = try await CacheInvalidationPlanner.plan(
            projectID: "proj_cache",
            chapters: chapters,
            scriptsByChapterID: scripts,
            catalog: evolvedCatalog,
            providerID: "voxcpm2-mlx",
            modelID: "voxcpm2-8bit",
            modelRevision: "local",
            store: store
        )
        #expect(stagePlan.reusableSegments == 10)
        #expect(stagePlan.invalidatedSegments == 2)
        let invalidatedIDs = Set(stagePlan.entries.filter(\.needsResynthesis).map(\.segmentID))
        #expect(invalidatedIDs == ["ch_005_seg_0002", "ch_006_seg_0002"])

        // Corrupt 1 WAV asset on disk (ch_002_seg_0001) -> ONLY that segment additionally flagged as corruptedAudioAsset!
        let ch2NarrAssetID = try #require(scripts["ch_002"]?.segments[0].audioArtifactID)
        await store.markCorrupted(assetID: ch2NarrAssetID)

        let corruptPlan = try await CacheInvalidationPlanner.plan(
            projectID: "proj_cache",
            chapters: chapters,
            scriptsByChapterID: scripts,
            catalog: evolvedCatalog,
            providerID: "voxcpm2-mlx",
            modelID: "voxcpm2-8bit",
            modelRevision: "local",
            store: store
        )
        #expect(corruptPlan.reusableSegments == 9)
        #expect(corruptPlan.invalidatedSegments == 3)
        let corruptEntry = try #require(corruptPlan.entries.first { $0.segmentID == "ch_002_seg_0001" })
        #expect(corruptEntry.reason == .corruptedAudioAsset)
    }
}

private actor CacheTestArtifactStore: ArtifactStoreProtocol {
    private var records: [String: AssetRecord] = [:]
    private var corrupted: Set<String> = []
    private var seq = 0

    func markCorrupted(assetID: String) {
        corrupted.insert(assetID)
    }

    func commitBytes(
        _ data: Data,
        projectID: String,
        kind: AssetKind,
        fileExtension: String,
        sampleRate: Int?,
        frameCount: Int?,
        provenance: AssetProvenance
    ) async throws -> AssetRecord {
        seq += 1
        let id = "ast_cache_\(seq)"
        let rec = AssetRecord(
            assetID: id,
            projectID: projectID,
            kind: kind,
            relativePath: "\(id).\(fileExtension)",
            fileExtension: fileExtension,
            fileSHA256: String(repeating: "c", count: 64),
            byteSize: Int64(data.count),
            sampleRate: sampleRate,
            frameCount: frameCount,
            provenance: provenance,
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )
        records[id] = rec
        return rec
    }

    func asset(id: String) async throws -> AssetRecord? { records[id] }
    func listAssets(projectID: String, kind: AssetKind?) async throws -> [AssetRecord] {
        records.values.filter { $0.projectID == projectID && (kind == nil || $0.kind == kind) }
    }
    func resolveFileURL(for assetID: String) async throws -> URL { URL(fileURLWithPath: "/tmp/\(assetID)") }
    func readVerifiedData(for assetID: String) async throws -> Data { Data() }
    func verifyAssetIntegrity(assetID: String) async throws -> Bool {
        records[assetID] != nil && !corrupted.contains(assetID)
    }
    func runStartupReconciliation() async throws -> OrphanGCReport { OrphanGCReport() }
}
