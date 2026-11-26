import Compression
import ContentKit
import Foundation
import Testing

private extension Data {
    mutating func little(_ value: Int, bytes: Int) {
        for shift in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
    }
}

private struct Member {
    let path: String
    let data: Data
    var compressed = false
    var descriptor = false
    var mode = 0o100644
    var declaredSize: Int?
    var localName: String?
    var badCRC = false

    init(_ path: String, _ content: String = "x", compressed: Bool = false) {
        self.path = path
        self.data = Data(content.utf8)
        self.compressed = compressed
    }
}

private func archive(_ members: [Member], count: Int? = nil) throws -> Data {
    var file = Data()
    var directory = Data()
    for entry in members {
        let name = Data(entry.path.utf8)
        let localName = Data((entry.localName ?? entry.path).utf8)
        var crc = UInt32.max
        for byte in entry.data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        let checksum = Int(~crc) ^ (entry.badCRC ? 1 : 0)
        let payload: Data
        if entry.compressed {
            var buffer = [UInt8](repeating: 0, count: entry.data.count + 256)
            let size = entry.data.withUnsafeBytes { src in
                compression_encode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
            try #require(size > 0)
            payload = Data(buffer.prefix(size))
        } else { payload = entry.data }
        let size = entry.declaredSize ?? entry.data.count
        let start = file.count
        var common = Data()
        for v in [20, 0x800 | (entry.descriptor ? 8 : 0), entry.compressed ? 8 : 0, 0, 0] { common.little(v, bytes: 2) }
        var sizes = Data()
        for v in [checksum, payload.count, size] { sizes.little(v, bytes: 4) }
        file.little(0x04034b50, bytes: 4)
        file += common
        file += entry.descriptor ? Data(repeating: 0, count: 12) : sizes
        file.little(localName.count, bytes: 2)
        file.little(0, bytes: 2)
        file += localName + payload
        if entry.descriptor { file.little(0x08074b50, bytes: 4); file += sizes }
        directory.little(0x02014b50, bytes: 4)
        directory.little(0x0314, bytes: 2)
        directory += common + sizes
        for v in [name.count,0,0,0,0] { directory.little(v, bytes: 2) }
        directory.little(entry.mode << 16, bytes: 4)
        directory.little(start, bytes: 4)
        directory += name
    }
    let start = file.count
    file += directory
    file.little(0x06054b50, bytes: 4)
    for v in [0,0,count ?? members.count,count ?? members.count] { file.little(v, bytes: 2) }
    file.little(directory.count, bytes: 4)
    file.little(start, bytes: 4)
    file.little(0, bytes: 2)
    return file
}

private func bookMembers() -> [Member] {
    let container = """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
        <rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
    let opf = """
        <package version="3.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:sonook:test</dc:identifier>
        <dc:title>河岸</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata>
        <manifest>
        <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
        <item id="omit" href="other.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="toc/nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
        <item id="ncx" href="old.ncx" media-type="application/x-dtbncx+xml"/>
        </manifest><spine toc="ncx"><itemref idref="a"/><itemref idref="omit" linear="no"/><itemref idref="b"/></spine></package>
        """
    let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body>
        <nav epub:type="page-list"><ol><li><a href="../a.xhtml#top">第一页</a></li></ol></nav>
        <nav epub:type="toc"><ol><li><a href="../a.xhtml#top">渡口</a></li></ol></nav></body></html>
        """
    let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:sonook:test"/></head>
        <docTitle><text>河岸</text></docTitle><navMap><navPoint id="p2" playOrder="1"><navLabel><text>回声</text></navLabel>
        <content src="b.xhtml"/></navPoint></navMap></ncx>
        """
    let a = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>书页甲</title><style>p { color: black }</style></head>
        <body><h1 id="top">晨光</h1><p>小舟<em>来了</em>🪶。</p></body></html>
        """
    let b = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>后记</title></head>
        <body><nav>导航</nav><p>再相逢。<script>void 0</script></p></body></html>
        """
    var compressed = Member("OPS/a.xhtml", a, compressed: true)
    compressed.descriptor = true
    return [Member("mimetype","application/epub+zip"), Member("META-INF/container.xml",container), Member("OPS/book.opf",opf),
            Member("OPS/other.xhtml", "<html><body><p>附页</p></body></html>"), Member("OPS/b.xhtml",b), compressed, Member("OPS/toc/nav.xhtml",nav), Member("OPS/old.ncx",ncx)]
}

@Test func zippedSpineNavigationTextAndOffsets() throws {
    let book = try importBook(archive(bookMembers()), name: "test.epub")
    #expect(book.format == .epub)
    #expect(book.chapters.map(\.title) == ["渡口", "回声"])
    #expect(book.chapters.map(\.originPath) == ["OPS/a.xhtml","OPS/b.xhtml"])
    #expect(book.normalizedText == "晨光\n小舟来了🪶。\n再相逢。")
    for (chapter, exact) in zip(book.chapters, ["晨光\n小舟来了🪶。\n", "再相逢。"]) {
        #expect(book.normalizedUTF8Data[chapter.sourceSpan.start..<chapter.sourceSpan.endExclusive] == Data(exact.utf8))
    }
}

private func rejected(_ members: [Member], count: Int? = nil) throws -> ContentImportError? {
    do {
        _ = try importBook(archive(members, count: count), name: "test.epub")
        Issue.record("Expected rejected archive")
        return nil
    } catch let error as ContentImportError { return error }
}

@Test func unsafePathsAndDirectoryDisagreement() throws {
    var link = Member("alias")
    link.mode = 0o120777
    for members in [[Member("../x")], [Member("a\\..\\x")], [Member("/x")], [Member("\\x")], [Member("C:x")],
                    [Member("a/./b"),Member("a/b")], [Member("a\\b"),Member("a/b")], [link]] {
        guard case .unsafeArchivePath = try rejected(members) else { Issue.record("Expected unsafeArchivePath"); continue }
    }
    var different = Member("a")
    different.localName = "b"
    var corrupt = Member("a","校验", compressed: true)
    corrupt.badCRC = true
    var understated = Member("a","文本超过声明长度", compressed: true)
    understated.declaredSize = 1
    for entry in [different,corrupt,understated] {
        guard case .malformedArchive = try rejected([entry]) else { Issue.record("Expected malformedArchive"); continue }
    }
}

@Test func rejectsDeclaredLimitsBeforeInflating() throws {
    var huge = Member("single")
    huge.declaredSize = 16 * 1024 * 1024 + 1
    var ratio = Member("ratio", "声明值", compressed: true)
    ratio.declaredSize = 65537
    // Metadata-only samples exercise each bound without allocating large outputs.
    let total = (0..<5).map { i in
        var member = Member("empty\(i)", "")
        member.declaredSize = 16 * 1024 * 1024
        return member
    }
    for (entries, count): ([Member], Int?) in [([huge], nil), ([ratio], nil), ([], 2001), (total,nil)] {
        guard case .archiveLimitExceeded = try rejected(entries, count: count) else { Issue.record("Expected archiveLimitExceeded"); continue }
    }
}

@Test func rejectsRightsEncryptionAndEntityDeclarations() throws {
    for entry in [Member("META-INF/rights.xml"), Member("META-INF/encryption.xml", #"<encryption xmlns:e="urn:sample"><e:EncryptedData/></encryption>"#)] {
        guard case .unsupportedDRM = try rejected(bookMembers() + [entry]) else { Issue.record("Expected unsupportedDRM"); continue }
    }
    for path in ["META-INF/container.xml", "OPS/book.opf", "OPS/toc/nav.xhtml", "OPS/old.ncx", "OPS/a.xhtml"] {
        let members = bookMembers().map { member in
            member.path == path ? Member(path, #"<!DOCTYPE sample [<!ENTITY harmless "test">]><sample/>"#) : member
        }
        guard case .malformedArchive(let reason) = try rejected(members) else { Issue.record("Expected rejection for \(path)"); continue }
        #expect(reason.contains("Unsafe XML"))
    }
}
