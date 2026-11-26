import AudioCore
import Foundation
import StorageKit
import Testing
import WorkflowKit

private func metrics(_ provider: String) -> InferenceMetrics {
    InferenceMetrics(providerID: provider, modelID: "fixture", modelRevision: "r1", inferenceDurationMs: 1)
}

private actor ScriptProvider: LLMProvider {
    let capabilities = LLMCapabilities()
    var isLoaded = false
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func generateAccepted(prompt: String, parameters: AcceptedParameters) throws -> LLMResponse {
        var start = 0
        let segments = try prompt.split(separator: "\n").enumerated().map { index, line in
            let span = try SourceSpan(start: start, endExclusive: start + line.utf8.count)
            start = span.endExclusive + 1
            return ScriptSegment(segmentID: String(index + 1), chapterID: "chapter", sourceDocumentRevision: "r1",
                                 sourceSpan: span, sourceText: String(line), spokenText: String(line),
                                 speakerID: "hero", voiceProfileRevision: "r1", scriptRevision: 1)
        }
        let script = ScriptDocument(chapterID: "chapter", sourceDocumentRevision: "r1", scriptRevision: 1, segments: segments)
        return LLMResponse(text: String(decoding: try JSONEncoder().encode(script), as: UTF8.self), metrics: metrics("llm"))
    }
}

actor SpeechProvider: TTSProvider {
    let capabilities = TTSCapabilities()
    var isLoaded = false
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func synthesizeAccepted(text: String, parameters: AcceptedParameters) throws -> SynthesizedAudio {
        try SynthesizedAudio(pcmSamples: text.utf8.map { Float(Int($0) - 128) / 128 }, sampleRate: 8000, metrics: metrics("tts"))
    }
}

private actor TranscriptProvider: ASRProvider {
    let capabilities = ASRCapabilities()
    var isLoaded = false
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func transcribeAccepted(pcmSamples: [Float], sampleRate: Int, parameters: AcceptedParameters) throws -> TranscriptResult {
        let bytes = pcmSamples.map { UInt8($0 * 128 + 128) }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw NodeExecutionError.permanent("Invalid test signal") }
        return TranscriptResult(text: text, metrics: metrics("asr"))
    }
}

// 8-bit mono PCM WAVE. The fake signal is reversible so ASR verifies persisted audio end to end.
func wave(_ pcm: Data) -> Data {
    func word<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var data = Data("RIFF".utf8)
    data += word(UInt32(36 + pcm.count + pcm.count % 2))
    data += Data("WAVEfmt ".utf8)
    data += word(UInt32(16))
    for field: UInt16 in [1, 1] { data += word(field) }
    for field: UInt32 in [8000, 8000] { data += word(field) }
    for field: UInt16 in [1, 8] { data += word(field) }
    data += Data("data".utf8)
    data += word(UInt32(pcm.count))
    data += pcm
    if !pcm.count.isMultiple(of: 2) { data.append(0) }
    return data
}

