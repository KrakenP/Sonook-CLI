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

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", projectID = "project_id", jobID = "job_id"
        case blockingSegmentIDs = "blocking_segment_ids", status, guidance, export, publication
    }
}

extension SonookEngine {
    /// Builds a new verbatim audiobook project. Blocked builds retain their job and assets for review.
    public func buildAudiobook(
        sourceFileURL: URL, projectName: String, chapterSpec: String? = nil, format: ExportFormat = .m4b,
        soundscapeEnabled: Bool = false, soundLibraryDirectory: URL? = nil,
        sfxHelperExecutable: URL? = nil, sfxLicenseTag: String? = nil, publishPack: Bool = false,
        outputURL: URL? = nil, seed: UInt64 = 42, maxRepairRounds: Int = 2,
        progress: @escaping @Sendable (String) -> Void = { _ in }
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
        let source = try sourceFileURL.resolvingSymlinksInPath().resourceValues(forKeys: fileKeys)
        guard source.isRegularFile == true else { throw EngineSDKError.invalidInput("Expected a source file") }
        if let outputURL {
            let timelineURL = outputURL.deletingPathExtension().appendingPathExtension("timeline.json")
            for url in [outputURL, timelineURL] where FileManager.default.fileExists(atPath: url.path) {
                let existing = try url.resolvingSymlinksInPath().resourceValues(forKeys: fileKeys)
                guard existing.isRegularFile == true else { throw EngineSDKError.invalidInput("Expected an output file at \(url.path)") }
                if let sourceID = source.fileResourceIdentifier, sourceID.isEqual(existing.fileResourceIdentifier) {
                    throw EngineSDKError.invalidInput("The output would overwrite the source file")
                }
            }
        }

        let project = try await createProject(name: projectName)
        let id = project.projectID
        progress("[Build] Importing source into project \(id)...")
        _ = try await importBook(projectID: id, fileURL: sourceFileURL)
        _ = try await analyzeChapters(projectID: id, chapterSpec: chapterSpec, seed: seed, progress: progress)
        let job = try await submitAudiobookGenerateJob(projectID: id, chapterSpec: chapterSpec,
                                                      seed: seed, maxRepairRounds: maxRepairRounds)
        let jobID = job.job.jobID
        progress("[Build] Running generation job \(jobID)...")
        let generation = try await runJob(jobID: jobID, progress: progress)
        let verification = try await verifyProject(projectID: id, chapterSpec: chapterSpec)
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
            return AudiobookBuildReport(projectID: id, jobID: jobID,
                                        status: finished ? .needsReview : jobStatus,
                                        blockingSegmentIDs: verification.blockingSegmentIDs,
                                        guidance: guidance, export: nil, publication: nil)
        }

        let exported = try await exportBook(projectID: id, format: format, destinationURL: outputURL,
                                            chapterSpec: chapterSpec, soundscapeEnabled: soundscapeEnabled,
                                            soundLibraryDirectory: soundLibraryDirectory, sfxHelperExecutable: sfxHelperExecutable,
                                            sfxLicenseTag: sfxLicenseTag, progress: progress)
        let publication = publishPack ? try await publishAudioPack(
            projectID: id, chapterSpec: chapterSpec, soundscapeEnabled: soundscapeEnabled,
            soundLibraryDirectory: soundLibraryDirectory, sfxHelperExecutable: sfxHelperExecutable,
            sfxLicenseTag: sfxLicenseTag, progress: progress
        ) : nil
        return AudiobookBuildReport(projectID: id, jobID: jobID, status: .completed, blockingSegmentIDs: [],
                                    guidance: [], export: exported, publication: publication)
    }
}
