import AudioCore
import Foundation
import Testing

@Suite struct SourceContractTests {
    @Test(arguments: [TextEncodingDetected.utf8, .utf8BOM, .utf16LE, .utf16BE])
    func allEncodingsShareCanonicalBytes(_ encoding: TextEncodingDetected) throws {
        let canonical = "第一章\n长乐渡口🛶\nEcho\n"
        let original = "第一章\r\n长乐渡口🛶\rEcho\n"
        let reference = try SourceNormalizer.normalize(data: Data(canonical.utf8), documentID: "doc", revision: "r1")
        let marker: [UInt8]
        let content: Data
        switch encoding {
        case .utf8, .utf8BOM:
            marker = encoding == .utf8BOM ? [0xEF, 0xBB, 0xBF] : []
            content = Data(original.utf8)
        case .utf16LE, .utf16BE:
            marker = encoding == .utf16LE ? [0xFF, 0xFE] : [0xFE, 0xFF]
            content = try #require(original.data(using: encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian))
        }
        let withMarker = Data(marker) + content
        let variants = [withMarker] + ([.utf16BE, .utf16LE].contains(encoding) ? [content] : [])
        for data in variants {
            let doc = try SourceNormalizer.normalize(data: data, documentID: "doc", revision: "r1")
            #expect(doc.detectedEncoding == encoding)
            #expect(doc.canonicalUTF8Text.utf8.elementsEqual(canonical.utf8))
            #expect(doc.utf8ByteCount == canonical.utf8.count)
            #expect(doc.sha256Hex == reference.sha256Hex)
            #expect(try JSONDecoder().decode(NormalizedSourceDocument.self, from: JSONEncoder().encode(doc)) == doc)
        }
    }

    @Test func ambiguousUnmarkedTextAndMalformedData() throws {
        let bytes = Data([0x60, 0x4F, 0x7D, 0x59])
        let doc = try SourceNormalizer.normalize(data: bytes, documentID: "d", revision: "r", encodingHint: .utf16LE)
        #expect(doc.canonicalUTF8Text == "你好")
        for invalid in [[0xEF, 0xBB, 0xBF, 0xFF], [0xFF, 0xFE, 0x01], [0xFE, 0xFF, 0xD8, 0x00], [0xFF]] as [[UInt8]] {
            #expect(throws: SourceNormalizationError.self) {
                try SourceNormalizer.normalize(data: Data(invalid), documentID: "d", revision: "r")
            }
        }
        let empty = try SourceNormalizer.normalize(data: Data(), documentID: "e", revision: "r")
        #expect(empty.sha256Hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ChapterExtractor.extractChapters(from: empty).map(\.sourceSpan) == [try SourceSpan(start: 0, endExclusive: 0)])
    }

    @Test func bothUnmarkedUTF16EditionsMatchTheCheckedInGoldenDocument() throws {
        let (golden, source) = try GoldenFixture.load()
        for (encoding, expected): (String.Encoding, TextEncodingDetected) in [(.utf16BigEndian, .utf16BE), (.utf16LittleEndian, .utf16LE)] {
            let bytes = try #require(source.canonicalUTF8Text.data(using: encoding))
            let imported = try SourceNormalizer.normalize(data: bytes, documentID: golden.documentID, revision: golden.sourceDocumentRevision)
            #expect(imported.sha256Hex == golden.sha256Hex && imported.detectedEncoding == expected)
            #expect(ChapterExtractor.extractChapters(from: imported).map(\.sourceSpan) == golden.chapters.map(\.sourceSpan))
        }
    }

    @Test func corruptedSourceAndUnsupportedVersionAreRejected() throws {
        let (_, source) = try GoldenFixture.load()
        let json = try JSONEncoder().encode(source)
        for (key, replacement) in [("sha256_hex", "bad" as Any), ("utf8_byte_count", 0), ("schema_version", 2)] {
            var fields = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
            fields[key] = replacement
            let changed = try JSONSerialization.data(withJSONObject: fields)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(NormalizedSourceDocument.self, from: changed) }
        }
    }

    @Test func slicesAreHalfOpenAndScalarAligned() throws {
        let text = "水🛶e\u{301}A"
        #expect(try SourceSpan(start: 3, endExclusive: 7).slice(in: text) == "🛶")
        #expect(try SourceSpan(start: 8, endExclusive: 10).slice(in: text) == "\u{301}")
        for offset in [1, 2, 4, 5, 6, 9] {
            #expect(throws: SourceSpanError.splitsUnicodeScalar) { try SourceSpan(start: offset, endExclusive: offset).slice(in: text) }
            #expect(throws: SourceSpanError.splitsUnicodeScalar) { try SourceSpan(start: 0, endExclusive: offset).slice(in: text) }
        }
        #expect(try SourceSpan(start: 11, endExclusive: 11).slice(in: text).isEmpty)
        #expect(throws: SourceSpanError.outOfBounds) { try SourceSpan(start: 0, endExclusive: Int.max).slice(in: text) }
        #expect(throws: SourceSpanError.invalidRange) { try SourceSpan(start: -1, endExclusive: 0) }
        let reversed = Data(#"{"unit":"utf8_byte","start":3,"end_exclusive":1}"#.utf8)
        #expect(throws: SourceSpanError.invalidRange) { try JSONDecoder().decode(SourceSpan.self, from: reversed) }
    }

    @Test func headingsAtLineStartAndFallback() throws {
        func extract(_ text: String) throws -> [ChapterSlice] {
            ChapterExtractor.extractChapters(from: try SourceNormalizer.normalize(data: Data(text.utf8), documentID: "d", revision: "r"))
        }
        #expect(try extract("本段提到第一章\n 第2章\n第九回").map(\.title) == ["全文"])
        let text = "卷首\n第两百章 镜\n第12章 船\n"
        let parts = try extract(text)
        #expect(parts.map(\.title) == ["序", "第两百章 镜", "第12章 船"])
        #expect(parts.map(\.text).joined() == text)
        #expect(parts.map(\.sourceSpan.start) == [0, 7, 24])
    }

    @Test func originalFixtureMatchesEveryGoldenByteAndSpeaker() throws {
        let (golden, source) = try GoldenFixture.load()
        let chapters = ChapterExtractor.extractChapters(from: source)
        #expect(golden.schemaVersion == 1)
        #expect(source.sha256Hex == golden.sha256Hex)
        #expect(source.utf8ByteCount == golden.utf8ByteCount)
        #expect(chapters.count == 2)
        #expect(chapters.count == golden.chapters.count)
        var cursor = 0
        var speakers: Set<String> = []
        for (actual, expected) in zip(chapters, golden.chapters) {
            #expect(actual.title == expected.title)
            #expect(actual.chapterID == expected.chapterID)
            #expect(actual.sourceSpan == expected.sourceSpan)
            #expect(actual.sourceSpan.start == cursor)
            for line in expected.segments {
                #expect(line.sourceSpan.start == cursor)
                #expect(try line.sourceSpan.slice(in: source.canonicalUTF8Text).utf8.elementsEqual(line.sourceText.utf8))
                speakers.insert(line.speakerID)
                cursor = line.sourceSpan.endExclusive
            }
            #expect(actual.sourceSpan.endExclusive == cursor)
            let coverage = SourceCoverageValidator.validate(golden.script(for: expected), against: actual)
            #expect(coverage.isValid)
            #expect(coverage.coverageRatio == 1)
        }
        #expect(cursor == source.utf8ByteCount)
        #expect(speakers == ["narrator", "cen", "wen", "mu"])
    }
}