@Suite("Audiobook DAG")
struct FakeAudiobookTests {
    @Test func providersExchangeCommittedAssetsFromAnalysisToRender() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        let lines = ["灯亮了。", "我看见了。"]
        let llm = ScriptProvider()
        let tts = SpeechProvider()
        let asr = TranscriptProvider()
        await llm.load()
        await tts.load()
        await asr.load()
        try await ws.create(ids: ["analyze", "audition", "tts_1", "tts_2", "asr_1", "asr_2", "render"],
                            edges: [("analyze", "audition", true), ("audition", "tts_1", true), ("audition", "tts_2", true),
                                    ("tts_1", "asr_1", true), ("tts_2", "asr_2", true),
                                    ("asr_1", "render", true), ("asr_2", "render", true)])
        let executor = RecordingExecutor { node in
            let state = try await ws.snapshot()
            func output(_ id: String) async throws -> AssetRecord {
                let upstream = try #require(state.nodes.first { $0.nodeID == id })
                #expect(upstream.status == .completed)
                let assetID = try #require(upstream.outputAssetID)
                return try #require(try await ws.store.asset(id: assetID))
            }
            func store(_ bytes: Data, kind: AssetKind, frames: Int?, segment: String? = nil) async throws -> NodeExecutionOutcome {
                let record = try await ws.store.commitBytes(bytes, projectID: "book", kind: kind,
                    fileExtension: frames == nil ? "json" : "wav", sampleRate: frames == nil ? nil : 8000, frameCount: frames,
                    provenance: .init(sourceDocumentRevision: "r1", chapterID: "chapter", segmentID: segment,
                                      characterID: "hero", scriptRevision: 1, providerID: node.kind, modelID: "fixture",
                                      modelRevision: "r1", inputFingerprint: node.inputFingerprint))
                return .completed(outputAssetID: record.assetID, outputPayloadJSON: nil)
            }
            func samples(_ record: AssetRecord) async throws -> Data {
                let bytes = try await ws.store.readVerifiedData(for: record.assetID)
                let frames = try #require(record.frameCount)
                return Data(bytes.dropFirst(44).prefix(frames))
            }

            switch node.kind {
            case "analyze":
                let response = try await llm.generate(.init(prompt: lines.joined(separator: "\n")))
                let bytes = Data(response.text.utf8)
                let script = try JSONDecoder().decode(ScriptDocument.self, from: bytes)
                #expect(script.segments.map(\.spokenText) == lines)
                try await ws.store.saveScript(script, projectID: "book")
                return try await store(bytes, kind: .scriptSnapshot, frames: nil)
            case "audition", "tts_1", "tts_2":
                let scriptAsset = try await output("analyze")
                let script = try JSONDecoder().decode(ScriptDocument.self, from: try await ws.store.readVerifiedData(for: scriptAsset.assetID))
                let audition = node.kind == "audition"
                let segment = script.segments[node.kind == "tts_2" ? 1 : 0]
                if !audition {
                    let anchor = try await output("audition")
                    #expect(try await ws.store.verifyAssetIntegrity(assetID: anchor.assetID))
                }
                let audio = try await tts.synthesize(.init(text: audition ? "试听。" : segment.spokenText))
                return try await store(wave(Data(audio.pcmSamples.map { UInt8($0 * 128 + 128) })),
                                       kind: audition ? .voiceAudition : .segmentWAV, frames: audio.frameCount, segment: segment.segmentID)
            case "asr_1", "asr_2":
                let first = node.kind == "asr_1"
                let source = try await output(first ? "tts_1" : "tts_2")
                let pcm = try await samples(source).map { Float(Int($0) - 128) / 128 }
                let transcript = try await asr.transcribe(.init(pcmSamples: pcm, sampleRate: 8000))
                let cer = ChineseCERCalculator.calculate(reference: lines[first ? 0 : 1], hypothesis: transcript.text)
                guard cer.cer == 0 else { throw NodeExecutionError.permanent("Transcript mismatch") }
                return .completed(outputAssetID: source.assetID, outputPayloadJSON: try String(decoding: JSONEncoder().encode(transcript.text), as: UTF8.self))
            case "render":
                var pcm = Data()
                for id in ["asr_1", "asr_2"] { pcm += try await samples(output(id)) }
                return try await store(wave(pcm), kind: .chapterRender, frames: pcm.count)
            default: throw NodeExecutionError.unsupportedCapability(node.kind)
            }
        }
        let report = try await ws.engine(executor, config: .init(maxConcurrency: 2)).run(jobID: "job")
        await llm.unload()
        await tts.unload()
        await asr.unload()
        let state = try await ws.snapshot()
        #expect(report.finalStatus == .completed && report.executedNodeIDs.count == 7)
        #expect(report.failedNodeIDs.isEmpty && report.needsReviewNodeIDs.isEmpty)
        #expect(state.nodes.allSatisfy { $0.status == .completed && $0.attemptCount == 1 })
        let render = try #require(state.nodes.first { $0.nodeID == "render" }?.outputAssetID)
        #expect(try await ws.store.readVerifiedData(for: render) == wave(Data(lines.joined().utf8)))
        #expect(try await ws.store.runStartupReconciliation() == OrphanGCReport())
    }

    @Test func catalogEditsReuseBothChaptersAndStageRevisionInvalidatesOnlyChapter20() async throws {
        let ws = try await WorkflowWorkspace()
        defer { ws.remove() }
        let sample = try await ws.store.commitBytes(Data([0, 1]), projectID: "book", kind: .voiceAudition, fileExtension: "pcm",
                                                   sampleRate: 8000, frameCount: 2, provenance: .init(characterID: "hero"))
        let anchor = VoiceTimbreAnchor(anchorID: "main", assetID: sample.assetID, fileSHA256: sample.fileSHA256,
                                      generatorProviderID: "fake", generatorModelID: "fixture", designPrompt: "平和",
                                      auditionText: "走。", sampleRate: 8000, createdAtISO8601: ws.stamp)
        let baseline = VoiceDeliveryStage(stageID: "early", effectiveFromChapter: 1, stageLabel: "初遇", deliveryBaseline: "明快")
        var card = CharacterVoiceCard(characterID: "hero", canonicalName: "阿沐", timbreAnchor: anchor,
                                      deliveryStages: [baseline], locked: true)
        func fingerprint(_ voice: CharacterVoiceCard, _ chapter: Int) -> String {
            voice.synthesisFingerprint(chapterIndex: chapter, spokenText: "前面有光。", direction: .init(),
                                       providerID: "fake", modelID: "fixture", modelRevision: "r1")
        }
        func saveAndLoad(_ voice: CharacterVoiceCard) async throws -> CharacterVoiceCard {
            try await ws.store.saveCatalog(.init(projectID: "book", cards: [voice]))
            return try #require(try await ws.store.loadCatalog(projectID: "book")?.cards.first)
        }
        // The caller supplies the new DAG revision, carrying intact checkpoints whose input key still matches.
        func createRevision(_ jobID: String, _ voice: CharacterVoiceCard, from previous: [JobNodeRecord]) async throws {
            let nodes = [1, 20].map { chapter in
                let key = fingerprint(voice, chapter)
                let id = "ch\(chapter)"
                let cached = previous.first { $0.nodeID == id && $0.inputFingerprint == key && $0.status == .completed }
                return JobNodeRecord(nodeID: id, jobID: jobID, kind: "tts", status: cached?.status ?? .pending,
                                     inputFingerprint: key, outputAssetID: cached?.outputAssetID, createdAtISO8601: ws.stamp)
            }
            try await ws.store.createJob(.init(jobID: jobID, projectID: "book", workflowKind: "speech", createdAtISO8601: ws.stamp),
                                         nodes: nodes, edges: [])
        }
        let executor = RecordingExecutor { node in
            let asset = try await ws.asset(node.inputFingerprint, nodeID: node.nodeID)
            return .completed(outputAssetID: asset.assetID, outputPayloadJSON: nil)
        }
        let engine = ws.engine(executor)
        try await createRevision("original", saveAndLoad(card), from: [])
        #expect(try await engine.run(jobID: "original").executedNodeIDs == ["ch1", "ch20"])
        let original = try await ws.snapshot("original")
        card.aliases.append("小沐")
        card.evidenceExcerpts.append("第十二章的称呼")
        card.deliveryStages[0].evidence = "第二处证据"
        let metadata = try await saveAndLoad(card)
        try await createRevision("metadata", metadata, from: original.nodes)
        let unchanged = try await engine.resume(jobID: "metadata")
        #expect(unchanged.executedNodeIDs.isEmpty && unchanged.skippedCompletedNodeIDs == ["ch1", "ch20"])
        card.deliveryStages.append(.init(stageID: "mature", effectiveFromChapter: 20, stageLabel: "重逢",
                                         deliveryBaseline: "从容", speakingRate: 0.9))
        let mature = try await saveAndLoad(card)
        #expect(mature.timbreAnchor == anchor && mature.activeDeliveryStage(forChapter: 19) == metadata.deliveryStages[0])
        #expect(mature.activeDeliveryStage(forChapter: 20)?.stageID == "mature")
        try await createRevision("growth", mature, from: original.nodes)
        let changed = try await engine.resume(jobID: "growth")
        #expect(changed.executedNodeIDs == ["ch20"] && changed.skippedCompletedNodeIDs == ["ch1"])
        #expect(await executor.calls == ["ch1", "ch20", "ch20"])
        let revised = try await ws.snapshot("growth")
        #expect(revised.nodes[0].outputAssetID == original.nodes[0].outputAssetID)
        #expect(revised.nodes[1].outputAssetID != original.nodes[1].outputAssetID)
        for node in original.nodes { #expect(try await ws.store.verifyAssetIntegrity(assetID: #require(node.outputAssetID))) }
    }
}
