import AudioCore
import Foundation
import Testing

private func metrics(_ provider: String, duration: Double? = nil) -> InferenceMetrics {
    .init(providerID: provider, modelID: "fake-" + provider, modelRevision: "fixture-r1", loadDurationMs: 30,
          inferenceDurationMs: 5, audioDurationSeconds: duration, peakResidentBytes: 1024)
}

private actor FakeLLMProvider: LLMProvider {
    let capabilities = LLMCapabilities(parameters: ["format": .oneOf(["script_json"])])
    private(set) var isLoaded = false
    private(set) var calls = 0
    let scripts: [String: ScriptDocument]
    init(scripts: [String: ScriptDocument] = [:]) { self.scripts = scripts }
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func generateAccepted(prompt: String, parameters: AcceptedParameters) throws -> LLMResponse {
        guard isLoaded else { throw ProviderCapabilityError.modelNotLoaded }
        calls += 1
        var measures = metrics("llm")
        let text: String
        if parameters["format"] == "script_json" {
            guard let script = scripts[prompt] else { throw ProviderCapabilityError.invalidInput("Unknown chapter") }
            text = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
        } else {
            text = prompt
        }
        measures.promptTokens = prompt.count
        measures.outputTokens = text.count
        return .init(text: text, metrics: measures)
    }
}

// A reversible test signal. Its first frame identifies the voice. Later frames
// carry UTF-8 bytes so ASR must actually consume the synthesized mono samples.
private actor FakeTTSProvider: TTSProvider {
    static let voices = ["narrator", "wen", "cen", "mu"]
    let capabilities = TTSCapabilities(parameters: ["speaker_id": .oneOf(Set(voices))])
    private(set) var isLoaded = false
    private(set) var calls = 0
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func synthesizeAccepted(text: String, parameters: AcceptedParameters) throws -> SynthesizedAudio {
        guard isLoaded else { throw ProviderCapabilityError.modelNotLoaded }
        calls += 1
        let index = Self.voices.firstIndex(of: parameters["speaker_id"] ?? "narrator")!
        let samples = [Float(index + 1) / 8] + text.utf8.map { Float(Int($0) + 1) / 512 }
        let duration = Double(samples.count) / 16000
        return try .init(pcmSamples: samples, sampleRate: 16000, metrics: metrics("tts", duration: duration))
    }
}

private actor FakeASRProvider: ASRProvider {
    let capabilities = ASRCapabilities(parameters: ["case": .oneOf(["uppercase"])])
    private(set) var isLoaded = false
    private(set) var calls = 0
    func load() { isLoaded = true }
    func unload() { isLoaded = false }

    func transcribeAccepted(pcmSamples: [Float], sampleRate: Int, parameters: AcceptedParameters) throws -> TranscriptResult {
        guard isLoaded else { throw ProviderCapabilityError.modelNotLoaded }
        calls += 1
        guard sampleRate == 16000, pcmSamples.count > 1 else { throw ProviderCapabilityError.invalidInput("Invalid fake signal") }
        let bytes = try pcmSamples.dropFirst().map { sample -> UInt8 in
            guard let byte = UInt8(exactly: sample * 512 - 1) else {
                throw ProviderCapabilityError.invalidInput("Damaged fake signal")
            }
            return byte
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw ProviderCapabilityError.invalidInput("Invalid UTF-8 signal") }
        let text = parameters["case"] == "uppercase" ? decoded.uppercased() : decoded
        return .init(text: text, metrics: metrics("asr", duration: Double(pcmSamples.count) / Double(sampleRate)))
    }
}

