import Darwin
import Foundation
import MLX

public struct MemorySample: Codable, Equatable, Sendable {
    public let label: String
    public let timestampISO8601: String
    public let physFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let mlxActiveBytes: Int
    public let mlxCacheBytes: Int
    public let mlxPeakBytes: Int
    public let thermalState: String

    enum CodingKeys: String, CodingKey {
        case label
        case timestampISO8601 = "timestamp_iso8601"
        case physFootprintBytes = "phys_footprint_bytes"
        case residentBytes = "resident_bytes"
        case mlxActiveBytes = "mlx_active_bytes"
        case mlxCacheBytes = "mlx_cache_bytes"
        case mlxPeakBytes = "mlx_peak_bytes"
        case thermalState = "thermal_state"
    }
}

public enum MemoryProbe: Sendable {
    public static func currentProcessMemory() -> (physFootprint: UInt64, resident: UInt64) {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }
        let footprint: UInt64 = vmStatus == KERN_SUCCESS ? vmInfo.phys_footprint : 0

        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basicInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &basicCount)
            }
        }
        let resident: UInt64 = basicStatus == KERN_SUCCESS ? basicInfo.resident_size : 0
        return (footprint, resident)
    }

    public static func thermalStateLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public static func sample(label: String) -> MemorySample {
        let proc = currentProcessMemory()
        let mlx = Memory.snapshot()
        return MemorySample(
            label: label,
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            physFootprintBytes: proc.physFootprint,
            residentBytes: proc.resident,
            mlxActiveBytes: mlx.activeMemory,
            mlxCacheBytes: mlx.cacheMemory,
            mlxPeakBytes: mlx.peakMemory,
            thermalState: thermalStateLabel()
        )
    }

    public static func resetMLXPeak() {
        Memory.peakMemory = 0
    }

    public static func clearMLXCache() {
        Memory.clearCache()
    }

    public static func formatMiB(_ bytes: UInt64) -> String {
        String(format: "%.1f MiB", Double(bytes) / (1024.0 * 1024.0))
    }

    public static func formatMiB(_ bytes: Int) -> String {
        String(format: "%.1f MiB", Double(bytes) / (1024.0 * 1024.0))
    }
}

/// Creates a temporary directory populated with symlinks to the read-only source model directory,
/// ensuring upstream loaders that write helper files (e.g. `tokenizer.json`) never mutate original weights.
enum StagingDirectoryHelper {
    static func createSymlinkStage(from sourceDir: URL, prefix: String) throws -> URL {
        let fm = FileManager.default
        let resolvedSource = sourceDir.resolvingSymlinksInPath()
        let stage = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try populateStage(from: resolvedSource, to: stage, fm: fm)
        return stage
    }

    private static func populateStage(from sourceDir: URL, to destDir: URL, fm: FileManager) throws {
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let resolved = item.resolvingSymlinksInPath()
            let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let dest = destDir.appendingPathComponent(item.lastPathComponent)
            if isDir {
                try populateStage(from: resolved, to: dest, fm: fm)
            } else {
                try fm.createSymbolicLink(at: dest, withDestinationURL: resolved)
            }
        }
    }
}
