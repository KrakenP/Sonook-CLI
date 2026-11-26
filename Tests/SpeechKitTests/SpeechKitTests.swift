import AudioCore
import Foundation
import SpeechKit
import Testing

@Suite("SpeechKit Proper-Noun QA & Single-Segment Regeneration")
struct SpeechKitTests {
    private func sampleCatalog() -> CharacterVoiceCatalog {
        let narrator = CharacterVoiceCard(
            characterID: "char_narrator",
            canonicalName: "旁白",
            aliases: ["叙述者"],
            voiceDesignPrompt: "沉稳男声",
            locked: true
        )
        let protagonist = CharacterVoiceCard(
            characterID: "char_001",
            canonicalName: "顾辰",
            aliases: ["顾师兄", "前辈"],
            voiceDesignPrompt: "清朗青年男声",
            deliveryStages: [
                VoiceDeliveryStage(
                    stageID: "st_ch2",
                    effectiveFromChapter: 2,
                    stageLabel: "沉稳蜕变期",
                    deliveryBaseline: "历经磨砺后的沉稳克制语气，语速略缓",
                    speakingRate: 0.95
                )
            ],
            locked: true
        )
        let companion = CharacterVoiceCard(
            characterID: "char_002",
            canonicalName: "林清瑶",
            aliases: ["清瑶", "前辈"], // Shared alias "前辈" must NOT be whitelisted
            voiceDesignPrompt: "温润女声",
            locked: true
        )
        return CharacterVoiceCatalog(projectID: "proj_speech_test", revision: 1, cards: [narrator, protagonist, companion])
    }

    private func cleanIntegrity() -> AudioIntegrityReport {
        let samples = (0..<24_000).map { Float(sin(2.0 * .pi * 300.0 * Double($0) / 24_000.0) * 0.25) }
        return AudioIntegrityChecker.analyze(pcmSamples: samples, sampleRate: 24_000)
    }

    @Test func tonePinyinExactMatchAndToneRejection() {
        #expect(TonePinyinConverter.tonePinyin(of: "顾辰") == "gù chén")
        #expect(TonePinyinConverter.tonePinyin(of: "故尘") == "gù chén")
        #expect(TonePinyinConverter.tonePinyin(of: "古晨") == "gǔ chén")

        #expect(TonePinyinConverter.isExactToneHomophone("顾辰", "故尘"))
        #expect(!TonePinyinConverter.isExactToneHomophone("顾辰", "古晨"))
        #expect(!TonePinyinConverter.isExactToneHomophone("林清瑶", "林庆瑶"))
        #expect(TonePinyinConverter.isExactToneHomophone("林清瑶", "林青瑶"))
        #expect(!TonePinyinConverter.isExactToneHomophone("顾辰", "顾"))
        #expect(!TonePinyinConverter.isExactToneHomophone("abc", "abc"))
    }

    @Test func properNounExactToneHomophonePassesWithFullAuditTrail() {
        let outcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0001",
            wavAssetID: "ast_001",
            referenceText: "顾辰站在石阶上，对林清瑶微微一笑。",
            hypothesisTranscript: "故尘站在石阶上，对林青瑶微微一笑。",
            integrity: cleanIntegrity(),
            catalog: sampleCatalog()
        )

