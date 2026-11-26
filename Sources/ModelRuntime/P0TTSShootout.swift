import AudioCore
import Foundation

public enum TTSShootoutEngine: String, Sendable {
    case qwen3CustomVoice = "qwen3-custom-voice"
    case qwen3VoiceDesign = "qwen3-voice-design"
    case voxcpm2Design = "voxcpm2-design"
    case voxcpm2Locked = "voxcpm2-locked"
    case fishS2Pro = "fish-s2-pro"
    case indexTTS15 = "indextts-1.5"
}

public struct P0TTSShootoutConfig: Sendable {
    public let engine: TTSShootoutEngine
    public let scriptPath: URL
    public let catalogPath: URL
    public let ttsModelDirectory: URL
    public let ttsLabel: String
    public let asrModelDirectory: URL
    public let asrLabel: String
    public let outputDirectory: URL
    public let saveAuditionsDirectory: URL?
    public let loadAuditionsDirectory: URL?

    public init(
        engine: TTSShootoutEngine,
        scriptPath: URL,
        catalogPath: URL,
        ttsModelDirectory: URL,
        ttsLabel: String,
        asrModelDirectory: URL,
        asrLabel: String,
        outputDirectory: URL,
        saveAuditionsDirectory: URL? = nil,
        loadAuditionsDirectory: URL? = nil
    ) {
        self.engine = engine
        self.scriptPath = scriptPath
        self.catalogPath = catalogPath
        self.ttsModelDirectory = ttsModelDirectory
        self.ttsLabel = ttsLabel
        self.asrModelDirectory = asrModelDirectory
        self.asrLabel = asrLabel
        self.outputDirectory = outputDirectory
        self.saveAuditionsDirectory = saveAuditionsDirectory
        self.loadAuditionsDirectory = loadAuditionsDirectory
    }
}

public struct TTSShootoutReport: Codable, Sendable {
    public let schemaVersion: Int
    public let engine: String
    public let ttsModel: String
    public let sampleRate: Int
    public let asrModel: String
    public let segmentCount: Int
    public let ttsLoadMs: Double
    public let ttsTotalInferenceMs: Double
    public let totalAudioDurationSeconds: Double
    public let aggregateRTFExcludingLoad: Double
    public let aggregateRTFIncludingLoad: Double
    public let asrLoadMs: Double
    public let asrTotalInferenceMs: Double
    public let weightedCER: Double
    public let passedSegments: Int
    public let needsReviewSegments: Int
    public let retryableFailureSegments: Int
    public let ttsPeakMLXBytes: Int
    public let ttsPeakPhysFootprintBytes: UInt64
    public let ttsUnloadedMLXActiveBytes: Int
    public let memoryTimeline: [MemorySample]
    public let segments: [SegmentBenchmarkRecord]
    public let artifacts: [String: String]
}

public enum P0TTSShootoutRunner {
    private static let narratorCalmPrompt = "标准普通话中年男性有声书旁白，声音温厚克制，语速均匀平稳，呼吸自然，不做戏剧化夸张起伏。"

