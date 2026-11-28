import Foundation

public enum BuildProgressStage: Int, Codable, Equatable, Sendable, CaseIterable {
    case importing = 1
    case analyzing = 2
    case auditioning = 3
    case synthesizing = 4
    case exporting = 5

    public static let totalStages = 5

    public var displayTitle: String {
        switch self {
        case .importing: "导入文本"
        case .analyzing: "本地模型分析"
        case .auditioning: "角色试音定型"
        case .synthesizing: "语音合成与质检"
        case .exporting: "导出音频"
        }
    }
}

public struct BuildProgressEvent: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let stage: BuildProgressStage
    public let subphase: String?
    public let completed: Int?
    public let total: Int?
    public let message: String

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", stage, subphase, completed, total, message
    }

    public init(stage: BuildProgressStage, subphase: String? = nil, completed: Int? = nil,
                total: Int? = nil, message: String) {
        self.stage = stage
        self.subphase = subphase
        self.completed = completed
        self.total = total
        self.message = message
    }
}

public enum BuildProgressFormatter: Sendable {
    public static func formatBar(completed: Int, total: Int, width: Int = 20) -> String {
        let total = max(0, total)
        let done = min(max(0, completed), total)
        func scaled(to scale: Int) -> Int {
            total > 0 ? total.dividingFullWidth(done.multipliedFullWidth(by: scale)).quotient : 0
        }
        let width = max(0, width)
        let filled = scaled(to: width)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        return "[\(bar)] \(scaled(to: 100))% (\(done)/\(total))"
    }

    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let time = seconds.isFinite && seconds > 0 ? Int(exactly: seconds.rounded(.down)) ?? Int.max : 0
        let minutesAndSeconds = String(format: "%02d:%02d", time / 60 % 60, time % 60)
        return time >= 3600 ? "\(time / 3600):\(minutesAndSeconds)" : minutesAndSeconds
    }

    public static func formatEvent(_ event: BuildProgressEvent, elapsedSeconds: TimeInterval, interactiveTTY: Bool) -> String {
        var parts: [String] = []
        if !interactiveTTY {
            parts.append("[\(event.stage.rawValue)/\(BuildProgressStage.totalStages)] \(event.stage.displayTitle)")
        }
        parts.append(event.message.components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
            .filter { !$0.isEmpty }.joined(separator: " "))
        if let completed = event.completed, let total = event.total, total > 0 {
            parts.append(formatBar(completed: completed, total: total))
        }
        parts.append(formatElapsed(elapsedSeconds))
        return parts.joined(separator: "  ")
    }
}