        #expect(outcome.verdict == .passed)
        #expect(outcome.audit.rawCER > 0.15)
        #expect(outcome.audit.adjustedCER == 0.0)
        #expect(outcome.audit.nonExemptSubstitutions == 0)
        #expect(outcome.audit.exemptions.count == 2)
        #expect(outcome.audit.exemptions[0].characterID == "char_001")
        #expect(outcome.audit.exemptions[0].referenceText == "顾辰")
        #expect(outcome.audit.exemptions[0].hypothesisText == "故尘")
        #expect(outcome.audit.exemptions[0].tonePinyin == "gù chén")
        #expect(outcome.audit.exemptions[1].characterID == "char_002")
        #expect(outcome.audit.exemptions[1].referenceText == "林清瑶")
        #expect(outcome.audit.exemptions[1].hypothesisText == "林青瑶")
    }

    @Test func wrongToneProperNounSubstitutionIsRejected() {
        let outcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0002",
            wavAssetID: "ast_002",
            referenceText: "顾辰轻轻点头。",
            hypothesisTranscript: "古晨轻轻点头。",
            integrity: cleanIntegrity(),
            catalog: sampleCatalog()
        )

        #expect(outcome.audit.exemptions.isEmpty)
        #expect(outcome.audit.adjustedCER == outcome.audit.rawCER)
        #expect(outcome.verdict == .needsReview([.highCER]))
    }

    @Test func properNounHomophoneCannotMaskOmissionElsewhere() {
        let outcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0003",
            wavAssetID: "ast_003",
            referenceText: "顾辰缓步走出山门，回头望了一眼古老的石碑。",
            hypothesisTranscript: "故尘缓步走出山门，回头望了一眼古老石碑。", // omitted "的"
            integrity: cleanIntegrity(),
            catalog: sampleCatalog()
        )

        // Proper noun "顾辰"->"故尘" is logged as exempted, BUT omission ("的") still forces needsReview!
        #expect(outcome.audit.exemptions.count == 1)
        #expect(outcome.audit.deletions == 1)
        if case .needsReview(let reasons) = outcome.verdict {
            #expect(reasons.contains(.suspectedOmission))
        } else {
            Issue.record("Expected needsReview with suspectedOmission, got \(outcome.verdict)")
        }
    }

    @Test func nonNameHomophoneAndAmbiguousSharedAliasAreNeverExempted() {
        // Non-name word "石阶" -> "时节" (different tone anyway) and "石碑" -> "实悲" or "公道" -> "工道"
        let nonName = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0004",
            wavAssetID: "ast_004",
            referenceText: "此事公道自在人心。",
            hypothesisTranscript: "此事工道自在人心。",
            integrity: cleanIntegrity(),
            catalog: sampleCatalog()
        )
        #expect(nonName.audit.exemptions.isEmpty)
        #expect(nonName.verdict == .needsReview([.highCER]))

        // Shared alias "前辈" belongs to BOTH char_001 and char_002, so it must NOT be exempted.
        let ambiguous = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0005",
            wavAssetID: "ast_005",
            referenceText: "前辈请留步。",
            hypothesisTranscript: "钱辈请留步。",
            integrity: cleanIntegrity(),
            catalog: sampleCatalog()
        )
        #expect(ambiguous.audit.exemptions.isEmpty)
        #expect(ambiguous.verdict == .needsReview([.highCER]))
    }

    @Test func silentAudioAlwaysFailsAsRetryableEvenWithExactTranscript() {
        let silentSamples = Array(repeating: Float(0), count: 24_000)
        let silentIntegrity = AudioIntegrityChecker.analyze(pcmSamples: silentSamples, sampleRate: 24_000)
        let outcome = ProperNounAwareASRVerifier.evaluate(
            segmentID: "ch_001_seg_0006",
            wavAssetID: "ast_006",
            referenceText: "顾辰轻轻点头。",
            hypothesisTranscript: "顾辰轻轻点头。",
            integrity: silentIntegrity,
            catalog: sampleCatalog()
        )
        #expect(outcome.verdict == .retryableFailure([.silent]))
        #expect(outcome.audit.verdictLabel == "retryable_failure")
    }

    @Test func deliveryStageLayersIntoChapterTwoControlWithoutAffectingChapterOne() throws {
        let catalog = sampleCatalog()
        let card = try #require(catalog.resolveCharacter(namedOrAliased: "char_001"))
        let seg = ScriptSegment(
            segmentID: "ch_002_seg_0001",
            chapterID: "ch_002",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: 12),
            sourceText: "“我们走吧。”",
            spokenText: "我们走吧。",
            speakerID: "char_001",
            voiceProfileRevision: "char_001_rev_1",
            direction: SegmentDirection(emotion: "calm", styleInstruction: "轻声提醒"),
            scriptRevision: 1
        )

        let reqCh1 = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
            segment: seg,
            card: card,
            chapterNumber: 1,
            providerID: "mlx-voxcpm2",
            verifiedAnchorPath: "/tmp/anchor.wav",
            seed: 42
        )
        let reqCh2 = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
            segment: seg,
            card: card,
            chapterNumber: 2,
            providerID: "mlx-voxcpm2",
            verifiedAnchorPath: "/tmp/anchor.wav",
            seed: 42
        )

        #expect(reqCh1.parameters["control_instruction"] == "轻声提醒")
        #expect(reqCh2.parameters["control_instruction"] == "历经磨砺后的沉稳克制语气，语速略缓，轻声提醒")
        #expect(reqCh1.parameters["ref_audio_path"] == "/tmp/anchor.wav")
        #expect(reqCh2.parameters["ref_audio_path"] == "/tmp/anchor.wav")
    }

    @Test func singleSegmentRegenerationIsolatesTargetAndProtectsQualifiedAsset() async throws {
        let store = InMemorySpeechStore(catalog: sampleCatalog())
        let seg1 = ScriptSegment(
            segmentID: "ch_001_seg_0001",
            chapterID: "ch_001",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: 6),
            sourceText: "山风微凉。",
            spokenText: "山风微凉。",
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            scriptRevision: 1,
            audioArtifactID: "ast_keep_1",
            status: .verified
        )
        let seg2 = ScriptSegment(
            segmentID: "ch_001_seg_0002",
            chapterID: "ch_001",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 6, endExclusive: 18),
            sourceText: "“顾辰，走吧。”",
            spokenText: "顾辰，走吧。",
            speakerID: "char_002",
            voiceProfileRevision: "char_002_rev_1",
            scriptRevision: 1,
            audioArtifactID: "ast_old_2",
            status: .needsReview
        )
        let seg3 = ScriptSegment(
            segmentID: "ch_001_seg_0003",
            chapterID: "ch_001",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 18, endExclusive: 24),
            sourceText: "两人离开。",
            spokenText: "两人离开。",
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            scriptRevision: 1,
            audioArtifactID: "ast_keep_3",
            status: .verified
        )
        try await store.saveScript(
            ScriptDocument(chapterID: "ch_001", sourceDocumentRevision: "rev_1", scriptRevision: 1, segments: [seg1, seg2, seg3]),
            projectID: "proj_speech_test"
        )

        let callCounter = CounterBox()
        let goodSamples = (0..<24_000).map { Float(sin(2.0 * .pi * 280.0 * Double($0) / 24_000.0) * 0.25) }

        // 1. Regenerate seg2 -> passes via proper-noun exact-tone homophone ("故尘") and swaps cleanly!
        let passResult = try await SingleSegmentRegenerator.regenerate(
            request: SegmentRegenerationRequest(
                projectID: "proj_speech_test",
                segmentID: "ch_001_seg_0002",
                chapterNumber: 1,
                providerID: "fake-tts",
                modelID: "fake-voxcpm2",
                asrProviderID: "fake-asr",
                asrModelID: "fake-asr",
                seed: 99
            ),
            store: store,
            encodeWAV: { _, _ in Data("FAKEWAV_GOOD".utf8) },
            synthesize: { _ in
                await callCounter.incTTS()
                return try SynthesizedAudio(
                    pcmSamples: goodSamples,
                    sampleRate: 24_000,
                    metrics: InferenceMetrics(providerID: "fake-tts", modelID: "fake-voxcpm2", modelRevision: "1", inferenceDurationMs: 10)
                )
            },
            transcribe: { _ in
                await callCounter.incASR()
                return TranscriptResult(
                    text: "故尘，走吧。",
                    metrics: InferenceMetrics(providerID: "fake-asr", modelID: "fake-asr", modelRevision: "1", inferenceDurationMs: 5)
                )
            }
        )

        #expect(await callCounter.ttsCalls == 1)
        #expect(await callCounter.asrCalls == 1)
        #expect(passResult.swapped == true)
        #expect(passResult.previousAssetID == "ast_old_2")
        #expect(passResult.newStatus == .verified)
        #expect(passResult.audit.exemptions.count == 1)

        let updatedScript = try #require(await store.loadScript(projectID: "proj_speech_test", chapterID: "ch_001"))
        #expect(updatedScript.segments[0].audioArtifactID == "ast_keep_1")
        #expect(updatedScript.segments[1].audioArtifactID == passResult.candidateAssetID)
        #expect(updatedScript.segments[1].status == .verified)
        #expect(updatedScript.segments[2].audioArtifactID == "ast_keep_3")

        // 2. Regenerate seg2 again, but now TTS outputs silent broken audio -> MUST NOT overwrite verified asset!
        let silentSamples = Array(repeating: Float(0), count: 24_000)
        let brokenResult = try await SingleSegmentRegenerator.regenerate(
            request: SegmentRegenerationRequest(
                projectID: "proj_speech_test",
                segmentID: "ch_001_seg_0002",
                chapterNumber: 1,
                providerID: "fake-tts",
                modelID: "fake-voxcpm2",
                asrProviderID: "fake-asr",
                asrModelID: "fake-asr",
                seed: 100
            ),
            store: store,
            encodeWAV: { _, _ in Data("FAKEWAV_SILENT".utf8) },
            synthesize: { _ in
                try SynthesizedAudio(
                    pcmSamples: silentSamples,
                    sampleRate: 24_000,
                    metrics: InferenceMetrics(providerID: "fake-tts", modelID: "fake-voxcpm2", modelRevision: "1", inferenceDurationMs: 10)
                )
            },
            transcribe: { _ in
                TranscriptResult(
                    text: "顾辰，走吧。",
                    metrics: InferenceMetrics(providerID: "fake-asr", modelID: "fake-asr", modelRevision: "1", inferenceDurationMs: 5)
                )
            }
        )

        #expect(brokenResult.swapped == false)
        #expect(brokenResult.newStatus == .verified)
        let preservedScript = try #require(await store.loadScript(projectID: "proj_speech_test", chapterID: "ch_001"))
        #expect(preservedScript.segments[1].audioArtifactID == passResult.candidateAssetID)
        #expect(preservedScript.segments[1].status == .verified)
    }

    @Test("Non-verbal scene-break punctuation (e.g. ……) produces deterministic pause WAV without calling TTS or ASR")
    func nonVerbalPauseSegmentSkipsTTSAndASR() async throws {
        #expect(SpeechRequestBuilder.isNonVerbalPauseText("……") == true)
        #expect(SpeechRequestBuilder.isNonVerbalPauseText("  ***  ") == true)
        #expect(SpeechRequestBuilder.isNonVerbalPauseText("林清") == false)
        #expect(SpeechRequestBuilder.isNonVerbalPauseText("123") == false)

        let catalog = CharacterVoiceCatalog(projectID: "proj_pause_test", revision: 1, cards: [
            CharacterVoiceCard(characterID: "char_narrator", canonicalName: "旁白", voiceDesignPrompt: "旁白")
        ])
        let store = InMemorySpeechStore(catalog: catalog)
        let pauseSeg = ScriptSegment(
            segmentID: "ch_002_seg_0006",
            chapterID: "ch_002",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: 6),
            sourceText: "……",
            spokenText: "……",
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            direction: SegmentDirection(pauseAfterMs: 1200),
            scriptRevision: 1,
            status: .pending
        )
        try await store.saveScript(
            ScriptDocument(chapterID: "ch_002", sourceDocumentRevision: "rev_1", scriptRevision: 1, segments: [pauseSeg]),
            projectID: "proj_pause_test"
        )

        let calls = CounterBox()
        let result = try await SingleSegmentRegenerator.regenerate(
            request: SegmentRegenerationRequest(
                projectID: "proj_pause_test",
                segmentID: "ch_002_seg_0006",
                chapterNumber: 2,
                providerID: "voxcpm2-mlx",
                modelID: "voxcpm2-8bit",
                asrProviderID: "qwen3-asr-mlx",
                asrModelID: "qwen3-asr"
            ),
            store: store,
            encodeWAV: { samples, sr in
                #expect(sr == 48_000)
                #expect(samples.count == 57_600)
                return Data("PAUSE_WAV".utf8)
            },
            synthesize: { _ in
                await calls.incTTS()
                fatalError("TTS must not be called for pure punctuation pause")
            },
            transcribe: { _ in
                await calls.incASR()
                fatalError("ASR must not be called for pure punctuation pause")
            }
        )

        #expect(await calls.ttsCalls == 0)
        #expect(await calls.asrCalls == 0)
        #expect(result.swapped == true)
        #expect(result.newStatus == .verified)
        #expect(result.audit.verdictLabel == "passed")
    }

    @Test("VoxCPM2 narrator always pins calm control instruction and QA flags >3.5st narrator pitch drift")
    func narratorControlLockAndPitchDriftGuard() throws {
        let narrator = CharacterVoiceCard(
            characterID: "char_narrator",
            canonicalName: "旁白",
            voiceDesignPrompt: "旁白"
        )
        let passage = "林清着急地走进了车站。"
        let seg = ScriptSegment(
            segmentID: "ch_005_seg_0010",
            chapterID: "ch_005",
            sourceDocumentRevision: "rev_1",
            sourceSpan: try SourceSpan(start: 0, endExclusive: passage.utf8.count),
            sourceText: passage,
            spokenText: passage,
            speakerID: "char_narrator",
            voiceProfileRevision: "char_narrator_rev_1",
            scriptRevision: 1
        )
        let req = try SpeechRequestBuilder.buildSegmentSynthesisRequest(
            segment: seg,
            card: narrator,
            chapterNumber: 5,
            providerID: "voxcpm2-mlx",
            verifiedAnchorPath: "/tmp/narrator_anchor.wav",
            seed: 42
        )
        #expect(req.parameters["control_instruction"] == SpeechRequestBuilder.narratorCalmControlInstruction)

        let goodSamples = (0..<24_000).map { Float(sin(2.0 * .pi * 100.0 * Double($0) / 24_000.0) * 0.2) }
        let integrity = AudioIntegrityChecker.analyze(pcmSamples: goodSamples, sampleRate: 24_000)

        let steady = ProperNounAwareASRVerifier.evaluate(
            segmentID: seg.segmentID,
            wavAssetID: "ast_steady",
            referenceText: seg.spokenText,
            hypothesisTranscript: seg.spokenText,
            integrity: integrity,
            catalog: nil,
            expectedPitchHz: 100.0,
            candidatePitchHz: 106.0
        )
        #expect(steady.verdict == .passed)

        let drifted = ProperNounAwareASRVerifier.evaluate(
            segmentID: seg.segmentID,
            wavAssetID: "ast_drifted",
            referenceText: seg.spokenText,
            hypothesisTranscript: seg.spokenText,
            integrity: integrity,
            catalog: nil,
            expectedPitchHz: 100.0,
            candidatePitchHz: 148.0
        )
        #expect(drifted.verdict == .needsReview([.pitchDrift]))
        #expect(drifted.audit.failureReasons.contains("pitchDrift"))
    }
}

