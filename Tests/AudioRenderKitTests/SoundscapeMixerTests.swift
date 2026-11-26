import AudioCore
import AudioRenderKit
import Foundation
import Testing

@Suite struct SoundscapeMixerTests {
    @Test func adjacentScenesCrossfadeAtAnchorsAndUnrelatedGapsStaySilent() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let rate = 8000
        // Deliberately discontinuous loop endpoints and different source rates.
        let ramp = (0..<128).map { Float($0) / 1270 + 0.05 }
        try f.wav("rain_light.wav", samples: ramp, rate: rate / 2)
        try f.wav("forest_wind.wav", samples: [Float](repeating: 0.2, count: 301), rate: rate)
        let library = try f.registry()
        let dry = [Float](repeating: 0, count: 5000)
        let timeline = try SoundFixture.timeline(rate: rate, count: dry.count,
                                                entries: [("one", "a", 160, 1760), ("one", "b", 1920, 3600), ("one", "c", 3800, 4900)])
        let cues = [SoundFixture.scene("first", .rainLight), SoundFixture.scene("second", .forestWind, first: "b", last: "b"),
                    SoundFixture.scene("quiet", .none, first: "c", last: "c")]
        let render = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: [SoundFixture.plan(cues)], library: library)
        let pcm = render.samples
        #expect(pcm.count == dry.count && pcm.allSatisfy(\.isFinite))
        #expect(pcm[..<160].allSatisfy { $0 == 0 } && pcm[3600...].allSatisfy { $0 == 0 })
        #expect(pcm[160] == 0 && pcm[3599] == 0)
        // The old bed continues through the 160-frame pause. Both beds contribute halfway
        // into the new scene's 800-frame fade; fading each scene to zero would fail here.
        #expect(pcm[1760..<1920].allSatisfy { $0 > 0.04 })
        #expect(pcm[2320] > 0.2 * sin(Float.pi / 4) + 0.03)
        #expect(abs(pcm[2740] - 0.2) < 0.0001)
        let largestStep = zip(pcm, pcm.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(largestStep < 0.003)
    }

    @Test func voiceActivityReducesAmbientRMSAndRecoversAcrossMultiSegmentScene() throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let rate = 8000
        try f.wav("rain_light.wav", samples: [Float](repeating: 0.1, count: 131))
        let dry = [Float](repeating: 0, count: rate) + [Float](repeating: 0.25, count: rate) + [Float](repeating: 0, count: rate)
        let timeline = try SoundFixture.timeline(rate: rate, count: dry.count,
                                                entries: [("one", "a", 0, rate / 2), ("one", "b", rate, 2 * rate),
                                                          ("one", "c", rate * 5 / 2, dry.count)])
        let result = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: [
            SoundFixture.plan([SoundFixture.scene("rain", .rainLight, last: "c")])
        ], library: f.registry())
        func rms(_ range: Range<Int>) -> Float {
            sqrt(range.reduce(Float(0)) { sum, i in
                let residual = result.samples[i] - dry[i]
                return sum + residual * residual
            } / Float(range.count))
        }
        #expect(rms(12000..<15000) < 0.45 * rms(3500..<7000))
        #expect(rms(21500..<23000) > 2 * rms(12000..<15000))
    }

    @Test func pointEffectsRespectPlacementSignedOffsetsGainClippingAndChapterLocalIDs() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        try f.wav("sfx/door.wav", samples: [Float](repeating: 0.4, count: 400), rate: 4000)
        let library = try f.registry()
        let store = TestSoundStore(f.directory)
        let rate = 8000
        let dry = [Float](repeating: 0, count: 4000)
        let timeline = try SoundFixture.timeline(rate: rate, count: dry.count,
                                                entries: [("one", "a", 40, 200), ("two", "a", 1200, 2200)])
        let first = SoundFixture.point("shared", placement: .before) // only the last 40 frames fit
        let points = [SoundFixture.point("shared", chapter: "two", placement: .before, offset: -5),
                      SoundFixture.point("during", chapter: "two", offset: 10, gain: -6),
                      SoundFixture.point("after", chapter: "two", placement: .after, offset: 15)]
        let resolutions = try await SFXAssetResolver(store: store, projectID: "book", library: library).resolve([first] + points)
        let plans = [SoundFixture.plan([], [first]), SoundFixture.plan([], points, chapter: "two")]
        let result = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: plans, sfx: resolutions)
        let ranges = [0..<40, 960..<1160, 1280..<1480, 2320..<2520]
        for (idx, range) in ranges.enumerated() {
            #expect(result.samples[range.lowerBound] == 0 && result.samples[range.upperBound - 1] == 0)
            #expect(result.samples[range.lowerBound + 1] > 0 && result.samples[range.upperBound - 2] > 0)
            let center = result.samples[range.lowerBound + range.count / 2]
            let expected: Float = idx == 2 ? 0.4 * pow(10, -6 / 20.0) : 0.4
            #expect(abs(center - expected) < (idx == 0 ? 0.003 : 0.0001))
        }
        #expect(result.samples.indices.filter { i in !ranges.contains { $0.contains(i) } }.allSatisfy { result.samples[$0] == 0 })
    }

    @Test func rechecksLibraryFileContainmentWhenMixingPreviouslyResolvedEffects() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let outside = try SoundFixture()
        defer { outside.remove() }
        let effect = try f.wav("sfx/door.wav", samples: [0.2, 0.1, 0])
        let library = try f.registry()
        let point = SoundFixture.point()
        let sfx = try await SFXAssetResolver(store: TestSoundStore(f.directory), projectID: "book", library: library).resolve([point])
        let moved = outside.directory.appendingPathComponent("effect.wav")
        try FileManager.default.moveItem(at: effect, to: moved)
        try FileManager.default.createSymbolicLink(at: effect, withDestinationURL: moved)
        let timeline = try SoundFixture.timeline(rate: 8000, count: 200, entries: [("one", "a", 0, 200)])
        #expect(throws: SoundLibraryError.unsafePath("sfx/door.wav")) {
            try SoundscapeMixer.mix(drySpeech: [Float](repeating: 0, count: 200), timeline: timeline,
                                    plans: [SoundFixture.plan([], [point])], sfx: sfx)
        }
    }

    @Test func fingerprintsBindDryFilesPlansAndResolvedAssetBytes() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let rate = 8000
        let dryURL = try f.wav("speech.wav", samples: [Float](repeating: 0.05, count: 1000))
        let dryDigest = SoundFixture.hash(try Data(contentsOf: dryURL))
        let dry = try PCMCodec.readMonoSamples(from: dryURL).samples
        try f.wav("rain_light.wav", samples: [0.05, 0.05, 0.05])
        try f.wav("sfx/door.wav", samples: [Float](repeating: 0.1, count: 250))
        let timeline = try SoundFixture.timeline(rate: rate, count: dry.count, entries: [("one", "a", 0, dry.count)], dryHash: dryDigest)
        let cue = SoundFixture.scene("rain", .rainLight)
        let point = SoundFixture.point()
        let plan = SoundFixture.plan([cue], [point])
        func render(_ plan: ChapterSoundscapePlan, dryPCM: [Float]? = nil) async throws -> SoundscapeRender {
            let library = try f.registry()
            let sfx = try await SFXAssetResolver(store: TestSoundStore(f.directory), projectID: "book", library: library).resolve([point])
            return try SoundscapeMixer.mix(drySpeech: dryPCM ?? dry, timeline: timeline, plans: [plan], library: library, sfx: sfx)
        }
        let original = try await render(plan)
        let fp = original.timeline.renderFingerprint
        #expect(try await render(plan).timeline.renderFingerprint == fp)
        #expect(try await render(SoundFixture.plan([cue])).timeline.renderFingerprint != fp)
        #expect(try await render(plan, dryPCM: dry.map { $0 * 2 }).timeline.renderFingerprint != fp)
        try f.wav("rain_light.wav", samples: [0.02, 0.02, 0.02])
        let changedBed = try await render(plan).timeline.renderFingerprint
        #expect(changedBed != fp)
        try f.wav("sfx/door.wav", samples: [Float](repeating: 0.3, count: 250))
        #expect(try await render(plan).timeline.renderFingerprint != changedBed)
        #expect(SoundFixture.hash(try Data(contentsOf: dryURL)) == dryDigest)
        #expect(try PCMCodec.readMonoSamples(from: dryURL).samples == dry)
        #expect(timeline.renderFingerprint == dryDigest && original.timeline.entries == timeline.entries)
    }

    @Test func limitsIntersamplePeaksAndOverloadedMultiTrackSums() async throws {
        let rate = 8000
        let count = 2000
        // fs/4 with a 45-degree phase puts its true peak between samples; *all* sample
        // peaks are below the soft knee. A sample-peak clamp leaves the sine > 1 dBTP.
        let dry = (0..<count).map { Float(1.12 * sin(Double.pi * Double($0) / 2 + .pi / 4)) }
        let timeline = try SoundFixture.timeline(rate: rate, count: count, entries: [("one", "a", 0, count)])
        let result = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: [])
        #expect(abs(result.samples[1000]) * sqrt(Float(2)) <= 0.8911)
        #expect(abs(result.samples[1000]) > 0.50)
        var transient = [Float](repeating: 0.1, count: rate * 2)
        transient[rate] = 2
        let longTimeline = try SoundFixture.timeline(rate: rate, count: transient.count, entries: [])
        let recovered = try SoundscapeMixer.mix(drySpeech: transient, timeline: longTimeline, plans: []).samples
        #expect(abs(recovered[100] - 0.1) < 0.001 && abs(recovered[rate * 2 - 100] - 0.1) < 0.001)
        #expect(recovered[rate] <= 0.89101 && recovered[rate + 10] < 0.06)
        let f = try SoundFixture()
        defer { f.remove() }
        try f.wav("forest_wind.wav", samples: [1, 1, 1, 1])
        try f.wav("sfx/door.wav", samples: [Float](repeating: 1, count: 200))
        let library = try f.registry()
        let point = SoundFixture.point(offset: 70, gain: 8)
        let sfx = try await SFXAssetResolver(store: TestSoundStore(f.directory), projectID: "book", library: library).resolve([point])
        let plan = SoundFixture.plan([SoundFixture.scene("forest", .forestWind, gain: 8)], [point])
        let hot = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: [plan], library: library, sfx: sfx)
        #expect(hot.samples.allSatisfy { $0.isFinite && abs($0) <= 0.89101 })
    }

    @Test func multiTrackBookExportsAllFormatsAndReadsBackOriginalM4BMarkers() async throws {
        let f = try SoundFixture()
        defer { f.remove() }
        let rate = 24000
        let count = rate * 2
        // Resample the library bed and point effect from 8 kHz during the mix.
        try f.wav("forest_wind.wav", samples: (0..<3200).map { Float(0.2 * sin(Double($0) * 0.1)) })
        try f.wav("sfx/door.wav", samples: (0..<800).map { Float(0.4 * sin(Double($0) * 0.3)) })
        let library = try f.registry()
        let markers = [ChapterMarker(chapterID: "one", title: "林中", startFrame: 0, endFrameExclusive: 19000, sampleRate: rate),
                       ChapterMarker(chapterID: "two", title: "归来", startFrame: 19000, endFrameExclusive: Int64(count), sampleRate: rate)]
        let timeline = try SoundFixture.timeline(rate: rate, count: count,
                                                entries: [("one", "a", 0, 18000), ("two", "a", 19000, count)], markers: markers)
        let point = SoundFixture.point(chapter: "two", offset: 50)
        let sfx = try await SFXAssetResolver(store: TestSoundStore(f.directory), projectID: "book", library: library).resolve([point])
        let plans = [SoundFixture.plan([SoundFixture.scene("forest", .forestWind)]), SoundFixture.plan([], [point], chapter: "two")]
        let dry = (0..<count).map { Float(0.05 * sin(Double($0) * 0.04)) }
        let result = try SoundscapeMixer.mix(drySpeech: dry, timeline: timeline, plans: plans, library: library, sfx: sfx)
        #expect(result.timeline.chapters == markers && result.samples != dry)
        for format: ExportFormat in [.m4b, .wav, .m4a] {
            let url = f.directory.appendingPathComponent("book." + format.rawValue)
            let readback = try await BookExporter.export(result, format: format, metadata: .init(title: "音景测试"), to: url)
            let decoded = try PCMCodec.readMonoSamples(from: url)
            #expect(decoded.sampleRate == rate && abs(decoded.samples.count - count) < 1024)
            if format == .wav { #expect(decoded.samples == result.samples) }
            if format == .m4b {
                let report = try #require(readback)
                #expect(report.chapters.map(\.title) == markers.map(\.title))
                for (actual, expected) in zip(report.chapters, markers) {
                    #expect(abs(actual.startSeconds - expected.startSeconds) < 0.001)
                    #expect(abs(actual.durationSeconds - expected.durationSeconds) < 0.002)
                }
            }
        }
    }
}
