import Foundation

/// Per-character narrative state captured at the end of a specific chapter (`<= chapterNumber`).
public struct CharacterChapterState: Codable, Equatable, Sendable {
    public let characterID: String
    public let canonicalName: String
    public let statusSummary: String
    public let location: String?
    public let relationships: [String]
    public let lastSeenChapter: Int

    public init(
        characterID: String,
        canonicalName: String,
        statusSummary: String,
        location: String? = nil,
        relationships: [String] = [],
        lastSeenChapter: Int
    ) {
        self.characterID = characterID
        self.canonicalName = canonicalName
        self.statusSummary = statusSummary
        self.location = location
        self.relationships = relationships
        self.lastSeenChapter = lastSeenChapter
    }

    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case canonicalName = "canonical_name"
        case statusSummary = "status_summary"
        case location
        case relationships
        case lastSeenChapter = "last_seen_chapter"
    }
}

/// Spoiler-free, versioned chapter narrative memory persisted after analyzing a chapter.
/// Queries for chapter `N` must only read records with `chapterNumber < N` (or `<= N` for playback up to `N`).
public struct ChapterMemoryRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let chapterID: String
    public let chapterNumber: Int
    public let sourceDocumentRevision: String
    public let summary: String
    public let activeCharacterIDs: [String]
    public let characterStates: [CharacterChapterState]
    public let openThreads: [String]
    public let createdAtISO8601: String

    public init(
        projectID: String,
        chapterID: String,
        chapterNumber: Int,
        sourceDocumentRevision: String,
        summary: String,
        activeCharacterIDs: [String],
        characterStates: [CharacterChapterState] = [],
        openThreads: [String] = [],
        createdAtISO8601: String
    ) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.sourceDocumentRevision = sourceDocumentRevision
        self.summary = summary
        self.activeCharacterIDs = activeCharacterIDs
        self.characterStates = characterStates
        self.openThreads = openThreads
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case sourceDocumentRevision = "source_document_revision"
        case summary
        case activeCharacterIDs = "active_character_ids"
        case characterStates = "character_states"
        case openThreads = "open_threads"
        case createdAtISO8601 = "created_at"
    }
}

/// Storage protocol for spoiler-free cross-chapter narrative memory (`StorageKit` v3).
public protocol ChapterMemoryStoreProtocol: Sendable {
    func saveChapterMemory(_ memory: ChapterMemoryRecord) async throws
    func chapterMemory(projectID: String, chapterID: String) async throws -> ChapterMemoryRecord?
    /// Returns chapter memories ordered ascending by `chapterNumber`, strictly filtered to `chapterNumber <= maxChapterNumber`.
    func chapterMemoriesUpTo(projectID: String, maxChapterNumber: Int) async throws -> [ChapterMemoryRecord]
}
