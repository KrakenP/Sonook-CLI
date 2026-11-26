import AudioCore
import Foundation

public enum SpeechKitInfo: Sendable {
    public static let qaRuleVersion = "speechkit_qa_v1"
    public static let pinyinExemptionRuleVersion = "pinyin_tone_exact_v1"
}

public enum SpeechKitError: Error, Equatable, LocalizedError, Sendable {
    case segmentNotFound(String)
    case scriptNotFound(String)
    case catalogNotFound(String)
    case speakerNotFound(String)
    case missingTimbreAnchor(characterID: String, canonicalName: String)
    case corruptedTimbreAnchor(characterID: String, assetID: String)
    case unsupportedTTSProvider(String)
    case audioEncodingError(String)

    public var errorDescription: String? {
        switch self {
        case .segmentNotFound(let id):
            return "Segment not found in project scripts: \(id)"
        case .scriptNotFound(let id):
            return "Script not found for chapter: \(id)"
        case .catalogNotFound(let id):
            return "Character voice catalog not found for project: \(id)"
        case .speakerNotFound(let id):
            return "Speaker not found in voice catalog: \(id)"
        case .missingTimbreAnchor(let cid, let name):
            return "Missing immutable timbre anchor for \(cid) (\(name)). Run audition first."
        case .corruptedTimbreAnchor(let cid, let aid):
            return "Timbre anchor asset \(aid) for \(cid) failed integrity verification."
        case .unsupportedTTSProvider(let p):
            return "Unsupported TTS provider in SpeechKit: \(p)"
        case .audioEncodingError(let msg):
            return "Audio encoding error: \(msg)"
        }
    }
}

/// Builds deterministic TTS requests for auditioning and locked-timbre synthesis
/// while keeping SpeechKit completely decoupled from MLX/ModelRuntime.
public enum SpeechRequestBuilder: Sendable {
    public static let nonVerbalPauseProviderID = "sonook.pause-synth"
    public static let narratorCalmPrompt = "标准普通话中年男性有声书旁白，声音温厚克制，语速均匀平稳，呼吸自然，不做戏剧化夸张起伏。"
    public static let narratorCalmControlInstruction = "低沉温厚、平稳克制的成年男声旁白，语速均匀稳定，不做夸张起伏。"

    /// Returns true when a segment contains only punctuation, symbols, or whitespace (e.g. `"……"` or `"***"`),
    /// representing a non-verbal scene-break pause rather than spoken words.
    public static func isNonVerbalPauseText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Generates clean deterministic digital silence samples for a non-verbal pause segment.
    public static func nonVerbalPauseSamples(pauseAfterMs: Int, sampleRate: Int = 48_000) -> [Float] {
        let clampedMs = max(900, min(pauseAfterMs, 4_000))
        let count = max(1, (sampleRate * clampedMs) / 1_000)
        return Array(repeating: 0.0, count: count)
    }

    public static let narratorAuditionText = "窗外微风拂过树梢，山间石桌上仍摆着半局残棋，一切显得安静而从容。"
    public static let characterAuditionText = "今天天气不错，大家先把事情商量清楚，等会儿再一起出发也来得及。"

    public static func normalizedDesignPrompt(for card: CharacterVoiceCard) -> String {
        if card.characterID == "char_narrator" {
            return narratorCalmPrompt
        }
        let base = card.voiceDesignPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "标准普通话青年男声，吐字清晰自然，语速适中。"
        }
        if base.contains("普通话") || base.contains("方言") {
            return base
        }
        return "标准普通话，\(base)"
    }

    public static func buildAuditionRequest(
        for card: CharacterVoiceCard,
        seed: UInt64 = 42
    ) -> (request: SpeechRequest, auditionText: String, designPrompt: String) {
        let isNarrator = (card.characterID == "char_narrator")
        let auditionText = isNarrator ? narratorAuditionText : characterAuditionText
        let designPrompt = normalizedDesignPrompt(for: card)
        let req = SpeechRequest(
            text: auditionText,
            parameters: [
                "voice_design_prompt": designPrompt,
                "language": "Chinese",
                "temperature": isNarrator ? "0.35" : "0.45",
                "top_p": "0.80",
                "seed": String(seed)
            ]
        )
        return (req, auditionText, designPrompt)
    }

    /// Builds a synthesis request respecting locked `VoiceTimbreAnchor` and chapter-indexed `VoiceDeliveryStage`.
    public static func buildSegmentSynthesisRequest(
        segment: ScriptSegment,
        card: CharacterVoiceCard,
        chapterNumber: Int,
        providerID: String,
        verifiedAnchorPath: String?,
        seed: UInt64 = 42
    ) throws -> SpeechRequest {
        let isNarrator = (card.characterID == "char_narrator")
        var params: [String: String] = ["seed": String(seed)]

        if providerID.contains("voxcpm2") {
            guard let anchorPath = verifiedAnchorPath, !anchorPath.isEmpty else {
                throw SpeechKitError.missingTimbreAnchor(characterID: card.characterID, canonicalName: card.canonicalName)
            }
            params["ref_audio_path"] = anchorPath
            if !isNarrator {
                let control = card.effectiveControlInstruction(forChapter: chapterNumber, direction: segment.direction)
                if !control.isEmpty {
                    params["control_instruction"] = control
                }
            } else {
                let stageBaseline = card.activeDeliveryStage(forChapter: chapterNumber)?
                    .deliveryBaseline.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                params["control_instruction"] = stageBaseline.isEmpty ? narratorCalmControlInstruction : stageBaseline
            }
            params["max_tokens"] = String(max(220, segment.spokenText.count * 6))
        } else if providerID.contains("voice-design") {
            let basePrompt = normalizedDesignPrompt(for: card)
            let control = isNarrator ? "" : card.effectiveControlInstruction(forChapter: chapterNumber, direction: segment.direction)
            params["voice_design_prompt"] = control.isEmpty ? basePrompt : "\(basePrompt)当前语气：\(control)。"
            params["language"] = "Chinese"
            params["temperature"] = isNarrator ? "0.35" : "0.48"
            params["top_p"] = isNarrator ? "0.80" : "0.85"
        } else if providerID.hasPrefix("fake") {
            if let anchorPath = verifiedAnchorPath, !anchorPath.isEmpty {
                params["ref_audio_path"] = anchorPath
            }
            let control = card.effectiveControlInstruction(forChapter: chapterNumber, direction: segment.direction)
            if !control.isEmpty {
                params["control_instruction"] = control
            }
        } else {
            throw SpeechKitError.unsupportedTTSProvider(providerID)
        }

        return SpeechRequest(text: segment.spokenText, parameters: params)
    }
}
