import AudioCore
import Darwin
import Foundation

final class BuildProgressRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private let interactive: Bool
    private var stage: BuildProgressStage?
    private var lineOpen = false

    var elapsed: String { BuildProgressFormatter.formatElapsed(ProcessInfo.processInfo.systemUptime - start) }

    init(title: String, source: URL, outputDirectory: URL?, jsonMode: Bool) {
        interactive = isatty(STDERR_FILENO) != 0 && !jsonMode
        if interactive {
            let lines = ["Sonook 听澜 · \(title)", "原文  \(source.path)"] + (outputDirectory.map { ["输出  \($0.path)"] } ?? [])
            for line in lines {
                SonookCLI.stderrWrite(line.components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
                    .joined(separator: " ") + "\n")
            }
        }
    }

    func render(_ event: BuildProgressEvent) {
        lock.withLock {
            if interactive, event.stage != stage {
                endOpenLine()
                SonookCLI.stderrWrite("[\(event.stage.rawValue)/\(BuildProgressStage.totalStages)] \(event.stage.displayTitle)\n")
                stage = event.stage
            }
            let line = BuildProgressFormatter.formatEvent(event, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                                         interactiveTTY: interactive)
            SonookCLI.stderrWrite(interactive ? "\r\u{1B}[2K\(line)" : "\(line)\n")
            lineOpen = interactive
        }
    }

    func finishLine() {
        lock.withLock { endOpenLine() }
    }

    private func endOpenLine() {
        if lineOpen { SonookCLI.stderrWrite("\n") }
        lineOpen = false
    }
}
