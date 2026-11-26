import AudioCore
import EngineSDK
import Foundation

extension SonookCLI {
    static func runBuild(args: [String], jsonMode: Bool) async throws {
        let opts = try AudioCommandOptions(args[...], options: [
            "--name", "--chapters", "--format", "--out", "--sound-library", "--sfx-helper",
            "--sfx-license", "--seed", "--max-repair-rounds"
        ], switches: ["--soundscape", "--publish"], pathCount: 1)
        let name = try opts.required("--name")
        guard let format = ExportFormat(rawValue: opts.values["--format"]?.lowercased() ?? "m4b") else {
            throw EngineSDKError.invalidInput("--format requires m4b, m4a or wav")
        }
        guard let rounds = Int(opts.values["--max-repair-rounds"] ?? "2"), rounds >= 0 else {
            throw EngineSDKError.invalidInput("--max-repair-rounds requires a nonnegative integer")
        }
        let seed = try opts.seed
        func file(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.buildAudiobook(
            sourceFileURL: file(opts.paths[0]), projectName: name, chapterSpec: opts.values["--chapters"],
            format: format, soundscapeEnabled: opts.flags.contains("--soundscape"),
            soundLibraryDirectory: opts.values["--sound-library"].map(file),
            sfxHelperExecutable: opts.values["--sfx-helper"].map(file), sfxLicenseTag: opts.values["--sfx-license"],
            publishPack: opts.flags.contains("--publish"), outputURL: opts.values["--out"].map(file),
            seed: seed, maxRepairRounds: rounds, progress: { stderrWrite($0 + "\n") }
        )
        if jsonMode {
            try printJSON(report)
        } else if let exported = report.export {
            print("Exported \(report.projectID) to \(exported.outputPath)")
            if let pack = report.publication { print("Published \(pack.outputPath)") }
        } else {
            stderrWrite("Build stopped for \(report.projectID) (job \(report.jobID), \(report.status.rawValue)).\n")
            if !report.blockingSegmentIDs.isEmpty {
                stderrWrite("Blocking segments: \(report.blockingSegmentIDs.joined(separator: ", "))\n")
            }
            for command in report.guidance { stderrWrite("  \(command)\n") }
        }
        if report.status != .completed { exit(report.status == .needsReview ? 3 : 1) }
    }
}
