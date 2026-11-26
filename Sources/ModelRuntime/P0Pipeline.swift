import AudioCore
import CryptoKit
import Foundation

public struct P0PipelineConfig: Sendable {
    public let inputPath: URL
    public let chapterNumber: Int
    public let maxCharacters: Int
    public let llmModelDirectory: URL
    public let ttsModelDirectory: URL
    public let asrModelDirectory: URL
    public let outputDirectory: URL
    public let existingCatalogPath: URL?
    public let llmLabel: String?
    public let ttsLabel: String?
    public let asrLabel: String?
    public let skipTTSAndASR: Bool

    public init(
        inputPath: URL,
        chapterNumber: Int = 1,
        maxCharacters: Int = 900,
        llmModelDirectory: URL,
        ttsModelDirectory: URL,
        asrModelDirectory: URL,
        outputDirectory: URL,
        existingCatalogPath: URL? = nil,
        llmLabel: String? = nil,
        ttsLabel: String? = nil,
        asrLabel: String? = nil,
        skipTTSAndASR: Bool = false
    ) {
        self.inputPath = inputPath
        self.chapterNumber = chapterNumber
        self.maxCharacters = maxCharacters
        self.llmModelDirectory = llmModelDirectory
        self.ttsModelDirectory = ttsModelDirectory
        self.asrModelDirectory = asrModelDirectory
        self.outputDirectory = outputDirectory
        self.existingCatalogPath = existingCatalogPath
        self.llmLabel = llmLabel
        self.ttsLabel = ttsLabel
        self.asrLabel = asrLabel
        self.skipTTSAndASR = skipTTSAndASR
    }
}

public struct SegmentBenchmarkRecord: Codable, Sendable {
    public let segmentID: String
    public let speakerID: String
    public let speakerName: String
    public let ttsVoice: String
    public let isDialogue: Bool
    public let sourceByteStart: Int
    public let sourceByteEndExclusive: Int
    public let charCount: Int
    public let ttsInferenceMs: Double?
    public let audioDurationSeconds: Double?
    public let rtf: Double?
    public let asrInferenceMs: Double?
    public let cer: Double?
    public let rmsDBFS: Double?
    public let verdict: String
    public let verdictReasons: [String]
}

public struct FaultInjectionReport: Codable, Sendable {
    public let silentAudioVerdict: String
    public let silentAudioPassedExpectation: Bool
    public let omittedTranscriptVerdict: String
    public let omittedTranscriptPassedExpectation: Bool
    public let capabilityStrictRejected: Bool
    public let capabilityDegradeLoggedCount: Int
}

public struct RegenerationReport: Codable, Sendable {
    public let targetSegmentID: String
    public let previousCER: Double?
    public let newCER: Double?
    public let previousAudioSHA256: String
    public let newAudioSHA256: String
    public let otherAssetsCheckedCount: Int
    public let otherAssetsUntouched: Bool
}

public struct P0BenchmarkReport: Codable, Sendable {
    public let schemaVersion: Int
    public let project: String
    public let llmModel: String
    public let ttsModel: String
    public let asrModel: String
    public let chapterID: String
    public let chapterIndex: Int
    public let detectedSourceEncoding: String
    public let analyzedCharCount: Int
    public let analyzedUTF8Bytes: Int
    public let sourceCoverageRatio: Double
    public let sourceCoverageValid: Bool
    public let characterCount: Int
    public let catalogRevision: Int
    public let markdownRoundTripVerified: Bool
    public let segmentCount: Int
    public let dialogueSegmentCount: Int
    public let llmLoadMs: Double
    public let llmProfileMs: Double
    public let llmAttributionMs: Double
    public let ttsLoadMs: Double?
    public let ttsTotalInferenceMs: Double?
    public let totalAudioDurationSeconds: Double?
    public let aggregateTTSRTFExcludingLoad: Double?
    public let aggregateTTSRTFIncludingLoad: Double?
    public let asrLoadMs: Double?
    public let asrTotalInferenceMs: Double?
    public let weightedCER: Double?
    public let passedSegments: Int
    public let needsReviewSegments: Int
    public let retryableFailureSegments: Int
    public let faultInjection: FaultInjectionReport?
    public let regeneration: RegenerationReport?
    public let memoryTimeline: [MemorySample]
    public let segments: [SegmentBenchmarkRecord]
    public let artifacts: [String: String]
}

public struct VerbatimUnit: Sendable {
    public let index: Int
    public let span: SourceSpan
    public let sourceText: String
    public let spokenText: String
    public let isQuotedDialogue: Bool
}

public enum VerbatimSegmenter: Sendable {
    /// Deterministically splits a chapter slice into contiguous non-overlapping UTF-8 spans
    /// separating narration and Chinese quoted dialogue (`“...”` / `「...」`), preserving 100% of non-whitespace bytes.
    public static func segment(chapter: ChapterSlice, maxCharacters: Int) throws -> (slice: ChapterSlice, units: [VerbatimUnit]) {
        let trimmedChapter = try truncateAtParagraphBoundary(chapter: chapter, maxCharacters: maxCharacters)
        let text = trimmedChapter.text
        let baseOffset = trimmedChapter.sourceSpan.start

        var units: [VerbatimUnit] = []

        func advanceBytes(from start: String.Index, to end: String.Index) -> Int {
            text.utf8.distance(from: start, to: end)
        }

        func appendUnit(startIdx: String.Index, endIdx: String.Index, isDialogue: Bool) throws {
            // Trim leading/trailing whitespace so missing-span check only requires non-whitespace bytes.
            var s = startIdx
            var e = endIdx
            while s < e && text[s].isWhitespace { s = text.index(after: s) }
            while e > s {
                let prev = text.index(before: e)
                if text[prev].isWhitespace { e = prev } else { break }
            }
            guard s < e else { return }

            let raw = String(text[s..<e])
            if !isDialogue && raw.count > 180 {
                try splitLongNarration(startIdx: s, endIdx: e)
                return
            }

            let lo = baseOffset + advanceBytes(from: text.startIndex, to: s)
            let hi = baseOffset + advanceBytes(from: text.startIndex, to: e)
            let span = try SourceSpan(start: lo, endExclusive: hi)
            let spoken = cleanSpokenText(raw, isDialogue: isDialogue)
            units.append(VerbatimUnit(
                index: units.count,
                span: span,
                sourceText: raw,
                spokenText: spoken.isEmpty ? raw : spoken,
                isQuotedDialogue: isDialogue
            ))
        }

        func splitLongNarration(startIdx: String.Index, endIdx: String.Index) throws {
            let breakChars: Set<Character> = ["。", "！", "？", "\n"]
            var chunkStart = startIdx
            var i = startIdx
            var count = 0
            while i < endIdx {
                let ch = text[i]
                let next = text.index(after: i)
                count += 1
                if count >= 40 && breakChars.contains(ch) {
                    try appendAtomic(startIdx: chunkStart, endIdx: next, isDialogue: false)
                    chunkStart = next
                    count = 0
                }
                i = next
            }
            if chunkStart < endIdx {
                try appendAtomic(startIdx: chunkStart, endIdx: endIdx, isDialogue: false)
            }
        }

        func appendAtomic(startIdx: String.Index, endIdx: String.Index, isDialogue: Bool) throws {
            var s = startIdx
            var e = endIdx
            while s < e && text[s].isWhitespace { s = text.index(after: s) }
            while e > s {
                let prev = text.index(before: e)
                if text[prev].isWhitespace { e = prev } else { break }
            }
            guard s < e else { return }
            let raw = String(text[s..<e])
            let lo = baseOffset + advanceBytes(from: text.startIndex, to: s)
            let hi = baseOffset + advanceBytes(from: text.startIndex, to: e)
            let span = try SourceSpan(start: lo, endExclusive: hi)
            let spoken = cleanSpokenText(raw, isDialogue: isDialogue)
            units.append(VerbatimUnit(
                index: units.count,
                span: span,
                sourceText: raw,
                spokenText: spoken.isEmpty ? raw : spoken,
                isQuotedDialogue: isDialogue
            ))
        }

        // Scan paragraph by paragraph, isolating quoted spans (“...” or 「...」)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lineStart = text.startIndex
        for (lineIdx, lineSub) in lines.enumerated() {
            let lineEnd = text.index(lineStart, offsetBy: lineSub.count)
            var scan = lineStart
            var segStart = lineStart
            while scan < lineEnd {
                let ch = text[scan]
                if ch == "“" || ch == "「" {
                    let closeChar: Character = (ch == "“") ? "”" : "」"
                    if let closeIdx = text[text.index(after: scan)..<lineEnd].firstIndex(of: closeChar) {
                        if segStart < scan {
                            try appendUnit(startIdx: segStart, endIdx: scan, isDialogue: false)
                        }
                        let afterClose = text.index(after: closeIdx)
                        try appendUnit(startIdx: scan, endIdx: afterClose, isDialogue: true)
                        scan = afterClose
                        segStart = afterClose
                        continue
                    }
                }
                scan = text.index(after: scan)
            }
            if segStart < lineEnd {
                try appendUnit(startIdx: segStart, endIdx: lineEnd, isDialogue: false)
            }
            if lineIdx + 1 < lines.count {
                lineStart = text.index(after: lineEnd)
            }
        }
        return (trimmedChapter, units)
    }

