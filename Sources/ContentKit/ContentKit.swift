import AudioCore
import CryptoKit
import Foundation

public enum ContentImportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case encodingError(String)
    case ambiguousEncoding(String)
    case malformedArchive(String)
    case unsafeArchivePath(String)
    case archiveLimitExceeded(String)
    case unsupportedDRM(String)
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): return "Unsupported source format: \(f)"
        case .encodingError(let m): return "Encoding error: \(m)"
        case .ambiguousEncoding(let m): return "Ambiguous text encoding (specify --encoding explicitly): \(m)"
        case .malformedArchive(let m): return "Malformed EPUB archive: \(m)"
        case .unsafeArchivePath(let p): return "Unsafe archive path rejected: \(p)"
        case .archiveLimitExceeded(let m): return "Archive security limit exceeded: \(m)"
        case .unsupportedDRM(let m): return "Encrypted/DRM EPUB is not supported: \(m)"
        case .emptyContent: return "Imported source contains no readable text"
        }
    }
}

public enum ExplicitTextEncoding: String, Codable, CaseIterable, Sendable {
    case utf8 = "utf-8"
    case utf16LE = "utf-16le"
    case utf16BE = "utf-16be"
    case gb18030 = "gb18030"
}

public struct ImportedBook: Equatable, Sendable {
    public let format: SourceFormat
    public let detectedEncoding: String
    public let parserVersion: String
    public let normalizedText: String
    public let normalizedUTF8Data: Data
    public let normalizedSHA256: String
    public let chapters: [ChapterRecord]

    public init(
        format: SourceFormat,
        detectedEncoding: String,
        parserVersion: String,
        normalizedText: String,
        normalizedUTF8Data: Data,
        normalizedSHA256: String,
        chapters: [ChapterRecord]
    ) {
        self.format = format
        self.detectedEncoding = detectedEncoding
        self.parserVersion = parserVersion
        self.normalizedText = normalizedText
        self.normalizedUTF8Data = normalizedUTF8Data
        self.normalizedSHA256 = normalizedSHA256
        self.chapters = chapters
    }
}

public enum ContentImporter: Sendable {
    public static let parserVersion = "contentkit_v1"

    public static func detectFormat(fileName: String) throws -> SourceFormat {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "txt", "text": return .txt
        case "md", "markdown": return .markdown
        case "epub": return .epub
        default: throw ContentImportError.unsupportedFormat(fileName)
        }
    }

    public static func importData(
        _ rawData: Data,
        fileName: String,
        projectID: String,
        sourceDocumentRevision: String,
        explicitFormat: SourceFormat? = nil,
        explicitEncoding: ExplicitTextEncoding? = nil
    ) throws -> ImportedBook {
        let format = try explicitFormat ?? detectFormat(fileName: fileName)
        let book: ChapterText
        let encoding: String
        if format == .epub {
            book = try EPUBBook.read(rawData)
            encoding = "utf-8"
        } else {
            let decoded = try TextDecoder.decode(rawData, explicit: explicitEncoding)
            encoding = decoded.1
            book = ChapterText(source: decoded.0, markdown: format == .markdown)
        }
        let chapters = try book.records(fileName: fileName, projectID: projectID, revision: sourceDocumentRevision)
        let data = Data(book.text.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImportedBook(format: format, detectedEncoding: encoding, parserVersion: parserVersion,
                            normalizedText: book.text, normalizedUTF8Data: data, normalizedSHA256: digest, chapters: chapters)
    }
}
