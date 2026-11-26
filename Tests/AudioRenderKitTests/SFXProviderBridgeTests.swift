import AudioCore
@testable import AudioRenderKit
import Foundation
import Testing

private actor FakeSFXProvider: SFXProvider {
    let providerID = "fake-sfx"
    let capabilities = SFXCapabilities()
    private(set) var calls = 0
    func load() {}
    func unload() {}
    func generateSFX(_ request: SFXRequest) throws -> SFXResult {
        calls += 1
        let metrics = InferenceMetrics(providerID: providerID, modelID: "test-model", modelRevision: "r2",
                                       inferenceDurationMs: 10, audioDurationSeconds: 0.025)
        let audio = try SynthesizedAudio(pcmSamples: [Float](repeating: 0.25, count: 200), sampleRate: 8000, metrics: metrics)
        return SFXResult(audio: audio, licenseTag: "stability-community-license", metrics: metrics)
    }
}

@Suite struct SFXProviderBridgeTests {
    @Test func crossChapterCachePersistsLicenseAndProvenanceWithAudio() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let store = TestSoundStore(f.directory)
        let fake = FakeSFXProvider()
        let first = SoundFixture.point()
        let second = SoundFixture.point("echo", chapter: "two")
        let resolver = SFXAssetResolver(store: store, projectID: "book", backend: .provider(fake, modelRevision: "r2"))
        let hits = try await resolver.resolve([first, second], scriptRevision: 3, sourceDocumentRevision: "source1")
        #expect(hits.map(\.source) == [.generated, .cache])
        #expect(await fake.calls == 1)
        let asset = try #require(hits.first?.asset)
        #expect(hits.last?.cue.resolvedAssetID == asset.assetID)
        let records = await store.listAssets(projectID: "book", kind: .sfxAudio)
        #expect(records.count == 1)
        let record = try #require(records.first)
        let key = SFXRequest(prompt: first.soundPrompt, durationSeconds: first.durationSeconds).cacheKey(providerID: "fake-sfx", modelRevision: "r2")
        #expect(record.provenance.inputFingerprint == key)
        #expect(record.provenance.modelID == "test-model" && record.provenance.modelRevision == "r2")
        #expect(record.provenance.chapterID == "one" && record.provenance.segmentID == "a")
        #expect(record.provenance.sourceDocumentRevision == "source1" && record.provenance.scriptRevision == 3)
        let receipt = try SFXWAVMetadata.read(try await store.readVerifiedData(for: asset.assetID))
        #expect(receipt.cueID == first.cueID && receipt.license == "stability-community-license")
        #expect(receipt.seed == 42 && receipt.prompt == first.soundPrompt)
        #expect(try PCMCodec.readMonoSamples(from: asset.fileURL).samples == [Float](repeating: 0.25, count: 200))
        let reopened = SFXAssetResolver(store: store, projectID: "book", backend: .cacheOnly(providerID: fake.providerID, modelRevision: "r2"))
        let cached = try await reopened.resolve([second])
        #expect(cached.first?.source == .cache && cached.first?.asset?.license == asset.license)
        try Data().write(to: asset.fileURL)
        await #expect(throws: WorkflowStoreError.self) { try await reopened.resolve([second]) }
    }

    @Test func libraryPrecedesEvenAnExistingCacheAndMissingAssetsStayUnresolved() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        try f.wav("sfx/door_knock.wav", samples: [0, 1, 0])
        let library = try f.registry()
        let store = TestSoundStore(f.directory)
        let fake = FakeSFXProvider()
        let cue = SoundFixture.point()
        let backend = SFXAssetResolver.Backend.provider(fake, modelRevision: "r2")
        _ = try await SFXAssetResolver(store: store, projectID: "book", backend: backend).resolve([cue])
        let hits = try await SFXAssetResolver(store: store, projectID: "book", library: library, backend: backend).resolve([cue])
        #expect(hits.first?.source == .library && hits.first?.asset?.license == "CC0-1.0")
        #expect(await fake.calls == 1)
        var stale = cue
        stale.resolvedAssetID = "old"
        let missing = try await SFXAssetResolver(store: store, projectID: "book").resolve([stale])
        #expect(missing.first?.source == .unresolved && missing.first?.cue.resolvedAssetID == nil)
        let differentModel = SFXAssetResolver(store: store, projectID: "book", backend: .cacheOnly(providerID: fake.providerID, modelRevision: "r3"))
        #expect(try await differentModel.resolve([cue]).first?.source == .unresolved)
    }

    #if os(macOS)
    private func helper(_ f: SoundFixture, body: String, timeout: Duration = .seconds(3)) throws -> SubprocessSFXProvider {
        let url = f.directory.appendingPathComponent("test helper")
        try Data(("#!/bin/sh\nset -eu\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return SubprocessSFXProvider(executable: url, providerID: "helper", modelID: "local", modelRevision: "1",
                                     capabilities: .init(parameters: ["mode": .oneOf(["mono"])],
                                                         maxDurationSeconds: 1, defaultSampleRate: 8000), timeout: timeout)
    }

    @Test func localHelperGetsOnlyJSONAndReturnsLicensedWAVWithExplicitDegradations() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let pcm: [Float] = [0, 0.5, 0]
        try f.wav("fixture.wav", samples: pcm)
        let provider = try helper(f, body: #"""
            [ "$#" = 2 ] && [ "$1" = --request-json ] && [ "$2" = request.json ] || exit 4
            dir="${0%/*}"
            /bin/cp "$2" "$dir/received.json"
            /bin/cp "$dir/fixture.wav" output.wav
            echo '{"schema_version":1,"license":"provider-reported"}' > metadata.json
            """#)
        let prompt = #"door"; touch INJECTED; $(false) --output /tmp/example"#
        try await provider.load()
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("mode")) {
            try await provider.generateSFX(.init(prompt: prompt, parameters: ["mode": "stereo"]))
        }
        await #expect(throws: ProviderCapabilityError.unsupportedParameter("duration_seconds")) {
            try await provider.generateSFX(.init(prompt: prompt, durationSeconds: 2))
        }
        let result = try await provider.generateSFX(.init(prompt: prompt, durationSeconds: 2, seed: 78,
                                                          parameters: ["unknown": "abc", "mode": "mono"], policy: .degrade))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.directory.appendingPathComponent("received.json"))) as? [String: Any])
        #expect(json["prompt"] as? String == prompt && json["seed"] as? Int == 78)
        #expect(json["parameters"] as? [String: String] == ["mode": "mono"] && json["duration_seconds"] as? Int == 1)
        #expect(result.audio.pcmSamples == pcm && result.audio.sampleRate == 8000)
        #expect(result.licenseTag == "provider-reported")
        #expect(result.metrics.degradations.map(\.parameter) == ["unknown", "duration_seconds"])
        await provider.unload()
        await #expect(throws: ProviderCapabilityError.modelNotLoaded) { try await provider.generateSFX(.init(prompt: prompt)) }
    }

    @Test func helperTimeoutAndCancellationTerminateTheRunningProcess() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let body = #"echo $$ > "${0%/*}/pid"; exec /bin/sleep 15"#
        let pidURL = f.directory.appendingPathComponent("pid")
        let provider = try helper(f, body: body, timeout: .seconds(2))
        let request = SFXRequest(prompt: "knock", durationSeconds: 0.2)
        try await provider.load()
        await #expect(throws: SFXBridgeError.timedOut) { try await provider.generateSFX(request) }
        func checkStopped() throws {
            let pid = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        }
        try checkStopped()
        try FileManager.default.removeItem(at: pidURL)
        let cancellable = try helper(f, body: body, timeout: .seconds(10))
        try await cancellable.load()
        let task = Task { try await cancellable.generateSFX(request) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: pidURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try checkStopped()
    }

    @Test func rejectsUnlicensedOutputAndEscapedOutputPaths() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        try f.wav("fixture.wav", samples: [0, 1, 0])
        let request = SFXRequest(prompt: "knock", durationSeconds: 0.2)
        let unlicensed = try helper(f, body: #"echo '{"schema_version":1}' > metadata.json; /bin/cp "${0%/*}/fixture.wav" output.wav"#)
        try await unlicensed.load()
        await #expect(throws: SFXBridgeError.self) { try await unlicensed.generateSFX(request) }
        let escaped = try helper(f, body: #"echo '{"schema_version":1,"license":"CC0"}' > metadata.json; /bin/ln -s "${0%/*}/fixture.wav" output.wav"#)
        try await escaped.load()
        await #expect(throws: SoundLibraryError.unsafePath("output.wav")) { try await escaped.generateSFX(request) }
    }
    #endif
}
