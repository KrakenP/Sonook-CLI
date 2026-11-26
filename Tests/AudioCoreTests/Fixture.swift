import AudioCore
import Foundation
import Testing

struct GoldenFixture: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let segmentID: String
        let sourceSpan: SourceSpan
        let sourceText: String
        let speakerID: String
        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id", sourceSpan = "source_span", sourceText = "source_text", speakerID = "speaker_id"
        }
    }
    struct Chapter: Decodable, Sendable {
        let chapterID: String
        let title: String
        let sourceSpan: SourceSpan
        let segments: [Segment]
        enum CodingKeys: String, CodingKey { case chapterID = "chapter_id", title, sourceSpan = "source_span", segments }
    }
    let schemaVersion: Int
    let documentID: String
    let sourceDocumentRevision: String
    let sha256Hex: String
    let utf8ByteCount: Int
    let chapters: [Chapter]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", documentID = "document_id", sourceDocumentRevision = "source_document_revision"
        case sha256Hex = "sha256_hex", utf8ByteCount = "utf8_byte_count", chapters
    }

    static func load() throws -> (golden: Self, source: NormalizedSourceDocument) {
        func bytes(_ name: String, _ ext: String) throws -> Data {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            return try Data(contentsOf: url)
        }
        let fixture = try JSONDecoder().decode(Self.self, from: bytes("p0-unit-golden", "json"))
        return try (fixture, SourceNormalizer.normalize(data: bytes("p0-unit-sample", "txt"),
                                                        documentID: fixture.documentID, revision: fixture.sourceDocumentRevision))
    }

    func script(for chapter: Chapter) -> ScriptDocument {
        let segments = chapter.segments.map { s in
            ScriptSegment(segmentID: s.segmentID, chapterID: chapter.chapterID, sourceDocumentRevision: sourceDocumentRevision,
                          sourceSpan: s.sourceSpan, sourceText: s.sourceText, spokenText: s.sourceText, speakerID: s.speakerID,
                          voiceProfileRevision: s.speakerID + "-r1", scriptRevision: 1)
        }
        return .init(chapterID: chapter.chapterID, sourceDocumentRevision: sourceDocumentRevision,
                     scriptRevision: 1, segments: segments)
    }
}
