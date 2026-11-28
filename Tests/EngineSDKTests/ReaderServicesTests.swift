import AudioCore
import AudioRenderKit
@testable import EngineSDK
import Foundation
import Testing

@Suite struct ReaderServicesTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    @Test func readsExportedChapterAndSelectsMatchingAudio() async throws {
        let engine = try SonookEngine(workspaceRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await engine.createProject(name: "书")
        let id = project.projectID
        let source = root.appendingPathComponent("book.txt")
        try Data("第一章\r\n开篇。\r\n第二章\r\n“好📖”".utf8).write(to: source)
        let book = try await engine.importBook(projectID: id, fileURL: source)
        let chapter = try #require(book.chapters.last)
        let raw = "“好📖”"
        let span = try SourceSpan(start: chapter.sourceSpan.endExclusive - raw.utf8.count,
                                  endExclusive: chapter.sourceSpan.endExclusive)
        let wav = try PCMCodec.encodeWAVData(samples: Array(repeating: 0.1, count: 4800), sampleRate: 48_000)
        let asset = try await engine.store.commitBytes(wav, projectID: id, kind: .segmentWAV, fileExtension: "wav",
            sampleRate: 48_000, frameCount: 4800, provenance: .init(chapterID: chapter.chapterID, segmentID: "s"))
        let segment = ScriptSegment(segmentID: "s", chapterID: chapter.chapterID, sourceDocumentRevision: chapter.sourceDocumentRevision,
            sourceSpan: span, sourceText: raw, spokenText: "好📖", speakerID: "c", voiceProfileRevision: "1", scriptRevision: 1,
            audioArtifactID: asset.assetID, status: .verified)
        var script = ScriptDocument(chapterID: chapter.chapterID, sourceDocumentRevision: chapter.sourceDocumentRevision,
                                    scriptRevision: 1, segments: [segment])
        try await engine.store.saveScript(script, projectID: id)
        try await engine.store.saveCatalog(.init(projectID: id, cards: [.init(characterID: "c", canonicalName: "小林")]))
        let exported = try await engine.exportBook(projectID: id, format: .wav, chapterSpec: "2")
        let audio = URL(fileURLWithPath: exported.outputPath)
        let directory = SonookWorkspaceLayout.audiobooksDirectory(workspaceRoot: root, project: project)
        #expect(audio.deletingLastPathComponent().path == directory.path)
        let timeline = try JSONDecoder().decode(RenderedBookTimeline.self, from: Data(contentsOf: URL(fileURLWithPath: exported.timelinePath)))
        let entry = try #require(timeline.entries.first)
        let wrong = directory.appendingPathComponent("other.m4b")
        let bare = directory.appendingPathComponent("newest.m4a")
        try Data().write(to: wrong)
        try Data().write(to: bare)
        let other = RenderedBookTimeline(sampleRate: 48_000, totalFrames: 96_000, totalDurationSeconds: 2,
            ambientMixed: false, renderFingerprint: "other", chapters: [], entries: [
                .init(chapterID: "other", segmentID: "s", speakerID: "c", sourceSpan: span,
                      startFrame: 48_000, endFrameExclusive: 96_000, startSeconds: 1, endSeconds: 2, pauseAfterMs: 0)])
        try JSONEncoder().encode(other).write(to: wrong.deletingPathExtension().appendingPathExtension("timeline.json"))
        for (index, url) in [audio, wrong, bare].enumerated() {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                                                  ofItemAtPath: url.path)
        }
        script.segments[0].status = .needsReview
        try await engine.store.saveScript(script, projectID: id)
        let audit = SegmentQualityAudit(segmentID: "s", wavAssetID: asset.assetID, rawTranscript: "", rawCER: 1, adjustedCER: 1,
            exemptions: [], nonExemptSubstitutions: 0, deletions: 1, insertions: 0, rmsDBFS: -20,
            verdictLabel: "needs_review", failureReasons: ["highCER"])
        _ = try await engine.store.commitBytes(JSONEncoder().encode(audit), projectID: id, kind: .qualityReport, fileExtension: "json",
            sampleRate: nil, frameCount: nil, provenance: .init(chapterID: chapter.chapterID))

