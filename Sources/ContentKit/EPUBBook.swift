import Foundation

enum EPUBBook {
    static func read(_ data: Data) throws -> ChapterText {
        let files = try EPUBArchive(data).files
        func parse(_ path: String, as kind: EPUBXML.Kind) throws -> EPUBXML {
            guard let bytes = files[path] else { throw ContentImportError.malformedArchive("Missing \(path)") }
            return try EPUBXML.read(bytes, kind: kind)
        }
        if files["META-INF/rights.xml"] != nil { throw ContentImportError.unsupportedDRM("rights.xml") }
        if files["META-INF/encryption.xml"] != nil {
            let encryption = try parse("META-INF/encryption.xml", as: .encryption)
            if encryption.encrypted { throw ContentImportError.unsupportedDRM("encryption.xml") }
        }
        let container = try parse("META-INF/container.xml", as: .container)
        guard let root = container.rootfile else { throw ContentImportError.malformedArchive("Missing rootfile") }
        let opfPath = try EPUBArchive.normalizedPath(root)
        let opf = try parse(opfPath, as: .package)
        var titles = [String: String]()
        let nav = opf.items.first { $0.properties.contains("nav") }
        let ncx = opf.items.first { $0.id == opf.tocID } ?? opf.items.first { $0.mediaType == "application/x-dtbncx+xml" }
        for (item, kind) in [(nav, EPUBXML.Kind.navigation), (ncx, .ncx)] {
            guard let item else { continue }
            let path = try resolve(item.href, from: opfPath)
            for (href, title) in try parse(path, as: kind).links {
                let target = try resolve(href, from: path)
                if titles[target] == nil { titles[target] = title }
            }
        }
        var manifest = [String: EPUBXML.Item]()
        for item in opf.items {
            guard manifest.updateValue(item, forKey: item.id) == nil else {
                throw ContentImportError.malformedArchive("Duplicate OPF manifest ID")
            }
        }
        var text = ""
        var headings = [ChapterText.Heading]()
        var spinePaths = Set<String>()
        for id in opf.spine {
            guard let item = manifest[id] else { throw ContentImportError.malformedArchive("Unknown spine item: \(id)") }
            let path = try resolve(item.href, from: opfPath)
            guard spinePaths.insert(path).inserted else { throw ContentImportError.malformedArchive("Repeated spine document") }
            let page = try parse(path, as: .body)
            guard !page.paragraphs.isEmpty else { continue }
            if !text.isEmpty { text += "\n" }
            let title = titles[path] ?? page.heading ?? page.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            headings.append(.init(offset: text.utf8.count, title: title, path: path))
            text += page.paragraphs.joined(separator: "\n")
        }
        return ChapterText(text: text, headings: headings)
    }