    private static func cleanSpokenText(_ raw: String, isDialogue: Bool) -> String {
        guard isDialogue else { return raw }
        var s = raw
        if s.hasPrefix("“") || s.hasPrefix("「") { s.removeFirst() }
        if s.hasSuffix("”") || s.hasSuffix("」") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncateAtParagraphBoundary(chapter: ChapterSlice, maxCharacters: Int) throws -> ChapterSlice {
        guard maxCharacters > 0, chapter.text.count > maxCharacters else { return chapter }
        let text = chapter.text
        var chosenEnd = text.startIndex
        var count = 0
        var lastParagraphEnd = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            let next = text.index(after: idx)
            count += 1
            if ch == "\n" {
                lastParagraphEnd = next
                if count >= maxCharacters {
                    chosenEnd = next
                    break
                }
            }
            idx = next
        }
        if chosenEnd == text.startIndex {
            chosenEnd = lastParagraphEnd > text.startIndex ? lastParagraphEnd : idx
        }
        let prefixText = String(text[..<chosenEnd])
        let byteLen = prefixText.utf8.count
        let newSpan = try SourceSpan(start: chapter.sourceSpan.start, endExclusive: chapter.sourceSpan.start + byteLen)
        return ChapterSlice(
            chapterID: chapter.chapterID,
            title: chapter.title,
            sourceDocumentRevision: chapter.sourceDocumentRevision,
            sourceSpan: newSpan,
            text: prefixText
        )
    }
}

private struct LLMCharacterProfilePayload: Decodable {
    struct Entry: Decodable {
        let canonicalName: String
        let aliases: [String]?
        let gender: String?
        let ageBand: String?
        let personaSummary: String?
        let speechHabits: [String]?
        let evidenceExcerpts: [String]?
        let voiceDesignPrompt: String?
        let suggestedSpeaker: String?
        let baseInstruction: String?

        enum CodingKeys: String, CodingKey {
            case canonicalName = "canonical_name"
            case aliases, gender
            case ageBand = "age_band"
            case personaSummary = "persona_summary"
            case speechHabits = "speech_habits"
            case evidenceExcerpts = "evidence_excerpts"
            case voiceDesignPrompt = "voice_design_prompt"
            case suggestedSpeaker = "suggested_speaker"
            case baseInstruction = "base_instruction"
        }
    }
    let characters: [Entry]
}

private struct LLMAttributionPayload: Decodable {
    struct Item: Decodable {
        let index: Int
        let speaker: String
        let emotion: String?
        let styleInstruction: String?
        let pauseAfterMs: Int?
        let confidence: Double?
        let evidence: String?

        enum CodingKeys: String, CodingKey {
            case index, speaker, emotion
            case styleInstruction = "style_instruction"
            case pauseAfterMs = "pause_after_ms"
            case confidence, evidence
        }
    }
    let attributions: [Item]
}

public enum P0PipelineRunner {
    private static let chinesePresetSpeakers = ["Uncle_Fu", "Dylan", "Eric", "Vivian", "Serena"]

    public static func run(config: P0PipelineConfig, stderrLog: @Sendable (String) -> Void) async throws -> P0BenchmarkReport {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let segmentsDir = config.outputDirectory.appendingPathComponent("segments", isDirectory: true)
        try fm.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        var memoryTimeline: [MemorySample] = []
        MemoryProbe.resetMLXPeak()
        memoryTimeline.append(MemoryProbe.sample(label: "baseline"))

        // 1. Source import & normalization
        stderrLog("[Stage 1] Normalizing source document and extracting chapter \(config.chapterNumber)...")
        let rawData = try Data(contentsOf: config.inputPath)
        let normalizedDoc = try SourceNormalizer.normalize(
            data: rawData,
            documentID: "doc_p0",
            revision: "doc_rev_1"
        )
        let chapters = ChapterExtractor.extractChapters(from: normalizedDoc)
        let targetChapter = selectChapter(from: chapters, requestedNumber: config.chapterNumber)
        let (activeSlice, units) = try VerbatimSegmenter.segment(chapter: targetChapter, maxCharacters: config.maxCharacters)
        stderrLog("[Stage 1] Encoding=\(normalizedDoc.detectedEncoding.rawValue) chapter=\(activeSlice.chapterID) chars=\(activeSlice.text.count) utf8Bytes=\(activeSlice.text.utf8.count) units=\(units.count)")

        // Load existing catalog if provided (cross-chapter consistency test)
        var catalog: CharacterVoiceCatalog
        if let existingPath = config.existingCatalogPath, fm.fileExists(atPath: existingPath.path) {
            let data = try Data(contentsOf: existingPath)
            catalog = try CharacterVoiceCatalog.decodeJSON(data)
            stderrLog("[Stage 1] Loaded existing CharacterVoiceCatalog rev=\(catalog.revision) cards=\(catalog.cards.count)")
        } else {
            catalog = CharacterVoiceCatalog(
                projectID: "sonook_p0",
                revision: 1,
                cards: [defaultNarratorCard()]
            )
        }

        // 2. LLM Phase: Character Profiling + Voice Cards + Dialogue Attribution
        let llmProvider = MLXLocalLLMProvider(
            modelDirectory: config.llmModelDirectory,
            modelID: config.llmLabel ?? config.llmModelDirectory.lastPathComponent
        )
        stderrLog("[Stage 2] Loading LLM (\(llmProvider.modelID))...")
        MemoryProbe.resetMLXPeak()
        let tLLMLoad = Date()
        try await llmProvider.load()
        let llmLoadMs = Date().timeIntervalSince(tLLMLoad) * 1000.0
        memoryTimeline.append(MemoryProbe.sample(label: "llm_loaded"))
        stderrLog(String(format: "[Stage 2] LLM loaded in %.0fms (MLX active=%@)", llmLoadMs, MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)))

        // 2A. Character profiling & Voice Design Cards
        stderrLog("[Stage 2A] Generating CharacterVoiceCards from chapter text...")
        let tProfile = Date()
        let existingNamesSummary = catalog.cards.map { "\($0.characterID): \($0.canonicalName)（别名：\($0.aliases.joined(separator: "、"))）" }.joined(separator: "\n")
        let profilePrompt = """
        请通读以下中文小说章节文本，提取所有出场或开口说话的角色（保留旁白），为每个角色建立人物画像和「声音风格描述（voice_design_prompt）」，以便后续长篇章节保持声线一致。

        角色去重与合并硬规则：
        - 如果同一人物在前半段以泛称出现（如「另一个同事」「队友」「那人」）、后文揭晓了真名或外号（如「张三」「老三」），必须合并为同一个角色，以真名作 canonical_name，泛称与外号写入 aliases，严禁拆成两个重复角色。
        - 只有确实出场或说话的人物才建档；不要为泛称群像（如「一群人」「同事们」）单独建档。

        已有角色档案（如本次再次出现，请沿用相同的 canonical_name 并补充新别名）：
        \(existingNamesSummary)

        可选预设声线（suggested_speaker 仅能从以下 5 个中择一，尽量为同一场景中对话的不同角色错开音色）：
        - Uncle_Fu：标准普通话沉稳成熟男声（默认用于旁白与年长男性）
        - Dylan：青年男声（轻微北方口音，接近标准普通话，优先用于年轻男主角）
        - Eric：带四川方言口音的男声（仅用于有地方特色或需要与男主明显区分声线的男性配角）
        - Vivian：标准普通话清脆年轻女声
        - Serena：标准普通话温润成熟女声

        请严格输出一个 JSON 对象，不要输出任何额外解释文字，先在 coreference_notes 里梳理所有人物的真名、外号与前文泛称的对应关系，再输出去重后的 characters 列表：
        {
          "coreference_notes": "梳理全文出现的人物、外号以及前文泛称（如'另一个同事'）与后文真名的对应关系",
          "characters": [
            {
              "canonical_name": "角色标准名",
              "aliases": ["称谓或别名"],
              "gender": "男/女/未知",
              "age_band": "少年/青年/中年/老年/未知",
              "persona_summary": "一句话人物性格与身份画像",
              "speech_habits": ["说话习惯或口癖"],
              "evidence_excerpts": ["原文简短依据(20字内)"],
              "voice_design_prompt": "用于文本捏声的详细中文声音风格描述（明确标准普通话、性别、年龄段、音色质地、语速与气质，彼此之间有明显区分度）",
              "suggested_speaker": "Dylan",
              "base_instruction": "简短中文语气与语速基调指令"
            }
          ]
        }

        章节文本：
        \(activeSlice.text)
        """

