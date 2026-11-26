import Darwin
import Foundation

/// Isolates POSIX `STDOUT_FILENO` when `--json` mode is active so third-party model libraries
/// (such as upstream `mlx-audio-swift` / `mlx-swift-lm` `print(...)` / C `printf(...)` diagnostics)
/// are transparently redirected to `STDERR_FILENO`, guaranteeing clean, machine-parseable JSON on stdout.
final class JSONStdoutIsolator: @unchecked Sendable {
    private let lock = NSLock()
    private var savedStdoutFD: Int32 = -1

    static let shared = JSONStdoutIsolator()

    private init() {}

    func activateIfNeeded(jsonMode: Bool) {
        guard jsonMode else { return }
        lock.lock()
        defer { lock.unlock() }
        guard savedStdoutFD == -1 else { return }
        fflush(stdout)
        let dupFD = dup(STDOUT_FILENO)
        guard dupFD >= 0 else { return }
        savedStdoutFD = dupFD
        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func writeCleanJSONData(_ data: Data) {
        lock.lock()
        let targetFD = savedStdoutFD >= 0 ? savedStdoutFD : STDOUT_FILENO
        lock.unlock()

        var payload = data
        payload.append(0x0A) // trailing newline
        payload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            var offset = 0
            while remaining > 0 {
                let written = write(targetFD, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }

    func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard savedStdoutFD >= 0 else { return }
        fflush(stdout)
        _ = dup2(savedStdoutFD, STDOUT_FILENO)
        close(savedStdoutFD)
        savedStdoutFD = -1
    }
}
