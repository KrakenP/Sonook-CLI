import AudioCore
import AudioRenderKit
import ContentKit
import EngineSDK
import Foundation
import SpeechKit
import WorkflowKit

extension SonookCLI {
    static func runImport(args: [String], jsonMode: Bool) async throws {
        guard let filePath = args.first, !filePath.hasPrefix("-"),
              let projectID = option("--project", in: args) else {
            stderrWrite("Usage: sonook import <file> --project <id> [--encoding utf-8|utf-16le|utf-16be|gb18030] [--format txt|markdown|epub]\n")
            exit(2)
        }
        let explicitFormat: SourceFormat?
        if let rawFmt = option("--format", in: args) {
            guard let fmt = SourceFormat(rawValue: rawFmt.lowercased()) else {
                stderrWrite("Invalid --format '\(rawFmt)' (expected txt|markdown|epub)\n")
                exit(2)
            }
            explicitFormat = fmt
        } else {
            explicitFormat = nil
        }

        let explicitEncoding: ExplicitTextEncoding?
        if let rawEnc = option("--encoding", in: args) {
            guard let enc = ExplicitTextEncoding(rawValue: rawEnc.lowercased()) else {
                stderrWrite("Invalid --encoding '\(rawEnc)' (expected utf-8|utf-16le|utf-16be|gb18030)\n")
                exit(2)
            }
            explicitEncoding = enc
        } else {
            explicitEncoding = nil
        }

        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.importBook(
            projectID: projectID,
            fileURL: URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath),
            explicitFormat: explicitFormat,
            explicitEncoding: explicitEncoding
        )

