import AudioCore
import AudioRenderKit
import Foundation
import ModelRuntime

extension SonookEngine {
    public func listProjectSummaries() async throws -> [ProjectSummary] {
        let projects = try await store.listProjects().sorted {
            if $0.createdAtISO8601 == $1.createdAtISO8601 { return $0.projectID < $1.projectID }
            return $0.createdAtISO8601 > $1.createdAtISO8601
        }
        var summaries: [ProjectSummary] = []
        for project in projects {
            let id = project.projectID
            let chapters = (try? productionChapters(projectID: id)) ?? []
            let revisions = Dictionary(chapters.map { ($0.chapterID, $0.sourceDocumentRevision) }, uniquingKeysWith: { first, _ in first })
            // Legacy chapter jobs saved scripts before the production chapter index existed.
            let scripts = try await store.listScripts(projectID: id).filter {
                chapters.isEmpty || revisions[$0.chapterID] == $0.sourceDocumentRevision
            }
            let reviewCount = scripts.reduce(0) { $0 + $1.segments.count(where: { $0.status == .needsReview }) }
            // StorageKit orders jobs by creation time, then job ID, both ascending.
            let job = try await store.listJobs(projectID: id).last
            let exports = try readerExports(for: project)
            let export = exports.first { $0.timelineURL != nil } ?? exports.first
            summaries.append(ProjectSummary(projectID: id, name: project.name, projectType: project.projectType,
                createdAtISO8601: project.createdAtISO8601, chapterCount: chapters.count,
                analyzedChapterCount: scripts.count, needsReviewCount: reviewCount,
                latestJobID: job?.jobID, latestJobStatus: job?.status,
                latestAudioPath: export?.audioURL.path, latestTimelinePath: export?.timelineURL?.path))
        }
        return summaries
    }

    public func loadReaderChapter(projectID: String, chapterID: String? = nil, preferredAudioURL: URL? = nil) async throws -> ReaderChapterPayload {
        guard let project = try await store.project(id: projectID) else { throw EngineSDKError.projectNotFound(projectID) }
        let chapters = try productionChapters(projectID: projectID)
        guard let chapter = chapters.first(where: { chapterID == nil || $0.chapterID == chapterID }) else {
            if let chapterID { throw EngineSDKError.invalidInput("Unknown chapter \(chapterID)") }
            throw EngineSDKError.sourceNotImported(projectID)
        }
        let text = try await readerChapterText(chapter)
        let media = try readerMedia(for: project, chapterID: chapter.chapterID, preferredAudioURL: preferredAudioURL)
        var segments: [ReaderSegment] = []
        if let script = try await store.loadScript(projectID: projectID, chapterID: chapter.chapterID),
           script.sourceDocumentRevision == chapter.sourceDocumentRevision, !script.segments.isEmpty {
            let cards = try await store.loadCatalog(projectID: projectID)?.cards ?? []
            let names = Dictionary(cards.map { ($0.characterID, $0.canonicalName) }, uniquingKeysWith: { first, _ in first })
            let entries = (media.timeline?.entries ?? []).filter { $0.chapterID == chapter.chapterID }
            let timings = Dictionary(entries.map { ($0.segmentID, $0) }, uniquingKeysWith: { first, _ in first })
            let audits = try await loadQualityAudits(projectID: projectID, chapterID: chapter.chapterID)
            for segment in script.segments {
                let assetID = segment.audioArtifactID
                var path: String?
                if let assetID, let url = try? await store.resolveFileURL(for: assetID),
                   FileManager.default.fileExists(atPath: url.path) { path = url.path }
                let audit = assetID.flatMap { audits.byAssetID[$0] }
                let start = max(0, segment.sourceSpan.start - chapter.sourceSpan.start)
                let end = max(start, segment.sourceSpan.endExclusive - chapter.sourceSpan.start)
                let timing = timings[segment.segmentID]
                segments.append(ReaderSegment(segmentID: segment.segmentID, chapterID: chapter.chapterID,
                    speakerID: segment.speakerID, speakerName: names[segment.speakerID] ?? segment.speakerID,
                    sourceSpan: segment.sourceSpan, chapterUTF8Start: start, chapterUTF8EndExclusive: end,
                    sourceText: segment.sourceText, spokenText: segment.spokenText, status: segment.status,
                    startSeconds: timing?.startSeconds, endSeconds: timing?.endSeconds, segmentAudioPath: path,
                    qualityReasons: audit?.failureReasons.compactMap(QualityReason.init(rawValue:)) ?? []))
            }
        }
        return ReaderChapterPayload(projectID: projectID, chapterID: chapter.chapterID, chapterNumber: chapter.chapterNumber,
            title: chapter.title, chapterText: text, chapterStartUTF8Byte: chapter.sourceSpan.start,
            audioFilePath: media.export?.audioURL.path, timelinePath: media.export?.timelineURL?.path,
            audioDurationSeconds: media.timeline?.totalDurationSeconds, segments: segments)
    }

