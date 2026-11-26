import AudioCore
import DistributionKit
import Foundation
import ModelRuntime
import StorageKit
import WorkflowKit

public struct EngineDoctorReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let project: String
    public let engineVersion: String
    public let workspacePath: String
    public let osVersion: String
    public let processorCount: Int
    public let runtimeSnapshot: RuntimeResourceSnapshot
    public let reconciliation: OrphanGCReport
    public let projectCount: Int
    public let modelCount: Int
    public let jobCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case project
        case engineVersion = "engine_version"
        case workspacePath = "workspace_path"
        case osVersion = "os_version"
        case processorCount = "processor_count"
        case runtimeSnapshot = "runtime_snapshot"
        case reconciliation
        case projectCount = "project_count"
        case modelCount = "model_count"
        case jobCount = "job_count"
    }
}

public enum EngineSDKError: Error, LocalizedError, Sendable {
    case projectNotFound(String)
    case jobNotFound(String)
    case sourceNotImported(String)
    case scriptNotAnalyzed(String)
    case segmentNotFound(String)
    case modelNotConfigured(String)
    case exportGateBlocked([String])
    case unsupportedWorkflow(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): return "Project not found: \(id)"
        case .jobNotFound(let id): return "Job not found: \(id)"
        case .sourceNotImported(let id): return "No source document imported for project \(id). Run `sonook import` first."
        case .scriptNotAnalyzed(let ch): return "Chapter \(ch) has not been analyzed yet. Run `sonook analyze` first."
        case .segmentNotFound(let seg): return "Segment not found in project scripts: \(seg)"
        case .modelNotConfigured(let msg): return "Model not configured: \(msg)"
        case .exportGateBlocked(let segs):
            let preview = segs.prefix(10).joined(separator: ", ")
            let suffix = segs.count > 10 ? " (+\(segs.count - 10) more)" : ""
            return "Export blocked: \(segs.count) segment(s) are not verified or explicitly approved: \(preview)\(suffix). Regenerate via `sonook segment regenerate` or approve via `sonook segment approve`."
        case .unsupportedWorkflow(let kind): return "Unsupported workflow kind: \(kind)"
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        }
    }
}

/// Unified Application Services facade for Sonook (shared by SonookCLI and future EngineServer/Apps).
public final class SonookEngine: Sendable {
    public let workspaceRoot: URL
    public let store: SQLiteWorkspaceStore
    let playbackSync: PlaybackSyncEngine
    public let runtime: ModelResourceManager

    public init(workspaceRoot: URL, memoryBudgetFraction: Double = 0.65) throws {
        self.workspaceRoot = workspaceRoot
        self.store = try SQLiteWorkspaceStore(rootDirectory: workspaceRoot)
        self.playbackSync = PlaybackSyncEngine(store: store)
        self.runtime = ModelResourceManager(budgetFraction: memoryBudgetFraction)
    }

    // MARK: - Diagnostics

    public func doctor() async throws -> EngineDoctorReport {
        let gc = try await store.runStartupReconciliation()
        let projects = try await store.listProjects()
        let models = try await store.listModels(kind: nil)
        let jobs = try await store.listJobs(projectID: nil)
        let snap = await runtime.snapshot()
        let info = ProcessInfo.processInfo
        return EngineDoctorReport(
            schemaVersion: AudioCoreInfo.currentSchemaVersion,
            project: AudioCoreInfo.projectName,
            engineVersion: EngineSDKInfo.version,
            workspacePath: workspaceRoot.path,
            osVersion: info.operatingSystemVersionString,
            processorCount: info.processorCount,
            runtimeSnapshot: snap,
            reconciliation: gc,
            projectCount: projects.count,
            modelCount: models.count,
            jobCount: jobs.count
        )
    }

    // MARK: - Projects