private actor CounterBox {
    var ttsCalls = 0
    var asrCalls = 0
    func incTTS() { ttsCalls += 1 }
    func incASR() { asrCalls += 1 }
}

private actor InMemorySpeechStore: WorkspaceStoreProtocol {
    nonisolated let rootDirectory = URL(fileURLWithPath: "/tmp/sonook-speechkit-mem")
    private var catalog: CharacterVoiceCatalog?
    private var scripts: [String: ScriptDocument] = [:]
    private var assets: [String: (AssetRecord, Data)] = [:]
    private var nextAssetNum = 1

    init(catalog: CharacterVoiceCatalog) {
        self.catalog = catalog
    }

    func saveProject(_ project: ProjectRecord) async throws {}
    func project(id: String) async throws -> ProjectRecord? { nil }
    func listProjects() async throws -> [ProjectRecord] { [] }
    func upsertModel(_ entry: ModelRegistryEntry) async throws {}
    func model(id: String) async throws -> ModelRegistryEntry? { nil }
    func listModels(kind: ModelKind?) async throws -> [ModelRegistryEntry] { [] }
    func updateMeasuredPeakBytes(modelID: String, peakBytes: UInt64) async throws {}

    func saveCatalog(_ catalog: CharacterVoiceCatalog) async throws { self.catalog = catalog }
    func loadCatalog(projectID: String) async throws -> CharacterVoiceCatalog? { catalog }

    func saveScript(_ script: ScriptDocument, projectID: String) async throws {
        scripts[script.chapterID] = script
    }
    func loadScript(projectID: String, chapterID: String) async throws -> ScriptDocument? {
        scripts[chapterID]
    }
    func listScripts(projectID: String) async throws -> [ScriptDocument] {
        scripts.values.sorted { $0.chapterID < $1.chapterID }
    }
    func locateSegment(projectID: String, segmentID: String) async throws -> LocatedSegment? {
        for script in scripts.values {
            if let seg = script.segments.first(where: { $0.segmentID == segmentID }) {
                return LocatedSegment(chapterID: script.chapterID, segment: seg)
            }
        }
        return nil
    }

    func saveSourceDocument(_ document: SourceDocumentRecord, chapters: [ChapterRecord]) async throws {}
    func latestSourceDocument(projectID: String) async throws -> SourceDocumentRecord? { nil }
    func listChapters(projectID: String, sourceDocumentRevision: String?) async throws -> [ChapterRecord] { [] }
    func chapter(projectID: String, chapterID: String) async throws -> ChapterRecord? { nil }
    func saveSegmentApproval(_ approval: SegmentApprovalRecord) async throws {}
    func segmentApprovals(projectID: String, chapterID: String) async throws -> [SegmentApprovalRecord] { [] }
    func saveChapterMemory(_ memory: ChapterMemoryRecord) async throws {}
    func chapterMemory(projectID: String, chapterID: String) async throws -> ChapterMemoryRecord? { nil }
    func chapterMemoriesUpTo(projectID: String, maxChapterNumber: Int) async throws -> [ChapterMemoryRecord] { [] }

    func createJob(_ job: JobRecord, nodes: [JobNodeRecord], edges: [JobEdgeRecord]) async throws {}
    func jobSnapshot(jobID: String) async throws -> JobSnapshot? { nil }
    func listJobs(projectID: String?) async throws -> [JobRecord] { [] }
    func refreshReadyNodes(jobID: String, now: Date) async throws -> Int { 0 }
    func claimNextReadyNode(jobID: String?, workerID: String, leaseDurationSeconds: TimeInterval, now: Date) async throws -> ClaimedNode? { nil }
    func renewLease(_ lease: NodeLease, leaseDurationSeconds: TimeInterval, now: Date) async throws -> NodeLease { lease }
    func commitNodeResult(lease: NodeLease, status: NodeStatus, outputAssetID: String?, outputPayloadJSON: String?, lastError: String?, nextRetryAt: Date?, now: Date) async throws {}
    func requestCancel(jobID: String, now: Date) async throws -> JobRecord { fatalError() }
    func prepareResume(jobID: String, now: Date) async throws -> JobRecord { fatalError() }
    func recomputeJobStatus(jobID: String, now: Date) async throws -> JobRecord { fatalError() }

    func commitBytes(_ data: Data, projectID: String, kind: AssetKind, fileExtension: String, sampleRate: Int?, frameCount: Int?, provenance: AssetProvenance) async throws -> AssetRecord {
        let id = "ast_mem_\(nextAssetNum)"
        nextAssetNum += 1
        let rec = AssetRecord(
            assetID: id,
            projectID: projectID,
            kind: kind,
            relativePath: "\(id).\(fileExtension)",
            fileExtension: fileExtension,
            fileSHA256: "sha_\(id)",
            byteSize: Int64(data.count),
            sampleRate: sampleRate,
            frameCount: frameCount,
            provenance: provenance,
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )
        assets[id] = (rec, data)
        return rec
    }
    func asset(id: String) async throws -> AssetRecord? { assets[id]?.0 }
    func listAssets(projectID: String, kind: AssetKind?) async throws -> [AssetRecord] {
        assets.values.map(\.0).filter { $0.projectID == projectID && (kind == nil || $0.kind == kind) }
    }
    func resolveFileURL(for assetID: String) async throws -> URL { rootDirectory.appendingPathComponent(assetID) }
    func readVerifiedData(for assetID: String) async throws -> Data { assets[assetID]?.1 ?? Data() }
    func verifyAssetIntegrity(assetID: String) async throws -> Bool { assets[assetID] != nil }
    func runStartupReconciliation() async throws -> OrphanGCReport { OrphanGCReport() }
}
