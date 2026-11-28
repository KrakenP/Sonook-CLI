import AudioCore
import EngineSDK
import Foundation

extension SonookCLI {
    static func runBuild(args: [String], jsonMode: Bool) async throws {
        try await build(args: args, jsonMode: jsonMode, useSidecar: false)
    }

    static func runQuickBuild(args: [String], jsonMode: Bool) async throws {
        try await build(args: args, jsonMode: jsonMode, useSidecar: true)
    }

    private static func build(args: [String], jsonMode: Bool, useSidecar: Bool) async throws {
        let opts = try AudioCommandOptions(args[...], options: [
            "--name", "--chapters", "--format", "--out", "--sound-library", "--sfx-helper",
            "--sfx-license", "--seed", "--max-repair-rounds"
        ], switches: ["--soundscape", "--publish"], pathCount: 1)
        guard let format = ExportFormat(rawValue: opts.values["--format"]?.lowercased() ?? "m4b") else {
            throw EngineSDKError.invalidInput("--format requires m4b, m4a or wav")
        }
        guard let rounds = Int(opts.values["--max-repair-rounds"] ?? "2"), rounds >= 0 else {
            throw EngineSDKError.invalidInput("--max-repair-rounds requires a nonnegative integer")
        }
        let seed = try opts.seed
        func file(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let source = file(opts.paths[0])
        let name = opts.values["--name"] ?? SonookWorkspaceLayout.defaultProjectTitle(forSourceFile: source)
        let sidecar = useSidecar ? SonookWorkspaceLayout.sidecarOutputDirectory(forSourceFile: source, title: name) : nil
        let renderer = BuildProgressRenderer(title: name, source: source, outputDirectory: sidecar, jsonMode: jsonMode)
        defer { renderer.finishLine() }
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: args))
        let report = try await engine.buildAudiobook(
            sourceFileURL: source, projectName: name, chapterSpec: opts.values["--chapters"],
            format: format, soundscapeEnabled: opts.flags.contains("--soundscape"),
            soundLibraryDirectory: opts.values["--sound-library"].map(file),
            sfxHelperExecutable: opts.values["--sfx-helper"].map(file), sfxLicenseTag: opts.values["--sfx-license"],
            publishPack: opts.flags.contains("--publish"), outputURL: opts.values["--out"].map(file),
            seed: seed, maxRepairRounds: rounds, sidecarOutputDirectory: sidecar, onEvent: renderer.render
        )
        renderer.finishLine()
        if jsonMode {
            try printJSON(report)
        } else if let exported = report.export {
            if let directory = report.outputDirectory {
                print("输出目录  \(directory)")
                print("有声书    \(exported.outputPath)")
                if let cards = report.charactersPath { print("角色声卡  \(cards)") }
                if let verify = report.verifyReportPath { print("质检报告  \(verify)") }
                if let pack = report.publication { print("发行包    \(pack.outputPath)") }
                print("总用时    \(renderer.elapsed)")
            } else {
                print("Exported \(report.projectID) to \(exported.outputPath)")
                if let pack = report.publication { print("Published \(pack.outputPath)") }
            }
        } else {
            if useSidecar {
                let reason = report.status == .needsReview ? "有声书待审核" : "构建已停止"
                stderrWrite("\(reason)（\(report.status.rawValue)）  \(report.projectID) / \(report.jobID)\n")
            } else {
                stderrWrite("Build stopped for \(report.projectID) (job \(report.jobID), \(report.status.rawValue)).\n")
            }
            if !report.blockingSegmentIDs.isEmpty {
                let label = useSidecar ? "待处理片段  " : "Blocking segments: "
                stderrWrite(label + report.blockingSegmentIDs.joined(separator: ", ") + "\n")
            }
            if let verify = report.verifyReportPath { stderrWrite("质检报告  \(verify)\n") }
            if useSidecar, !report.guidance.isEmpty { stderrWrite("处理命令\n") }
            for command in report.guidance { stderrWrite("  \(command)\n") }
        }
        if report.status != .completed { exit(report.status == .needsReview ? 3 : 1) }
    }
}