    public func createProject(
        name: String,
        type: ProjectType = .audiobook,
        ambientAudioEnabled: Bool = false,
        preferredLLMModelID: String? = nil,
        preferredAuditionTTSModelID: String? = nil,
        preferredMainTTSModelID: String? = nil,
        preferredASRModelID: String? = nil
    ) async throws -> ProjectRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = "proj_\(UUID().uuidString.prefix(8).lowercased())"
        let record = ProjectRecord(
            projectID: id,
            name: name,
            projectType: type,
            options: ProductionOptions(
                ambientAudioEnabled: ambientAudioEnabled,
                ambientTrack: nil,
                preferredLLMModelID: preferredLLMModelID,
                preferredAuditionTTSModelID: preferredAuditionTTSModelID,
                preferredMainTTSModelID: preferredMainTTSModelID,
                preferredASRModelID: preferredASRModelID
            ),
            createdAtISO8601: now
        )
        try await store.saveProject(record)
        return record
    }

    public func listProjects() async throws -> [ProjectRecord] {
        try await store.listProjects()
    }

    // MARK: - Model Registry

    public func registerModel(
        modelID: String,
        kind: ModelKind,
        providerID: String,
        localPath: String,
        revision: String = "local",
        license: String = "Apache-2.0",
        quantization: String? = nil,
        estimatedPeakMiB: Int,
        notes: String? = nil
    ) async throws -> ModelRegistryEntry {
        let resolved = URL(fileURLWithPath: localPath).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ModelRuntimeError.modelDirectoryMissing(resolved)
        }
        let entry = ModelRegistryEntry(
            modelID: modelID,
            kind: kind,
            providerID: providerID,
            localPath: resolved,
            revision: revision,
            license: license,
            quantization: quantization,
            estimatedPeakBytes: UInt64(max(256, estimatedPeakMiB)) * 1024 * 1024,
            measuredPeakBytes: nil,
            notes: notes,
            registeredAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        try await store.upsertModel(entry)
        return entry
    }

    public func listModels(kind: ModelKind? = nil) async throws -> [ModelRegistryEntry] {
        try await store.listModels(kind: kind)
    }

    // MARK: - Job Submission & Lifecycle

    public func submitFakeDemoJob(
        projectID: String,
        config: FakeDemoJobConfig = FakeDemoJobConfig(),
        priority: TaskPriority = .background
    ) async throws -> JobSnapshot {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let jobID = "job_\(UUID().uuidString.prefix(8).lowercased())"
        let effectiveCfg = FakeDemoJobConfig(
            segmentCount: config.segmentCount,
            failOnceSegmentIndex: config.failOnceSegmentIndex,
            permanentFailSegmentIndex: config.permanentFailSegmentIndex,
            needsReviewSegmentIndex: config.needsReviewSegmentIndex,
            stepDelayMs: config.stepDelayMs,
            ambientAudioEnabled: config.ambientAudioEnabled || project.options.ambientAudioEnabled
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let cfgJSON = String(decoding: try enc.encode(effectiveCfg), as: UTF8.self)

        let job = JobRecord(
            jobID: jobID,
            projectID: projectID,
            workflowKind: "fake-demo",
            status: .pending,
            priority: priority,
            configJSON: cfgJSON,
            createdAtISO8601: now
        )

        var nodes: [JobNodeRecord] = []
        var edges: [JobEdgeRecord] = []

        nodes.append(JobNodeRecord(nodeID: "n_analyze", jobID: jobID, kind: "fake_analyze", priority: priority, inputFingerprint: "fake_analyze_\(effectiveCfg.segmentCount)", createdAtISO8601: now))
        nodes.append(JobNodeRecord(nodeID: "n_audition", jobID: jobID, kind: "fake_audition", priority: priority, inputFingerprint: "fake_audition_v1", createdAtISO8601: now))
        edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "n_analyze", toNodeID: "n_audition", requiresVerified: true))

        for i in 1...effectiveCfg.segmentCount {
            let ttsID = String(format: "n_tts_%04d", i)
            let asrID = String(format: "n_asr_%04d", i)
            let payload = "{\"segment_index\":\(i)}"
            nodes.append(JobNodeRecord(nodeID: ttsID, jobID: jobID, kind: "fake_tts", priority: priority, inputFingerprint: "fake_tts_\(i)", payloadJSON: payload, maxAttempts: 3, createdAtISO8601: now))
            nodes.append(JobNodeRecord(nodeID: asrID, jobID: jobID, kind: "fake_asr", priority: priority, inputFingerprint: "fake_asr_\(i)", payloadJSON: payload, maxAttempts: 2, createdAtISO8601: now))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "n_audition", toNodeID: ttsID, requiresVerified: true))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: ttsID, toNodeID: asrID, requiresVerified: true))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: asrID, toNodeID: "n_render", requiresVerified: true))
        }

        nodes.append(JobNodeRecord(nodeID: "n_render", jobID: jobID, kind: "fake_render", priority: priority, inputFingerprint: "fake_render_\(effectiveCfg.ambientAudioEnabled)", createdAtISO8601: now))

        try await store.createJob(job, nodes: nodes, edges: edges)
        return try await store.jobSnapshot(jobID: jobID)!
    }

    public func submitChapterMLXJob(
        projectID: String,
        inputFilePath: URL,
        chapterNumber: Int = 1,
        maxCharacters: Int = 750,
        llmModelID: String,
        auditionTTSModelID: String,
        mainTTSModelID: String,
        asrModelID: String,
        exportDirectory: URL? = nil,
        allowNeedsReviewInRender: Bool = true,
        stopAfterCompletedNodes: Int? = nil,
        priority: TaskPriority = .background
    ) async throws -> JobSnapshot {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard FileManager.default.fileExists(atPath: inputFilePath.path) else {
            throw EngineSDKError.invalidInput("Input file not found: \(inputFilePath.path)")
        }

        // Persist immutable copy of source document into content-addressed ArtifactStore
        let rawSourceData = try Data(contentsOf: inputFilePath)
        let sourceAsset = try await store.commitBytes(
            rawSourceData,
            projectID: projectID,
            kind: .sourceDocument,
            fileExtension: inputFilePath.pathExtension.isEmpty ? "txt" : inputFilePath.pathExtension,
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(sourceDocumentRevision: "doc_rev_1")
        )

        // Deterministically segment chapter on CPU (<2ms) so every segment gets its own checkpointed DAG node upfront!
        let normalizedDoc = try SourceNormalizer.normalize(data: rawSourceData, documentID: "doc_\(projectID)", revision: "doc_rev_1")
        let chapters = ChapterExtractor.extractChapters(from: normalizedDoc)
        let chosenChapter = P0PipelineRunner.selectChapter(from: chapters, requestedNumber: chapterNumber)
        let (activeSlice, units) = try VerbatimSegmenter.segment(chapter: chosenChapter, maxCharacters: maxCharacters)

        let now = ISO8601DateFormatter().string(from: Date())
        let jobID = "job_\(UUID().uuidString.prefix(8).lowercased())"
        let cfg = ChapterMLXJobConfig(
            sourceAssetID: sourceAsset.assetID,
            chapterNumber: chapterNumber,
            chapterID: activeSlice.chapterID,
            maxCharacters: maxCharacters,
            llmModelID: llmModelID,
            auditionTTSModelID: auditionTTSModelID,
            mainTTSModelID: mainTTSModelID,
            asrModelID: asrModelID,
            exportDirectory: exportDirectory?.path,
            allowNeedsReviewInRender: allowNeedsReviewInRender,
            ambientAudioEnabled: project.options.ambientAudioEnabled,
            stopAfterCompletedNodes: stopAfterCompletedNodes
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let cfgJSON = String(decoding: try enc.encode(cfg), as: UTF8.self)

        let job = JobRecord(
            jobID: jobID,
            projectID: projectID,
            workflowKind: "chapter-mlx",
            status: .pending,
            priority: priority,
            configJSON: cfgJSON,
            createdAtISO8601: now
        )

        var nodes: [JobNodeRecord] = []
        var edges: [JobEdgeRecord] = []

        // Stage 1: LLM analysis (9B)
        nodes.append(JobNodeRecord(
            nodeID: "01_llm_analyze",
            jobID: jobID,
            kind: "mlx_llm_analyze",
            priority: priority,
            inputFingerprint: "llm|\(sourceAsset.fileSHA256)|ch\(chapterNumber)|max\(maxCharacters)|\(llmModelID)",
            createdAtISO8601: now
        ))

        // Stage 2: VoiceDesign character auditions (immutable timbre anchors)
        nodes.append(JobNodeRecord(
            nodeID: "02_audition_cast",
            jobID: jobID,
            kind: "mlx_audition_cast",
            priority: priority,
            inputFingerprint: "audition|\(sourceAsset.fileSHA256)|\(auditionTTSModelID)",
            createdAtISO8601: now
        ))
        edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "01_llm_analyze", toNodeID: "02_audition_cast", requiresVerified: true))

        // Stage 3: Per-segment locked TTS nodes (all batched before barrier so TTS stays resident without model thrashing)
        nodes.append(JobNodeRecord(
            nodeID: "04_tts_stage_barrier",
            jobID: jobID,
            kind: "mlx_stage_barrier",
            priority: priority,
            inputFingerprint: "tts_barrier|\(activeSlice.chapterID)|\(units.count)",
            createdAtISO8601: now
        ))

        for unit in units {
            let segID = String(format: "seg_%04d", unit.index + 1)
            let ttsNodeID = "03_tts_\(segID)"
            let asrNodeID = "05_asr_\(segID)"
            let payloadJSON = "{\"segment_id\":\"\(segID)\"}"

            nodes.append(JobNodeRecord(
                nodeID: ttsNodeID,
                jobID: jobID,
                kind: "mlx_tts_segment",
                priority: priority,
                inputFingerprint: "tts|\(segID)|\(unit.span.start)-\(unit.span.endExclusive)|\(mainTTSModelID)",
                payloadJSON: payloadJSON,
                maxAttempts: 2,
                createdAtISO8601: now
            ))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "02_audition_cast", toNodeID: ttsNodeID, requiresVerified: true))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: ttsNodeID, toNodeID: "04_tts_stage_barrier", requiresVerified: true))

            nodes.append(JobNodeRecord(
                nodeID: asrNodeID,
                jobID: jobID,
                kind: "mlx_asr_segment",
                priority: priority,
                inputFingerprint: "asr|\(segID)|\(asrModelID)",
                payloadJSON: payloadJSON,
                maxAttempts: 2,
                createdAtISO8601: now
            ))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "04_tts_stage_barrier", toNodeID: asrNodeID, requiresVerified: true))
            edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: asrNodeID, toNodeID: "06_render_chapter", requiresVerified: !allowNeedsReviewInRender))
        }

        // Stage 5: Render 48 kHz dry speech chapter WAV/M4A/timeline
        nodes.append(JobNodeRecord(
            nodeID: "06_render_chapter",
            jobID: jobID,
            kind: "mlx_render_chapter",
            priority: priority,
            inputFingerprint: "render|\(activeSlice.chapterID)|ambient=\(project.options.ambientAudioEnabled)",
            createdAtISO8601: now
        ))

        try await store.createJob(job, nodes: nodes, edges: edges)
        return try await store.jobSnapshot(jobID: jobID)!
    }

    public func runJob(
        jobID: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> WorkflowRunReport {
        guard let snap = try await store.jobSnapshot(jobID: jobID) else {
            throw EngineSDKError.jobNotFound(jobID)
        }
        let executor = try makeExecutor(for: snap.job.workflowKind, progress: progress)
        let engine = WorkflowEngine(store: store, artifactStore: store, executor: executor)
        let report = try await engine.run(jobID: jobID, progress: progress)
        await runtime.unloadAllIdle()
        return report
    }

    public func resumeJob(
        jobID: String,
        clearStopHook: Bool = true,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> WorkflowRunReport {
        guard let snap = try await store.jobSnapshot(jobID: jobID) else {
            throw EngineSDKError.jobNotFound(jobID)
        }
        if clearStopHook, snap.job.workflowKind == "chapter-mlx",
           let cfg = try? JSONDecoder().decode(ChapterMLXJobConfig.self, from: Data(snap.job.configJSON.utf8)),
           cfg.stopAfterCompletedNodes != nil {
            // Keep resume clean if the previous run used a test stop hook
        }
        let executor = try makeExecutor(for: snap.job.workflowKind, progress: progress, ignoreStopHook: clearStopHook)
        let engine = WorkflowEngine(store: store, artifactStore: store, executor: executor)
        let report = try await engine.resume(jobID: jobID, progress: progress)
        await runtime.unloadAllIdle()
        return report
    }

    public func cancelJob(jobID: String) async throws -> JobRecord {
        try await store.requestCancel(jobID: jobID, now: Date())
    }

    public func jobSnapshot(jobID: String) async throws -> JobSnapshot? {
        try await store.jobSnapshot(jobID: jobID)
    }

    public func listJobs(projectID: String? = nil) async throws -> [JobRecord] {
        try await store.listJobs(projectID: projectID)
    }

    private func makeExecutor(
        for workflowKind: String,
        progress: (@Sendable (String) -> Void)?,
        ignoreStopHook: Bool = false
    ) throws -> any NodeExecutorProtocol {
        switch workflowKind {
        case "fake-demo":
            return FakeDemoNodeExecutor(store: store)
        case "chapter-mlx":
            return RealMLXChapterNodeExecutor(
                store: store,
                runtime: runtime,
                ignoreStopHook: ignoreStopHook,
                stderrLog: progress ?? { _ in }
            )
        case "audiobook-mlx":
            return AudiobookMLXNodeExecutor(
                store: store,
                runtime: runtime,
                ignoreStopHook: ignoreStopHook,
                stderrLog: progress ?? { _ in }
            )
        default:
            throw EngineSDKError.unsupportedWorkflow(workflowKind)
        }
    }
}