@Suite struct ProviderContractTests {
    @Test func llmStrictDegradeLifecycleAndCancellation() async throws {
        let adapter = FakeLLMProvider()
        let provider: any LLMProvider = adapter
        let input = LLMRequest(prompt: "渡口")
        #expect(await !provider.isLoaded)
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.generate(input) }
        try await provider.load()
        #expect(await provider.isLoaded)
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("top_k")) {
            try await provider.generate(.init(prompt: "渡口", parameters: ["top_k": "2"]))
        }
        let unsupported = ["format": "xml", "top_k": "2"]
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("format")) {
            try await provider.generate(.init(prompt: "渡口", parameters: unsupported))
        }
        #expect(await adapter.calls == 0)
        let result = try await provider.generate(.init(prompt: "渡口", parameters: unsupported, policy: .degrade))
        #expect(result.text == "渡口" && result.metrics.promptTokens == 2)
        #expect(result.metrics.degradations == [
            .init(parameter: "format", requestedValue: "xml", appliedBehavior: "omitted; provider default", reason: "unsupported value"),
            .init(parameter: "top_k", requestedValue: "2", appliedBehavior: "omitted; provider default", reason: "unsupported parameter")
        ])
        await #expect(throws: ProviderCapabilityError.invalidInput("Empty prompt")) { try await provider.generate(.init(prompt: "")) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.generate(input)
        }
        await #expect(throws: ProviderCapabilityError.cancelled) { try await task.value }
        #expect(await adapter.calls == 1)
        await provider.unload()
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.generate(input) }
    }

    @Test func ttsCapabilitiesDigestsAndTimings() async throws {
        let adapter = FakeTTSProvider()
        let provider: any TTSProvider = adapter
        let request = SpeechRequest(text: "铃", parameters: ["speaker_id": "wen"])
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.synthesize(request) }
        try await provider.load()
        let params = ["speaker_id": "unknown"]
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("speaker_id")) {
            try await provider.synthesize(.init(text: "铃", parameters: params))
        }
        #expect(await adapter.calls == 0)
        let audio = try await provider.synthesize(request)
        let fallback = try await provider.synthesize(.init(text: "铃", parameters: params, policy: .degrade))
        let plain = try await provider.synthesize(.init(text: "铃"))
        #expect(audio.metrics.degradations.isEmpty)
        #expect(fallback.metrics.degradations.map(\.requestedValue) == ["unknown"])
        #expect(fallback.sha256Hex == plain.sha256Hex && fallback.sha256Hex != audio.sha256Hex)
        #expect(audio.frameCount == 4 && audio.sampleRate == 16000 && audio.metrics.rtf == 20)
        let encoded = try JSONEncoder().encode(audio.metrics)
        #expect(try JSONDecoder().decode(InferenceMetrics.self, from: encoded) == audio.metrics)
        let mono = try SynthesizedAudio(pcmSamples: [0], sampleRate: 8000, metrics: metrics("test"))
        #expect(mono.sha256Hex == "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119")
        for (samples, rate): ([Float], Int) in [([], 16000), ([.nan], 16000), ([0], 0)] {
            #expect(throws: ProviderCapabilityError.self) { try SynthesizedAudio(pcmSamples: samples, sampleRate: rate, metrics: metrics("test")) }
        }
        await #expect(throws: ProviderCapabilityError.invalidInput("Empty speech text")) {
            try await provider.synthesize(.init(text: ""))
        }
        await provider.unload()
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.synthesize(request) }
    }

    @Test func asrCapabilityNegotiationAndInvalidInput() async throws {
        let adapter = FakeASRProvider()
        let provider: any ASRProvider = adapter
        let samples: [Float] = [0.125, 98.0 / 512] // encoded "a"
        let request = ASRRequest(pcmSamples: samples, sampleRate: 16000)
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.transcribe(request) }
        try await provider.load()
        let parameters = ["case": "uppercase", "timestamps": "true"]
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("timestamps")) {
            try await provider.transcribe(.init(pcmSamples: samples, sampleRate: 16000, parameters: parameters))
        }
        #expect(await adapter.calls == 0)
        let response = try await provider.transcribe(.init(pcmSamples: samples, sampleRate: 16000, parameters: parameters, policy: .degrade))
        #expect(response.text == "A")
        #expect(response.metrics.degradations.map(\.parameter) == ["timestamps"])
        #expect(response.metrics.degradations.first?.requestedValue == "true")
        await #expect(throws: ProviderCapabilityError.invalidInput("Invalid ASR mono PCM")) {
            try await provider.transcribe(.init(pcmSamples: [.nan], sampleRate: 16000))
        }
        await provider.unload()
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.transcribe(request) }
    }

    @Test func originalChaptersThroughAlternatingModels() async throws {
        let (golden, source) = try GoldenFixture.load()
        let chapters = ChapterExtractor.extractChapters(from: source)
        let scripts = Dictionary(uniqueKeysWithValues: zip(chapters, golden.chapters).map { ($0.text, golden.script(for: $1)) })
        let llm: any LLMProvider = FakeLLMProvider(scripts: scripts)
        let tts: any TTSProvider = FakeTTSProvider()
        let asr: any ASRProvider = FakeASRProvider()
        let catalog = CharacterVoiceCatalog(projectID: "ferry", cards: FakeTTSProvider.voices.map { id in
            .init(characterID: id, canonicalName: id, providerBindings: ["tts": .init(providerID: "tts", speakerID: id)], locked: true)
        })
        let voices = try CharacterVoiceCatalog.parseMarkdown(catalog.renderMarkdown())
        try await llm.load()
        var documents: [ScriptDocument] = []
        for chapter in chapters {
            let output = try await llm.generate(.init(prompt: chapter.text, parameters: ["format": "script_json"]))
            let script = try JSONDecoder().decode(ScriptDocument.self, from: Data(output.text.utf8))
            #expect(SourceCoverageValidator.validate(script, against: chapter).isValid)
            documents.append(script)
        }
        await llm.unload()
        try await tts.load()
        var artifacts: [String: SynthesizedAudio] = [:]
        for i in documents.indices {
            for j in documents[i].segments.indices {
                let segment = documents[i].segments[j]
                let binding = try #require(voices.resolveCharacter(namedOrAliased: segment.speakerID)?.providerBindings["tts"])
                let audio = try await tts.synthesize(.init(text: segment.spokenText, parameters: ["speaker_id": binding.speakerID]))
                #expect(audio.metrics.providerID == binding.providerID && audio.metrics.modelRevision == "fixture-r1")
                artifacts[audio.sha256Hex] = audio
                documents[i].segments[j].audioArtifactID = audio.sha256Hex
                documents[i].segments[j].status = .synthesized
            }
        }
        await tts.unload()
        try await asr.load()
        var verified = 0
        for doc in documents {
            for segment in doc.segments {
                let id = try #require(segment.audioArtifactID)
                let audio = try #require(artifacts[id])
                let result = try await asr.transcribe(.init(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate))
                let cer = ChineseCERCalculator.calculate(reference: segment.spokenText, hypothesis: result.text)
                let integrity = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
                #expect(result.text.utf8.elementsEqual(segment.spokenText.utf8))
                #expect(segment.status == .synthesized && cer.cer == 0)
                #expect(QualityEvaluator.evaluate(cer: cer, integrity: integrity) == .passed)
                verified += 1
            }
        }
        await asr.unload()
        #expect(verified == golden.chapters.flatMap(\.segments).count)
        #expect(await !llm.isLoaded)
        #expect(await !tts.isLoaded)
        #expect(await !asr.isLoaded)
    }
}
