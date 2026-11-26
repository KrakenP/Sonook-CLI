import Foundation

/// Core domain namespace and schema versioning constants for Sonook (听澜).
public enum AudioCoreInfo: Sendable {
    public static let version = "1.0.0"
    public static let projectName = "Sonook"
    public static let chineseName = "听澜"
    public static let currentSchemaVersion = 1
}

/// Decoding an unknown or absent version fails before callers use a persisted document.
enum SchemaVersion: Int, Codable, Sendable {
    case v1 = 1
}
