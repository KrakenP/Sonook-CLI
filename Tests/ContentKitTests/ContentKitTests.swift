import AudioCore
import ContentKit
import Foundation
import Testing

func importBook(_ bytes: Data, name: String = "渡口.txt", encoding: ExplicitTextEncoding? = nil) throws -> ImportedBook {
    try ContentImporter.importData(bytes, fileName: name, projectID: "p", sourceDocumentRevision: "rev", explicitEncoding: encoding)
}

@Test func strictEncodingsAndCanonicalHash() throws {
    let source = "雪\r\n灯\r"
    let canonical = "雪\n灯\n"
    let utf8 = Data(source.utf8)
    var examples: [(Data, ExplicitTextEncoding, String)] = [(utf8, .utf8, "utf-8"), (Data([0xef,0xbb,0xbf]) + utf8, .utf8, "utf-8-bom")]
    for (encoding, format, marker): (ExplicitTextEncoding, String.Encoding, [UInt8]) in [
        (.utf16LE, .utf16LittleEndian, [0xff,0xfe]), (.utf16BE, .utf16BigEndian, [0xfe,0xff])
    ] {
        let bytes = try #require(source.data(using: format))
        examples.append((bytes, encoding, encoding.rawValue))
        examples.append((Data(marker) + bytes, encoding, encoding.rawValue))
    }
    for (data, encoding, detected) in examples {
        for hint in [nil, encoding] as [ExplicitTextEncoding?] {
            let book = try importBook(data, encoding: hint)
            #expect(book.detectedEncoding == detected)
            #expect(book.normalizedUTF8Data == Data(canonical.utf8))
            #expect(book.normalizedText == canonical)
            #expect(book.normalizedSHA256 == "db19f4ee8dd31a72323a10163b18ca7e4a4fc142a072f1f1aa5e681c94cfbe11")
        }
    }
    let gb = Data([0xb5,0xda,0xd2,0xbb,0xd5,0xc2,13,10,0xc0,0xb4,0xc1,0xcb,0x95,0x32,0x82,0x36,0xa1,0xa3])
    for hint in [nil, ExplicitTextEncoding.gb18030] {
        let book = try importBook(gb, encoding: hint)
        #expect(book.detectedEncoding == "gb18030")
        #expect(book.normalizedText == "第一章\n来了𠀀。")
    }
}

@Test func invalidAndAmbiguousBytesAreActionable() throws {
    for (bytes, encoding): ([UInt8], ExplicitTextEncoding?) in [
        ([0xff], nil), ([0xef,0xbb,0xbf,0xff], nil), ([0xff,0xfe,0,0xd8], nil), ([0xfe,0xff,0], nil),
        ([0xc0,0xaf], .utf8), ([0,0xdc], .utf16LE), ([0xd8,0], .utf16BE), ([0x81,0x30,0x81], .gb18030),
        ([0x81,0x7f], .gb18030), ([0xff,0xfe,65,0], .utf8)
    ] {
        do {
            _ = try importBook(Data(bytes), encoding: encoding)
            Issue.record("Expected encodingError for invalid bytes")
        } catch ContentImportError.encodingError { }
    }
    let ambiguous = Data([0x82,0x85])
    do {
        _ = try importBook(ambiguous)
        Issue.record("Expected ambiguous encoding")
    } catch ContentImportError.ambiguousEncoding {
        #expect(try importBook(ambiguous, encoding: .utf16LE).normalizedText != importBook(ambiguous, encoding: .utf16BE).normalizedText)
    }
    #expect(throws: ContentImportError.emptyContent) { try importBook(Data(" \t\n　".utf8)) }
}

@Test func chaptersPreserveAbsoluteBytesAndPreface() throws {
    let parts = ["前言🪶\n", "　第一回 舟\n河岸\n", "  cHaPtEr 2 Tide\n来了\n", "第三卷\n终"]
    let book = try importBook(Data(parts.joined().utf8))
    #expect(book.chapters.map(\.chapterID) == ["ch_000","ch_001","ch_002","ch_003"])
    #expect(book.chapters.map(\.title) == ["序","第一回 舟","cHaPtEr 2 Tide","第三卷"])
    for (chapter, part) in zip(book.chapters, parts) {
        #expect(try chapter.sourceSpan.slice(in: book.normalizedText).utf8.elementsEqual(part.utf8))
        #expect(book.normalizedUTF8Data[chapter.sourceSpan.start..<chapter.sourceSpan.endExclusive] == Data(part.utf8))
    }
    let fallback = try importBook(Data("长明灯".utf8))
    #expect(fallback.chapters.map(\.title) == ["渡口"] && fallback.chapters.first?.chapterNumber == 1)
    let many = try importBook(Data(("\n" + (1...1000).map { "第\($0)节" }.joined(separator: "\n")).utf8))
    #expect(many.chapters.count == 1000 && many.chapters.last?.chapterID == "ch_1000" && many.chapters.first?.sourceSpan.start == 0)
}

@Test func markdownCleanTextMatchesChapterSlices() throws {
    let fence = String(repeating: "`", count: 3)
    let source = "# **岸边**\n读[灯](about:blank)和_书_。\n\(fence)swift\n# 隐藏\n\(fence)\n~~~\n## 隐藏二\n~~~\n## 山顶 ##\n*远处*。"
    let book = try importBook(Data(source.utf8), name: "书.md")
    #expect(book.chapters.map(\.title) == ["岸边","山顶"])
    let slices = try book.chapters.map { try $0.sourceSpan.slice(in: book.normalizedText) }
    #expect(slices == ["岸边\n读灯和书。\n","山顶\n远处。"])
    #expect(book.normalizedText == slices.joined())
    let fallback = try importBook(Data("第一章 船\n水\n第二章 灯".utf8), name: "篇.markdown")
    #expect(fallback.chapters.map(\.chapterNumber) == [1,2])
}