    public static func run(config: P0TTSShootoutConfig, stderrLog: @Sendable (String) -> Void) async throws -> TTSShootoutReport {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let segmentsDir = config.outputDirectory.appendingPathComponent("segments", isDirectory: true)
        try fm.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        let scriptDoc = try JSONDecoder().decode(ScriptDocument.self, from: try Data(contentsOf: config.scriptPath))
        let catalog = try CharacterVoiceCatalog.decodeJSON(try Data(contentsOf: config.catalogPath))

        var memoryTimeline: [MemorySample] = []
        MemoryProbe.resetMLXPeak()
        memoryTimeline.append(MemoryProbe.sample(label: "baseline"))

        // Instantiate the chosen native Swift MLX TTS provider
        let ttsProvider: any TTSProvider
        let sampleRate: Int
        stderrLog("[TTS-Bench][\(config.engine.rawValue)] Loading \(config.ttsLabel)...")
        let tLoad = Date()
        switch config.engine {
        case .qwen3CustomVoice:
            let p = MLXQwen3TTSProvider(modelDirectory: config.ttsModelDirectory, mode: .customVoice, modelID: config.ttsLabel)
            try await p.load()
            sampleRate = await p.sampleRate
            ttsProvider = p
        case .qwen3VoiceDesign:
            let p = MLXQwen3TTSProvider(modelDirectory: config.ttsModelDirectory, mode: .voiceDesign, modelID: config.ttsLabel)
            try await p.load()
            sampleRate = await p.sampleRate
            ttsProvider = p
        case .voxcpm2Design, .voxcpm2Locked:
            let p = MLXVoxCPM2Provider(modelDirectory: config.ttsModelDirectory, modelID: config.ttsLabel)
            try await p.load()
            sampleRate = await p.sampleRate
            ttsProvider = p
        case .fishS2Pro:
            let p = MLXFishSpeechProvider(modelDirectory: config.ttsModelDirectory, modelID: config.ttsLabel)
            try await p.load()
            sampleRate = await p.sampleRate
            ttsProvider = p
        case .indexTTS15:
            let p = MLXIndexTTSProvider(modelDirectory: config.ttsModelDirectory, modelID: config.ttsLabel)
            try await p.load()
            sampleRate = await p.sampleRate
            ttsProvider = p
        }
        let ttsLoadMs = Date().timeIntervalSince(tLoad) * 1000.0
        memoryTimeline.append(MemoryProbe.sample(label: "tts_loaded"))
        stderrLog(String(format: "[TTS-Bench] Loaded in %.0fms (sr=%d Hz, MLX active=%@)", ttsLoadMs, sampleRate, MemoryProbe.formatMiB(memoryTimeline.last!.mlxActiveBytes)))

        // Optionally synthesize clean audition anchor clips for each character from their LLM voice_design_prompt
        if let auditionDir = config.saveAuditionsDirectory {
            try fm.createDirectory(at: auditionDir, withIntermediateDirectories: true)
            for card in catalog.cards {
                let isNarrator = (card.characterID == "char_narrator")
                let auditionText = isNarrator
                    ? "窗外微风拂过树梢，山间石桌上仍摆着半局残棋，一切显得安静而从容。"
                    : "今天天气不错，大家先把事情商量清楚，等会儿再一起出发也来得及。"
                let designPrompt = normalizedMandarinDesignPrompt(for: card)
                var params: [String: String] = ["seed": "42"]
                switch config.engine {
                case .qwen3CustomVoice:
                    let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
                    params["speaker"] = isNarrator ? "Uncle_Fu" : (binding?.speakerID ?? "Dylan")
                    params["instruction"] = ""
                    params["language"] = "Chinese"
                    params["temperature"] = isNarrator ? "0.35" : "0.45"
                    params["top_p"] = "0.80"
                case .qwen3VoiceDesign:
                    params["voice_design_prompt"] = designPrompt
                    params["language"] = "Chinese"
                    params["temperature"] = isNarrator ? "0.35" : "0.45"
                    params["top_p"] = "0.80"
                case .voxcpm2Design, .voxcpm2Locked:
                    params["voice_design_prompt"] = designPrompt
                    params["max_tokens"] = "180"
                case .fishS2Pro, .indexTTS15:
                    break
                }
                let audio = try await ttsProvider.synthesize(SpeechRequest(text: auditionText, parameters: params))
                let wavURL = auditionDir.appendingPathComponent("audition_\(card.characterID).wav")
                let txtURL = auditionDir.appendingPathComponent("audition_\(card.characterID).txt")
                try NativeAudioRenderer.writeWAV(samples: audio.pcmSamples, sampleRate: audio.sampleRate, to: wavURL)
                try Data(auditionText.utf8).write(to: txtURL, options: .atomic)
                stderrLog(String(format: "[TTS-Bench] Saved audition clip for %@ (%@): %.2fs", card.characterID, card.canonicalName, Double(audio.pcmSamples.count) / Double(audio.sampleRate)))
            }
        }

        // Synthesize all segments from the identical verified script.json
        var pcmBySeg: [String: [Float]] = [:]
        var metricsBySeg: [String: InferenceMetrics] = [:]
        var integrityBySeg: [String: AudioIntegrityReport] = [:]
        var totalInferenceMs = 0.0
        var totalAudioDur = 0.0
        var peakPhysBytes: UInt64 = memoryTimeline.last?.physFootprintBytes ?? 0

        for seg in scriptDoc.segments {
            let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) ?? catalog.cards.first!
            let isNarrator = (seg.speakerID == "char_narrator")
            let designPrompt = normalizedMandarinDesignPrompt(for: card)
            let dialogueHint = isNarrator ? "" : (seg.direction.styleInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            var params: [String: String] = ["seed": "42"]
            switch config.engine {
            case .qwen3CustomVoice:
                let binding = card.providerBindings[MLXQwen3TTSProvider.providerIdentifier]
                params["speaker"] = isNarrator ? "Uncle_Fu" : (binding?.speakerID ?? "Dylan")
                if isNarrator {
                    params["instruction"] = ""
                    params["temperature"] = "0.35"
                    params["top_p"] = "0.80"
                } else {
                    let combined = [binding?.baseInstruction, dialogueHint]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "，")
                    params["instruction"] = combined
                    params["temperature"] = "0.52"
                    params["top_p"] = "0.85"
                }
                params["language"] = "Chinese"
                params["repetition_penalty"] = "1.05"
            case .qwen3VoiceDesign:
                let combinedPrompt = dialogueHint.isEmpty ? designPrompt : "\(designPrompt)当前语气：\(dialogueHint)。"
                params["voice_design_prompt"] = combinedPrompt
                params["language"] = "Chinese"
                params["temperature"] = isNarrator ? "0.35" : "0.48"
                params["top_p"] = isNarrator ? "0.80" : "0.85"
                params["repetition_penalty"] = "1.05"
            case .voxcpm2Design:
                let combinedPrompt = dialogueHint.isEmpty ? designPrompt : "\(designPrompt)\(dialogueHint)"
                params["voice_design_prompt"] = combinedPrompt
                params["max_tokens"] = String(max(220, seg.spokenText.count * 6))
            case .voxcpm2Locked:
                if let dir = config.loadAuditionsDirectory {
                    let refWAV = dir.appendingPathComponent("audition_\(card.characterID).wav")
                    if fm.fileExists(atPath: refWAV.path) {
                        params["ref_audio_path"] = refWAV.path
                    }
                }
                if !dialogueHint.isEmpty {
                    params["control_instruction"] = dialogueHint
                }
                params["max_tokens"] = String(max(220, seg.spokenText.count * 6))
            case .fishS2Pro:
                if let dir = config.loadAuditionsDirectory {
                    let refWAV = dir.appendingPathComponent("audition_\(card.characterID).wav")
                    let refTXT = dir.appendingPathComponent("audition_\(card.characterID).txt")
                    if fm.fileExists(atPath: refWAV.path) {
                        params["ref_audio_path"] = refWAV.path
                    }
                    if let txt = try? String(contentsOf: refTXT, encoding: .utf8) {
                        params["ref_text"] = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                params["temperature"] = isNarrator ? "0.45" : "0.65"
                params["top_p"] = "0.80"
                params["max_tokens"] = "2048"
            case .indexTTS15:
                if let dir = config.loadAuditionsDirectory {
                    let refWAV = dir.appendingPathComponent("audition_\(card.characterID).wav")
                    if fm.fileExists(atPath: refWAV.path) {
                        params["ref_audio_path"] = refWAV.path
                    }
                }
                params["temperature"] = isNarrator ? "0.55" : "0.75"
                params["top_p"] = "0.85"
                params["top_k"] = "30"
                params["max_tokens"] = "2048"
            }

            let audio = try await ttsProvider.synthesize(SpeechRequest(text: seg.spokenText, parameters: params))
            pcmBySeg[seg.segmentID] = audio.pcmSamples
            metricsBySeg[seg.segmentID] = audio.metrics
            totalInferenceMs += audio.metrics.inferenceDurationMs
            let dur = Double(audio.pcmSamples.count) / Double(audio.sampleRate)
            totalAudioDur += dur
            if let mem = audio.metrics.peakResidentBytes, mem > peakPhysBytes {
                peakPhysBytes = mem
            }
            integrityBySeg[seg.segmentID] = AudioIntegrityChecker.analyze(pcmSamples: audio.pcmSamples, sampleRate: audio.sampleRate)

            let segWAVURL = segmentsDir.appendingPathComponent("\(seg.segmentID).wav")
            try NativeAudioRenderer.writeWAV(samples: audio.pcmSamples, sampleRate: audio.sampleRate, to: segWAVURL)
            stderrLog(String(format: "[TTS-Bench][%@] %@ (%@) %.2fs in %.2fs (RTF=%.2f)", config.engine.rawValue, seg.segmentID, card.canonicalName, dur, audio.metrics.inferenceDurationMs / 1000.0, audio.metrics.rtf ?? 0))
        }

        let ttsDoneSample = MemoryProbe.sample(label: "tts_done")
        memoryTimeline.append(ttsDoneSample)
        let ttsPeakMLX = ttsDoneSample.mlxPeakBytes
        if ttsDoneSample.physFootprintBytes > peakPhysBytes {
            peakPhysBytes = ttsDoneSample.physFootprintBytes
        }

        await ttsProvider.unload()
        let ttsUnloadedSample = MemoryProbe.sample(label: "tts_unloaded")
        memoryTimeline.append(ttsUnloadedSample)
        stderrLog("[TTS-Bench] TTS unloaded -> MLX active=\(MemoryProbe.formatMiB(ttsUnloadedSample.mlxActiveBytes)) cache=\(MemoryProbe.formatMiB(ttsUnloadedSample.mlxCacheBytes))")

        // ASR verification using the exact same Qwen3-ASR-1.7B model
        let asrProvider = MLXQwen3ASRProvider(modelDirectory: config.asrModelDirectory, modelID: config.asrLabel)
        MemoryProbe.resetMLXPeak()
        let tASRLoad = Date()
        try await asrProvider.load()
        let asrLoadMs = Date().timeIntervalSince(tASRLoad) * 1000.0
        memoryTimeline.append(MemoryProbe.sample(label: "asr_loaded"))

        var cerBySeg: [String: CERReport] = [:]
        var verdictBySeg: [String: QualityVerdict] = [:]
        var asrMsBySeg: [String: Double] = [:]
        var asrTotalMs = 0.0
        var totalEdits = 0
        var totalRefChars = 0

        for seg in scriptDoc.segments {
            guard let pcm = pcmBySeg[seg.segmentID],
                  let integrity = integrityBySeg[seg.segmentID] else { continue }
            let tr = try await asrProvider.transcribe(ASRRequest(
                pcmSamples: pcm,
                sampleRate: sampleRate,
                parameters: ["language": "Chinese"]
            ))
            asrMsBySeg[seg.segmentID] = tr.metrics.inferenceDurationMs
            asrTotalMs += tr.metrics.inferenceDurationMs
            let cer = ChineseCERCalculator.calculate(reference: seg.spokenText, hypothesis: tr.text, normalizeNumerals: true)
            cerBySeg[seg.segmentID] = cer
            totalEdits += cer.substitutions + cer.deletions + cer.insertions
            totalRefChars += cer.referenceLength
            let verdict = QualityEvaluator.evaluate(
                cer: cer,
                integrity: integrity,
                thresholds: QualityThresholds(maxCER: 0.05, maxInternalSilenceSeconds: 2.5, maxClippingSampleCount: 10)
            )
            verdictBySeg[seg.segmentID] = verdict
        }
        memoryTimeline.append(MemoryProbe.sample(label: "asr_done"))
        await asrProvider.unload()
        memoryTimeline.append(MemoryProbe.sample(label: "asr_unloaded"))

        // Render preview WAV + M4A + timeline.json
        let renderInputs: [(segment: ScriptSegment, samples: [Float])] = scriptDoc.segments.compactMap { seg in
            guard let pcm = pcmBySeg[seg.segmentID] else { return nil }
            return (seg, pcm)
        }
        let previewWAV = config.outputDirectory.appendingPathComponent("preview.wav")
        let previewM4A = config.outputDirectory.appendingPathComponent("preview.m4a")
        let timelineURL = config.outputDirectory.appendingPathComponent("timeline.json")
        let timeline = try NativeAudioRenderer.renderChapter(
            chapterID: scriptDoc.chapterID,
            segments: renderInputs,
            sampleRate: sampleRate,
            wavURL: previewWAV,
            m4aURL: previewM4A
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(timeline).write(to: timelineURL, options: .atomic)

        var passed = 0
        var needsReview = 0
        var retryable = 0
        let segRecords: [SegmentBenchmarkRecord] = scriptDoc.segments.map { seg in
            let card = catalog.resolveCharacter(namedOrAliased: seg.speakerID) ?? catalog.cards.first!
            let verdict = verdictBySeg[seg.segmentID] ?? .needsReview([])
            let reasons: [String]
            let label: String
            switch verdict {
            case .passed:
                passed += 1; label = "passed"; reasons = []
            case .needsReview(let r):
                needsReview += 1; label = "needs_review"; reasons = r.map(\.rawValue)
            case .retryableFailure(let r):
                retryable += 1; label = "retryable_failure"; reasons = r.map(\.rawValue)
            }
            let m = metricsBySeg[seg.segmentID]
            let integ = integrityBySeg[seg.segmentID]
            return SegmentBenchmarkRecord(
                segmentID: seg.segmentID,
                speakerID: seg.speakerID,
                speakerName: card.canonicalName,
                ttsVoice: config.engine.rawValue,
                isDialogue: seg.speakerID != "char_narrator",
                sourceByteStart: seg.sourceSpan.start,
                sourceByteEndExclusive: seg.sourceSpan.endExclusive,
                charCount: seg.spokenText.count,
                ttsInferenceMs: m?.inferenceDurationMs,
                audioDurationSeconds: m?.audioDurationSeconds,
                rtf: m?.rtf,
                asrInferenceMs: asrMsBySeg[seg.segmentID],
                cer: cerBySeg[seg.segmentID]?.cer,
                rmsDBFS: integ?.rmsDBFS,
                verdict: label,
                verdictReasons: reasons
            )
        }

        let rtfExcl = totalAudioDur > 0 ? (totalInferenceMs / 1000.0) / totalAudioDur : 0
        let rtfIncl = totalAudioDur > 0 ? ((totalInferenceMs + ttsLoadMs) / 1000.0) / totalAudioDur : 0
        let weightedCER = totalRefChars > 0 ? Double(totalEdits) / Double(totalRefChars) : 0

        let report = TTSShootoutReport(
            schemaVersion: AudioCoreInfo.currentSchemaVersion,
            engine: config.engine.rawValue,
            ttsModel: config.ttsLabel,
            sampleRate: sampleRate,
            asrModel: config.asrLabel,
            segmentCount: scriptDoc.segments.count,
            ttsLoadMs: ttsLoadMs,
            ttsTotalInferenceMs: totalInferenceMs,
            totalAudioDurationSeconds: totalAudioDur,
            aggregateRTFExcludingLoad: rtfExcl,
            aggregateRTFIncludingLoad: rtfIncl,
            asrLoadMs: asrLoadMs,
            asrTotalInferenceMs: asrTotalMs,
            weightedCER: weightedCER,
            passedSegments: passed,
            needsReviewSegments: needsReview,
            retryableFailureSegments: retryable,
            ttsPeakMLXBytes: ttsPeakMLX,
            ttsPeakPhysFootprintBytes: peakPhysBytes,
            ttsUnloadedMLXActiveBytes: ttsUnloadedSample.mlxActiveBytes,
            memoryTimeline: memoryTimeline,
            segments: segRecords,
            artifacts: [
                "preview_m4a": previewM4A.path,
                "preview_wav": previewWAV.path,
                "timeline_json": timelineURL.path
            ]
        )

        let reportURL = config.outputDirectory.appendingPathComponent("tts-bench-report.json")
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        stderrLog(String(format: "[TTS-Bench][%@] DONE sr=%dHz audio=%.1fs RTF=%.3f CER=%.2f%% (passed=%d/%d) -> %@",
                         config.engine.rawValue, sampleRate, totalAudioDur, rtfExcl, weightedCER * 100, passed, scriptDoc.segments.count, previewM4A.path))
        return report
    }

    private static func normalizedMandarinDesignPrompt(for card: CharacterVoiceCard) -> String {
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
}
