import AudioCore
import AudioRenderKit
import ContentKit
import DirectorKit
import Foundation
import ModelRuntime
import NarrativeKit
import SpeechKit
import StorageKit
import WorkflowKit

extension SonookEngine {
    // MARK: - Book Import & Chapters

    public func importBook(
        projectID: String,
        fileURL: URL,
        explicitFormat: SourceFormat? = nil,
        explicitEncoding: ExplicitTextEncoding? = nil
    ) async throws -> BookImportReport {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let input = try BookImportInput(fileURL: fileURL, projectID: projectID, format: explicitFormat, encoding: explicitEncoding)
        return try await persistBook(input, projectID: projectID)
    }

    struct BookImportInput {
        let fileURL: URL
        let rawData: Data
        let revision = "doc_\(UUID().uuidString.prefix(8).lowercased())"
        let book: ImportedBook

        init(fileURL: URL, projectID: String, format: SourceFormat? = nil, encoding: ExplicitTextEncoding? = nil) throws {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw EngineSDKError.invalidInput("Source file not found: \(fileURL.path)")
            }
            self.fileURL = fileURL
            rawData = try Data(contentsOf: fileURL)
            book = try ContentImporter.importData(rawData, fileName: fileURL.lastPathComponent, projectID: projectID,
                                                  sourceDocumentRevision: revision, explicitFormat: format, explicitEncoding: encoding)
        }
    }

    func persistBook(_ input: BookImportInput, projectID: String) async throws -> BookImportReport {
        let imported = input.book
        let fileURL = input.fileURL
        let revision = input.revision
        let rawExt = fileURL.pathExtension.isEmpty ? imported.format.rawValue : fileURL.pathExtension.lowercased()
        let rawAsset = try await store.commitBytes(
            input.rawData,
            projectID: projectID,
            kind: .sourceDocument,
            fileExtension: rawExt,
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(sourceDocumentRevision: revision)
        )
        let normAsset = try await store.commitBytes(
            imported.normalizedUTF8Data,
            projectID: projectID,
            kind: .sourceDocument,
            fileExtension: "txt",
            sampleRate: nil,
            frameCount: nil,
            provenance: AssetProvenance(sourceDocumentRevision: revision)
        )

        let docRecord = SourceDocumentRecord(
            sourceDocumentRevision: revision,
            projectID: projectID,
            format: imported.format,
            originalFileName: fileURL.lastPathComponent,
            rawAssetID: rawAsset.assetID,
            rawSHA256: rawAsset.fileSHA256,
            normalizedAssetID: normAsset.assetID,
            normalizedSHA256: imported.normalizedSHA256,
            detectedEncoding: imported.detectedEncoding,
            parserVersion: imported.parserVersion,
            totalUTF8Bytes: imported.normalizedUTF8Data.count,
            chapterCount: imported.chapters.count,
            importedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        let lock = try await lockChapterPublication()
        defer { lock.closeFile() }
        let chapters = try numberImportedChapters(imported.chapters, projectID: projectID)
        try await store.saveSourceDocument(docRecord, chapters: chapters)
        return BookImportReport(sourceDocument: docRecord, chapters: chapters)
    }

    public func listChapters(projectID: String) async throws -> [ChapterRecord] {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        return try productionChapters(projectID: projectID)
    }

    public func listScripts(projectID: String, chapterID: String? = nil) async throws -> [ScriptDocument] {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        if let chapterID {
            guard let script = try await store.loadScript(projectID: projectID, chapterID: chapterID) else {
                throw EngineSDKError.scriptNotAnalyzed(chapterID)
            }
            return [script]
        }
        return try await store.listScripts(projectID: projectID)
    }

    // MARK: - Deterministic Narrative Analysis & Verbatim Directing

    public func analyzeChapters(
        projectID: String,
        chapterSpec: String? = nil,
        llmModelID: String? = nil,
        maxCharacters: Int = 0,
        seed: UInt64 = 42,
        progress: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: (@Sendable (BuildProgressEvent) -> Void)? = nil
    ) async throws -> BookAnalysisReport {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let sourceDoc = try currentBookSource(projectID: projectID) else {
            throw EngineSDKError.sourceNotImported(projectID)
        }
        let allChapters = try await store.listChapters(projectID: projectID, sourceDocumentRevision: sourceDoc.sourceDocumentRevision)
        let selectedChapters = try ChapterSelection.select(from: allChapters, spec: chapterSpec)
        let normalizedUTF8 = try await store.readVerifiedData(for: sourceDoc.normalizedAssetID)

        let llmEntry = try await resolveModelEntry(
            explicitID: llmModelID ?? project.options.preferredLLMModelID,
            kind: .llm
        )

        var catalog = try await store.loadCatalog(projectID: projectID)
        let initialMemories = try await store.chapterMemoriesUpTo(projectID: projectID, maxChapterNumber: Int.max)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        // Keep LLM resident across all selected chapters for maximum speed & zero thrashing,
        // while checkpointing catalog + script + chapter memory incrementally after EVERY chapter.
        let initialCatalog = catalog
        let storeRef = store
        let analysisBatch: (CharacterVoiceCatalog, [ChapterAnalysisSummary]) =
            try await runtime.withLLMLease(entry: llmEntry, priority: .background) { provider in
                var rollingCatalog = initialCatalog
                var rollingMemories = initialMemories
                var batchSummaries: [ChapterAnalysisSummary] = []

                for (index, chapter) in selectedChapters.enumerated() {
                    onEvent?(.init(stage: .analyzing, completed: index, total: selectedChapters.count,
                                   message: "正在分析第 \(chapter.chapterNumber) 章"))
                    progress("[Analyze] Segmenting \(chapter.chapterID) (\(chapter.title))...")
                    let (slice, directedUnits) = try DirectorSegmenter.segmentChapter(
                        chapter: chapter,
                        normalizedDocumentUTF8: normalizedUTF8,
                        maxCharacters: maxCharacters
                    )
                    let narrativeUnits = directedUnits.map {
                        NarrativeUnitInput(
                            index: $0.index,
                            segmentID: $0.segmentID,
                            sourceText: $0.sourceText,
                            spokenText: $0.spokenText,
                            isQuotedDialogue: $0.isQuotedDialogue
                        )
                    }
                    let spoilerFreeMemories = rollingMemories.filter { $0.chapterNumber < chapter.chapterNumber }
                    progress("[Analyze] Running deterministic LLM (\(llmEntry.modelID), seed=\(seed), priorMemories=\(spoilerFreeMemories.count)) on \(chapter.chapterID) (\(directedUnits.count) units)...")
                    let output = try await NarrativeAnalyzer.analyzeChapter(
                        projectID: projectID,
                        chapterNumber: chapter.chapterNumber,
                        chapterText: slice.text,
                        units: narrativeUnits,
                        existingCatalog: rollingCatalog,
                        llmProvider: provider,
                        seed: seed,
                        chapterID: chapter.chapterID,
                        sourceDocumentRevision: chapter.sourceDocumentRevision,
                        priorMemories: spoilerFreeMemories,
                        maxRosterSize: 20,
                        stderrLog: progress
                    )
                    rollingCatalog = output.catalog
                    if let newMemory = output.chapterMemory {
                        rollingMemories.removeAll { $0.chapterID == newMemory.chapterID }
                        rollingMemories.append(newMemory)
                    }

                    let directorAnalysis = NarrativeAnalysisResult(
                        catalog: output.catalog,
                        attributions: output.attributions.map {
                            AttributedUnit(
                                index: $0.index,
                                speakerID: $0.speakerID,
                                emotion: $0.emotion,
                                styleInstruction: $0.styleInstruction,
                                pauseAfterMs: $0.pauseAfterMs,
                                confidence: $0.confidence,
                                evidence: $0.evidence,
                                needsReviewReason: $0.needsReviewReason
                            )
                        },
                        proposedStages: output.proposedStagesByCharacterID,
                        autoAttributedCount: output.autoAttributedCount,
                        needsReviewCount: output.needsReviewCount
                    )

                    let priorRevision = try await storeRef.loadScript(projectID: projectID, chapterID: chapter.chapterID)?.scriptRevision ?? 0
                    guard priorRevision < Int.max else { throw EngineSDKError.invalidInput("Chapter script revision overflow") }
                    let (scriptDoc, coverage) = try ScriptDirector.buildScript(
                        chapter: chapter,
                        slice: slice,
                        units: directedUnits,
                        analysis: directorAnalysis,
                        scriptRevision: priorRevision + 1
                    )

                    // Persist incrementally after each chapter so a late failure never loses completed chapters!
                    try await storeRef.saveCatalog(output.catalog)
                    try await storeRef.saveScript(scriptDoc, projectID: projectID)
                    if let chapterMemory = output.chapterMemory {
                        try await storeRef.saveChapterMemory(chapterMemory)
                    }
                    let scriptBytes = try enc.encode(scriptDoc)
                    let scriptAsset = try await storeRef.commitBytes(
                        scriptBytes,
                        projectID: projectID,
                        kind: .scriptSnapshot,
                        fileExtension: "json",
                        sampleRate: nil,
                        frameCount: nil,
                        provenance: AssetProvenance(
                            sourceDocumentRevision: scriptDoc.sourceDocumentRevision,
                            chapterID: scriptDoc.chapterID,
                            scriptRevision: scriptDoc.scriptRevision,
                            providerID: llmEntry.providerID,
                            modelID: llmEntry.modelID,
                            modelRevision: llmEntry.revision
                        )
                    )
                    let dialogueCount = scriptDoc.segments.filter { $0.speakerID != "char_narrator" }.count
                    let proposedCount = output.proposedStagesByCharacterID.values.reduce(0) { $0 + $1.count }
                    batchSummaries.append(ChapterAnalysisSummary(
                        chapterID: chapter.chapterID,
                        chapterNumber: chapter.chapterNumber,
                        title: chapter.title,
                        segmentCount: scriptDoc.segments.count,
                        dialogueSegmentCount: dialogueCount,
                        autoAttributedCount: output.autoAttributedCount,
                        needsReviewCount: output.needsReviewCount,
                        coverageRatio: coverage.coverageRatio,
                        scriptAssetID: scriptAsset.assetID,
                        proposedStagesCount: proposedCount
                    ))
                    onEvent?(.init(stage: .analyzing, completed: index + 1, total: selectedChapters.count,
                                   message: "第 \(chapter.chapterNumber) 章完成，\(scriptDoc.segments.count) 个片段，已识别 \(output.catalog.cards.count) 个角色"))
                }
                let finalCatalog = rollingCatalog ?? CharacterVoiceCatalog(projectID: projectID, revision: 1, cards: [NarrativeAnalyzer.defaultNarratorCard()])
                return (finalCatalog, batchSummaries)
            }

        await runtime.unloadAllIdle()
        if let peak = await runtime.measuredPeakBytes(for: llmEntry.modelID) {
            try? await store.updateMeasuredPeakBytes(modelID: llmEntry.modelID, peakBytes: peak)
        }

        catalog = analysisBatch.0

        return BookAnalysisReport(
            projectID: projectID,
            llmModelID: llmEntry.modelID,
            seed: seed,
            catalogRevision: analysisBatch.0.revision,
            characterCount: analysisBatch.0.cards.count,
            chapters: analysisBatch.1
        )
    }

    // MARK: - Character Voice Cards & Workspace Output Paths

    public func projectOutputDirectory(projectID: String) async throws -> URL {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        return SonookWorkspaceLayout.projectOutputDirectory(workspaceRoot: workspaceRoot, project: project)
    }

    public func defaultCharactersMarkdownURL(projectID: String) async throws -> URL {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        return SonookWorkspaceLayout.defaultCharactersMarkdownURL(workspaceRoot: workspaceRoot, project: project)
    }

    public func saveVerificationReport(
        _ report: ProjectVerificationReport,
        to destinationURL: URL? = nil
    ) async throws -> URL {
        guard let project = try await store.project(id: report.projectID) else {
            throw EngineSDKError.projectNotFound(report.projectID)
        }
        let allChapters = try productionChapters(projectID: report.projectID)
        let targetURL = destinationURL ?? SonookWorkspaceLayout.defaultVerifyReportURL(
            workspaceRoot: workspaceRoot,
            project: project,
            chapterNumbers: report.chapters.map(\.chapterNumber),
            totalChapterCount: allChapters.count
        )
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(report).write(to: targetURL, options: .atomic)
        return targetURL
    }

    public func loadCharacters(projectID: String) async throws -> CharacterVoiceCatalog {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let catalog = try await store.loadCatalog(projectID: projectID) else {
            return CharacterVoiceCatalog(projectID: projectID, revision: 1, cards: [])
        }
        return catalog
    }

    public func exportCharactersMarkdown(projectID: String, to destinationURL: URL? = nil) async throws -> String {
        let catalog = try await loadCharacters(projectID: projectID)
        let md = try catalog.renderMarkdown()
        if let url = destinationURL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(md.utf8).write(to: url, options: .atomic)
        }
        return md
    }

    public func importCharactersMarkdown(projectID: String, from sourceURL: URL) async throws -> CharacterVoiceCatalog {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        let parsed = try CharacterVoiceCatalog.parseMarkdown(raw)
        guard parsed.projectID == projectID else {
            throw EngineSDKError.invalidInput("Markdown catalog project_id '\(parsed.projectID)' does not match target project '\(projectID)'")
        }
        try await store.saveCatalog(parsed)
        return parsed
    }

    // MARK: - Multi-Chapter Audiobook Generation DAG

    public func submitAudiobookGenerateJob(
        projectID: String,
        chapterSpec: String? = nil,
        auditionTTSModelID: String? = nil,
        mainTTSModelID: String? = nil,
        asrModelID: String? = nil,
        seed: UInt64 = 42,
        stopAfterCompletedNodes: Int? = nil,
        maxRepairRounds: Int = 2,
        priority: TaskPriority = .background
    ) async throws -> JobSnapshot {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let selectedChapters = try selectedProductionChapters(projectID: projectID, spec: chapterSpec)

        let auditionEntry = try await resolveModelEntry(
            explicitID: auditionTTSModelID ?? project.options.preferredAuditionTTSModelID,
            kind: .tts,
            preferProviderContaining: "voice-design"
        )
        let mainEntry = try await resolveModelEntry(
            explicitID: mainTTSModelID ?? project.options.preferredMainTTSModelID,
            kind: .tts,
            preferProviderContaining: "voxcpm2"
        )
        let asrEntry = try await resolveModelEntry(
            explicitID: asrModelID ?? project.options.preferredASRModelID,
            kind: .asr
        )

        var scriptsByChapter: [(ChapterRecord, ScriptDocument)] = []
        var chapterNumbersByID: [String: Int] = [:]
        for ch in selectedChapters {
            let script = try await productionScript(ch)
            scriptsByChapter.append((ch, script))
            chapterNumbersByID[ch.chapterID] = ch.chapterNumber
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let jobID = "job_\(UUID().uuidString.prefix(8).lowercased())"
        let cfg = AudiobookMLXJobConfig(
            chapterIDs: selectedChapters.map(\.chapterID),
            chapterNumbersByID: chapterNumbersByID,
            auditionTTSModelID: auditionEntry.modelID,
            mainTTSModelID: mainEntry.modelID,
            asrModelID: asrEntry.modelID,
            seed: seed,
            stopAfterCompletedNodes: stopAfterCompletedNodes,
            maxRepairRounds: maxRepairRounds
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let cfgJSON = String(decoding: try enc.encode(cfg), as: UTF8.self)

        let job = JobRecord(
            jobID: jobID,
            projectID: projectID,
            workflowKind: "audiobook-mlx",
            status: .pending,
            priority: priority,
            configJSON: cfgJSON,
            createdAtISO8601: now
        )

        var nodes: [JobNodeRecord] = []
        var edges: [JobEdgeRecord] = []

        nodes.append(JobNodeRecord(
            nodeID: "01_audition_cast",
            jobID: jobID,
            kind: "mlx_book_audition_cast",
            priority: priority,
            inputFingerprint: "book_audition|\(projectID)|\(auditionEntry.modelID)|\(seed)",
            createdAtISO8601: now
        ))

        let totalSegments = scriptsByChapter.reduce(0) { $0 + $1.1.segments.count }
        nodes.append(JobNodeRecord(
            nodeID: "03_tts_stage_barrier",
            jobID: jobID,
            kind: "mlx_stage_barrier",
            priority: priority,
            inputFingerprint: "book_tts_barrier|\(selectedChapters.map(\.chapterID).joined(separator: ","))|\(totalSegments)",
            createdAtISO8601: now
        ))

        var allASRNodeIDs: [String] = []
        for (ch, script) in scriptsByChapter {
            for seg in script.segments {
                let ttsNodeID = "02_tts_\(seg.segmentID)"
                let asrNodeID = "04_asr_\(seg.segmentID)"
                let payloadJSON = String(decoding: try enc.encode(["chapter_id": ch.chapterID, "segment_id": seg.segmentID]), as: UTF8.self)

                nodes.append(JobNodeRecord(
                    nodeID: ttsNodeID,
                    jobID: jobID,
                    kind: "mlx_book_tts_segment",
                    priority: priority,
                    inputFingerprint: "book_tts|\(seg.segmentID)|\(seg.sourceSpan.start)-\(seg.sourceSpan.endExclusive)|\(mainEntry.modelID)|\(seed)",
                    payloadJSON: payloadJSON,
                    maxAttempts: 2,
                    createdAtISO8601: now
                ))
                edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "01_audition_cast", toNodeID: ttsNodeID, requiresVerified: true))
                edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: ttsNodeID, toNodeID: "03_tts_stage_barrier", requiresVerified: true))

                nodes.append(JobNodeRecord(
                    nodeID: asrNodeID,
                    jobID: jobID,
                    kind: "mlx_book_asr_segment",
                    priority: priority,
                    inputFingerprint: "book_asr|\(seg.segmentID)|\(asrEntry.modelID)",
                    payloadJSON: payloadJSON,
                    maxAttempts: 2,
                    createdAtISO8601: now
                ))
                edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: "03_tts_stage_barrier", toNodeID: asrNodeID, requiresVerified: true))
                allASRNodeIDs.append(asrNodeID)
            }
        }

        // Stage 4: Bounded post-ASR batch auto-repair rounds (requiresVerified: false so needs_review ASR nodes trigger repair!).
        let clampedRepairRounds = max(0, maxRepairRounds)
        if clampedRepairRounds > 0 && !allASRNodeIDs.isEmpty {
            var previousRepairNodeID: String?
            for round in 1...clampedRepairRounds {
                let repairNodeID = String(format: "05_auto_repair_round_%02d", round)
                nodes.append(JobNodeRecord(
                    nodeID: repairNodeID,
                    jobID: jobID,
                    kind: "mlx_book_auto_repair_round",
                    priority: priority,
                    inputFingerprint: "book_repair|\(projectID)|\(mainEntry.modelID)|\(asrEntry.modelID)|\(seed)|r\(round)",
                    payloadJSON: "{\"round\":\(round)}",
                    maxAttempts: 2,
                    createdAtISO8601: now
                ))
                if let prev = previousRepairNodeID {
                    edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: prev, toNodeID: repairNodeID, requiresVerified: false))
                } else {
                    for asrNodeID in allASRNodeIDs {
                        edges.append(JobEdgeRecord(jobID: jobID, fromNodeID: asrNodeID, toNodeID: repairNodeID, requiresVerified: false))
                    }
                }
                previousRepairNodeID = repairNodeID
            }
        }

        try await store.createJob(job, nodes: nodes, edges: edges)
        return try await store.jobSnapshot(jobID: jobID)!
    }

    // MARK: - Single-Segment Regeneration & Human Approval

    public func regenerateSegment(
        projectID: String,
        segmentID: String,
        mainTTSModelID: String? = nil,
        asrModelID: String? = nil,
        seed: UInt64 = 42,
        emotion: String? = nil,
        styleInstruction: String? = nil,
        pauseAfterMs: Int? = nil,
        allowNeedsReviewSwap: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SegmentRegenerationResult {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let located = try await store.locateSegment(projectID: projectID, segmentID: segmentID) else {
            throw EngineSDKError.segmentNotFound(segmentID)
        }
        let chapterRecord = try productionChapters(projectID: projectID).first { $0.chapterID == located.chapterID }
        let chapterNumber = chapterRecord?.chapterNumber ?? 1

        let mainEntry = try await resolveModelEntry(
            explicitID: mainTTSModelID ?? project.options.preferredMainTTSModelID,
            kind: .tts,
            preferProviderContaining: "voxcpm2"
        )
        let asrEntry = try await resolveModelEntry(
            explicitID: asrModelID ?? project.options.preferredASRModelID,
            kind: .asr
        )

        var directionOverride: SegmentDirection?
        if emotion != nil || styleInstruction != nil || pauseAfterMs != nil {
            var dir = located.segment.direction
            if let emotion { dir.emotion = emotion }
            if let styleInstruction { dir.styleInstruction = styleInstruction }
            if let pauseAfterMs { dir.pauseAfterMs = pauseAfterMs }
            directionOverride = dir
        }

        var expectedPitchHz: Double?
        if located.segment.speakerID == "char_narrator",
           let catalog = try await store.loadCatalog(projectID: projectID),
           let anchor = catalog.resolveCharacter(namedOrAliased: "char_narrator")?.timbreAnchor,
           let anchorURL = try? await store.resolveFileURL(for: anchor.assetID),
           let (anchorSamples, anchorSR) = try? PCMCodec.readMonoSamples(from: anchorURL) {
            expectedPitchHz = AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: anchorSamples, sampleRate: anchorSR)
        }

        let req = SegmentRegenerationRequest(
            projectID: projectID,
            segmentID: segmentID,
            chapterNumber: chapterNumber,
            providerID: mainEntry.providerID,
            modelID: mainEntry.modelID,
            modelRevision: mainEntry.revision,
            asrProviderID: asrEntry.providerID,
            asrModelID: asrEntry.modelID,
            asrModelRevision: asrEntry.revision,
            seed: seed,
            directionOverride: directionOverride,
            allowNeedsReviewSwap: allowNeedsReviewSwap,
            expectedPitchHz: expectedPitchHz
        )

        let rt = self.runtime
        progress("[Regenerate] Synthesizing single segment \(segmentID) (\(located.chapterID)) with \(mainEntry.modelID) (seed=\(seed))...")
        let result = try await SingleSegmentRegenerator.regenerate(
            request: req,
            store: store,
            encodeWAV: { samples, sr in
                try PCMCodec.encodeWAVData(samples: samples, sampleRate: sr)
            },
            synthesize: { speechReq in
                try await rt.withTTSLease(entry: mainEntry, priority: .interactive) { provider in
                    try await provider.synthesize(speechReq)
                }
            },
            transcribe: { asrReq in
                progress("[Regenerate] Verifying single segment \(segmentID) with \(asrEntry.modelID)...")
                return try await rt.withASRLease(entry: asrEntry, priority: .interactive) { provider in
                    try await provider.transcribe(asrReq)
                }
            }
        )
        await runtime.unloadAllIdle()
        progress("[Regenerate] Done \(segmentID): swapped=\(result.swapped), status=\(result.newStatus.rawValue), adjCER=\(String(format: "%.2f%%", result.audit.adjustedCER * 100))")
        return result
    }

    public func approveSegment(
        projectID: String,
        segmentID: String,
        note: String
    ) async throws -> SegmentApprovalRecord {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        guard let located = try await store.locateSegment(projectID: projectID, segmentID: segmentID) else {
            throw EngineSDKError.segmentNotFound(segmentID)
        }
        guard let assetID = located.segment.audioArtifactID else {
            throw EngineSDKError.invalidInput("Segment \(segmentID) has no synthesized audio asset to approve.")
        }
        guard try await store.verifyAssetIntegrity(assetID: assetID) else {
            throw EngineSDKError.invalidInput("Segment \(segmentID) audio asset \(assetID) failed SHA-256 integrity check.")
        }
        let record = SegmentApprovalRecord(
            projectID: projectID,
            chapterID: located.chapterID,
            segmentID: segmentID,
            approvedAssetID: assetID,
            reviewerNote: note,
            approvedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        try await store.saveSegmentApproval(record)
        return record
    }

    // MARK: - Verification & Formal Multi-Chapter Export (WAV / M4A / M4B + Optional Ambient Bed)

    public func verifyProject(
        projectID: String,
        chapterSpec: String? = nil,
        m4bURL: URL? = nil
    ) async throws -> ProjectVerificationReport {
        try await inspectBook(projectID: projectID, chapterSpec: chapterSpec, m4bURL: m4bURL).report
    }

    private func inspectBook(projectID: String, chapterSpec: String?, m4bURL: URL? = nil) async throws
        -> (report: ProjectVerificationReport, chapters: [(chapter: ChapterRecord, script: ScriptDocument)], totalChapterCount: Int) {
        guard try await store.project(id: projectID) != nil else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let allChapters = try productionChapters(projectID: projectID)
        guard !allChapters.isEmpty else { throw EngineSDKError.sourceNotImported(projectID) }
        let selectedChapters = try ChapterSelection.select(from: allChapters, spec: chapterSpec)
        var chapters: [(chapter: ChapterRecord, script: ScriptDocument)] = []
        var chapterReports: [ChapterVerificationReport] = []
        var allBlocking: [String] = []
        var totalSegs = 0
        var totalVerified = 0
        var totalApproved = 0

        for ch in selectedChapters {
            guard var script = try await store.loadScript(projectID: projectID, chapterID: ch.chapterID),
                  script.sourceDocumentRevision == ch.sourceDocumentRevision else {
                chapterReports.append(ChapterVerificationReport(
                    chapterID: ch.chapterID,
                    chapterNumber: ch.chapterNumber,
                    title: ch.title,
                    totalSegments: 0,
                    verifiedCount: 0,
                    approvedCount: 0,
                    needsReviewCount: 0,
                    pendingOrFailedCount: 0,
                    exportReady: false,
                    blockingSegmentIDs: ["\(ch.chapterID):unanalyzed"],
                    segments: []
                ))
                allBlocking.append("\(ch.chapterID):unanalyzed")
                continue
            }

            let approvals = try await store.segmentApprovals(projectID: projectID, chapterID: ch.chapterID)
            let approvalBySegID = Dictionary(uniqueKeysWithValues: approvals.map { ($0.segmentID, $0) })

            var entries: [SegmentVerificationEntry] = []
            var chBlocking: [String] = []
            var chVerified = 0
            var chApproved = 0
            var chNeedsReview = 0
            var chPendingOrFailed = 0

            for index in script.segments.indices {
                let seg = script.segments[index]
                let intact: Bool
                if let aid = seg.audioArtifactID {
                    intact = (try? await store.verifyAssetIntegrity(assetID: aid)) ?? false
                } else {
                    intact = false
                }
                let approved = seg.audioArtifactID != nil && approvalBySegID[seg.segmentID]?.approvedAssetID == seg.audioArtifactID
                let eligible = intact && (seg.status == .verified || approved)

                if seg.status == .verified && intact {
                    chVerified += 1
                } else if approved && intact {
                    chApproved += 1
                    // This render-only snapshot admits the exact approved asset to AudioPackWriter.
                    script.segments[index].status = .verified
                } else if seg.status == .needsReview {
                    chNeedsReview += 1
                } else {
                    chPendingOrFailed += 1
                }

                if !eligible {
                    chBlocking.append(seg.segmentID)
                }

                entries.append(SegmentVerificationEntry(
                    segmentID: seg.segmentID,
                    speakerID: seg.speakerID,
                    status: seg.status,
                    audioAssetID: seg.audioArtifactID,
                    assetIntact: intact,
                    explicitlyApproved: approved,
                    exportEligible: eligible
                ))
            }

            if script.segments.isEmpty { chBlocking.append("\(ch.chapterID):empty") }
            chapters.append((ch, script))
            totalSegs += script.segments.count
            totalVerified += chVerified
            totalApproved += chApproved
            allBlocking.append(contentsOf: chBlocking)

            chapterReports.append(ChapterVerificationReport(
                chapterID: ch.chapterID,
                chapterNumber: ch.chapterNumber,
                title: ch.title,
                totalSegments: script.segments.count,
                verifiedCount: chVerified,
                approvedCount: chApproved,
                needsReviewCount: chNeedsReview,
                pendingOrFailedCount: chPendingOrFailed,
                exportReady: chBlocking.isEmpty && !script.segments.isEmpty,
                blockingSegmentIDs: chBlocking,
                segments: entries
            ))
        }

        let inspectedM4B: M4BVerificationReport?
        if let m4bURL {
            inspectedM4B = try await M4BChapterReader.inspect(url: m4bURL)
        } else {
            inspectedM4B = nil
        }

        let report = ProjectVerificationReport(
            projectID: projectID,
            exportReady: allBlocking.isEmpty && totalSegs > 0,
            totalSegments: totalSegs,
            verifiedSegments: totalVerified,
            approvedSegments: totalApproved,
            blockingSegmentIDs: allBlocking,
            chapters: chapterReports,
            inspectedM4B: inspectedM4B
        )
        return (report, chapters, allChapters.count)
    }

    public func exportBook(
        projectID: String,
        format: ExportFormat,
        destinationURL: URL? = nil,
        chapterSpec: String? = nil,
        title: String? = nil,
        author: String? = nil,
        narrator: String? = nil,
        ambientFileURL: URL? = nil,
        ambientGainDB: Double = -24.0,
        ambientDuckingDB: Double = -8.0,
        chapterGapMs: Int = 1200,
        soundscapeEnabled: Bool = false,
        soundLibraryDirectory: URL? = nil,
        sfxHelperExecutable: URL? = nil,
        sfxLicenseTag: String? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BookExportReport {
        guard let project = try await store.project(id: projectID) else {
            throw EngineSDKError.projectNotFound(projectID)
        }
        let render = try await renderBook(projectID: projectID, chapterSpec: chapterSpec, chapterGapMs: chapterGapMs,
            ambientFileURL: ambientFileURL, ambientGainDB: ambientGainDB, ambientDuckingDB: ambientDuckingDB,
            soundscapeEnabled: soundscapeEnabled, soundLibraryDirectory: soundLibraryDirectory,
            sfxHelperExecutable: sfxHelperExecutable, sfxLicenseTag: sfxLicenseTag, progress: progress)
        let timeline = render.timeline
        let bookTitle = title ?? project.name
        let resolvedDestinationURL = destinationURL ?? SonookWorkspaceLayout.defaultAudiobookOutputURL(
            workspaceRoot: workspaceRoot,
            project: project,
            title: bookTitle,
            chapterNumbers: render.chapters.map(\.chapter.chapterNumber),
            totalChapterCount: render.totalChapterCount,
            audioMode: render.audioMode,
            format: format
        )
        let assetsRoot = workspaceRoot.appendingPathComponent(SonookWorkspaceLayout.assetsFolderName)
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = resolvedDestinationURL.resolvingSymlinksInPath().standardizedFileURL
        let caseSensitive = try assetsRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let insideAssets = destination.pathComponents.starts(with: assetsRoot.pathComponents) {
            caseSensitive ? $0 == $1 : $0.caseInsensitiveCompare($1) == .orderedSame
        }
        guard !insideAssets else {
            throw EngineSDKError.invalidInput("Export destination is inside immutable workspace assets")
        }
        try FileManager.default.createDirectory(at: resolvedDestinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let metadata = BookExportMetadata(
            title: bookTitle,
            author: author,
            narrator: narrator ?? "旁白",
            languageTag: "zh-Hans"
        )

        progress("[Export] Encoding \(format.rawValue.uppercased()) to \(resolvedDestinationURL.path)...")
        try await BookExporter.export(
            samples: render.samples,
            sampleRate: timeline.sampleRate,
            format: format,
            markers: timeline.chapters,
            metadata: metadata,
            to: resolvedDestinationURL
        )

        let verifiedM4B: M4BVerificationReport?
        if format == .m4b {
            verifiedM4B = try await M4BChapterReader.inspect(url: resolvedDestinationURL)
            progress("[Export] Verified M4B readback: \(verifiedM4B?.chapters.count ?? 0) embedded chapter(s).")
        } else {
            verifiedM4B = nil
        }

        let timelineURL = resolvedDestinationURL
            .deletingPathExtension()
            .appendingPathExtension("timeline.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(timeline).write(to: timelineURL, options: .atomic)

        return BookExportReport(
            projectID: projectID,
            format: format,
            outputPath: resolvedDestinationURL.path,
            timelinePath: timelineURL.path,
            sampleRate: timeline.sampleRate,
            durationSeconds: timeline.totalDurationSeconds,
            chapterCount: timeline.chapters.count,
            segmentCount: timeline.entries.count,
            ambientMixed: timeline.ambientMixed,
            ambientAssetID: render.ambientAssetID,
            renderFingerprint: timeline.renderFingerprint,
            drySegmentAssetSHA256s: render.drySegmentHashes,
            verifiedM4B: verifiedM4B
        )
    }

    struct RenderedProduction {
        let chapters: [(chapter: ChapterRecord, script: ScriptDocument)]
        let totalChapterCount: Int
        let samples: [Float]
        let timeline: RenderedBookTimeline
        let audioMode: ExportAudioMode
        let ambientAssetID: String?
        let drySegmentHashes: [String: String]
    }

    static func validateSoundscapeOptions(enabled: Bool, library: URL?, helper: URL?, license: String?) throws {
        guard enabled || (library == nil && helper == nil && license == nil) else {
            throw EngineSDKError.invalidInput("Sound library and SFX options require soundscape export")
        }
        guard license == nil || helper != nil else {
            throw EngineSDKError.invalidInput("An SFX license override requires an SFX helper")
        }
    }

    func renderBook(projectID: String, chapterSpec: String?, chapterGapMs: Int,
                    ambientFileURL: URL? = nil, ambientGainDB: Double = -24, ambientDuckingDB: Double = -8,
                    soundscapeEnabled: Bool, soundLibraryDirectory: URL?, sfxHelperExecutable: URL?,
                    sfxLicenseTag: String?, progress: @Sendable (String) -> Void) async throws -> RenderedProduction {
        try Self.validateSoundscapeOptions(enabled: soundscapeEnabled, library: soundLibraryDirectory,
                                           helper: sfxHelperExecutable, license: sfxLicenseTag)
        guard !soundscapeEnabled || ambientFileURL == nil else {
            throw EngineSDKError.invalidInput("Choose a manual ambient bed or a planned soundscape for this export")
        }

        // Formal Export Gate: every segment MUST be verified OR explicitly approved with intact SHA-256 WAV!
        let inspected = try await inspectBook(projectID: projectID, chapterSpec: chapterSpec)
        guard inspected.report.exportReady else {
            throw EngineSDKError.exportGateBlocked(inspected.report.blockingSegmentIDs)
        }

        var soundscapes: [(ChapterSoundscapePlan, ScriptDocument)] = []
        var chapterInputs: [ChapterAudioInput] = []
        var drySegmentHashes: [String: String] = [:]
        var orderedHashes: [String] = []
        var masterSampleRate = 48_000
        var hasSampleRate = false

        for (ch, script) in inspected.chapters {
            try Task.checkCancellation()
            if soundscapeEnabled {
                let plan = try await soundscape(for: ch, script: script)
                soundscapes.append((plan, script))
            }
            var segAudio: [(segment: ScriptSegment, samples: [Float], sampleRate: Int)] = []
            for seg in script.segments {
                guard let assetID = seg.audioArtifactID,
                      let rec = try await store.asset(id: assetID),
                      try await store.verifyAssetIntegrity(assetID: assetID) else {
                    throw EngineSDKError.exportGateBlocked([seg.segmentID])
                }
                let wavURL = try await store.resolveFileURL(for: assetID)
                let (samples, sr) = try PCMCodec.readMonoSamples(from: wavURL)
                if !hasSampleRate {
                    masterSampleRate = sr
                    hasSampleRate = true
                }
                drySegmentHashes[seg.segmentID] = rec.fileSHA256
                orderedHashes.append(rec.fileSHA256)
                segAudio.append((seg, samples, sr))
            }
            chapterInputs.append(ChapterAudioInput(chapterID: ch.chapterID, title: ch.title, segments: segAudio))
        }

        progress("[Export] Assembling \(chapterInputs.count) chapter(s) at \(masterSampleRate) Hz...")
        let (dryPCM, markers, entries) = try PCMCodec.assembleBookPCM(
            chapters: chapterInputs,
            sampleRate: masterSampleRate,
            chapterGapMs: chapterGapMs
        )

        var finalPCM = dryPCM
        var ambientSpec: AmbientTrackSpec?
        var ambientAssetID: String?

        if let ambientURL = ambientFileURL {
            guard FileManager.default.fileExists(atPath: ambientURL.path) else {
                throw EngineSDKError.invalidInput("Ambient audio file not found: \(ambientURL.path)")
            }
            let ambientBytes = try Data(contentsOf: ambientURL)
            let ambientExt = ambientURL.pathExtension.isEmpty ? "wav" : ambientURL.pathExtension.lowercased()
            let (ambientSamples, ambientSR) = try PCMCodec.readMonoSamples(from: ambientURL, targetSampleRate: masterSampleRate)
            let ambientAsset = try await store.commitBytes(
                ambientBytes,
                projectID: projectID,
                kind: .ambientBed,
                fileExtension: ambientExt,
                sampleRate: ambientSR,
                frameCount: ambientSamples.count,
                provenance: AssetProvenance(providerID: "user-ambient-bed", modelID: ambientURL.lastPathComponent)
            )
            ambientAssetID = ambientAsset.assetID
            let spec = AmbientTrackSpec(
                assetID: ambientAsset.assetID,
                presetName: ambientURL.deletingPathExtension().lastPathComponent,
                gainDB: ambientGainDB,
                duckingDB: ambientDuckingDB
            )
            ambientSpec = spec
            progress(String(format: "[Export] Mixing optional ambient bed '%@' (gain=%.1f dB, duck=%.1f dB)...", ambientURL.lastPathComponent, ambientGainDB, ambientDuckingDB))
            finalPCM = AmbientAudioMixer.mix(
                drySpeech: dryPCM,
                sampleRate: masterSampleRate,
                ambient: AmbientMixInput(ambientSamples: ambientSamples, ambientSampleRate: ambientSR, spec: spec)
            )
        }

        let renderConfig = ChapterRenderConfig(
            chapterID: inspected.chapters.map(\.chapter.chapterID).joined(separator: "+"),
            sampleRate: masterSampleRate,
            targetRMSDBFS: -20.0,
            ambientTrack: ambientSpec
        )
        let renderFP = renderConfig.renderFingerprint(segmentAssetHashes: orderedHashes)

        var timeline = RenderedBookTimeline(
            sampleRate: masterSampleRate,
            totalFrames: Int64(finalPCM.count),
            totalDurationSeconds: Double(finalPCM.count) / Double(masterSampleRate),
            ambientMixed: ambientSpec != nil,
            renderFingerprint: renderFP,
            chapters: markers,
            entries: entries
        )
        if soundscapeEnabled {
            let render = try await renderSoundscape(projectID: projectID, drySpeech: dryPCM, timeline: timeline,
                chapters: soundscapes, libraryDirectory: soundLibraryDirectory, helperExecutable: sfxHelperExecutable,
                license: sfxLicenseTag, progress: progress)
            finalPCM = render.samples
            timeline = render.timeline
        }
        let audioMode: ExportAudioMode = soundscapeEnabled ? .soundscape : (ambientSpec != nil ? .ambient : .dry)

        return RenderedProduction(chapters: inspected.chapters, totalChapterCount: inspected.totalChapterCount,
                                  samples: finalPCM, timeline: timeline, audioMode: audioMode,
                                  ambientAssetID: ambientAssetID, drySegmentHashes: drySegmentHashes)
    }

    // MARK: - Model Resolution Helper

    internal func resolveModelEntry(
        explicitID: String?,
        kind: ModelKind,
        preferProviderContaining: String? = nil
    ) async throws -> ModelRegistryEntry {
        if let id = explicitID, !id.isEmpty {
            guard let entry = try await store.model(id: id) else {
                throw EngineSDKError.modelNotConfigured("Model '\(id)' is not registered.")
            }
            guard entry.kind == kind else {
                throw EngineSDKError.invalidInput("Model '\(id)' has kind '\(entry.kind.rawValue)', expected '\(kind.rawValue)'.")
            }
            return entry
        }
        let candidates = try await store.listModels(kind: kind)
        if let hint = preferProviderContaining,
           let matched = candidates.first(where: { $0.providerID.contains(hint) }) {
            return matched
        }
        if let first = candidates.first {
            return first
        }
        throw EngineSDKError.modelNotConfigured("No \(kind.rawValue) model registered in workspace. Run `sonook model register` first.")
    }
}