        let profileResponse = try await llmProvider.generate(LLMRequest(
            prompt: profilePrompt,
            parameters: [
                "system_prompt": "你是专业的中文有声书选角导演与文本分析引擎。严格只输出单个合法 JSON 对象，字段名完全匹配要求。",
                "max_tokens": "2048",
                "temperature": "0.1",
                "enable_thinking": "false"
            ]
        ))
        let llmProfileMs = Date().timeIntervalSince(tProfile) * 1000.0
        let incomingCards = parseCharacterCards(from: profileResponse.text, existingCatalog: catalog)
        catalog = try catalog.merging(incomingCards: incomingCards)

        // Persist JSON + Markdown voice cards & verify lossless Markdown round-trip
        let catalogJSONURL = config.outputDirectory.appendingPathComponent("characters.voice-cards.json")
        let catalogMDURL = config.outputDirectory.appendingPathComponent("characters.voice-cards.md")
        let catalogJSONData = try catalog.encodeJSON()
        try catalogJSONData.write(to: catalogJSONURL, options: .atomic)
        let catalogMarkdown = try catalog.renderMarkdown()
        try Data(catalogMarkdown.utf8).write(to: catalogMDURL, options: .atomic)
        let reparsedCatalog = try CharacterVoiceCatalog.parseMarkdown(catalogMarkdown)
        let markdownRoundTripOK = (reparsedCatalog == catalog)
        stderrLog("[Stage 2A] CharacterVoiceCatalog rev=\(catalog.revision) cards=\(catalog.cards.count) markdownRoundTrip=\(markdownRoundTripOK)")

        // 2B. Dialogue attribution & direction in batches
        stderrLog("[Stage 2B] Running dialogue attribution & direction across \(units.count) verbatim units...")
        let tAttr = Date()
        var attributionMap: [Int: LLMAttributionPayload.Item] = [:]
        let rosterLines = catalog.cards.map { card in
            "- \(card.characterID) | \(card.canonicalName) | 别名：\(card.aliases.joined(separator: "、")) | 画像：\(card.personaSummary)"
        }.joined(separator: "\n")

        let batchSize = 10
        var batchStart = 0
        while batchStart < units.count {
            let batchEnd = min(batchStart + batchSize, units.count)
            let batch = Array(units[batchStart..<batchEnd])
            // Include 2 preceding AND 2 following units as read-only context so dialogue tags after quotes are visible
            let contextStart = max(0, batchStart - 2)
            let contextLines = units[contextStart..<batchStart].map { "[\($0.index)] \($0.sourceText)" }.joined(separator: "\n")
            let afterEnd = min(units.count, batchEnd + 2)
            let afterLines = units[batchEnd..<afterEnd].map { "[\($0.index)] \($0.sourceText)" }.joined(separator: "\n")
            let unitLines = batch.map { unit in
                let tag = unit.isQuotedDialogue ? "[对白]" : "[旁白候选]"
                return "[\(unit.index)] \(tag) \(unit.sourceText)"
            }.joined(separator: "\n")

            let beforeBlock = contextLines.isEmpty ? "" : "上文衔接参考（无需输出）：\n\(contextLines)\n\n"
            let afterBlock = afterLines.isEmpty ? "" : "\n\n下文衔接参考（无需输出）：\n\(afterLines)"
            let attrPrompt = """
            根据角色表，为下面每个编号片段确定说话人与简短朗读导演指令。

            角色表：
            \(rosterLines)

            \(beforeBlock)规则：
            1. [旁白候选] 默认归属 "旁白"。
            2. [对白] 必须根据前后文归属到具体说话角色，speaker 字段直接填角色表中的角色标准名（不要猜编号，也不得把角色对白随意填为 "旁白"）。
            3. 连续多行无引号外标注的对话必然是两人交替进行（一问一答 / 抱怨与反驳 / 提议与拒绝）：绝不可能同一个人刚提议完（如「下把换我配合你」）下一句又自己拒绝自己（如「别别别，还是找别人吧」）；只要后一句在回应、反驳、道歉或拒绝前一句，说话人就必须切换到对话另一方！
            4. 呼语排除铁律：凡是台词里直呼某人名字或外号（如「哎哎哎张三张三，快点……」「甲，乙，别玩了……」），被喊到名字的人一定是「听话人」，绝对不是「说话人」！说话人一定是对话中的另一方或第三者。
            5. 严格只输出一个合法 JSON 对象，不要 markdown 代码块，不要多余解释，必须覆盖本批全部编号；每条先写 evidence（一句话推理：谁在跟谁说话、依据是呼语/人称/前后文），再写 speaker：
            {"attributions":[{"index":0,"evidence":"叙述句","speaker":"旁白","emotion":"calm","style_instruction":"平稳克制","pause_after_ms":350,"confidence":0.95}]}

            待归属片段：
            \(unitLines)\(afterBlock)
            """

            var parsedItems: [LLMAttributionPayload.Item] = []
            for attempt in 1...2 {
                let resp = try await llmProvider.generate(LLMRequest(
                    prompt: attrPrompt,
                    parameters: [
                        "system_prompt": "你是严格的 JSON 输出引擎。只输出单个合法 JSON 对象 {\"attributions\":[...]}，不输出任何额外文字。",
                        "max_tokens": "2400",
                        "temperature": attempt == 1 ? "0.05" : "0.0",
                        "enable_thinking": "false"
                    ]
                ))
                parsedItems = parseAttributions(from: resp.text, stderrLog: stderrLog)
                if !parsedItems.isEmpty { break }
                stderrLog("[Stage 2B] Batch \(batchStart)..<\(batchEnd) attempt \(attempt) parsed 0 items, retrying...")
            }
            stderrLog("[Stage 2B] Batch \(batchStart)..<\(batchEnd) parsed \(parsedItems.count)/\(batch.count) attributions")
            for item in parsedItems {
                attributionMap[item.index] = item
            }
            batchStart = batchEnd
        }
        let llmAttributionMs = Date().timeIntervalSince(tAttr) * 1000.0
        memoryTimeline.append(MemoryProbe.sample(label: "llm_done"))

        // Assemble ScriptDocument and validate 100% verbatim source coverage
        var scriptSegments: [ScriptSegment] = []
        for unit in units {
            let attr = attributionMap[unit.index]
            let resolvedCard: CharacterVoiceCard
            if let rawSpeaker = attr?.speaker,
               let matched = catalog.resolveCharacter(namedOrAliased: rawSpeaker) {
                resolvedCard = matched
            } else if !unit.isQuotedDialogue {
                resolvedCard = catalog.resolveCharacter(namedOrAliased: "char_narrator") ?? defaultNarratorCard()
            } else {
                // Keep narration fallback only if LLM failed to match any known card
                resolvedCard = catalog.resolveCharacter(namedOrAliased: "char_narrator") ?? defaultNarratorCard()
            }

            let direction = SegmentDirection(
                emotion: attr?.emotion ?? (unit.isQuotedDialogue ? "natural" : "calm"),
                rate: 1.0,
                pauseAfterMs: attr?.pauseAfterMs ?? (unit.isQuotedDialogue ? 320 : 380),
                styleInstruction: attr?.styleInstruction
            )
            let segmentID = String(format: "seg_%04d", unit.index + 1)
            let evidenceStr = attr?.evidence ?? ""
            let evidenceList: [String] = evidenceStr.isEmpty ? [] : [evidenceStr]
            scriptSegments.append(ScriptSegment(
                segmentID: segmentID,
                chapterID: activeSlice.chapterID,
                sourceDocumentRevision: normalizedDoc.revision,
                sourceSpan: unit.span,
                sourceText: unit.sourceText,
                spokenText: unit.spokenText,
                speakerID: resolvedCard.characterID,
                voiceProfileRevision: "\(resolvedCard.characterID)_rev_\(resolvedCard.revision)",
                direction: direction,
                scriptRevision: 1,
                audioArtifactID: nil,
                status: .pending,
                attributionConfidence: attr?.confidence ?? (unit.isQuotedDialogue ? 0.5 : 0.9),
                attributionEvidence: evidenceList,
                normalizationNote: nil
            ))
        }

        var scriptDoc = ScriptDocument(
            chapterID: activeSlice.chapterID,
            sourceDocumentRevision: normalizedDoc.revision,
            scriptRevision: 1,
            segments: scriptSegments
        )
        let coverageReport = SourceCoverageValidator.validate(scriptDoc, against: activeSlice, verbatim: true)
        stderrLog(String(format: "[Stage 2] Source coverage=%.2f%% valid=%@ issues=%d", coverageReport.coverageRatio * 100.0, String(coverageReport.isValid), coverageReport.issues.count))