    public func auditionAudioURL(forCharacterID characterID: String, inProjectID projectID: String) async throws -> URL? {
        let catalog = try await store.loadCatalog(projectID: projectID)
        guard let card = catalog?.cards.first(where: { $0.characterID == characterID }), card.timbreAnchor != nil else { return nil }
        return try? await ModelResourceManager.resolveVerifiedTimbreAnchorURL(for: card, artifactStore: store).fileURL
    }

    private func readerChapterText(_ chapter: ChapterRecord) async throws -> String {
        var source = try await store.latestSourceDocument(projectID: chapter.projectID)
        if source?.sourceDocumentRevision != chapter.sourceDocumentRevision {
            // A project can include a book and several independently imported episode transcripts.
            source = try await store.sourceDocument(projectID: chapter.projectID, revision: chapter.sourceDocumentRevision)
        }
        guard let source else { throw EngineSDKError.sourceNotImported(chapter.projectID) }
        let data = try await store.readVerifiedData(for: source.normalizedAssetID)
        let span = chapter.sourceSpan
        guard span.endExclusive <= data.count else { throw SourceSpanError.outOfBounds }
        let start = data.startIndex + span.start
        let end = data.startIndex + span.endExclusive
        guard start == data.endIndex || data[start] & 0xC0 != 0x80,
              let text = String(data: data[start..<end], encoding: .utf8) else { throw SourceSpanError.splitsUnicodeScalar }
        return text
    }

    private func readerExports(for project: ProjectRecord) throws -> [ReaderExport] {
        let directory = SonookWorkspaceLayout.audiobooksDirectory(workspaceRoot: workspaceRoot, project: project)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                               options: .skipsHiddenFiles)
        let dated = files.compactMap { url -> (url: URL, date: Date)? in
            guard ["m4a", "m4b", "wav"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            // Keep the same workspace path spelling that exportBook returned, including symlinked roots.
            return (directory.appendingPathComponent(url.lastPathComponent), values.contentModificationDate ?? .distantPast)
        }
        return dated.sorted {
            if $0.date == $1.date { return $0.url.lastPathComponent < $1.url.lastPathComponent }
            return $0.date > $1.date
        }.map { ReaderExport(audioURL: $0.url) }
    }

    private func readerMedia(for project: ProjectRecord, chapterID: String, preferredAudioURL: URL?) throws
        -> (export: ReaderExport?, timeline: RenderedBookTimeline?) {
        if let preferredAudioURL, preferredAudioURL.isFileURL,
           (try? preferredAudioURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let export = ReaderExport(audioURL: preferredAudioURL)
            return (export, export.loadTimeline())
        }
        let exports = try readerExports(for: project)
        var newestTimeline: RenderedBookTimeline?
        for (index, export) in exports.enumerated() {
            guard let timeline = export.loadTimeline() else { continue }
            if timeline.entries.contains(where: { $0.chapterID == chapterID }) { return (export, timeline) }
            if index == 0 { newestTimeline = timeline }
        }
        return (exports.first, newestTimeline)
    }
}

private struct ReaderExport {
    let audioURL: URL
    let timelineURL: URL?

    init(audioURL: URL) {
        self.audioURL = audioURL
        let url = audioURL.deletingPathExtension().appendingPathExtension("timeline.json")
        timelineURL = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true ? url : nil
    }

    func loadTimeline() -> RenderedBookTimeline? {
        guard let timelineURL, let data = try? Data(contentsOf: timelineURL),
              let timeline = try? JSONDecoder().decode(RenderedBookTimeline.self, from: data),
              timeline.schemaVersion == AudioCoreInfo.currentSchemaVersion else { return nil }
        return timeline
    }
}
