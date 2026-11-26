import AudioCore
import EngineSDK
import Foundation

struct AudioCommandOptions {
    var values: [String: String] = [:]
    var flags = Set<String>()
    var paths: [String] = []

    init(_ args: ArraySlice<String>, options: Set<String>, switches: Set<String> = [], pathCount: Int = 0) throws {
        var iterator = args.makeIterator()
        while let token = iterator.next() {
            if switches.contains(token) || token == "--json" {
                flags.insert(token)
            } else if options.contains(token) || token == "--workspace" {
                guard let value = iterator.next(), !value.hasPrefix("--"), !value.isEmpty else {
                    throw EngineSDKError.invalidInput("Missing value for \(token)")
                }
                values[token] = value
            } else if token.hasPrefix("-") {
                throw EngineSDKError.invalidInput("Unknown option \(token)")
            } else {
                paths.append(token)
            }
        }
        guard paths.count == pathCount else {
            throw EngineSDKError.invalidInput(pathCount == 1 ? "Expected one positional argument" : "Unexpected positional argument")
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw EngineSDKError.invalidInput("Missing \(key)") }
        return value
    }

    var seed: UInt64 {
        get throws {
            guard let raw = values["--seed"] else { return 42 }
            guard let n = UInt64(raw) else { throw EngineSDKError.invalidInput("--seed requires an unsigned integer") }
            return n
        }
    }

    var limit: Int {
        get throws {
            guard let raw = values["--limit"] else { return 8 }
            guard let n = Int(raw), n > 0 else { throw EngineSDKError.invalidInput("--limit requires a positive integer") }
            return n
        }
    }
}

extension SonookCLI {
    static func runUniversalAudio(command: String, args: [String], jsonMode: Bool) async throws {
        let planning: Set<String> = ["--project", "--llm", "--seed"]
        let lexical: Set<String> = ["--lexical-only"]
        let log: @Sendable (String) -> Void = { stderrWrite($0 + "\n") }
        func engine() throws -> SonookEngine { try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args)) }
        func file(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let rest = args.dropFirst()
        switch (command, args.first) {
        case ("soundscape", "plan"):
            let opts = try AudioCommandOptions(rest, options: planning.union(["--chapters"]), switches: lexical)
            let report = try await engine().planSoundscapes(projectID: opts.required("--project"), chapterSpec: opts.values["--chapters"],
                llmModelID: opts.values["--llm"], useLLM: !opts.flags.contains("--lexical-only"), seed: opts.seed, progress: log)
            if jsonMode { try printJSON(report) }
            else { print("Planned \(report.chapterCount) chapter(s), \(report.totalSceneCues) scenes, \(report.totalSFXCues) sound effects.") }
        case ("soundscape", "list"):
            let opts = try AudioCommandOptions(rest, options: ["--project"])
            let plans = try await engine().listSoundscapes(projectID: opts.required("--project"))
            if jsonMode { try printJSON(plans) }
            else { for p in plans { print("\(p.chapterID)\t\(p.sceneCues.count) scenes\t\(p.sfxCues.count) effects") } }
        case ("soundscape", "library") where rest.first == "scan":
            let opts = try AudioCommandOptions(rest.dropFirst(), options: [], switches: ["--write-manifest"], pathCount: 1)
            let report = try engine().scanSoundLibrary(directory: file(opts.paths[0]), writeManifest: opts.flags.contains("--write-manifest"))
            if jsonMode { try printJSON(report) }
            else {
                print("\(report.manifest.entries.count) sound library entries.")
                for entry in report.licenseAudit { print("\(entry.entryID)\t\(entry.license)\t\(entry.classification)") }
            }
        case ("drama", "adapt"):
            let opts = try AudioCommandOptions(rest, options: planning.union(["--chapters", "--note"]),
                                               switches: lexical.union(["--authorize", "--keep-narration", "--no-sfx"]))
            guard opts.flags.contains("--authorize") else {
                throw EngineSDKError.invalidInput("drama adapt requires explicit adaptation authorization via --authorize")
            }
            let authorization = AdaptationAuthorization(authorizedByUser: true,
                allowNarrationCompression: !opts.flags.contains("--keep-narration"), allowSFXInjection: !opts.flags.contains("--no-sfx"),
                auditNote: opts.values["--note"] ?? "", authorizedAtISO8601: Date().ISO8601Format())
            let report = try await engine().adaptAudioDrama(projectID: opts.required("--project"), chapterSpec: opts.values["--chapters"],
                authorization: authorization, llmModelID: opts.values["--llm"], useLLM: !opts.flags.contains("--lexical-only"),
                seed: opts.seed, progress: log)
            if jsonMode { try printJSON(report) }
            else { print("Adapted \(report.chapterCount) chapter(s).") }
        case ("podcast", "ingest"):
            let opts = try AudioCommandOptions(rest, options: ["--project", "--title"], pathCount: 1)
            let source = try await engine().ingestKnowledge(projectID: opts.required("--project"), fileURL: file(opts.paths[0]),
                                                           title: opts.values["--title"])
            if jsonMode { try printJSON(source) }
            else { print("\(source.title)\t\(source.sourceID)\t\(source.chunkCount) chunks") }
        case ("podcast", "sources"):
            let opts = try AudioCommandOptions(rest, options: ["--project"])
            let sources = try await engine().listKnowledgeSources(projectID: opts.required("--project"))
            if jsonMode { try printJSON(sources) }
            else { for s in sources { print("\(s.sourceID)\t\(s.title)\t\(s.chunkCount) chunks") } }
        case ("podcast", "search"):
            let opts = try AudioCommandOptions(rest, options: ["--project", "--query", "--limit"])
            let hits = try await engine().searchKnowledge(projectID: opts.required("--project"), query: opts.required("--query"), limit: opts.limit)
            if jsonMode { try printJSON(hits) }
            else { for h in hits { print("\(h.sourceTitle)\t\(h.snippet)") } }
        case ("podcast", "plan"):
            let opts = try AudioCommandOptions(rest, options: planning.union(["--episode", "--topic", "--title", "--format", "--limit"]),
                                               switches: lexical)
            let format: PodcastFormat = switch opts.values["--format"] ?? "solo" {
            case "solo": .soloExplainer
            case "dual": .dualHostDiscussion
            default: throw EngineSDKError.invalidInput("--format requires solo or dual")
            }
            let report = try await engine().planPodcastEpisode(projectID: opts.required("--project"),
                episodeID: opts.values["--episode"] ?? "ep_" + UUID().uuidString.lowercased(), title: opts.values["--title"],
                topicQuery: opts.required("--topic"), format: format, limit: opts.limit, llmModelID: opts.values["--llm"],
                useLLM: !opts.flags.contains("--lexical-only"), seed: opts.seed, progress: log)
            if jsonMode { try printJSON(report) }
            else { print("Chapter \(report.chapterNumber)\t\(report.plan.title)\t\(report.plan.episodeID)\t\(report.plan.citations.count) citations") }
        default:
            throw EngineSDKError.invalidInput("Unknown \(command) action. See sonook \(command) --help.")
        }
    }
}
