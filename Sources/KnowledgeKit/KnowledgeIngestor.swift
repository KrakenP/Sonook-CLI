import AudioCore
import CryptoKit
import Foundation

public enum KnowledgeError: Error, Equatable, Sendable {
    case invalidConfiguration, inputTooLarge, invalidUTF8, expectedLocalFile, emptySource
    case noEvidence, invalidEvidence, invalidEpisode
}

func knowledgeDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct KnowledgeIngestor: Sendable {
    private let store: any KnowledgeStoreProtocol
    private let maxChars: Int
    private let overlap: Int
    private let maxBytes: Int

    public init(store: any KnowledgeStoreProtocol, maxChars: Int = 600, overlap: Int = 80, maxBytes: Int = 4 * 1024 * 1024) {
        self.store = store
        self.maxChars = maxChars
        self.overlap = overlap
        self.maxBytes = maxBytes
    }

    private func validateConfiguration() throws {
        guard maxChars > 0, (0..<maxChars).contains(overlap), maxBytes > 0 else { throw KnowledgeError.invalidConfiguration }
    }

    @discardableResult
    public func ingest(file: URL, projectID: String, title: String? = nil, sourceID: String? = nil,
                       ingestedAt: Date = Date()) async throws -> KnowledgeSourceRecord {
        try validateConfiguration()
        guard file.isFileURL else { throw KnowledgeError.expectedLocalFile }
        let path = file.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw KnowledgeError.expectedLocalFile }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maxBytes) { throw KnowledgeError.inputTooLarge }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: min(64 * 1024, maxBytes - data.count) + 1), !part.isEmpty {
            guard part.count <= maxBytes - data.count else { throw KnowledgeError.inputTooLarge }
            data.append(part)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else { throw KnowledgeError.invalidUTF8 }
        return try await ingest(text: text, projectID: projectID, title: title ?? file.lastPathComponent, sourceID: sourceID,
                                sourceURI: file.standardizedFileURL.absoluteString, ingestedAt: ingestedAt)
    }

    @discardableResult
    public func ingest(text: String, projectID: String, title: String, sourceID: String? = nil,
                       sourceURI: String? = nil, ingestedAt: Date = Date()) async throws -> KnowledgeSourceRecord {
        try validateConfiguration()
        guard text.utf8.count <= maxBytes else { throw KnowledgeError.inputTooLarge }
        guard text.contains(where: { !$0.isWhitespace }) else { throw KnowledgeError.emptySource }
        let digest = knowledgeDigest(text)
        let uri = sourceURI ?? "urn:sha256:\(digest)"
        let id = sourceID ?? knowledgeDigest(uri)
        let chunks = try split(text, projectID: projectID, id: id, digest: digest)
        let source = KnowledgeSourceRecord(sourceID: id, projectID: projectID, title: title, sourceURI: uri,
                                           contentSHA256: digest, ingestedAtISO8601: ingestedAt.ISO8601Format(),
                                           chunkCount: chunks.count)
        try await store.upsertKnowledgeSource(source, chunks: chunks)
        return source
    }

    private func split(_ text: String, projectID: String, id: String, digest: String) throws -> [KnowledgeChunk] {
        var chunks: [KnowledgeChunk] = []
        var heading: String?
        var sectionStart = text.startIndex
        var paragraphs: [String.Index] = []
        func emitSection(to end: String.Index) throws {
            var start = sectionStart
            var previousEnd = start
            var paragraph = 0
            while start < end {
                let hardEnd = text.index(start, offsetBy: maxChars, limitedBy: end) ?? end
                var cut = hardEnd
                // Prefer a complete paragraph when it fits. Never emit a window entirely inside the previous one.
                while paragraph < paragraphs.count && paragraphs[paragraph] <= hardEnd {
                    if hardEnd < end && paragraphs[paragraph] > previousEnd { cut = paragraphs[paragraph] }
                    paragraph += 1
                }
                let slice = text[start..<cut]
                let lo = text.utf8.distance(from: text.startIndex, to: start)
                let hi = text.utf8.distance(from: text.startIndex, to: cut)
                chunks.append(.init(chunkID: "\(id):\(digest):\(lo)-\(hi)", sourceID: id, projectID: projectID,
                                    sequenceIndex: chunks.count, text: String(slice), sourceSpan: try .init(start: lo, endExclusive: hi),
                                    sectionHeading: heading, tokenEstimate: max(1, (slice.utf8.count + 3) / 4)))
                if cut == end { break }
                let next = text.index(cut, offsetBy: -overlap, limitedBy: start) ?? start
                start = next > start ? next : cut
                previousEnd = cut
            }
            sectionStart = end
            paragraphs.removeAll(keepingCapacity: true)
        }

        var lineStart = text.startIndex
        var afterBlank = false
        var paragraphStart: String.Index?
        var fence: (char: Character, count: Int)?
        while lineStart < text.endIndex {
            let end = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let raw = text[lineStart..<end]
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            let indented = raw.hasPrefix("    ") || raw.first == "\t"
            if let first = line.first, first == "`" || first == "~" {
                let markers = line.prefix(while: { $0 == first })
                if let open = fence {
                    if !indented, open.char == first, markers.count >= open.count,
                       line[markers.endIndex...].allSatisfy(\.isWhitespace) { fence = nil }
                } else if !indented, markers.count >= 3 { fence = (first, markers.count) }
                paragraphStart = nil
            } else if fence == nil, !indented, !line.isEmpty {
                let hashes = line.prefix(while: { $0 == "#" })
                let rest = line[hashes.endIndex...]
                if (1...6).contains(hashes.count), rest.isEmpty || rest.first?.isWhitespace == true {
                    try emitSection(to: lineStart)
                    heading = rest.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    paragraphStart = nil
                } else if let titleStart = paragraphStart, let marker = line.first, marker == "=" || marker == "-",
                          line.drop(while: { $0 == marker }).allSatisfy(\.isWhitespace) {
                    try emitSection(to: titleStart)
                    heading = text[titleStart..<lineStart].trimmingCharacters(in: .whitespacesAndNewlines)
                    paragraphStart = nil
                } else {
                    if afterBlank { paragraphs.append(lineStart) }
                    if paragraphStart == nil { paragraphStart = lineStart }
                }
            } else {
                paragraphStart = nil
            }
            afterBlank = line.isEmpty
            lineStart = end < text.endIndex ? text.index(after: end) : end
        }
        try emitSection(to: text.endIndex)
        return chunks
    }
}

public struct KnowledgeRetriever: Sendable {
    private let store: any KnowledgeStoreProtocol

    public init(store: any KnowledgeStoreProtocol) { self.store = store }

    public func search(projectID: String, query: String, limit: Int = 8) async throws -> [KnowledgeSearchHit] {
        try await store.searchKnowledge(projectID: projectID, query: query, limit: limit)
    }
}
