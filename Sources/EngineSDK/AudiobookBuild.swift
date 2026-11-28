import AudioCore
import Foundation

public struct AudiobookBuildReport: Encodable, Sendable {
    public let schemaVersion = 1
    public let projectID: String
    public let jobID: String
    public let status: JobStatus
    public let blockingSegmentIDs: [String]
    public let guidance: [String]
    public let export: BookExportReport?
    public let publication: PublishAudioPackReport?
    public let outputDirectory: String?
    public let charactersPath: String?
    public let verifyReportPath: String?
    public let chapterCount: Int?
    public let characterCount: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", projectID = "project_id", jobID = "job_id"
        case blockingSegmentIDs = "blocking_segment_ids", status, guidance, export, publication
        case outputDirectory = "output_directory", charactersPath = "characters_path", verifyReportPath = "verify_report_path"
        case chapterCount = "chapter_count", characterCount = "character_count"
    }
}

extension SonookEngine {
    private func buildModel(_ kind: ModelKind, preferring hint: String? = nil) async throws -> String {
        let entry = try await resolveModelEntry(explicitID: nil, kind: kind, preferProviderContaining: hint)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.localPath, isDirectory: &directory), directory.boolValue else {
            throw EngineSDKError.modelNotConfigured("Missing local model \(entry.modelID). Run `sonook model register` first.")
        }
        return entry.modelID
    }

    private func validateBuildOutputs(source: URLResourceValues, files: [URL], directories: [URL]) throws {
        guard !files.isEmpty || !directories.isEmpty else { return }
        // A new output can already alias another planned path through a symlinked parent
        // or case-insensitive volume, even before either file has a resource identifier.
        func pathKey(_ url: URL) throws -> String {
            guard url.isFileURL else { throw EngineSDKError.invalidInput("Expected a local output path") }
            var ancestor = url.standardizedFileURL
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
            let resolved = missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
            let sensitive = try ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            return sensitive == false ? resolved.path.lowercased() : resolved.path
        }
        let assets = try pathKey(workspaceRoot.appendingPathComponent(SonookWorkspaceLayout.assetsFolderName))
        func outputKey(_ url: URL) throws -> String {
            let key = try pathKey(url)
            guard key != assets, !key.hasPrefix(assets + "/") else {
                throw EngineSDKError.invalidInput("Export destination is inside immutable workspace assets")
            }
            return key
        }
        var paths = Set<String>()
        for directory in directories {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw EngineSDKError.invalidInput("Expected an output directory at \(directory.path)")
            }
            paths.insert(try outputKey(directory))
        }
        var existingOutputs: [URLResourceValues] = []
        for url in files {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard paths.insert(try outputKey(url)).inserted else {
                throw EngineSDKError.invalidInput("Build outputs overlap at \(url.path)")
            }
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            let existing = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileResourceIdentifierKey])
            guard existing.isRegularFile == true else { throw EngineSDKError.invalidInput("Expected an output file at \(url.path)") }
            if let id = existing.fileResourceIdentifier {
                guard !id.isEqual(source.fileResourceIdentifier) else {
                    throw EngineSDKError.invalidInput("The output would overwrite the source file")
                }
                guard !existingOutputs.contains(where: { id.isEqual($0.fileResourceIdentifier) }) else {
                    throw EngineSDKError.invalidInput("Build outputs overlap at \(url.path)")
                }
                existingOutputs.append(existing)
            }
        }
    }

    /// Builds a new verbatim audiobook project. Blocked builds retain their job and assets for review.
    public func buildAudiobook(
        sourceFileURL: URL, projectName: String, chapterSpec: String? = nil, format: ExportFormat = .m4b,
        soundscapeEnabled: Bool = false, soundLibraryDirectory: URL? = nil,
        sfxHelperExecutable: URL? = nil, sfxLicenseTag: String? = nil, publishPack: Bool = false,
        outputURL: URL? = nil, seed: UInt64 = 42, maxRepairRounds: Int = 2,
        sidecarOutputDirectory: URL? = nil, progress: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: (@Sendable (BuildProgressEvent) -> Void)? = nil
    ) async throws -> AudiobookBuildReport {
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineSDKError.invalidInput("An audiobook title is required")
        }
        guard maxRepairRounds >= 0 else {
            throw EngineSDKError.invalidInput("Maximum repair rounds must be nonnegative")
        }
        try Self.validateSoundscapeOptions(enabled: soundscapeEnabled, library: soundLibraryDirectory,
                                           helper: sfxHelperExecutable, license: sfxLicenseTag)
        let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileResourceIdentifierKey]
        guard sourceFileURL.isFileURL else { throw EngineSDKError.invalidInput("Expected a local source file") }
        let source = try sourceFileURL.resolvingSymlinksInPath().resourceValues(forKeys: fileKeys)
        guard source.isRegularFile == true else { throw EngineSDKError.invalidInput("Expected a source file") }
        let cards = sidecarOutputDirectory?.appendingPathComponent(SonookWorkspaceLayout.charactersMarkdownFileName)
        let verify = sidecarOutputDirectory?.appendingPathComponent("verify-report.json")
        let releases = publishPack ? sidecarOutputDirectory?.appendingPathComponent("releases", isDirectory: true) : nil
        let directories = [sidecarOutputDirectory, releases].compactMap { $0 }
        func outputFiles(_ audio: URL?) -> [URL] {
            [audio, audio?.deletingPathExtension().appendingPathExtension("timeline.json"), cards, verify].compactMap { $0 }
        }
        try validateBuildOutputs(source: source, files: outputFiles(outputURL), directories: directories)
        let llm = try await buildModel(.llm)
        let audition = try await buildModel(.tts, preferring: "voice-design")
        let tts = try await buildModel(.tts, preferring: "voxcpm2")
        let asr = try await buildModel(.asr)

        @Sendable func emit(_ event: BuildProgressEvent) {
            progress(event.message)
            onEvent?(event)
        }
        let project = Self.newProject(name: projectName)
        let id = project.projectID
        emit(.init(stage: .importing, message: "正在读取原文"))
        let input = try BookImportInput(fileURL: sourceFileURL, projectID: id)
        let selected = try ChapterSelection.select(from: input.book.chapters, spec: chapterSpec)
        let destination = outputURL ?? sidecarOutputDirectory.map {
            SonookWorkspaceLayout.sidecarAudiobookOutputURL(in: $0, title: projectName,
                chapterNumbers: selected.map(\.chapterNumber), totalChapterCount: input.book.chapters.count,
                audioMode: soundscapeEnabled ? .soundscape : .dry, format: format)
        }
        if let sidecarOutputDirectory {
            if outputURL == nil { try validateBuildOutputs(source: source, files: outputFiles(destination), directories: directories) }
            try FileManager.default.createDirectory(at: sidecarOutputDirectory, withIntermediateDirectories: true)
        }
        try await store.saveProject(project)
        let imported = try await persistBook(input, projectID: id)
        emit(.init(stage: .importing, message: "已导入 \(imported.chapters.count) 章，\(imported.sourceDocument.totalUTF8Bytes) UTF-8 字节"))
        emit(.init(stage: .analyzing, message: "正在加载本地分析模型"))
        let analysis = try await analyzeChapters(projectID: id, chapterSpec: chapterSpec, llmModelID: llm,
                                                 seed: seed, progress: progress, onEvent: emit)
        if let cards { _ = try await exportCharactersMarkdown(projectID: id, to: cards) }
        let job = try await submitAudiobookGenerateJob(projectID: id, chapterSpec: chapterSpec,
                                                      auditionTTSModelID: audition, mainTTSModelID: tts, asrModelID: asr,
                                                      seed: seed, maxRepairRounds: maxRepairRounds)
        let jobID = job.job.jobID
        progress("[Build] Running generation job \(jobID)...")
        let generation = try await runJob(jobID: jobID, progress: progress, onEvent: emit)
        emit(.init(stage: .synthesizing, message: "正在核验片段与音频文件"))
        let verification = try await verifyProject(projectID: id, chapterSpec: chapterSpec)
        if let verify { _ = try await saveVerificationReport(verification, to: verify) }
        func report(status: JobStatus, blocking: [String] = [], guidance: [String] = [],
                    export: BookExportReport? = nil, publication: PublishAudioPackReport? = nil) -> AudiobookBuildReport {
            AudiobookBuildReport(projectID: id, jobID: jobID, status: status, blockingSegmentIDs: blocking,
                                 guidance: guidance, export: export, publication: publication,
                                 outputDirectory: sidecarOutputDirectory?.path, charactersPath: cards?.path,
                                 verifyReportPath: verify?.path, chapterCount: analysis.chapters.count,
                                 characterCount: analysis.characterCount)
        }
        let jobStatus: JobStatus = generation.cancelled ? .cancelled : generation.finalStatus
        let finished = jobStatus == .completed || jobStatus == .needsReview
        guard finished && verification.exportReady else {
            func quoted(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            let workspace = "--workspace \(quoted(workspaceRoot.path))"
            let selection = chapterSpec.map { " --chapters \(quoted($0))" } ?? ""
            let scope = "--project \(id)\(selection) \(workspace)"
            var guidance: [String] = []
            if !finished {
                guidance += ["sonook job status \(jobID) \(workspace)", "sonook job resume \(jobID) \(workspace)"]
            }
            if !verification.exportReady {
                guidance += ["sonook review list \(scope)", "sonook review retry \(scope)",
                             "sonook review approve-all \(scope) --note '<review note>'"]
            }
            return report(status: finished ? .needsReview : jobStatus, blocking: verification.blockingSegmentIDs, guidance: guidance)
        }

        emit(.init(stage: .exporting, message: "正在导出 \(format.rawValue.uppercased())"))
        let exported = try await exportBook(projectID: id, format: format, destinationURL: destination,
                                            chapterSpec: chapterSpec, soundscapeEnabled: soundscapeEnabled,
                                            soundLibraryDirectory: soundLibraryDirectory, sfxHelperExecutable: sfxHelperExecutable,
                                            sfxLicenseTag: sfxLicenseTag, progress: progress)
        let packURL = releases?.appendingPathComponent("\(SonookWorkspaceLayout.sanitizeFileNameComponent(projectName))__\(id).audiopack", isDirectory: true)
        let publication = publishPack ? try await publishAudioPack(
            projectID: id, chapterSpec: chapterSpec, outputURL: packURL,
            soundscapeEnabled: soundscapeEnabled,
            soundLibraryDirectory: soundLibraryDirectory, sfxHelperExecutable: sfxHelperExecutable,
            sfxLicenseTag: sfxLicenseTag, progress: progress
        ) : nil
        emit(.init(stage: .exporting, message: "已完成导出"))
        return report(status: .completed, export: exported, publication: publication)
    }
}