    private static func resolve(_ reference: String, from file: String) throws -> String {
        let raw = reference.prefix(while: { $0 != "#" })
        if raw.isEmpty { return file }
        guard let decoded = raw.removingPercentEncoding else { throw ContentImportError.unsafeArchivePath(reference) }
        let path = decoded.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else {
            throw ContentImportError.unsafeArchivePath(reference)
        }
        var parts = Array(file.split(separator: "/").dropLast())
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                guard parts.popLast() != nil else { throw ContentImportError.unsafeArchivePath(reference) }
            } else { parts.append(part) }
        }
        return try EPUBArchive.normalizedPath(parts.joined(separator: "/"))
    }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    enum Kind { case container, package, encryption, navigation, ncx, body }
    struct Item {
        let id: String
        let href: String
        let properties: [Substring]
        let mediaType: String?
    }

    let kind: Kind
    var rootfile: String?
    var items = [Item]()
    var spine = [String]()
    var tocID: String?
    var encrypted = false
    var links = [(String, String)]()
    var title: String?
    var heading: String?
    var paragraphs = [String]()

    private var stack = [String]()
    private var skipDepth: Int?
    private var tocDepth: Int?
    private var href: String?
    private var points = [(href: String?, label: String?)]()
    private var capture: (tag: String, text: String)?
    private var paragraph = ""
    private var inBody = false
    private static let blocks: Set<String> = ["p","div","br","section","article","li","h1","h2","h3","h4","h5","h6",
                                               "blockquote","hr","tr","dt","dd","figcaption","pre","body"]

    init(_ kind: Kind) { self.kind = kind }

    static func read(_ data: Data, kind: Kind) throws -> EPUBXML {
        // EPUB XML resources are Unicode. Inspect the same decoded characters
        // that reach XMLParser, including documents with a UTF-16 declaration.
        let utf16: ExplicitTextEncoding? = data.starts(with: [0xff,0xfe]) || data.starts(with: [0x3c,0]) ? .utf16LE :
            (data.starts(with: [0xfe,0xff]) || data.starts(with: [0,0x3c]) ? .utf16BE : nil)
        var (xml, _) = try TextDecoder.decode(data, explicit: utf16 ?? .utf8)
        guard !xml.contains("\0"), xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw ContentImportError.malformedArchive("Unsafe XML declaration")
        }
        if xml.range(of: #"^<\?xml\s"#, options: .regularExpression) != nil,
           let end = xml.range(of: "?>") { xml.removeSubrange(..<end.upperBound) }
        let reader = EPUBXML(kind)
        let canonical = #"<?xml version="1.0" encoding="UTF-8"?>"# + xml
        let parser = XMLParser(data: Data(canonical.utf8))
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse(), parser.parserError == nil else { throw ContentImportError.malformedArchive("Invalid EPUB XML") }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement tag: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        let parent = stack.last
        stack.append(tag)
        if skipDepth != nil { return }
        switch kind {
        case .container:
            if tag == "rootfile", rootfile == nil { rootfile = attrs["full-path"] }
        case .encryption:
            if tag == "EncryptedData" { encrypted = true }
        case .package:
            if tag == "item", parent == "manifest", let id = attrs["id"], let href = attrs["href"] {
                items.append(Item(id: id, href: href, properties: (attrs["properties"] ?? "").split(whereSeparator: \.isWhitespace),
                                  mediaType: attrs["media-type"]))
            }
            if tag == "spine" { tocID = attrs["toc"] }
            if tag == "itemref", parent == "spine", attrs["linear"] != "no", let id = attrs["idref"] { spine.append(id) }
        case .navigation:
            if tag == "nav" {
                let type = attrs["epub:type"] ?? attrs["type"]
                if type?.split(separator: " ").contains("toc") ?? true { tocDepth = stack.count }
            }
            if tag == "a", tocDepth != nil { href = attrs["href"]; capture = (tag, "") }
        case .ncx:
            if tag == "navPoint" { points.append((nil, nil)) }
            if tag == "text", parent == "navLabel" { capture = (tag, "") }
            if tag == "content", !points.isEmpty { points[points.count - 1].href = attrs["src"] }
        case .body:
            if ["script", "style", "nav"].contains(tag) { skipDepth = stack.count; return }
            if tag == "title", parent == "head" { capture = (tag, "") }
            if tag == "body" { inBody = true }
            if inBody {
                if Self.blocks.contains(tag) { flushParagraph() }
                if tag == "h1", heading == nil { capture = (tag, "") }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == nil else { return }
        capture?.text.append(string)
        if inBody { paragraph.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let string = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement tag: String, namespaceURI: String?, qualifiedName: String?) {
        defer { stack.removeLast() }
        if let skipDepth {
            if skipDepth == stack.count { self.skipDepth = nil }
            return
        }
        if capture?.tag == tag, let value = capture {
            let label = Self.clean(value.text)
            if !label.isEmpty {
                switch tag {
                case "title": title = label
                case "h1": heading = label
                case "a": if let href { links.append((href, label)) }
                case "text": if !points.isEmpty { points[points.count - 1].label = label }
                default: break
                }
            }
            capture = nil
        }
        if kind == .ncx, tag == "navPoint", let point = points.popLast(), let src = point.href, let name = point.label {
            links.append((src, name))
        }
        if tag == "nav", stack.count == tocDepth { tocDepth = nil }
        if inBody, Self.blocks.contains(tag) { flushParagraph() }
        if tag == "body" { inBody = false }
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func flushParagraph() {
        let line = Self.clean(paragraph)
        if !line.isEmpty { paragraphs.append(line) }
        paragraph = ""
    }
}
