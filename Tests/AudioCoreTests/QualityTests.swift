import AudioCore
import Foundation
import Testing

@Suite struct QualityTests {
    func setup(_ text: String) throws -> (ChapterSlice, ScriptDocument) {
        let doc = try SourceNormalizer.normalize(data: Data(text.utf8), documentID: "d", revision: "r")
        let chapter = try #require(ChapterExtractor.extractChapters(from: doc).last)
        return (chapter, .init(chapterID: chapter.chapterID, sourceDocumentRevision: "r", scriptRevision: 1, segments: []))
    }

    func segment(_ id: String, _ start: Int, _ end: Int, _ chapter: ChapterSlice, _ sourceText: String) throws -> ScriptSegment {
        try .init(segmentID: id, chapterID: chapter.chapterID, sourceDocumentRevision: "r",
                  sourceSpan: SourceSpan(start: chapter.sourceSpan.start + start, endExclusive: chapter.sourceSpan.start + end),
                  sourceText: sourceText, spokenText: sourceText, speakerID: "narrator", voiceProfileRevision: "v1", scriptRevision: 1)
    }

    @Test func gapsAndOverlapsUseAbsoluteNonWhitespaceByteCoverage() throws {
        var (chapter, script) = try setup("序\n第2章\n甲 乙\u{3000}丙A")
        let base = chapter.sourceSpan.start
        // Local byte spans: heading 0..<7, LF 7, 甲 8..<11, 乙 12..<15, 丙 18..<21, A 21.
        script.segments = try [segment("h", 0, 7, chapter, "第2章"),
                               segment("a", 8, 11, chapter, "甲"),
                               segment("b", 8, 11, chapter, "甲"),
                               segment("c", 8, 11, chapter, "甲"),
                               segment("d", 21, 22, chapter, "A")]
        let result = SourceCoverageValidator.validate(script, against: chapter)
        #expect(!result.isValid)
        #expect(result.issues.isEmpty)
        #expect(result.coverageRatio == 11.0 / 17)
        #expect(result.missingSpans == [try SourceSpan(start: base + 12, endExclusive: base + 15),
                                        try SourceSpan(start: base + 18, endExclusive: base + 21)])
        #expect(result.overlappingSpans == [try SourceSpan(start: base + 8, endExclusive: base + 11)])
        script.segments = try [segment("h", 0, 7, chapter, "第2章"), segment("a", 8, 11, chapter, "甲"),
                               segment("b", 12, 15, chapter, "乙"), segment("c", 18, 22, chapter, "丙A")]
        #expect(SourceCoverageValidator.validate(script, against: chapter).isValid)
    }

    @Test func invalidSpansNeverContributeAndTextMatchIsByteExact() throws {
        var (chapter, script) = try setup("岸e\u{301}")
        script.segments = try [segment("mid", 1, 3, chapter, ""), segment("over", 3, 7, chapter, ""),
                               segment("empty", 0, 0, chapter, ""), segment("valid", 3, 6, chapter, "é")]
        let result = SourceCoverageValidator.validate(script, against: chapter)
        #expect(result.issues == [.invalidSpan("mid"), .invalidSpan("over"), .invalidSpan("empty"), .sourceTextMismatch("valid")])
        #expect(result.coverageRatio == 0.5)
        #expect(result.missingSpans == [try SourceSpan(start: 0, endExclusive: 3)])
        let (blank, empty) = try setup(" \t\n\u{3000}")
        #expect(SourceCoverageValidator.validate(empty, against: blank).isValid)
        #expect(SourceCoverageValidator.validate(empty, against: blank).coverageRatio == 1)
    }

    @Test func rewriteMustHaveAnAuditNoteAndCorrectProvenance() throws {
        var (chapter, script) = try setup("还有12寸！")
        var s = try segment("a", 0, chapter.text.utf8.count, chapter, chapter.text)
        s.spokenText = "还有１２寸。"
        script.segments = [s]
        #expect(SourceCoverageValidator.validate(script, against: chapter).isValid)
        s.spokenText = "还有十二寸。"
        for note: String? in [nil, "  "] {
            s.normalizationNote = note
            script.segments = [s]
            #expect(SourceCoverageValidator.validate(script, against: chapter).issues == [.unauthorizedRewrite("a")])
        }
        #expect(SourceCoverageValidator.validate(script, against: chapter, verbatim: false).isValid)
        s.normalizationNote = "12 按数量读作十二"
        script.segments = [s]
        #expect(SourceCoverageValidator.validate(script, against: chapter).isValid)
        let wrong = ScriptDocument(chapterID: "elsewhere", sourceDocumentRevision: "stale", scriptRevision: 2, segments: [s])
        #expect(SourceCoverageValidator.validate(wrong, against: chapter).issues == [.documentMismatch, .segmentRevisionMismatch("a")])
    }

    @Test func outOfOrderAndDuplicateDoNotPass() throws {
        var (chapter, script) = try setup("甲乙")
        script.segments = try [segment("s", 3, 6, chapter, "乙"), segment("s", 0, 3, chapter, "甲")]
        let result = SourceCoverageValidator.validate(script, against: chapter)
        #expect(result.coverageRatio == 1)
        #expect(result.issues == [.duplicateSegmentID("s"), .outOfOrder("s")])
    }

    @Test func normalizationIsAuditableAndOptional() {
        #expect(ChineseCERCalculator.normalize("　ＥｃＨＯ，“水！”\t Ａ１。") == "echo水a1")
        #expect(ChineseCERCalculator.normalize("快给大啊~~ 真的～♪") == "快给大啊真的")
        #expect(ChineseCERCalculator.normalize("ÄＢ") == "Äb")
        let r = ChineseCERCalculator.calculate(reference: "０１２号，2024年，12次，10001米，0.05寸。",
                                                hypothesis: "零一二号二零二四年十二次一万零一米零点零五寸", normalizeNumerals: true)
        #expect(r.normalizedReference == r.normalizedHypothesis && r.cer == 0)
        #expect(ChineseCERCalculator.calculate(reference: "12", hypothesis: "十二").cer > 0)
        #expect(ChineseCERCalculator.normalize("101000米，300500010个", normalizeNumerals: true) == "十万一千米三亿零五十万零一十个")
    }

    @Test func cerDetectsSubstitutionsOmissionsAndActualRepeats() {
        let sub = ChineseCERCalculator.calculate(reference: "长乐渡", hypothesis: "长乐路")
        #expect(sub.substitutions == 1 && sub.deletions == 0 && sub.insertions == 0)
        #expect(sub.referenceLength == 3 && sub.cer == 1.0 / 3)
        let omission = ChineseCERCalculator.calculate(reference: "抬头听回音", hypothesis: "抬头音")
        #expect(omission.deletions == 2 && omission.suspectedOmission)
        for hyp in ["抬头抬头听回音", "抬头听回音回音"] {
            let repeated = ChineseCERCalculator.calculate(reference: "抬头听回音", hypothesis: hyp)
            #expect(repeated.insertions == 2 && repeated.suspectedRepetition && !repeated.suspectedOmission)
        }
        let triple = ChineseCERCalculator.calculate(reference: "长乐渡", hypothesis: "长乐渡长乐渡长乐渡")
        #expect(triple.insertions == 6 && triple.suspectedRepetition)
        let extra = ChineseCERCalculator.calculate(reference: "甲乙", hypothesis: "甲丙乙")
        #expect(extra.insertions == 1 && !extra.suspectedRepetition)
        #expect(ChineseCERCalculator.calculate(reference: "", hypothesis: "").cer == 0)
        #expect(ChineseCERCalculator.calculate(reference: "。", hypothesis: "甲乙").cer == 2)
        #expect(ChineseCERCalculator.calculate(reference: "甲", hypothesis: "").suspectedOmission)
        let mixed = ChineseCERCalculator.calculate(reference: "kitten", hypothesis: "sitting")
        #expect(mixed.cer == 3.0 / 6 && mixed.substitutions == 2 && mixed.insertions == 1)
    }

    let exact = ChineseCERCalculator.calculate(reference: "铃", hypothesis: "铃")

    @Test func pcmLevelsAndSilenceRunsHaveKnownValues() {
        let report = AudioIntegrityChecker.analyze(pcmSamples: [0, 0, 0.5, 0, 0, 0, -0.5, 0], sampleRate: 4)
        #expect(report.durationSeconds == 2 && !report.isTruncated && !report.isSilent)
        #expect(abs(report.peakDBFS + 6.0206) < 0.0001)
        #expect(abs(report.rmsDBFS + 12.0412) < 0.0001)
        #expect(report.leadingSilenceSeconds == 0.5 && report.trailingSilenceSeconds == 0.25)
        #expect(report.maxInternalSilenceSeconds == 0.75 && report.clippingSampleCount == 0)
        #expect(QualityEvaluator.evaluate(cer: exact, integrity: report) == .passed)
        #expect(QualityEvaluator.evaluate(cer: exact, integrity: report, thresholds: .init(maxInternalSilenceSeconds: 0.5))
                == .retryableFailure([.internalSilence]))
    }

    @Test func brokenAudioRetriesAndTranscriptDisagreementNeedsReview() {
        let silent = AudioIntegrityChecker.analyze(pcmSamples: [0, 0, 0], sampleRate: 3)
        #expect(silent.isSilent && silent.peakDBFS == -.infinity && silent.rmsDBFS == -.infinity)
        #expect(silent.leadingSilenceSeconds == 1 && silent.trailingSilenceSeconds == 1 && silent.maxInternalSilenceSeconds == 0)
        #expect(QualityEvaluator.evaluate(cer: exact, integrity: silent) == .retryableFailure([.silent]))
        let clipped = AudioIntegrityChecker.analyze(pcmSamples: [1, -1.1, 0], sampleRate: 10, expectedFrameCount: 4)
        #expect(clipped.clippingSampleCount == 2 && clipped.isTruncated && clipped.peakDBFS > 0)
        #expect(QualityEvaluator.evaluate(cer: exact, integrity: clipped) == .retryableFailure([.truncated, .clipping]))
        for (samples, rate): ([Float], Int) in [([], 10), ([0.2], 0), ([.nan], 10), ([.infinity], 10)] {
            #expect(AudioIntegrityChecker.analyze(pcmSamples: samples, sampleRate: rate).isTruncated)
        }
        let good = AudioIntegrityChecker.analyze(pcmSamples: [0.3], sampleRate: 10)
        let missing = ChineseCERCalculator.calculate(reference: "水铃", hypothesis: "铃")
        #expect(QualityEvaluator.evaluate(cer: missing, integrity: good) == .needsReview([.highCER, .suspectedOmission]))
        let doubled = ChineseCERCalculator.calculate(reference: "铃", hypothesis: "铃铃")
        #expect(QualityEvaluator.evaluate(cer: doubled, integrity: good, thresholds: .init(maxCER: 1))
                == .needsReview([.suspectedRepetition]))
    }

    @Test func pitchEstimatorAndSemitoneDriftDetectVoiceCharacterJump() throws {
        let sr = 48_000
        let tone100 = (0..<(sr / 2)).map { Float(sin(2.0 * .pi * 100.0 * Double($0) / Double(sr)) * 0.25) }
        let tone148 = (0..<(sr / 2)).map { Float(sin(2.0 * .pi * 148.0 * Double($0) / Double(sr)) * 0.25) }
        let f0Base = try #require(AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: tone100, sampleRate: sr))
        let f0High = try #require(AudioIntegrityChecker.estimateMedianPitchHz(pcmSamples: tone148, sampleRate: sr))
        #expect(abs(f0Base - 100.0) < 3.0)
        #expect(abs(f0High - 148.0) < 4.0)
        let drift = AudioIntegrityChecker.pitchDriftSemitones(referenceHz: f0Base, candidateHz: f0High)
        #expect(drift > 6.0 && drift < 7.5)
    }
}
