import AudioCore
import Foundation

public enum KnowledgeKitInfo: Sendable {
    public static let version = AudioCoreInfo.version
}

// Encode an ordinary JSON string first. Unicode escapes preserve the original evidence for quoting
// while preventing untrusted text from spelling literal chat-template tokens inside the model prompt.
func quotedPromptString(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let quoted = String(decoding: try encoder.encode(value), as: UTF8.self)
    var result = ""
    for scalar in quoted.unicodeScalars {
        switch scalar {
        case "<", ">", "[", "]", "|", "`", "#", ":":
            result += String(format: "\\u%04x", scalar.value)
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