        let scriptURL = config.outputDirectory.appendingPathComponent("script.json")
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try jsonEncoder.encode(scriptDoc).write(to: scriptURL, options: .atomic)

        // Unload LLM & verify memory release
        await llmProvider.unload()
        memoryTimeline.append(MemoryProbe.sample(label: "llm_unloaded"))
        stderrLog("[Stage 2] LLM unloaded -> MLX active=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)) cache=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxCacheBytes))")

        let dialogueCount = units.filter(\.isQuotedDialogue).count
        var artifacts: [String: String] = [
            "voice_cards_json": catalogJSONURL.path,
            "voice_cards_md": catalogMDURL.path,
            "script_json": scriptURL.path
        ]

        if config.skipTTSAndASR {
            let segmentRecords = scriptDoc.segments.enumerated().map { idx, seg in
                let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) ?? defaultNarratorCard()
                let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
                return SegmentBenchmarkRecord(
                    segmentID: seg.segmentID,
                    speakerID: seg.speakerID,
                    speakerName: card.canonicalName,
                    ttsVoice: binding?.speakerID ?? "Uncle_Fu",
                    isDialogue: units[idx].isQuotedDialogue,
                    sourceByteStart: seg.sourceSpan.start,
                    sourceByteEndExclusive: seg.sourceSpan.endExclusive,
                    charCount: seg.spokenText.count,
                    ttsInferenceMs: nil,
                    audioDurationSeconds: nil,
                    rtf: nil,
                    asrInferenceMs: nil,
                    cer: nil,
                    rmsDBFS: nil,
                    verdict: "skipped",
                    verdictReasons: []
                )
            }
            let report = P0BenchmarkReport(
                schemaVersion: AudioCoreInfo.currentSchemaVersion,
                project: AudioCoreInfo.projectName,
                llmModel: llmProvider.modelID,
                ttsModel: "skipped",
                asrModel: "skipped",
                chapterID: activeSlice.chapterID,
                chapterIndex: config.chapterNumber,
                detectedSourceEncoding: normalizedDoc.detectedEncoding.rawValue,
                analyzedCharCount: activeSlice.text.count,
                analyzedUTF8Bytes: activeSlice.text.utf8.count,
                sourceCoverageRatio: coverageReport.coverageRatio,
                sourceCoverageValid: coverageReport.isValid,
                characterCount: catalog.cards.count,
                catalogRevision: catalog.revision,
                markdownRoundTripVerified: markdownRoundTripOK,
                segmentCount: scriptDoc.segments.count,
                dialogueSegmentCount: dialogueCount,
                llmLoadMs: llmLoadMs,
                llmProfileMs: llmProfileMs,
                llmAttributionMs: llmAttributionMs,
                ttsLoadMs: nil,
                ttsTotalInferenceMs: nil,
                totalAudioDurationSeconds: nil,
                aggregateTTSRTFExcludingLoad: nil,
                aggregateTTSRTFIncludingLoad: nil,
                asrLoadMs: nil,
                asrTotalInferenceMs: nil,
                weightedCER: nil,
                passedSegments: 0,
                needsReviewSegments: 0,
                retryableFailureSegments: 0,
                faultInjection: nil,
                regeneration: nil,
                memoryTimeline: memoryTimeline,
                segments: segmentRecords,
                artifacts: artifacts
            )
            let reportURL = config.outputDirectory.appendingPathComponent("benchmark-report.json")
            try jsonEncoder.encode(report).write(to: reportURL, options: .atomic)
            return report
        }

        // 3. TTS Phase: Synthesize all segments using locked CharacterVoiceCatalog bindings
        let ttsProvider = MLXQwen3TTSProvider(
            modelDirectory: config.ttsModelDirectory,
            modelID: config.ttsLabel ?? config.ttsModelDirectory.lastPathComponent
        )
        stderrLog("[Stage 3] Loading TTS (\(ttsProvider.modelID))...")
        MemoryProbe.resetMLXPeak()
        let tTTSLoad = Date()
        try await ttsProvider.load()
        let ttsLoadMs = Date().timeIntervalSince(tTTSLoad) * 1000.0
        let sampleRate = await ttsProvider.sampleRate
        memoryTimeline.append(MemoryProbe.sample(label: "tts_loaded"))
        stderrLog(String(format: "[Stage 3] TTS loaded in %.0fms (MLX active=%@)", ttsLoadMs, MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)))

        // Verify Provider capability enforcement on a real MLX provider (Redline #2)
        var strictRejected = false
        do {
            _ = try await ttsProvider.synthesize(SpeechRequest(
                text: "测试",
                parameters: ["speaker": "Uncle_Fu", "voice_clone_ref": "unsupported.wav"],
                policy: .strict
            ))
        } catch ProviderCapabilityError.unsupportedParameter("voice_clone_ref") {
            strictRejected = true
        }

        var synthesizedPCM: [String: [Float]] = [:]
        var synthesizedSHA: [String: String] = [:]
        var ttsMetricsBySeg: [String: InferenceMetrics] = [:]
        var integrityBySeg: [String: AudioIntegrityReport] = [:]
        var ttsTotalInferenceMs = 0.0
        var totalAudioDuration = 0.0
        var degradeLoggedCount = 0

        for idx in scriptDoc.segments.indices {
            let seg = scriptDoc.segments[idx]
            let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) ?? defaultNarratorCard()
            let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
                ?? ProviderVoiceBinding(providerID: MLXQwen3TTSProvider.providerIdentifier, speakerID: "Uncle_Fu", baseInstruction: "沉稳自然")

            let isNarrator = (seg.speakerID == "char_narrator")
            // Narration stays on a calm, consistent baseline (empty instruct + low temperature + fixed seed)
            // to prevent wave-like prosody swings and theatrical over-acting across stitched paragraphs.
            let effectiveInstruction: String
            let effectiveTemperature: String
            let effectiveTopP: String
            if isNarrator {
                effectiveInstruction = ""
                effectiveTemperature = "0.35"
                effectiveTopP = "0.80"
            } else {
                effectiveInstruction = [binding.baseInstruction, seg.direction.styleInstruction]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "，")
                effectiveTemperature = "0.52"
                effectiveTopP = "0.85"
            }

            var reqParams: [String: String] = [
                "speaker": binding.speakerID,
                "instruction": effectiveInstruction,
                "language": "Chinese",
                "temperature": effectiveTemperature,
                "top_p": effectiveTopP,
                "repetition_penalty": "1.05",
                "seed": "42"
            ]
            // On the first segment only, pass an unsupported parameter with .degrade to confirm explicit degradation logging
            let policy: UnsupportedParameterPolicy
            if idx == 0 {
                reqParams["unsupported_pitch_shift"] = "+2st"
                policy = .degrade
            } else {
                policy = .strict
            }

            let audio = try await ttsProvider.synthesize(SpeechRequest(
                text: seg.spokenText,
                parameters: reqParams,
                policy: policy
            ))
            if idx == 0 {
                degradeLoggedCount = audio.metrics.degradations.count
            }
            synthesizedPCM[seg.segmentID] = audio.pcmSamples
            synthesizedSHA[seg.segmentID] = audio.sha256Hex
            ttsMetricsBySeg[seg.segmentID] = audio.metrics
            ttsTotalInferenceMs += audio.metrics.inferenceDurationMs
            let dur = Double(audio.pcmSamples.count) / Double(audio.sampleRate)
            totalAudioDuration += dur

            let integrity = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)
            integrityBySeg[seg.segmentID] = integrity

            let segWAVURL = segmentsDir.appendingPathComponent("\(seg.segmentID).wav")
            try NativeAudioRenderer.writeWAV(samples: audio.pcmSamples, sampleRate: audio.sampleRate, to: segWAVURL)
            scriptDoc.segments[idx].audioArtifactID = "aud_\(seg.segmentID)_\(String(audio.sha256Hex.prefix(8)))"
            scriptDoc.segments[idx].status = .synthesized

            stderrLog(String(format: "[Stage 3] %@ (%@/%@) %.2fs audio in %.2fs (RTF=%.2f)", seg.segmentID, card.canonicalName, binding.speakerID, dur, audio.metrics.inferenceDurationMs / 1000.0, audio.metrics.rtf ?? 0))
        }
        memoryTimeline.append(MemoryProbe.sample(label: "tts_done"))

        await ttsProvider.unload()
        memoryTimeline.append(MemoryProbe.sample(label: "tts_unloaded"))
        stderrLog("[Stage 3] TTS unloaded -> MLX active=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)) cache=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxCacheBytes))")

        // 4. ASR Verification Phase + Fault Injection Check
        let asrProvider = MLXQwen3ASRProvider(
            modelDirectory: config.asrModelDirectory,
            modelID: config.asrLabel ?? config.asrModelDirectory.lastPathComponent
        )
        stderrLog("[Stage 4] Loading ASR (\(asrProvider.modelID))...")
        MemoryProbe.resetMLXPeak()
        let tASRLoad = Date()
        try await asrProvider.load()
        let asrLoadMs = Date().timeIntervalSince(tASRLoad) * 1000.0
        memoryTimeline.append(MemoryProbe.sample(label: "asr_loaded"))
        stderrLog(String(format: "[Stage 4] ASR loaded in %.0fms (MLX active=%@)", asrLoadMs, MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)))

        var cerBySeg: [String: CERReport] = [:]
        var verdictBySeg: [String: QualityVerdict] = [:]
        var asrMsBySeg: [String: Double] = [:]
        var asrTotalInferenceMs = 0.0
        var totalEdits = 0
        var totalRefChars = 0

        for idx in scriptDoc.segments.indices {
            let seg = scriptDoc.segments[idx]
            guard let pcm = synthesizedPCM[seg.segmentID],
                  let integrity = integrityBySeg[seg.segmentID] else { continue }
            let transcript = try await asrProvider.transcribe(ASRRequest(
                pcmSamples: pcm,
                sampleRate: sampleRate,
                parameters: ["language": "Chinese"]
            ))
            asrMsBySeg[seg.segmentID] = transcript.metrics.inferenceDurationMs
            asrTotalInferenceMs += transcript.metrics.inferenceDurationMs

            let cerReport = ChineseCERCalculator.calculate(
                reference: seg.spokenText,
                hypothesis: transcript.text,
                normalizeNumerals: true
            )
            cerBySeg[seg.segmentID] = cerReport
            totalEdits += cerReport.substitutions + cerReport.deletions + cerReport.insertions
            totalRefChars += cerReport.referenceLength

            let verdict = QualityEvaluator.evaluate(
                cer: cerReport,
                integrity: integrity,
                thresholds: QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10)
            )
            verdictBySeg[seg.segmentID] = verdict
            switch verdict {
            case .passed: scriptDoc.segments[idx].status = .verified
            case .needsReview: scriptDoc.segments[idx].status = .needsReview
            case .retryableFailure: scriptDoc.segments[idx].status = .failed
            }
            stderrLog(String(format: "[Stage 4] %@ CER=%.2f%% verdict=%@", seg.segmentID, cerReport.cer * 100.0, verdictLabel(verdict)))
        }
        memoryTimeline.append(MemoryProbe.sample(label: "asr_done"))

        // Fault injection checks
        let silentPCM = Array(repeating: Float(0), count: sampleRate)
        let silentIntegrity = AudioIntegrityChecker.analyze(pcmSamples: silentPCM, sampleRate: sampleRate)
        let dummyCER = ChineseCERCalculator.calculate(reference: "测试句子", hypothesis: "")
        let silentVerdict = QualityEvaluator.evaluate(cer: dummyCER, integrity: silentIntegrity)

        let goodPCM = synthesizedPCM[scriptDoc.segments.first?.segmentID ?? ""] ?? (0..<sampleRate).map { Float(sin(2.0 * .pi * 440.0 * Double($0) / Double(sampleRate)) * 0.2) }
        let goodIntegrity = AudioIntegrityChecker.analyze(pcmSamples: goodPCM, sampleRate: sampleRate)
        let omittedCER = ChineseCERCalculator.calculate(reference: "山间残棋犹在，老道士缓步而来", hypothesis: "山间残棋")
        let omittedVerdict = QualityEvaluator.evaluate(cer: omittedCER, integrity: goodIntegrity)

        let faultInjection = FaultInjectionReport(
            silentAudioVerdict: verdictLabel(silentVerdict),
            silentAudioPassedExpectation: { if case .retryableFailure(let r) = silentVerdict { return r.contains(.silent) }; return false }(),
            omittedTranscriptVerdict: verdictLabel(omittedVerdict),
            omittedTranscriptPassedExpectation: { if case .needsReview(let r) = omittedVerdict { return r.contains(.suspectedOmission) }; return false }(),
            capabilityStrictRejected: strictRejected,
            capabilityDegradeLoggedCount: degradeLoggedCount
        )

        await asrProvider.unload()
        memoryTimeline.append(MemoryProbe.sample(label: "asr_unloaded"))
        stderrLog("[Stage 4] ASR unloaded -> MLX active=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)) cache=\(MemoryProbe.formatMiB(memoryTimeline.last!.mlxCacheBytes))")

        // 5. Selective Local Regeneration Test (re-synthesize 1 worst/target segment, verify all others stay byte-identical!)
        var regenerationReport: RegenerationReport?
        if let targetIdx = selectRegenerationCandidate(segments: scriptDoc.segments, cerBySeg: cerBySeg, verdictBySeg: verdictBySeg) {
            let targetSeg = scriptDoc.segments[targetIdx]
            stderrLog("[Stage 5] Selective regeneration for \(targetSeg.segmentID) (verifying other assets remain untouched)...")

            var otherHashesBefore: [String: String] = [:]
            for seg in scriptDoc.segments where seg.segmentID != targetSeg.segmentID {
                let wavURL = segmentsDir.appendingPathComponent("\(seg.segmentID).wav")
                if let data = try? Data(contentsOf: wavURL) {
                    otherHashesBefore[seg.segmentID] = sha256Hex(data)
                }
            }

            let prevSHA = synthesizedSHA[targetSeg.segmentID] ?? ""
            let prevCER = cerBySeg[targetSeg.segmentID]?.cer

            try await ttsProvider.load()
            memoryTimeline.append(MemoryProbe.sample(label: "regen_tts_loaded"))
            let card = catalog.resolveCharacter(namedOrAliased: targetSeg.speakerID) ?? defaultNarratorCard()
            let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
                ?? ProviderVoiceBinding(providerID: MLXQwen3TTSProvider.providerIdentifier, speakerID: "Uncle_Fu", baseInstruction: "清晰稳重")
            let regenAudio = try await ttsProvider.synthesize(SpeechRequest(
                text: targetSeg.spokenText,
                parameters: [
                    "speaker": binding.speakerID,
                    "instruction": "\(binding.baseInstruction)，吐字清晰准确",
                    "language": "Chinese",
                    "temperature": "0.55",
                    "top_p": "0.85",
                    "repetition_penalty": "1.05"
                ]
            ))
            await ttsProvider.unload()
            memoryTimeline.append(MemoryProbe.sample(label: "regen_tts_unloaded"))

            try await asrProvider.load()
            let regenTranscript = try await asrProvider.transcribe(ASRRequest(
                pcmSamples: regenAudio.pcmSamples,
                sampleRate: regenAudio.sampleRate,
                parameters: ["language": "Chinese"]
            ))
            await asrProvider.unload()
            memoryTimeline.append(MemoryProbe.sample(label: "regen_final_unloaded"))

            let regenCER = ChineseCERCalculator.calculate(
                reference: targetSeg.spokenText,
                hypothesis: regenTranscript.text,
                normalizeNumerals: true
            )
            let regenIntegrity = AudioIntegrityChecker.analyze(pcmSamples: regenAudio.pcmSamples, sampleRate: regenAudio.sampleRate)
            let regenVerdict = QualityEvaluator.evaluate(
                cer: regenCER,
                integrity: regenIntegrity,
                thresholds: QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10)
            )

            // Replace target asset only if improved or equal
            let keepNew = (prevCER == nil) || (regenCER.cer <= (prevCER ?? 1.0))
            if keepNew {
                synthesizedPCM[targetSeg.segmentID] = regenAudio.pcmSamples
                synthesizedSHA[targetSeg.segmentID] = regenAudio.sha256Hex
                cerBySeg[targetSeg.segmentID] = regenCER
                verdictBySeg[targetSeg.segmentID] = regenVerdict
                integrityBySeg[targetSeg.segmentID] = regenIntegrity
                let segWAVURL = segmentsDir.appendingPathComponent("\(targetSeg.segmentID).wav")
                try NativeAudioRenderer.writeWAV(samples: regenAudio.pcmSamples, sampleRate: regenAudio.sampleRate, to: segWAVURL)
                scriptDoc.segments[targetIdx].audioArtifactID = "aud_\(targetSeg.segmentID)_\(String(regenAudio.sha256Hex.prefix(8)))"
                switch regenVerdict {
                case .passed: scriptDoc.segments[targetIdx].status = .verified
                case .needsReview: scriptDoc.segments[targetIdx].status = .needsReview
                case .retryableFailure: scriptDoc.segments[targetIdx].status = .failed
                }
            }

            var untouched = true
            for (segID, beforeHash) in otherHashesBefore {
                let wavURL = segmentsDir.appendingPathComponent("\(segID).wav")
                let afterHash = (try? Data(contentsOf: wavURL)).map(sha256Hex) ?? ""
                if afterHash != beforeHash { untouched = false }
            }

            regenerationReport = RegenerationReport(
                targetSegmentID: targetSeg.segmentID,
                previousCER: prevCER,
                newCER: regenCER.cer,
                previousAudioSHA256: prevSHA,
                newAudioSHA256: regenAudio.sha256Hex,
                otherAssetsCheckedCount: otherHashesBefore.count,
                otherAssetsUntouched: untouched
            )
            stderrLog(String(format: "[Stage 5] Regenerated %@ CER %.2f%% -> %.2f%%; other %d assets untouched=%@", targetSeg.segmentID, (prevCER ?? 0) * 100, regenCER.cer * 100, otherHashesBefore.count, String(untouched)))
        }

        // Save updated script.json with verified statuses & artifact IDs
        try jsonEncoder.encode(scriptDoc).write(to: scriptURL, options: .atomic)

        // 6. Native AVFoundation render to WAV + M4A + timeline.json
        stderrLog("[Stage 6] Rendering chapter audio (WAV + M4A) and timeline via AVFoundation...")
        let renderInputs: [(segment: ScriptSegment, samples: [Float])] = scriptDoc.segments.compactMap { seg in
            guard let pcm = synthesizedPCM[seg.segmentID] else { return nil }
            return (seg, pcm)
        }
        let previewWAV = config.outputDirectory.appendingPathComponent("preview.wav")
        let previewM4A = config.outputDirectory.appendingPathComponent("preview.m4a")
        let timelineURL = config.outputDirectory.appendingPathComponent("timeline.json")
        let timeline = try NativeAudioRenderer.renderChapter(
            chapterID: activeSlice.chapterID,
            segments: renderInputs,
            sampleRate: sampleRate,
            wavURL: previewWAV,
            m4aURL: previewM4A
        )
        try jsonEncoder.encode(timeline).write(to: timelineURL, options: .atomic)
        artifacts["preview_wav"] = previewWAV.path
        artifacts["preview_m4a"] = previewM4A.path
        artifacts["timeline_json"] = timelineURL.path

        // Recalculate final weighted CER & counts
        var finalEdits = 0
        var finalRefs = 0
        var passedCount = 0
        var needsReviewCount = 0
        var retryableCount = 0

        let segmentRecords: [SegmentBenchmarkRecord] = scriptDoc.segments.enumerated().map { idx, seg in
            let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) ?? defaultNarratorCard()
            let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
            let cer = cerBySeg[seg.segmentID]
            let verdict = verdictBySeg[seg.segmentID] ?? .needsReview([])
            if let cer {
                finalEdits += cer.substitutions + cer.deletions + cer.insertions
                finalRefs += cer.referenceLength
            }
            let reasons: [String]
            switch verdict {
            case .passed:
                passedCount += 1
                reasons = []
            case .needsReview(let r):
                needsReviewCount += 1
                reasons = r.map(\.rawValue)
            case .retryableFailure(let r):
                retryableCount += 1
                reasons = r.map(\.rawValue)
            }
            let metrics = ttsMetricsBySeg[seg.segmentID]
            let integrity = integrityBySeg[seg.segmentID]
            return SegmentBenchmarkRecord(
                segmentID: seg.segmentID,
                speakerID: seg.speakerID,
                speakerName: card.canonicalName,
                ttsVoice: binding?.speakerID ?? "Uncle_Fu",
                isDialogue: units[idx].isQuotedDialogue,
                sourceByteStart: seg.sourceSpan.start,
                sourceByteEndExclusive: seg.sourceSpan.endExclusive,
                charCount: seg.spokenText.count,
                ttsInferenceMs: metrics?.inferenceDurationMs,
                audioDurationSeconds: metrics?.audioDurationSeconds,
                rtf: metrics?.rtf,
                asrInferenceMs: asrMsBySeg[seg.segmentID],
                cer: cer?.cer,
                rmsDBFS: integrity?.rmsDBFS,
                verdict: verdictLabel(verdict),
                verdictReasons: reasons
            )
        }

        let rtfExcl = totalAudioDuration > 0 ? (ttsTotalInferenceMs / 1000.0) / totalAudioDuration : nil
        let rtfIncl = totalAudioDuration > 0 ? ((ttsTotalInferenceMs + ttsLoadMs) / 1000.0) / totalAudioDuration : nil
        let weightedCER = finalRefs > 0 ? Double(finalEdits) / Double(finalRefs) : nil

        let report = P0BenchmarkReport(
            schemaVersion: AudioCoreInfo.currentSchemaVersion,
            project: AudioCoreInfo.projectName,
            llmModel: llmProvider.modelID,
            ttsModel: ttsProvider.modelID,
            asrModel: asrProvider.modelID,
            chapterID: activeSlice.chapterID,
            chapterIndex: config.chapterNumber,
            detectedSourceEncoding: normalizedDoc.detectedEncoding.rawValue,
            analyzedCharCount: activeSlice.text.count,
            analyzedUTF8Bytes: activeSlice.text.utf8.count,
            sourceCoverageRatio: coverageReport.coverageRatio,
            sourceCoverageValid: coverageReport.isValid,
            characterCount: catalog.cards.count,
            catalogRevision: catalog.revision,
            markdownRoundTripVerified: markdownRoundTripOK,
            segmentCount: scriptDoc.segments.count,
            dialogueSegmentCount: dialogueCount,
            llmLoadMs: llmLoadMs,
            llmProfileMs: llmProfileMs,
            llmAttributionMs: llmAttributionMs,
            ttsLoadMs: ttsLoadMs,
            ttsTotalInferenceMs: ttsTotalInferenceMs,
            totalAudioDurationSeconds: totalAudioDuration,
            aggregateTTSRTFExcludingLoad: rtfExcl,
            aggregateTTSRTFIncludingLoad: rtfIncl,
            asrLoadMs: asrLoadMs,
            asrTotalInferenceMs: asrTotalInferenceMs,
            weightedCER: weightedCER,
            passedSegments: passedCount,
            needsReviewSegments: needsReviewCount,
            retryableFailureSegments: retryableCount,
            faultInjection: faultInjection,
            regeneration: regenerationReport,
            memoryTimeline: memoryTimeline,
            segments: segmentRecords,
            artifacts: artifacts
        )

        let reportURL = config.outputDirectory.appendingPathComponent("benchmark-report.json")
        try jsonEncoder.encode(report).write(to: reportURL, options: .atomic)
        stderrLog("[Done] Report written to \(reportURL.path); preview audio at \(previewM4A.path)")
        return report
    }

    public static func analyzeChapter(
        sourceData: Data,
        projectID: String,
        chapterNumber: Int,
        maxCharacters: Int,
        existingCatalog: CharacterVoiceCatalog?,
        llmProvider: any LLMProvider,
        stderrLog: @Sendable (String) -> Void
    ) async throws -> (chapter: ChapterSlice, catalog: CharacterVoiceCatalog, script: ScriptDocument, coverage: SourceCoverageReport) {
        let normalizedDoc = try SourceNormalizer.normalize(data: sourceData, documentID: "doc_\(projectID)", revision: "doc_rev_1")
        let chapters = ChapterExtractor.extractChapters(from: normalizedDoc)
        let chosenChapter = selectChapter(from: chapters, requestedNumber: chapterNumber)
        let (activeSlice, units) = try VerbatimSegmenter.segment(chapter: chosenChapter, maxCharacters: maxCharacters)

        var catalog: CharacterVoiceCatalog
        if let existing = existingCatalog {
            catalog = existing
        } else {
            catalog = CharacterVoiceCatalog(projectID: projectID, revision: 1, cards: [defaultNarratorCard()])
        }

        let existingNamesSummary = catalog.cards.map { "\($0.characterID): \($0.canonicalName)（别名：\($0.aliases.joined(separator: "、"))）" }.joined(separator: "\n")
        let profilePrompt = """
        请通读以下中文小说章节文本，提取所有出场或开口说话的角色（保留旁白），为每个角色建立人物画像和「声音风格描述（voice_design_prompt）」，以便后续长篇章节保持声线一致。

        角色去重与合并硬规则：
        - 如果同一人物在前半段以泛称出现（如「另一个同事」「队友」「那人」）、后文揭晓了真名或外号（如「张三」「老三」），必须合并为同一个角色，以真名作 canonical_name，泛称与外号写入 aliases，严禁拆成两个重复角色。
        - 只有确实出场或说话的人物才建档；不要为泛称群像（如「一群人」「同事们」）单独建档。

        已有角色档案（如本次再次出现，请沿用相同的 canonical_name 并补充新别名）：
        \(existingNamesSummary)

        可选预设声线（suggested_speaker 仅能从以下 5 个中择一，尽量为同一场景中对话的不同角色错开音色）：
        - Uncle_Fu：标准普通话沉稳成熟男声（默认用于旁白与年长男性）
        - Dylan：青年男声（轻微北方口音，接近标准普通话，优先用于年轻男主角）
        - Eric：带四川方言口音的男声（仅用于有地方特色或需要与男主明显区分声线的男性配角）
        - Vivian：标准普通话清脆年轻女声
        - Serena：标准普通话温润成熟女声

        请严格输出一个 JSON 对象，不要输出任何额外解释文字，先在 coreference_notes 里梳理所有人物的真名、外号与前文泛称的对应关系，再输出去重后的 characters 列表：
        {
          "coreference_notes": "梳理全文出现的人物、外号以及前文泛称（如'另一个同事'）与后文真名的对应关系",
          "characters": [
            {
              "canonical_name": "角色标准名",
              "aliases": ["称谓或别名"],
              "gender": "男/女/未知",
              "age_band": "少年/青年/中年/老年/未知",
              "persona_summary": "一句话人物性格与身份画像",
              "speech_habits": ["说话习惯或口癖"],
              "evidence_excerpts": ["原文简短依据(20字内)"],
              "voice_design_prompt": "用于文本捏声的详细中文声音风格描述（明确标准普通话、性别、年龄段、音色质地、语速与气质，彼此之间有明显区分度）",
              "suggested_speaker": "Dylan",
              "base_instruction": "简短中文语气与语速基调指令"
            }
          ]
        }

        章节文本：
        \(activeSlice.text)
        """

        let profileResponse = try await llmProvider.generate(LLMRequest(
            prompt: profilePrompt,
            parameters: [
                "system_prompt": "你是专业的中文有声书选角导演与文本分析引擎。严格只输出单个合法 JSON 对象，字段名完全匹配要求。",
                "max_tokens": "2048",
                "temperature": "0.1",
                "enable_thinking": "false"
            ]
        ))
        let incomingCards = parseCharacterCards(from: profileResponse.text, existingCatalog: catalog)
        catalog = try catalog.merging(incomingCards: incomingCards)

        var attributionMap: [Int: LLMAttributionPayload.Item] = [:]
        let rosterLines = catalog.cards.map { card in
            "- \(card.characterID) | \(card.canonicalName) | 别名：\(card.aliases.joined(separator: "、")) | 画像：\(card.personaSummary)"
        }.joined(separator: "\n")

        let batchSize = 10
        var batchStart = 0
        while batchStart < units.count {
            let batchEnd = min(batchStart + batchSize, units.count)
            let batch = Array(units[batchStart..<batchEnd])
            let contextStart = max(0, batchStart - 2)
            let contextLines = units[contextStart..<batchStart].map { "[\($0.index)] \($0.sourceText)" }.joined(separator: "\n")
            let afterEnd = min(units.count, batchEnd + 2)
            let afterLines = units[batchEnd..<afterEnd].map { "[\($0.index)] \($0.sourceText)" }.joined(separator: "\n")
            let unitLines = batch.map { unit in
                let tag = unit.isQuotedDialogue ? "[对白]" : "[旁白候选]"
                return "[\(unit.index)] \(tag) \(unit.sourceText)"
            }.joined(separator: "\n")

            let beforeBlock = contextLines.isEmpty ? "" : "上文衔接参考（无需输出）：\n\(contextLines)\n\n"
            let afterBlock = afterLines.isEmpty ? "" : "\n\n下文衔接参考（无需输出）：\n\(afterLines)"
            let attrPrompt = """
            根据角色表，为下面每个编号片段确定说话人与简短朗读导演指令。

            角色表：
            \(rosterLines)

            \(beforeBlock)规则：
            1. [旁白候选] 默认归属 "旁白"。
            2. [对白] 必须根据前后文归属到具体说话角色，speaker 字段直接填角色表中的角色标准名（不要猜编号，也不得把角色对白随意填为 "旁白"）。
            3. 连续多行无引号外标注的对话必然是两人交替进行（一问一答 / 抱怨与反驳 / 提议与拒绝）：绝不可能同一个人刚提议完（如「下把换我配合你」）下一句又自己拒绝自己（如「别别别，还是找别人吧」）；只要后一句在回应、反驳、道歉或拒绝前一句，说话人就必须切换到对话另一方！
            4. 呼语排除铁律：凡是台词里直呼某人名字或外号（如「哎哎哎张三张三，快点……」「甲，乙，别玩了……」），被喊到名字的人一定是「听话人」，绝对不是「说话人」！说话人一定是对话中的另一方或第三者。
            5. 严格只输出一个合法 JSON 对象，不要 markdown 代码块，不要多余解释，必须覆盖本批全部编号；每条先写 evidence（一句话推理：谁在跟谁说话、依据是呼语/人称/前后文），再写 speaker：
            {"attributions":[{"index":0,"evidence":"叙述句","speaker":"旁白","emotion":"calm","style_instruction":"平稳克制","pause_after_ms":350,"confidence":0.95}]}

            待归属片段：
            \(unitLines)\(afterBlock)
            """

            var parsedItems: [LLMAttributionPayload.Item] = []
            for attempt in 1...2 {
                let resp = try await llmProvider.generate(LLMRequest(
                    prompt: attrPrompt,
                    parameters: [
                        "system_prompt": "你是严格的 JSON 输出引擎。只输出单个合法 JSON 对象 {\"attributions\":[...]}，不输出任何额外文字。",
                        "max_tokens": "2400",
                        "temperature": attempt == 1 ? "0.05" : "0.0",
                        "enable_thinking": "false"
                    ]
                ))
                parsedItems = parseAttributions(from: resp.text, stderrLog: stderrLog)
                if !parsedItems.isEmpty { break }
            }
            for item in parsedItems {
                attributionMap[item.index] = item
            }
            batchStart = batchEnd
        }

        var scriptSegments: [ScriptSegment] = []
        for unit in units {
            let attr = attributionMap[unit.index]
            let resolvedCard: CharacterVoiceCard
            if let rawSpeaker = attr?.speaker,
               let matched = catalog.resolveCharacter(namedOrAliased: rawSpeaker) {
                resolvedCard = matched
            } else {
                resolvedCard = catalog.resolveCharacter(namedOrAliased: "char_narrator") ?? defaultNarratorCard()
            }
            let direction = SegmentDirection(
                emotion: attr?.emotion ?? (unit.isQuotedDialogue ? "natural" : "calm"),
                rate: 1.0,
                pauseAfterMs: attr?.pauseAfterMs ?? (unit.isQuotedDialogue ? 320 : 380),
                styleInstruction: attr?.styleInstruction
            )
            let segmentID = String(format: "seg_%04d", unit.index + 1)
            let evidenceStr = attr?.evidence ?? ""
            let evidenceList: [String] = evidenceStr.isEmpty ? [] : [evidenceStr]
            scriptSegments.append(ScriptSegment(
                segmentID: segmentID,
                chapterID: activeSlice.chapterID,
                sourceDocumentRevision: normalizedDoc.revision,
                sourceSpan: unit.span,
                sourceText: unit.sourceText,
                spokenText: unit.spokenText,
                speakerID: resolvedCard.characterID,
                voiceProfileRevision: "\(resolvedCard.characterID)_rev_\(resolvedCard.revision)",
                direction: direction,
                scriptRevision: 1,
                audioArtifactID: nil,
                status: .pending,
                attributionConfidence: attr?.confidence ?? (unit.isQuotedDialogue ? 0.5 : 0.9),
                attributionEvidence: evidenceList,
                normalizationNote: nil
            ))
        }

        let scriptDoc = ScriptDocument(
            chapterID: activeSlice.chapterID,
            sourceDocumentRevision: normalizedDoc.revision,
            scriptRevision: 1,
            segments: scriptSegments
        )
        let coverage = SourceCoverageValidator.validate(scriptDoc, against: activeSlice, verbatim: true)
        return (activeSlice, catalog, scriptDoc, coverage)
    }

    public static func selectChapter(from chapters: [ChapterSlice], requestedNumber: Int) -> ChapterSlice {
        // Chapters list may have a preface slice "序" at index 0 before "第0001章"
        let numbered = chapters.filter { $0.title.hasPrefix("第") }
        if requestedNumber >= 1 && requestedNumber <= numbered.count {
            return numbered[requestedNumber - 1]
        }
        if requestedNumber >= 1 && requestedNumber <= chapters.count {
            return chapters[requestedNumber - 1]
        }
        return chapters.first!
    }

    private static func defaultNarratorCard() -> CharacterVoiceCard {
        CharacterVoiceCard(
            characterID: "char_narrator",
            canonicalName: "旁白",
            aliases: ["叙述者", "narrator"],
            gender: "男",
            ageBand: "中年",
            personaSummary: "沉稳克制、有说书韵味的全知叙述者",
            speechHabits: ["吐字清晰", "节奏舒缓"],
            evidenceExcerpts: [],
            voiceDesignPrompt: "中年男性说书人声线，音色温厚略带磁性和沧桑感，语速平稳，叙事层次分明，克制而不夸张。",
            providerBindings: [
                MLXQwen3TTSProvider.providerIdentifier: ProviderVoiceBinding(
                    providerID: MLXQwen3TTSProvider.providerIdentifier,
                    speakerID: "Uncle_Fu",
                    baseInstruction: "沉稳温厚的说书人旁白语气，吐字清晰，语速适中",
                    speakingRate: 1.0
                )
            ],
            revision: 1,
            locked: true
        )
    }

    private static func parseCharacterCards(from raw: String, existingCatalog: CharacterVoiceCatalog) -> [CharacterVoiceCard] {
        guard let jsonData = extractJSONObjectData(from: raw),
              let payload = try? JSONDecoder().decode(LLMCharacterProfilePayload.self, from: jsonData) else {
            return []
        }

        var nextNumericID = existingCatalog.cards.count + 1
        var usedSpeakers = Set(existingCatalog.cards.compactMap {
            $0.providerBindings[MLXQwen3TTSProvider.providerIdentifier]?.speakerID
        })
        var cards: [CharacterVoiceCard] = []

        for entry in payload.characters {
            let name = entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if name == "旁白" || name.lowercased() == "narrator" { continue }

            let matchedExisting = existingCatalog.resolveCharacter(namedOrAliased: name)
                ?? (entry.aliases ?? []).compactMap { existingCatalog.resolveCharacter(namedOrAliased: $0) }.first

            let characterID: String
            if let existing = matchedExisting {
                characterID = existing.characterID
            } else {
                characterID = String(format: "char_%03d", nextNumericID)
                nextNumericID += 1
            }

            let chosenSpeaker = pickPresetSpeaker(
                suggested: entry.suggestedSpeaker,
                gender: entry.gender ?? "",
                ageBand: entry.ageBand ?? "",
                used: &usedSpeakers
            )
            let baseInstruction = (entry.baseInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry.voiceDesignPrompt?.prefix(40)).map(String.init)
                ?? "自然清晰"

            let binding = ProviderVoiceBinding(
                providerID: MLXQwen3TTSProvider.providerIdentifier,
                speakerID: chosenSpeaker,
                baseInstruction: baseInstruction,
                speakingRate: 1.0
            )
            cards.append(CharacterVoiceCard(
                characterID: characterID,
                canonicalName: name,
                aliases: entry.aliases ?? [],
                gender: entry.gender ?? "未知",
                ageBand: entry.ageBand ?? "未知",
                personaSummary: entry.personaSummary ?? "",
                speechHabits: entry.speechHabits ?? [],
                evidenceExcerpts: entry.evidenceExcerpts ?? [],
                voiceDesignPrompt: entry.voiceDesignPrompt ?? baseInstruction,
                providerBindings: [MLXQwen3TTSProvider.providerIdentifier: binding],
                revision: matchedExisting?.revision ?? 1,
                locked: true
            ))
        }
        return cards
    }

    private static func pickPresetSpeaker(suggested: String?, gender: String, ageBand: String, used: inout Set<String>) -> String {
        let isFemale = gender.contains("女")
        let isMale = gender.contains("男")
        let femaleSpeakers: Set<String> = ["Vivian", "Serena"]
        let maleSpeakers: Set<String> = ["Uncle_Fu", "Dylan", "Eric"]

        func genderCompatible(_ spk: String) -> Bool {
            if isFemale { return femaleSpeakers.contains(spk) }
            if isMale { return maleSpeakers.contains(spk) }
            return chinesePresetSpeakers.contains(spk)
        }

        // Avoid silently assigning the same voice to two characters in the same scene, and never cross gender.
        if let suggested, genderCompatible(suggested), !used.contains(suggested) {
            used.insert(suggested)
            return suggested
        }
        let preferredPool: [String]
        if isFemale {
            preferredPool = ageBand.contains("少") || ageBand.contains("青") ? ["Vivian", "Serena"] : ["Serena", "Vivian"]
        } else if ageBand.contains("老") {
            preferredPool = ["Uncle_Fu", "Dylan", "Eric"]
        } else if ageBand.contains("少") || ageBand.contains("青") {
            preferredPool = ["Dylan", "Uncle_Fu", "Eric"]
        } else {
            preferredPool = ["Uncle_Fu", "Dylan", "Eric"]
        }
        for candidate in preferredPool where !used.contains(candidate) {
            used.insert(candidate)
            return candidate
        }
        let fallback = (suggested.flatMap { genderCompatible($0) ? $0 : nil }) ?? preferredPool.first ?? "Dylan"
        used.insert(fallback)
        return fallback
    }

    private static func parseAttributions(from raw: String, stderrLog: @Sendable (String) -> Void) -> [LLMAttributionPayload.Item] {
        // Resiliently parse either {"attributions":[...]} or top-level [...] using JSONSerialization
        // so minor LLM numeric/string quirks (e.g. "7" vs 7, 350.0 vs 350) never silently drop attributions.
        let candidates: [Data] = [
            extractJSONObjectData(from: raw),
            extractJSONArrayData(from: raw)
        ].compactMap { $0 }

        for data in candidates {
            if let decoded = try? JSONDecoder().decode(LLMAttributionPayload.self, from: data) {
                return decoded.attributions
            }
            if let decodedArr = try? JSONDecoder().decode([LLMAttributionPayload.Item].self, from: data) {
                return decodedArr
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                let rawList: [[String: Any]]?
                if let dict = obj as? [String: Any] {
                    rawList = (dict["attributions"] ?? dict["segments"] ?? dict["items"]) as? [[String: Any]]
                } else {
                    rawList = obj as? [[String: Any]]
                }
                if let rawList {
                    let parsed: [LLMAttributionPayload.Item] = rawList.compactMap { entry in
                        let idx: Int?
                        if let i = entry["index"] as? Int { idx = i }
                        else if let d = entry["index"] as? Double { idx = Int(d) }
                        else if let s = entry["index"] as? String { idx = Int(s.trimmingCharacters(in: .whitespaces)) }
                        else { idx = nil }
                        guard let index = idx else { return nil }
                        let speaker = (entry["speaker"] ?? entry["speaker_id"] ?? entry["character_id"]) as? String ?? "char_narrator"
                        let pause: Int? = (entry["pause_after_ms"] as? Int) ?? (entry["pause_after_ms"] as? Double).map(Int.init)
                        let conf: Double? = (entry["confidence"] as? Double) ?? (entry["confidence"] as? Int).map(Double.init)
                        return LLMAttributionPayload.Item(
                            index: index,
                            speaker: speaker,
                            emotion: entry["emotion"] as? String,
                            styleInstruction: entry["style_instruction"] as? String,
                            pauseAfterMs: pause,
                            confidence: conf,
                            evidence: entry["evidence"] as? String
                        )
                    }
                    if !parsed.isEmpty { return parsed }
                }
            }
        }
        stderrLog("[Stage 2B][WARN] Attribution JSON parse failed (rawLen=\(raw.count) chars)")
        return []
    }

    private static func stripThinkingPrefix(_ text: String) -> String {
        if let endRange = text.range(of: "</think>", options: .backwards) {
            return String(text[endRange.upperBound...])
        }
        return text
    }

    private static func extractJSONArrayData(from text: String) -> Data? {
        let cleaned = stripThinkingPrefix(text)
        guard let first = cleaned.firstIndex(of: "["),
              let last = cleaned.lastIndex(of: "]"),
              first <= last else {
            return nil
        }
        return Data(String(cleaned[first...last]).utf8)
    }

    private static func extractJSONObjectData(from text: String) -> Data? {
        let cleaned = stripThinkingPrefix(text)
        guard let first = cleaned.firstIndex(of: "{"),
              let last = cleaned.lastIndex(of: "}"),
              first <= last else {
            return nil
        }
        let slice = String(cleaned[first...last])
        return Data(slice.utf8)
    }

    private static func selectRegenerationCandidate(
        segments: [ScriptSegment],
        cerBySeg: [String: CERReport],
        verdictBySeg: [String: QualityVerdict]
    ) -> Int? {
        guard !segments.isEmpty else { return nil }
        if let failing = segments.indices.first(where: { idx in
            switch verdictBySeg[segments[idx].segmentID] {
            case .retryableFailure, .needsReview: return true
            default: return false
            }
        }) {
            return failing
        }
        return segments.indices.max(by: { a, b in
            (cerBySeg[segments[a].segmentID]?.cer ?? 0) < (cerBySeg[segments[b].segmentID]?.cer ?? 0)
        })
    }

    private static func verdictLabel(_ verdict: QualityVerdict) -> String {
        switch verdict {
        case .passed: return "passed"
        case .needsReview: return "needs_review"
        case .retryableFailure: return "retryable_failure"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