        if jsonMode {
            try printJSON(report)
        } else {
            let doc = report.sourceDocument
            print("Imported '\(doc.originalFileName)' into \(doc.projectID) (rev=\(doc.sourceDocumentRevision), format=\(doc.format.rawValue), encoding=\(doc.detectedEncoding), bytes=\(doc.totalUTF8Bytes), chapters=\(doc.chapterCount))")
            for ch in report.chapters.prefix(15) {
                print("  \(ch.chapterID)\t#\(ch.chapterNumber)\t\(ch.title)\t[\(ch.sourceSpan.start)..\(ch.sourceSpan.endExclusive))")
            }
            if report.chapters.count > 15 {
                print("  ... (+\(report.chapters.count - 15) more chapters; run `sonook chapter list --project \(projectID)`)")
            }
        }
    }

    static func runChapter(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook chapter list --project <id>\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "list":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for chapter list.\n"); exit(2)
            }
            let chapters = try await engine.listChapters(projectID: projectID)
            if jsonMode {
                try printJSON(chapters)
            } else if chapters.isEmpty {
                print("No chapters imported for project \(projectID).")
            } else {
                for ch in chapters {
                    let bytes = ch.sourceSpan.endExclusive - ch.sourceSpan.start
                    print("\(ch.chapterID)\t#\(ch.chapterNumber)\t\(bytes)B\t\(ch.title)")
                }
            }
        default:
            stderrWrite("Unknown chapter subcommand: \(action)\n"); exit(2)
        }
    }

    static func runAnalyze(args: [String], jsonMode: Bool) async throws {
        guard let projectID = option("--project", in: args) else {
            stderrWrite("Usage: sonook analyze --project <id> [--chapters 1-2] [--llm <id>] [--max-chars <n>] [--seed <n>]\n")
            exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.analyzeChapters(
            projectID: projectID,
            chapterSpec: option("--chapters", in: args),
            llmModelID: option("--llm", in: args),
            maxCharacters: option("--max-chars", in: args).flatMap(Int.init) ?? 0,
            seed: option("--seed", in: args).flatMap(UInt64.init) ?? 42
        ) { msg in
            stderrWrite("\(msg)\n")
        }

        if jsonMode {
            try printJSON(report)
        } else {
            print("Analyzed \(report.chapters.count) chapter(s) for \(report.projectID) using \(report.llmModelID) (seed=\(report.seed), characters=\(report.characterCount), catalog rev=\(report.catalogRevision))")
            for ch in report.chapters {
                print(String(format: "  %@ (#%d %@): %d segs (%d dialogue), auto=%d, needs_review=%d, coverage=%.2f%%, stages=%d",
                             ch.chapterID, ch.chapterNumber, ch.title, ch.segmentCount, ch.dialogueSegmentCount,
                             ch.autoAttributedCount, ch.needsReviewCount, ch.coverageRatio * 100, ch.proposedStagesCount))
            }
        }
    }

    static func runCharacter(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook character list|export-md|import-md --project <id> ...\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        guard let projectID = option("--project", in: rest) else {
            stderrWrite("Missing --project for character \(action).\n"); exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "list":
            let catalog = try await engine.loadCharacters(projectID: projectID)
            if jsonMode {
                try printJSON(catalog)
            } else if catalog.cards.isEmpty {
                print("No characters found for project \(projectID).")
            } else {
                print("Character Catalog (\(catalog.projectID), rev=\(catalog.revision), count=\(catalog.cards.count)):")
                for card in catalog.cards {
                    let anchorStr = card.timbreAnchor.map { "anchor=\($0.assetID)" } ?? "anchor=none"
                    let stageStr = card.deliveryStages.isEmpty ? "stages=0" : "stages=\(card.deliveryStages.count)"
                    let aliasStr = card.aliases.isEmpty ? "-" : card.aliases.joined(separator: ",")
                    print("  \(card.characterID)\t\(card.canonicalName)\t[\(aliasStr)]\t\(anchorStr)\t\(stageStr)\tlocked=\(card.locked)")
                }
            }

        case "export-md":
            let writeToStdout = rest.contains("--stdout")
            let outURL: URL?
            if writeToStdout {
                outURL = nil
            } else if let explicitOut = option("--out", in: rest) {
                outURL = URL(fileURLWithPath: (explicitOut as NSString).expandingTildeInPath)
            } else {
                outURL = try await engine.defaultCharactersMarkdownURL(projectID: projectID)
            }
            let md = try await engine.exportCharactersMarkdown(projectID: projectID, to: outURL)
            if jsonMode {
                let payload = ["project_id": projectID, "output_path": outURL?.path ?? "stdout", "bytes": "\(md.utf8.count)"]
                try printJSON(payload)
            } else if let outURL {
                print("Exported character voice cards Markdown to \(outURL.path)")
            } else {
                print(md, terminator: "")
            }

        case "import-md":
            guard let inPath = option("--in", in: rest) else {
                stderrWrite("Missing --in <file> for character import-md.\n"); exit(2)
            }
            let catalog = try await engine.importCharactersMarkdown(projectID: projectID, from: URL(fileURLWithPath: (inPath as NSString).expandingTildeInPath))
            if jsonMode {
                try printJSON(catalog)
            } else {
                print("Imported character voice catalog for \(catalog.projectID) (rev=\(catalog.revision), cards=\(catalog.cards.count))")
            }

        default:
            stderrWrite("Unknown character subcommand: \(action)\n"); exit(2)
        }
    }

    static func runScript(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook script show --project <id> [--chapter <chapter-id>]\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        guard let projectID = option("--project", in: rest) else {
            stderrWrite("Missing --project for script \(action).\n"); exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))
        switch action {
        case "show":
            let scripts = try await engine.listScripts(projectID: projectID, chapterID: option("--chapter", in: rest))
            if jsonMode {
                try printJSON(scripts)
            } else if scripts.isEmpty {
                print("No scripts analyzed for project \(projectID).")
            } else {
                let catalog = try await engine.loadCharacters(projectID: projectID)
                let namesByID = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.characterID, $0.canonicalName) })
                for script in scripts {
                    print("Script \(script.chapterID) (rev=\(script.scriptRevision), segments=\(script.segments.count)):")
                    for seg in script.segments {
                        let speaker = namesByID[seg.speakerID] ?? seg.speakerID
                        let preview = seg.spokenText.count > 44 ? String(seg.spokenText.prefix(44)) + "…" : seg.spokenText
                        print("  \(seg.segmentID)\t\(seg.status.rawValue)\t\(speaker) (\(seg.speakerID))\t\(preview)")
                    }
                }
            }
        default:
            stderrWrite("Unknown script subcommand: \(action)\n"); exit(2)
        }
    }

    static func runGenerate(args: [String], jsonMode: Bool) async throws {
        guard let projectID = option("--project", in: args) else {
            stderrWrite("Usage: sonook generate --project <id> [--chapters 1-2] [--audition-tts <id>] [--main-tts <id>] [--asr <id>] [--seed <n>] [--stop-after <n>] [--run]\n")
            exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let priority: TaskPriority = args.contains("--interactive") ? .interactive : .background
        let snapshot = try await engine.submitAudiobookGenerateJob(
            projectID: projectID,
            chapterSpec: option("--chapters", in: args),
            auditionTTSModelID: option("--audition-tts", in: args),
            mainTTSModelID: option("--main-tts", in: args),
            asrModelID: option("--asr", in: args),
            seed: option("--seed", in: args).flatMap(UInt64.init) ?? 42,
            stopAfterCompletedNodes: option("--stop-after", in: args).flatMap(Int.init),
            maxRepairRounds: option("--max-repair-rounds", in: args).flatMap(Int.init) ?? 2,
            priority: priority
        )

        if args.contains("--run") {
            let report = try await engine.runJob(jobID: snapshot.job.jobID) { msg in
                stderrWrite("\(msg)\n")
            }
            if jsonMode {
                try printJSON(report)
            } else {
                print("Audiobook job \(report.jobID) finished: status=\(report.finalStatus.rawValue) executed=\(report.executedNodeIDs.count) skipped=\(report.skippedCompletedNodeIDs.count) needs_review=\(report.needsReviewNodeIDs.count) failed=\(report.failedNodeIDs.count) cancelled=\(report.cancelled)")
            }
        } else {
            if jsonMode {
                try printJSON(snapshot)
            } else {
                print("Submitted audiobook job \(snapshot.job.jobID) (nodes=\(snapshot.nodes.count), edges=\(snapshot.edges.count)). Run `sonook job run \(snapshot.job.jobID)` to execute.")
            }
        }
    }

    static func runSegment(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook segment regenerate|approve <segment-id> --project <id> ...\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        guard let segmentID = rest.first, !segmentID.hasPrefix("-"),
              let projectID = option("--project", in: rest) else {
            stderrWrite("Missing <segment-id> or --project for segment \(action).\n"); exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "regenerate":
            let result = try await engine.regenerateSegment(
                projectID: projectID,
                segmentID: segmentID,
                mainTTSModelID: option("--main-tts", in: rest),
                asrModelID: option("--asr", in: rest),
                seed: option("--seed", in: rest).flatMap(UInt64.init) ?? 42,
                emotion: option("--emotion", in: rest),
                styleInstruction: option("--style", in: rest),
                pauseAfterMs: option("--pause-ms", in: rest).flatMap(Int.init),
                allowNeedsReviewSwap: rest.contains("--allow-needs-review-swap")
            ) { msg in
                stderrWrite("\(msg)\n")
            }
            if jsonMode {
                try printJSON(result)
            } else {
                print(String(format: "Segment %@ regenerated: swapped=%@ status=%@->%@ rawCER=%.2f%% adjCER=%.2f%% exemptions=%d candidate=%@",
                             result.segmentID, String(result.swapped), result.previousStatus.rawValue,
                             result.newStatus.rawValue, result.audit.rawCER * 100, result.audit.adjustedCER * 100,
                             result.audit.exemptions.count, result.candidateAssetID))
            }

        case "approve":
            let note = option("--note", in: rest) ?? "approved by reviewer"
            let record = try await engine.approveSegment(projectID: projectID, segmentID: segmentID, note: note)
            if jsonMode {
                try printJSON(record)
            } else {
                print("Approved segment \(record.segmentID) (asset=\(record.approvedAssetID), note=\"\(record.reviewerNote)\")")
            }

        default:
            stderrWrite("Unknown segment subcommand: \(action)\n"); exit(2)
        }
    }

    static func runVerify(args: [String], jsonMode: Bool) async throws {
        guard let projectID = option("--project", in: args) else {
            stderrWrite("Usage: sonook verify --project <id> [--chapters 1-2] [--m4b <path>] [--save-report]\n")
            exit(2)
        }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.verifyProject(
            projectID: projectID,
            chapterSpec: option("--chapters", in: args),
            m4bURL: option("--m4b", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        )
        var savedReportURL: URL?
        if args.contains("--save-report") {
            savedReportURL = try await engine.saveVerificationReport(report)
        }

        if jsonMode {
            try printJSON(report)
        } else {
            print("Verification for \(report.projectID): export_ready=\(report.exportReady) (verified=\(report.verifiedSegments)/\(report.totalSegments), approved=\(report.approvedSegments), blocking=\(report.blockingSegmentIDs.count))")
            for ch in report.chapters {
                print("  \(ch.chapterID) (#\(ch.chapterNumber) \(ch.title)): verified=\(ch.verifiedCount)/\(ch.totalSegments) approved=\(ch.approvedCount) needs_review=\(ch.needsReviewCount) pending/failed=\(ch.pendingOrFailedCount) ready=\(ch.exportReady)")
            }
            if !report.blockingSegmentIDs.isEmpty {
                print("  Blocking segments: \(report.blockingSegmentIDs.joined(separator: ", "))")
            }
            if let m4b = report.inspectedM4B {
                print(String(format: "  M4B Readback: %.2fs, %d chapter(s)", m4b.durationSeconds, m4b.chapters.count))
                for c in m4b.chapters {
                    print(String(format: "    [%.2fs +%.2fs] %@", c.startSeconds, c.durationSeconds, c.title))
                }
            }
            if let savedReportURL {
                print("  Saved Report: \(savedReportURL.path)")
            }
        }
        if !report.exportReady {
            exit(3)
        }
    }

    static func runExport(args: [String], jsonMode: Bool) async throws {
        guard let projectID = option("--project", in: args),
              let format = ExportFormat(rawValue: (option("--format", in: args) ?? "m4a").lowercased()) else {
            stderrWrite("Usage: sonook export --project <id> [--format m4a|m4b|wav] [--out <file>] [--chapters 1-2] [--ambient-file <wav/m4a> | --soundscape] [--sound-library <dir>] [--sfx-helper <path>] [--sfx-license <tag>]\n")
            exit(2)
        }
        for key in ["--sound-library", "--sfx-helper", "--sfx-license"] where args.contains(key) {
            guard let value = option(key, in: args), !value.isEmpty, !value.hasPrefix("--") else {
                throw EngineSDKError.invalidInput("Missing value for \(key)")
            }
        }
        let explicitOutURL = option("--out", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.exportBook(
            projectID: projectID,
            format: format,
            destinationURL: explicitOutURL,
            chapterSpec: option("--chapters", in: args),
            title: option("--title", in: args),
            author: option("--author", in: args),
            narrator: option("--narrator", in: args),
            ambientFileURL: option("--ambient-file", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            ambientGainDB: option("--ambient-gain-db", in: args).flatMap(Double.init) ?? -24.0,
            ambientDuckingDB: option("--ambient-duck-db", in: args).flatMap(Double.init) ?? -8.0,
            chapterGapMs: option("--chapter-gap-ms", in: args).flatMap(Int.init) ?? 1200,
            soundscapeEnabled: args.contains("--soundscape"),
            soundLibraryDirectory: option("--sound-library", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            sfxHelperExecutable: option("--sfx-helper", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            sfxLicenseTag: option("--sfx-license", in: args)
        ) { msg in
            stderrWrite("\(msg)\n")
        }

        if jsonMode {
            try printJSON(report)
        } else {
            print(String(format: "Exported %@ (%@): %.2fs @ %d Hz, %d chapter(s), %d segment(s), ambient=%@",
                         report.outputPath, report.format.rawValue.uppercased(), report.durationSeconds,
                         report.sampleRate, report.chapterCount, report.segmentCount, String(report.ambientMixed)))
            print("  Timeline: \(report.timelinePath)")
            print("  Render Fingerprint: \(report.renderFingerprint)")
            if let m4b = report.verifiedM4B {
                print("  M4B Chapters Verified (\(m4b.chapters.count)):")
                for c in m4b.chapters {
                    print(String(format: "    [%.2fs +%.2fs] %@", c.startSeconds, c.durationSeconds, c.title))
                }
            }
        }
    }
}
