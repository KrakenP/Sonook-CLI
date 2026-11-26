import CryptoKit
import Foundation

public enum TextEncodingDetected: String, Codable, Sendable {
    case utf8, utf8BOM = "utf8_bom", utf16LE = "utf16_le", utf16BE = "utf16_be"
}

public struct NormalizedSourceDocument: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let documentID: String
    public let revision: String
    public let sha256Hex: String
    public let detectedEncoding: TextEncodingDetected
    public let canonicalUTF8Text: String
    public let utf8ByteCount: Int

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", documentID = "document_id", revision
        case sha256Hex = "sha256_hex", detectedEncoding = "detected_encoding"
        case canonicalUTF8Text = "canonical_utf8_text", utf8ByteCount = "utf8_byte_count"
    }

    fileprivate init(documentID: String, revision: String, encoding: TextEncodingDetected, text: String) {
        self.documentID = documentID
        self.revision = revision
        self.detectedEncoding = encoding
        self.canonicalUTF8Text = text
        let bytes = Data(text.utf8)
        self.utf8ByteCount = bytes.count
        self.sha256Hex = sha256Digest(bytes)
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        _ = try fields.decode(SchemaVersion.self, forKey: .version)
        try self.init(documentID: fields.decode(String.self, forKey: .documentID),
                      revision: fields.decode(String.self, forKey: .revision),
                      encoding: fields.decode(TextEncodingDetected.self, forKey: .detectedEncoding),
                      text: fields.decode(String.self, forKey: .canonicalUTF8Text))
        guard try fields.decode(String.self, forKey: .sha256Hex) == sha256Hex,
              try fields.decode(Int.self, forKey: .utf8ByteCount) == utf8ByteCount,
              !canonicalUTF8Text.utf8.contains(13) else {
            throw DecodingError.dataCorruptedError(forKey: .canonicalUTF8Text, in: fields,
                                                   debugDescription: "Inconsistent canonical source bytes")
        }
    }
}

func sha256Digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum SourceNormalizationError: Error, Sendable {
    case invalidEncoding
}

public enum SourceNormalizer: Sendable {
    /// A BOM is authoritative. For unmarked input prefer ordinary UTF-8; a hint
    /// resolves byte sequences that are legal text in more than one encoding.
    public static func normalize(data: Data, documentID: String, revision: String,
                                 encodingHint: TextEncodingDetected? = nil) throws -> NormalizedSourceDocument {
        let markers: [(TextEncodingDetected, [UInt8])] = [
            (.utf8BOM, [0xEF, 0xBB, 0xBF]), (.utf16LE, [0xFF, 0xFE]), (.utf16BE, [0xFE, 0xFF])
        ]
        let marker = markers.first { data.starts(with: $0.1) }
        let bytes = data.dropFirst(marker?.1.count ?? 0)
        let encoding: TextEncodingDetected
        let decoded: String
        if let specified = marker?.0 ?? encodingHint {
            guard let text = decode(bytes, as: specified) else { throw SourceNormalizationError.invalidEncoding }
            encoding = specified == .utf8BOM && marker == nil ? .utf8 : specified
            decoded = text
        } else if !bytes.contains(0), let text = decode(bytes, as: .utf8) {
            encoding = .utf8
            decoded = text
        } else {
            // ASCII/newline lanes, Han text and Chinese punctuation distinguish
            // most unmarked chapter files. Prefer LE for equally plausible UTF-16.
            let candidates = [TextEncodingDetected.utf16LE, .utf16BE, .utf8].compactMap { encoding in
                decode(bytes, as: encoding).map { (encoding, $0, plausibility($0)) }
            }
            guard let best = candidates.max(by: { $0.2 < $1.2 }) else {
                throw SourceNormalizationError.invalidEncoding
            }
            (encoding, decoded, _) = best
        }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return NormalizedSourceDocument(documentID: documentID, revision: revision, encoding: encoding, text: text)
    }

    private static func decode(_ bytes: Data, as encoding: TextEncodingDetected) -> String? {
        switch encoding {
        case .utf8, .utf8BOM:
            let text = String(decoding: bytes, as: UTF8.self)
            return text.utf8.elementsEqual(bytes) ? text : nil
        case .utf16BE, .utf16LE:
            guard bytes.count.isMultiple(of: 2) else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var iterator = bytes.makeIterator()
            while let a = iterator.next(), let b = iterator.next() {
                let (hi, lo) = encoding == .utf16BE ? (a, b) : (b, a)
                units.append(UInt16(hi) << 8 | UInt16(lo))
            }
            let text = String(decoding: units, as: UTF16.self)
            return text.utf16.elementsEqual(units) ? text : nil
        }
    }

    private static func plausibility(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { score, scalar in
            switch scalar.value {
            case 9, 10, 13, 32...126, 0x3000...0x303F, 0xFF01...0xFF60: score + 5
            case 0x4E00...0x9FFF: score + 2
            case 0...31, 127...159, 0xE000...0xF8FF, 0xFFFE...0xFFFF: score - 12
            default: score
            }
        }
    }
}

public struct ChapterSlice: Equatable, Sendable {
    public let chapterID: String
    public let title: String
    public let sourceDocumentRevision: String
    public let sourceSpan: SourceSpan
    public let text: String

    public init(chapterID: String, title: String, sourceDocumentRevision: String, sourceSpan: SourceSpan, text: String) {
        self.chapterID = chapterID
        self.title = title
        self.sourceDocumentRevision = sourceDocumentRevision
        self.sourceSpan = sourceSpan
        self.text = text
    }
}

public enum ChapterExtractor: Sendable {
    /// A preface before the first heading gets its own slice so every byte survives extraction.
    public static func extractChapters(from source: NormalizedSourceDocument) -> [ChapterSlice] {
        let text = source.canonicalUTF8Text
        var headings: [(offset: Int, title: String)] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("第"), line.prefixMatch(of: /^第[零一二三四五六七八九十百千万两0-9]+章/) != nil {
                headings.append((offset, String(line)))
            }
            offset += line.utf8.count + 1
        }
        if headings.first?.offset != 0 {
            headings.insert((0, headings.isEmpty ? "全文" : "序"), at: 0)
        }
        return headings.enumerated().map { index, heading in
            let end = index + 1 < headings.count ? headings[index + 1].offset : source.utf8ByteCount
            // Both endpoints were counted from complete lines in this very string.
            let span = try! SourceSpan(start: heading.offset, endExclusive: end)
            return ChapterSlice(chapterID: "ch_" + String(format: "%03d", index + 1), title: heading.title,
                                sourceDocumentRevision: source.revision, sourceSpan: span, text: try! span.slice(in: text))
        }
    }
}