        let summary = try #require(try await engine.listProjectSummaries().first)
        #expect(summary.chapterCount == 2 && summary.analyzedChapterCount == 1 && summary.needsReviewCount == 1)
        #expect(summary.latestAudioPath == wrong.path)
        #expect(summary.latestTimelinePath == wrong.deletingPathExtension().appendingPathExtension("timeline.json").path)
        let first = try await engine.loadReaderChapter(projectID: id)
        #expect(first.chapterText == "第一章\n开篇。\n" && first.segments.isEmpty)
        #expect(first.audioFilePath == bare.path && first.timelinePath == nil)
        let reader = try await engine.loadReaderChapter(projectID: id, chapterID: chapter.chapterID,
                                                       preferredAudioURL: root.appendingPathComponent("missing.wav"))
        #expect(reader.audioFilePath == audio.path && reader.timelinePath == exported.timelinePath)
        #expect(reader.audioDurationSeconds == timeline.totalDurationSeconds)
        #expect(reader.chapterText == "第二章\n" + raw && reader.chapterStartUTF8Byte == chapter.sourceSpan.start)
        let seg = try #require(reader.segments.first)
        #expect(seg.startSeconds == entry.startSeconds && seg.endSeconds == entry.endSeconds)
        #expect(seg.sourceSpan == span && seg.chapterUTF8Start == "第二章\n".utf8.count && seg.chapterUTF8EndExclusive == reader.chapterText.utf8.count)
        #expect(seg.speakerName == "小林" && seg.sourceText == raw && seg.spokenText == "好📖")
        #expect(seg.qualityReasons == [.highCER] && seg.status == .needsReview)
        let path = try await engine.store.resolveFileURL(for: asset.assetID)
        #expect(seg.segmentAudioPath == path.path)
        try FileManager.default.removeItem(at: path)
        try await engine.store.saveCatalog(.init(projectID: id))
        let preferred = try await engine.loadReaderChapter(projectID: id, chapterID: chapter.chapterID, preferredAudioURL: wrong)
        #expect(preferred.audioFilePath == wrong.path && preferred.audioDurationSeconds == 2)
        let missing = try #require(preferred.segments.first)
        #expect(missing.speakerName == "c" && missing.segmentAudioPath == nil && missing.startSeconds == nil)
        try FileManager.default.removeItem(atPath: exported.timelinePath)
        try FileManager.default.removeItem(at: wrong.deletingPathExtension().appendingPathExtension("timeline.json"))
        let bareSummary = try #require(try await engine.listProjectSummaries().first)
        #expect(bareSummary.latestAudioPath == bare.path && bareSummary.latestTimelinePath == nil)
    }

    @Test func summariesAndSourceRevisions() async throws {
        let engine = try SonookEngine(workspaceRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, date) in [("z", "2026-01-01"), ("b", "2026-01-02"), ("a", "2026-01-02")] {
            try await engine.store.saveProject(.init(projectID: id, name: id, createdAtISO8601: date))
        }
        for (id, date) in [("older", "2026-01-01"), ("latest", "2026-01-02")] {
            try await engine.store.createJob(.init(jobID: id, projectID: "a", workflowKind: "test", status: .paused,
                                                   createdAtISO8601: date), nodes: [], edges: [])
        }
        let source = root.appendingPathComponent("book.txt")
        try Data("原来的书".utf8).write(to: source)
        let book = try await engine.importBook(projectID: "a", fileURL: source)
        let doc = book.sourceDocument
        let episode = try await engine.store.commitBytes(Data("播客".utf8), projectID: "a", kind: .sourceDocument,
            fileExtension: "txt", sampleRate: nil, frameCount: nil, provenance: .init())
        try await engine.store.saveSourceDocument(.init(sourceDocumentRevision: "ep1", projectID: "a", format: .txt,
            originalFileName: "episode.txt", rawAssetID: episode.assetID, rawSHA256: episode.fileSHA256,
            normalizedAssetID: episode.assetID, normalizedSHA256: episode.fileSHA256, detectedEncoding: "utf-8",
            parserVersion: "podcast_transcript_v1", totalUTF8Bytes: 6, chapterCount: 0, importedAtISO8601: "9999-01-01"), chapters: [])
        let chapter = try #require(book.chapters.first)
        try await engine.store.saveScript(.init(chapterID: chapter.chapterID, sourceDocumentRevision: "old-edition",
                                                scriptRevision: 1, segments: []), projectID: "a")
        try await engine.store.saveScript(.init(chapterID: "legacy", sourceDocumentRevision: "v1",
                                                scriptRevision: 1, segments: []), projectID: "b")
        let summaries = try await engine.listProjectSummaries()
        #expect(summaries.map(\.projectID) == ["a", "b", "z"])
        let summary = try #require(summaries.first)
        #expect(summary.latestJobID == "latest" && summary.latestJobStatus == .paused)
        #expect(summary.chapterCount == 1 && summary.analyzedChapterCount == 0)
        #expect(summaries[1].chapterCount == 0 && summaries[1].analyzedChapterCount == 1)
        #expect(summaries.last?.chapterCount == 0 && summaries.last?.latestJobID == nil)
        let reader = try await engine.loadReaderChapter(projectID: "a")
        #expect(reader.chapterText == "原来的书" && reader.segments.isEmpty)
        await #expect(throws: EngineSDKError.self) { try await engine.loadReaderChapter(projectID: "missing") }
        await #expect(throws: EngineSDKError.self) { try await engine.loadReaderChapter(projectID: "z") }
        await #expect(throws: EngineSDKError.self) { try await engine.loadReaderChapter(projectID: "a", chapterID: "missing") }
        let normalized = try await engine.store.resolveFileURL(for: doc.normalizedAssetID)
        try Data("损坏".utf8).write(to: normalized)
        await #expect(throws: WorkflowStoreError.self) { try await engine.loadReaderChapter(projectID: "a") }
    }

    @Test func auditionsRequireMatchingAnchorAndIntactFile() async throws {
        let engine = try SonookEngine(workspaceRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await engine.createProject(name: "试音")
        let id = project.projectID
        let asset = try await engine.store.commitBytes(Data([1, 2]), projectID: id, kind: .voiceAudition, fileExtension: "wav",
            sampleRate: 24_000, frameCount: 1, provenance: .init(characterID: "c"))
        let url = try await engine.store.resolveFileURL(for: asset.assetID)
        func saveAnchor(hash: String) async throws {
            let anchor = VoiceTimbreAnchor(anchorID: "anchor", assetID: asset.assetID, fileSHA256: hash,
                generatorProviderID: "fake", generatorModelID: "voice", designPrompt: "", auditionText: "",
                sampleRate: 24_000, createdAtISO8601: "2026-01-01")
            try await engine.store.saveCatalog(.init(projectID: id, cards: [.init(characterID: "c", canonicalName: "林", timbreAnchor: anchor)]))
        }
        #expect(try await engine.auditionAudioURL(forCharacterID: "c", inProjectID: id) == nil)
        try await saveAnchor(hash: asset.fileSHA256)
        #expect(try await engine.auditionAudioURL(forCharacterID: "c", inProjectID: id) == url)
        #expect(try await engine.auditionAudioURL(forCharacterID: "林", inProjectID: id) == nil)
        try await saveAnchor(hash: "wrong")
        #expect(try await engine.auditionAudioURL(forCharacterID: "c", inProjectID: id) == nil)
        try await saveAnchor(hash: asset.fileSHA256)
        try Data([2, 1]).write(to: url)
        #expect(try await engine.auditionAudioURL(forCharacterID: "c", inProjectID: id) == nil)
    }

    @Test func stopDuringImportDoesNotPersistAProject() async throws {
        let engine = try SonookEngine(workspaceRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt")
        try Data("第一章\n初见。".utf8).write(to: source)
        let providers: [(String, ModelKind)] = [("llm", .llm), ("voice-design", .tts), ("voxcpm2", .tts), ("asr", .asr)]
        for (name, kind) in providers {
            _ = try await engine.registerModel(modelID: name, kind: kind, providerID: name, localPath: root.path, estimatedPeakMiB: 256)
        }
        let build = Task {
            try await engine.buildAudiobook(sourceFileURL: source, projectName: "书", onEvent: { event in
                if event.stage == .importing { withUnsafeCurrentTask { $0?.cancel() } }
            }, onJobCreated: { _, _ in Issue.record("Cancelled import submitted a generation job") })
        }
        await #expect(throws: CancellationError.self) { try await build.value }
        #expect(try await engine.listProjects().isEmpty)
    }

    @Test func cancelledBuildPreservesCheckpointAndCanResume() async throws {
        let engine = try SonookEngine(workspaceRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep the original method usable as a first-class function, including without a type annotation.
        let originalBuild = engine.buildAudiobook
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await originalBuild(root.appendingPathComponent("book.txt"), "书", nil, .wav, false,
                                           nil, nil, nil, false, nil, 42, 0, nil, { _ in }, nil)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await engine.listProjectSummaries().isEmpty)

        let project = try await engine.createProject(name: "书")
        let job = try await engine.submitFakeDemoJob(projectID: project.projectID, config: .init(segmentCount: 1)).job
        let created = AsyncStream<(String, String)>.makeStream()
        let task = Task {
            try await engine.runBuildJob(job, onJobCreated: { created.continuation.yield(($0, $1)) }, progress: { message in
                if message == "running n_asr_0001" { withUnsafeCurrentTask { $0?.cancel() } }
            }, onEvent: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        created.continuation.finish()
        var iterator = created.stream.makeAsyncIterator()
        let ids = try #require(await iterator.next())
        #expect(ids.0 == project.projectID && ids.1 == job.jobID)
        #expect(await iterator.next() == nil)
        let stopped = try #require(try await engine.jobSnapshot(jobID: job.jobID))
        #expect(stopped.job.cancelRequested && stopped.job.status == .cancelled)
        let checkpoint = try #require(stopped.nodes.first { $0.nodeID == "n_tts_0001" && $0.status == .completed }?.outputAssetID)
        #expect(try await engine.store.verifyAssetIntegrity(assetID: checkpoint))
        let resumed = try await engine.resumeJob(jobID: job.jobID)
        #expect(resumed.finalStatus == .completed && resumed.skippedCompletedNodeIDs.contains("n_tts_0001"))
        #expect(try await engine.store.verifyAssetIntegrity(assetID: checkpoint))
    }
}
