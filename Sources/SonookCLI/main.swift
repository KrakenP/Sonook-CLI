import AudioCore
import AudioRenderKit
import ContentKit
import EngineSDK
import Foundation
import ModelRuntime
import SpeechKit
import StorageKit
import WorkflowKit

@main
struct SonookCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }
        let jsonMode = args.contains("--json")
        JSONStdoutIsolator.shared.activateIfNeeded(jsonMode: jsonMode)
        defer { JSONStdoutIsolator.shared.restoreIfNeeded() }

        do {
            guard let subcommand = args.first else {
                printBanner(jsonMode: jsonMode)
                return
            }

            let rest = Array(args.dropFirst())
            switch subcommand {
            case "--version", "-v", "version":
                if jsonMode {
                    struct Version: Encodable {
                        let engine_version = EngineSDKInfo.version
                        let project = AudioCoreInfo.projectName
                        let schema_version = AudioCoreInfo.currentSchemaVersion
                    }
                    try printJSON(Version())
                } else {
                    print(EngineSDKInfo.version)
                }
            case "build":
                try await runBuild(args: rest, jsonMode: jsonMode)
            case "doctor":
                try await runDoctor(args: rest, jsonMode: jsonMode)
            case "project":
                try await runProject(args: rest, jsonMode: jsonMode)
            case "model":
                try await runModel(args: rest, jsonMode: jsonMode)
            case "import":
                try await runImport(args: rest, jsonMode: jsonMode)
            case "chapter":
                try await runChapter(args: rest, jsonMode: jsonMode)
            case "analyze":
                try await runAnalyze(args: rest, jsonMode: jsonMode)
            case "character":
                try await runCharacter(args: rest, jsonMode: jsonMode)
            case "script":
                try await runScript(args: rest, jsonMode: jsonMode)
            case "generate":
                try await runGenerate(args: rest, jsonMode: jsonMode)
            case "segment":
                try await runSegment(args: rest, jsonMode: jsonMode)
            case "review":
                try await runReview(args: rest, jsonMode: jsonMode)
            case "cache":
                try await runCache(args: rest, jsonMode: jsonMode)
            case "memory":
                try await runMemory(args: rest, jsonMode: jsonMode)
            case "verify":
                try await runVerify(args: rest, jsonMode: jsonMode)
            case "soundscape", "drama", "podcast":
                try await runUniversalAudio(command: subcommand, args: rest, jsonMode: jsonMode)
            case "publish", "pack", "releases", "sync", "context", "server", "serve":
                try await runService(command: subcommand, args: rest, jsonMode: jsonMode)
            case "export":
                try await runExport(args: rest, jsonMode: jsonMode)
            case "job":
                try await runJob(args: rest, jsonMode: jsonMode)
            case "p0-run":
                try await runP0Pipeline(args: rest, jsonMode: jsonMode)
            case "p0-tts-bench":
                try await runP0TTSShootout(args: rest, jsonMode: jsonMode)
            case _ where subcommand.hasPrefix("-"):
                printBanner(jsonMode: jsonMode)
            case "help":
                printUsage()
            default:
                if SonookWorkspaceLayout.isQuickBuildSourceArgument(subcommand) {
                    try await runQuickBuild(args: args, jsonMode: jsonMode)
                    return
                }
                stderrWrite("Unknown command: \(subcommand)\n")
                printUsage()
                exit(2)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            stderrWrite("ERROR: \(msg)\n")
            if jsonMode {
                let payload = ["status": "error", "message": msg]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    JSONStdoutIsolator.shared.writeCleanJSONData(data)
                }
            }
            JSONStdoutIsolator.shared.restoreIfNeeded()
            exit(1)
        }
    }

    // MARK: - Helpers

    static func option(_ name: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func resolveWorkspaceURL(from args: [String]) -> URL {
        if let explicit = option("--workspace", in: args) {
            let expanded = (explicit as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return SonookWorkspaceLayout.defaultWorkspaceRoot()
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        JSONStdoutIsolator.shared.writeCleanJSONData(data)
    }

    private static func printBanner(jsonMode: Bool) {
        if jsonMode {
            let banner = "{\"engine_version\":\"\(EngineSDKInfo.version)\",\"project\":\"\(AudioCoreInfo.projectName)\",\"schema_version\":\(AudioCoreInfo.currentSchemaVersion),\"status\":\"ready\"}"
            JSONStdoutIsolator.shared.writeCleanJSONData(Data(banner.utf8))
        } else {
            print("\(AudioCoreInfo.projectName) (\(AudioCoreInfo.chineseName)) CLI \(EngineSDKInfo.version) — schema v\(AudioCoreInfo.currentSchemaVersion)")
            printUsage()
        }
    }

    static func printUsage() {
        stderrWrite("""
        sonook <file> [options]
          Build an audiobook in <title>_sonook/ next to the source. Accepts the options listed for sonook build.

        Default Workspace: ~/Sonook (override with --workspace <dir> or SONOOK_WORKSPACE)
        Workspace Outputs: <workspace>/outputs/<name>__<projectID>/{audiobooks,characters,reports,releases}/
        Usage:
          sonook --version | -v | version [--json]
          sonook build <file> [--name <title>] [--chapters <spec>] [--format m4b|m4a|wav] [--out <file>]
                       [--soundscape] [--sound-library <dir>] [--sfx-helper <path>] [--sfx-license <tag>]
                       [--publish] [--seed <n>] [--max-repair-rounds <n>] [--workspace <dir>] [--json]
          sonook doctor [--workspace <dir>] [--json]

          sonook project create --name <name> [--type audiobook|audio_drama|podcast] [--ambient] [--workspace <dir>] [--json]
          sonook project list [--workspace <dir>] [--json]
          sonook project path <project-id> [--workspace <dir>] [--json]

          sonook model register --id <model-id> --kind <llm|tts|asr> --provider <provider-id> --path <dir>
                                [--license <spdx>] [--quant <tag>] [--peak-mib <n>] [--workspace <dir>] [--json]
          sonook model list [--kind <llm|tts|asr>] [--workspace <dir>] [--json]

          sonook import <file> --project <id> [--encoding utf-8|utf-16le|utf-16be|gb18030] [--format txt|markdown|epub] [--workspace <dir>] [--json]
          sonook chapter list --project <id> [--workspace <dir>] [--json]
          sonook analyze --project <id> [--chapters <spec>] [--llm <id>] [--max-chars <n>] [--seed <n>] [--workspace <dir>] [--json]
          sonook character list --project <id> [--workspace <dir>] [--json]
          sonook character export-md --project <id> [--out <file> | --stdout] [--workspace <dir>] [--json]
          sonook character import-md --project <id> --in <file> [--workspace <dir>] [--json]
          sonook script show --project <id> [--chapter <chapter-id>] [--workspace <dir>] [--json]
          sonook soundscape plan --project <id> [--chapters <spec>] [--llm <id>] [--lexical-only] [--seed <n>] [--workspace <dir>] [--json]
          sonook soundscape list --project <id> [--workspace <dir>] [--json]
          sonook soundscape library scan <dir> [--write-manifest] [--workspace <dir>] [--json]
              Without a manifest, scan expects a curated CC0 directory.
          sonook drama adapt --project <id> [--chapters <spec>] --authorize [--note <text>] [--keep-narration] [--no-sfx]
                             [--llm <id>] [--lexical-only] [--seed <n>] [--workspace <dir>] [--json]
          sonook podcast ingest <file> --project <id> [--title <t>] [--workspace <dir>] [--json]
          sonook podcast sources --project <id> [--workspace <dir>] [--json]
          sonook podcast search --project <id> --query <q> [--limit <n>] [--workspace <dir>] [--json]
          sonook podcast plan --project <id> --topic <q> [--title <t>] [--episode <id>] [--format solo|dual]
                              [--limit <n>] [--llm <id>] [--lexical-only] [--seed <n>] [--workspace <dir>] [--json]

          sonook generate --project <id> [--chapters <spec>] [--audition-tts <id>] [--main-tts <id>] [--asr <id>]
                          [--seed <n>] [--max-repair-rounds <2>] [--stop-after <n>] [--run] [--workspace <dir>] [--json]
          sonook segment regenerate <segment-id> --project <id> [--main-tts <id>] [--asr <id>] [--seed <n>]
                                    [--emotion <e>] [--style <s>] [--pause-ms <n>] [--allow-needs-review-swap] [--workspace <dir>] [--json]
          sonook segment approve <segment-id> --project <id> --note <text> [--workspace <dir>] [--json]
          sonook review list|retry|approve-all|reassign ... [--workspace <dir>] [--json]
          sonook cache plan --project <id> [--chapters <spec>] [--main-tts <id>] [--workspace <dir>] [--json]
          sonook memory list --project <id> [--up-to <chapter-num>] [--workspace <dir>] [--json]
          sonook verify --project <id> [--chapters <spec>] [--m4b <file>] [--save-report] [--workspace <dir>] [--json]
          sonook export --project <id> --format <wav|m4a|m4b> [--out <file>] [--chapters <spec>]
                        [--title <t>] [--author <a>] [--narrator <n>]
                        [--ambient-file <wav/m4a>] [--ambient-gain-db <-24>] [--ambient-duck-db <-8>]
                        [--soundscape] [--sound-library <dir>] [--sfx-helper <path>] [--sfx-license <tag>]
                        [--chapter-gap-ms <1200>] [--workspace <dir>] [--json]

          sonook publish --project <id> [--chapters <spec>] [--out <dir.audiopack>] [--title <t>] [--author <a>] [--narrator <n>]
                         [--soundscape] [--sound-library <dir>] [--sfx-helper <path>] [--sfx-license <tag>] [--workspace <dir>] [--json]
          sonook pack verify <dir.audiopack> [--workspace <dir>] [--json]
          sonook releases list [--project <id>] [--workspace <dir>] [--json]
          sonook sync push --file <events.json> [--workspace <dir>] [--json]
          sonook sync cursor --project <id> [--workspace <dir>] [--json]
          sonook context query --project <id> --chapter <n> [--segment <id>] --query <q>
                               [--allow-spoilers] [--lexical-only] [--llm <id>] [--workspace <dir>] [--json]
          sonook server pair-code [--scopes <csv>] [--ttl <seconds>] [--workspace <dir>] [--json]
          sonook server devices [--workspace <dir>] [--json]
          sonook server revoke <device-id> [--workspace <dir>] [--json]
          sonook serve [--host 127.0.0.1] [--port 8765] [--allow-lan] [--ready-file <path>]
                       [--llm-context] [--llm <id>] [--workspace <dir>] [--json]

          sonook job submit --project <id> --workflow fake-demo|chapter-mlx ... [--run] [--workspace <dir>] [--json]
          sonook job run|status|list|cancel|resume ... [--workspace <dir>] [--json]

          sonook p0-run --input <file> --llm <dir> --tts <dir> --asr <dir> --out <dir> [options]
          sonook p0-tts-bench --engine <engine> --script <json> --catalog <json> --tts <dir> --asr <dir> --out <dir> [options]
        """)
    }

    // MARK: - Formal P1 Commands (delegating 100% to EngineSDK)

    private static func runDoctor(args: [String], jsonMode: Bool) async throws {
        let wsURL = resolveWorkspaceURL(from: args)
        let engine = try SonookEngine(workspaceRoot: wsURL)
        let report = try await engine.doctor()
        if jsonMode {
            try printJSON(report)
        } else {
            let hwGiB = Double(report.runtimeSnapshot.hardwareMemoryBytes) / (1024 * 1024 * 1024)
            let budgetGiB = Double(report.runtimeSnapshot.budgetBytes) / (1024 * 1024 * 1024)
            print("Sonook (\(AudioCoreInfo.chineseName)) Doctor — \(report.engineVersion)")
            print("  Workspace: \(report.workspacePath)")
            print("  Outputs:   \(SonookWorkspaceLayout.outputsRoot(workspaceRoot: wsURL).path)")
            print("  OS: \(report.osVersion) (\(report.processorCount) CPUs)")
            print(String(format: "  Memory: %.1f GiB unified (budget %.1f GiB) | Thermal: %@", hwGiB, budgetGiB, report.runtimeSnapshot.memorySample.thermalState))
            print("  Catalog: \(report.projectCount) projects, \(report.modelCount) models, \(report.jobCount) jobs")
            print("  Reconciliation: removedTmp=\(report.reconciliation.removedTempFiles), removedOrphans=\(report.reconciliation.removedOrphanAssets), missing=\(report.reconciliation.missingReferencedAssetIDs.count), corrupted=\(report.reconciliation.corruptedAssetIDs.count)")
        }
    }

    private static func runProject(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            printUsage(); exit(2)
        }
        let rest = Array(args.dropFirst())
        let wsURL = resolveWorkspaceURL(from: rest)
        let engine = try SonookEngine(workspaceRoot: wsURL)

        switch action {
        case "create":
            guard let name = option("--name", in: rest), !name.isEmpty else {
                stderrWrite("Missing --name for project create.\n"); exit(2)
            }
            let typeRaw = option("--type", in: rest) ?? "audiobook"
            guard let projType = ProjectType(rawValue: typeRaw) else {
                stderrWrite("Invalid --type: \(typeRaw)\n"); exit(2)
            }
            let ambient = rest.contains("--ambient")
            let proj = try await engine.createProject(name: name, type: projType, ambientAudioEnabled: ambient)
            let outDir = SonookWorkspaceLayout.projectOutputDirectory(workspaceRoot: wsURL, project: proj)
            if jsonMode {
                try printJSON(proj)
            } else {
                print("Created project \(proj.projectID) (\(proj.name), type=\(proj.projectType.rawValue), ambient=\(proj.options.ambientAudioEnabled))")
                print("  Outputs: \(outDir.path)")
            }
        case "list":
            let projects = try await engine.listProjects()
            if jsonMode {
                try printJSON(projects)
            } else if projects.isEmpty {
                print("No projects in workspace.")
            } else {
                for p in projects {
                    let outDir = SonookWorkspaceLayout.projectOutputDirectory(workspaceRoot: wsURL, project: p)
                    print("\(p.projectID)\t\(p.projectType.rawValue)\tambient=\(p.options.ambientAudioEnabled)\t\(p.name)\t\(outDir.path)")
                }
            }
        case "path":
            guard let projectID = option("--project", in: rest) ?? rest.first(where: { !$0.hasPrefix("-") }) else {
                stderrWrite("Usage: sonook project path <project-id> [--workspace <dir>]\n"); exit(2)
            }
            let outDir = try await engine.projectOutputDirectory(projectID: projectID)
            if jsonMode {
                try printJSON([
                    "project_id": projectID,
                    "outputs_dir": outDir.path,
                    "audiobooks_dir": outDir.appendingPathComponent(SonookWorkspaceLayout.audiobooksFolderName).path,
                    "characters_dir": outDir.appendingPathComponent(SonookWorkspaceLayout.charactersFolderName).path,
                    "reports_dir": outDir.appendingPathComponent(SonookWorkspaceLayout.reportsFolderName).path
                ])
            } else {
                print(outDir.path)
            }
        default:
            stderrWrite("Unknown project subcommand: \(action)\n"); exit(2)
        }
    }

    private static func runModel(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            printUsage(); exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "register":
            guard let id = option("--id", in: rest),
                  let kindRaw = option("--kind", in: rest),
                  let kind = ModelKind(rawValue: kindRaw),
                  let providerID = option("--provider", in: rest),
                  let path = option("--path", in: rest) else {
                stderrWrite("Missing required options for model register (--id, --kind, --provider, --path).\n"); exit(2)
            }
            let entry = try await engine.registerModel(
                modelID: id,
                kind: kind,
                providerID: providerID,
                localPath: path,
                revision: option("--revision", in: rest) ?? "local",
                license: option("--license", in: rest) ?? "Apache-2.0",
                quantization: option("--quant", in: rest),
                estimatedPeakMiB: option("--peak-mib", in: rest).flatMap(Int.init) ?? 8192,
                notes: option("--notes", in: rest)
            )
            if jsonMode {
                try printJSON(entry)
            } else {
                print("Registered \(entry.kind.rawValue) model \(entry.modelID) (provider=\(entry.providerID), license=\(entry.license))")
            }
        case "list":
            let kindFilter = option("--kind", in: rest).flatMap(ModelKind.init(rawValue:))
            let models = try await engine.listModels(kind: kindFilter)
            if jsonMode {
                try printJSON(models)
            } else if models.isEmpty {
                print("No registered models.")
            } else {
                for m in models {
                    let peakMiB = Double(m.effectiveBudgetBytes) / (1024 * 1024)
                    print(String(format: "%@\t%@\t%@\t%@\t%.0f MiB", m.modelID, m.kind.rawValue, m.providerID, m.license, peakMiB))
                }
            }
        default:
            stderrWrite("Unknown model subcommand: \(action)\n"); exit(2)
        }
    }

    private static func runJob(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            printUsage(); exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "submit":
            guard let projectID = option("--project", in: rest),
                  let workflow = option("--workflow", in: rest) else {
                stderrWrite("Missing --project or --workflow for job submit.\n"); exit(2)
            }
            let priority: TaskPriority = rest.contains("--interactive") ? .interactive : .background
            let snapshot: JobSnapshot
            switch workflow {
            case "fake-demo":
                let cfg = FakeDemoJobConfig(
                    segmentCount: option("--segments", in: rest).flatMap(Int.init) ?? 4,
                    failOnceSegmentIndex: option("--fail-once", in: rest).flatMap(Int.init),
                    permanentFailSegmentIndex: option("--permanent-fail", in: rest).flatMap(Int.init),
                    needsReviewSegmentIndex: option("--needs-review", in: rest).flatMap(Int.init),
                    stepDelayMs: option("--delay-ms", in: rest).flatMap(Int.init) ?? 20,
                    ambientAudioEnabled: rest.contains("--ambient")
                )
                snapshot = try await engine.submitFakeDemoJob(projectID: projectID, config: cfg, priority: priority)
            case "chapter-mlx":
                guard let inputPath = option("--input", in: rest),
                      let llmID = option("--llm", in: rest),
                      let vdID = option("--audition-tts", in: rest),
                      let mainTTSID = option("--main-tts", in: rest),
                      let asrID = option("--asr", in: rest) else {
                    stderrWrite("Missing required options for chapter-mlx (--input, --llm, --audition-tts, --main-tts, --asr).\n"); exit(2)
                }
                snapshot = try await engine.submitChapterMLXJob(
                    projectID: projectID,
                    inputFilePath: URL(fileURLWithPath: inputPath),
                    chapterNumber: option("--chapter", in: rest).flatMap(Int.init) ?? 1,
                    maxCharacters: option("--max-chars", in: rest).flatMap(Int.init) ?? 750,
                    llmModelID: llmID,
                    auditionTTSModelID: vdID,
                    mainTTSModelID: mainTTSID,
                    asrModelID: asrID,
                    exportDirectory: option("--export-dir", in: rest).map { URL(fileURLWithPath: $0, isDirectory: true) },
                    allowNeedsReviewInRender: !rest.contains("--strict-verified-render"),
                    stopAfterCompletedNodes: option("--stop-after", in: rest).flatMap(Int.init),
                    priority: priority
                )
            default:
                stderrWrite("Unsupported workflow: \(workflow)\n"); exit(2)
            }

            if rest.contains("--run") {
                let report = try await engine.runJob(jobID: snapshot.job.jobID) { msg in
                    stderrWrite("\(msg)\n")
                }
                if jsonMode {
                    try printJSON(report)
                } else {
                    print("Job \(report.jobID) finished: status=\(report.finalStatus.rawValue) executed=\(report.executedNodeIDs.count) skipped=\(report.skippedCompletedNodeIDs.count) needs_review=\(report.needsReviewNodeIDs.count) failed=\(report.failedNodeIDs.count) cancelled=\(report.cancelled)")
                }
            } else {
                if jsonMode {
                    try printJSON(snapshot)
                } else {
                    print("Submitted job \(snapshot.job.jobID) (\(snapshot.job.workflowKind), nodes=\(snapshot.nodes.count), edges=\(snapshot.edges.count))")
                }
            }

        case "run":
            guard let jobID = rest.first, !jobID.hasPrefix("-") else {
                stderrWrite("Missing <job-id> for job run.\n"); exit(2)
            }
            let report = try await engine.runJob(jobID: jobID) { msg in
                stderrWrite("\(msg)\n")
            }
            if jsonMode {
                try printJSON(report)
            } else {
                print("Job \(report.jobID) run complete: status=\(report.finalStatus.rawValue) executed=\(report.executedNodeIDs.count) skipped=\(report.skippedCompletedNodeIDs.count) needs_review=\(report.needsReviewNodeIDs.count) failed=\(report.failedNodeIDs.count)")
            }

        case "resume":
            guard let jobID = rest.first, !jobID.hasPrefix("-") else {
                stderrWrite("Missing <job-id> for job resume.\n"); exit(2)
            }
            let report = try await engine.resumeJob(jobID: jobID) { msg in
                stderrWrite("\(msg)\n")
            }
            if jsonMode {
                try printJSON(report)
            } else {
                print("Job \(report.jobID) resumed: status=\(report.finalStatus.rawValue) executed=\(report.executedNodeIDs.count) skipped_completed=\(report.skippedCompletedNodeIDs.count) needs_review=\(report.needsReviewNodeIDs.count) failed=\(report.failedNodeIDs.count)")
            }

        case "cancel":
            guard let jobID = rest.first, !jobID.hasPrefix("-") else {
                stderrWrite("Missing <job-id> for job cancel.\n"); exit(2)
            }
            let updated = try await engine.cancelJob(jobID: jobID)
            if jsonMode {
                try printJSON(updated)
            } else {
                print("Cancelled job \(updated.jobID) (status=\(updated.status.rawValue), cancel_requested=\(updated.cancelRequested))")
            }

        case "status":
            guard let jobID = rest.first, !jobID.hasPrefix("-") else {
                stderrWrite("Missing <job-id> for job status.\n"); exit(2)
            }
            guard let snap = try await engine.jobSnapshot(jobID: jobID) else {
                stderrWrite("Job not found: \(jobID)\n"); exit(1)
            }
            if jsonMode {
                try printJSON(snap)
            } else {
                print("Job \(snap.job.jobID) [\(snap.job.workflowKind)] status=\(snap.job.status.rawValue) cancel_requested=\(snap.job.cancelRequested)")
                for n in snap.nodes {
                    print("  \(n.nodeID)\t\(n.kind)\t\(n.status.rawValue)\tattempts=\(n.attemptCount)/\(n.maxAttempts)\tgen=\(n.leaseGeneration)\tasset=\(n.outputAssetID ?? "-")")
                }
            }

        case "list":
            let jobs = try await engine.listJobs(projectID: option("--project", in: rest))
            if jsonMode {
                try printJSON(jobs)
            } else if jobs.isEmpty {
                print("No jobs in workspace.")
            } else {
                for j in jobs {
                    print("\(j.jobID)\t\(j.projectID)\t\(j.workflowKind)\t\(j.status.rawValue)\t\(j.updatedAtISO8601)")
                }
            }

        default:
            stderrWrite("Unknown job subcommand: \(action)\n"); exit(2)
        }
    }

    // MARK: - Preserved P0 Benchmark Commands

    private static func runP0Pipeline(args: [String], jsonMode: Bool) async throws {
        guard let inputPath = option("--input", in: args),
              let llmPath = option("--llm", in: args),
              let ttsPath = option("--tts", in: args),
              let asrPath = option("--asr", in: args),
              let outPath = option("--out", in: args) else {
            stderrWrite("Missing required options for p0-run.\n")
            printUsage()
            exit(2)
        }

        let config = P0PipelineConfig(
            inputPath: URL(fileURLWithPath: inputPath),
            chapterNumber: option("--chapter", in: args).flatMap(Int.init) ?? 1,
            maxCharacters: option("--max-chars", in: args).flatMap(Int.init) ?? 900,
            llmModelDirectory: URL(fileURLWithPath: llmPath),
            ttsModelDirectory: URL(fileURLWithPath: ttsPath),
            asrModelDirectory: URL(fileURLWithPath: asrPath),
            outputDirectory: URL(fileURLWithPath: outPath),
            existingCatalogPath: option("--catalog", in: args).map { URL(fileURLWithPath: $0) },
            llmLabel: option("--llm-label", in: args),
            ttsLabel: option("--tts-label", in: args),
            asrLabel: option("--asr-label", in: args),
            skipTTSAndASR: args.contains("--llm-only")
        )

        let report = try await P0PipelineRunner.run(config: config) { message in
            stderrWrite("\(message)\n")
        }

        if jsonMode {
            try printJSON(report)
        } else {
            print("Sonook P0 Run Complete (\(report.chapterID))")
            print(String(format: "  Coverage: %.2f%% (valid=%@)", report.sourceCoverageRatio * 100, String(report.sourceCoverageValid)))
            print("  Characters: \(report.characterCount) (catalog rev \(report.catalogRevision), md roundtrip=\(report.markdownRoundTripVerified))")
            print("  Segments: \(report.segmentCount) (dialogue=\(report.dialogueSegmentCount))")
            if let rtf = report.aggregateTTSRTFExcludingLoad, let dur = report.totalAudioDurationSeconds {
                print(String(format: "  TTS: %.2fs audio, RTF=%.3f (excl load)", dur, rtf))
            }
            if let cer = report.weightedCER {
                print(String(format: "  ASR Weighted CER: %.2f%% (passed=%d, needs_review=%d, retryable=%d)", cer * 100, report.passedSegments, report.needsReviewSegments, report.retryableFailureSegments))
            }
        }
    }

    private static func runP0TTSShootout(args: [String], jsonMode: Bool) async throws {
        guard let engineRaw = option("--engine", in: args),
              let engine = TTSShootoutEngine(rawValue: engineRaw),
              let scriptPath = option("--script", in: args),
              let catalogPath = option("--catalog", in: args),
              let ttsPath = option("--tts", in: args),
              let asrPath = option("--asr", in: args),
              let outPath = option("--out", in: args) else {
            stderrWrite("Missing or invalid options for p0-tts-bench.\n")
            printUsage()
            exit(2)
        }

        let ttsURL = URL(fileURLWithPath: ttsPath)
        let asrURL = URL(fileURLWithPath: asrPath)
        let config = P0TTSShootoutConfig(
            engine: engine,
            scriptPath: URL(fileURLWithPath: scriptPath),
            catalogPath: URL(fileURLWithPath: catalogPath),
            ttsModelDirectory: ttsURL,
            ttsLabel: option("--tts-label", in: args) ?? ttsURL.lastPathComponent,
            asrModelDirectory: asrURL,
            asrLabel: option("--asr-label", in: args) ?? asrURL.lastPathComponent,
            outputDirectory: URL(fileURLWithPath: outPath),
            saveAuditionsDirectory: option("--save-auditions", in: args).map { URL(fileURLWithPath: $0) },
            loadAuditionsDirectory: option("--auditions", in: args).map { URL(fileURLWithPath: $0) }
        )

        let report = try await P0TTSShootoutRunner.run(config: config) { msg in
            stderrWrite("\(msg)\n")
        }

        if jsonMode {
            try printJSON(report)
        } else {
            print("Sonook TTS Shootout Complete (\(report.engine) / \(report.ttsModel))")
            print(String(format: "  Audio: %.2fs @ %d Hz | RTF=%.3f (excl load) | Load=%.0fms", report.totalAudioDurationSeconds, report.sampleRate, report.aggregateRTFExcludingLoad, report.ttsLoadMs))
            print(String(format: "  ASR Weighted CER: %.2f%% (passed=%d/%d, needs_review=%d, retryable=%d)", report.weightedCER * 100, report.passedSegments, report.segmentCount, report.needsReviewSegments, report.retryableFailureSegments))
        }
    }

    static func stderrWrite(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
