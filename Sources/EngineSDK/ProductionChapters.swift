import AudioCore
import Darwin
import Foundation
import SQLite3

/// A production can contain the current book edition and multiple independently sourced episodes.
/// StorageKit's edition-scoped chapter API intentionally returns just one source revision.
extension SonookEngine {
    static let podcastParser = "podcast_transcript_v1"

    func lockChapterPublication() async throws -> FileHandle {
        // StorageKit replaces an edition's chapter list transactionally. Coordinate number allocation
        // and read-modify-write of identical transcripts across concurrent import and plan processes.
        let fd = open(workspaceRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            try await Task.sleep(for: .milliseconds(25))
        }
        return handle
    }

    private func readProductionRows<T: Decodable>(_ type: T.Type, projectID: String, sql: String) throws -> [T] {
        var db: OpaquePointer?
        let path = workspaceRoot.appendingPathComponent("sonook.sqlite").path
        let opened = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { throw WorkflowStoreError.storageFailure("Cannot read production chapters") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkflowStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
        return try projectID.withCString { id in
            guard sqlite3_bind_text(statement, 1, id, Int32(projectID.utf8.count), nil) == SQLITE_OK else {
                throw WorkflowStoreError.storageFailure("Cannot bind production project")
            }
            var results: [T] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let bytes = sqlite3_column_bytes(statement, 0)
                guard let value = sqlite3_column_blob(statement, 0) else {
                    throw WorkflowStoreError.storageFailure("Missing production record")
                }
                results.append(try JSONDecoder().decode(T.self, from: Data(bytes: value, count: Int(bytes))))
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw WorkflowStoreError.storageFailure(String(cString: sqlite3_errmsg(db))) }
            return results
        }
    }

    private static let currentBook = """
        SELECT * FROM source_documents WHERE project_id=?1
        AND json_extract(document,'$.parser_version') != '\(podcastParser)'
        ORDER BY imported_at DESC, source_document_revision DESC LIMIT 1
        """

    func currentBookSource(projectID: String) throws -> SourceDocumentRecord? {
        try readProductionRows(SourceDocumentRecord.self, projectID: projectID, sql:
            "SELECT document FROM (\(Self.currentBook))").first
    }

    func productionChapters(projectID: String) throws -> [ChapterRecord] {
        try readProductionRows(ChapterRecord.self, projectID: projectID, sql: """
            WITH book AS (\(Self.currentBook))
            SELECT c.document FROM chapters c WHERE c.project_id=?1 AND (
                c.source_document_revision=(SELECT source_document_revision FROM book)
                OR EXISTS (SELECT 1 FROM podcast_plans p WHERE p.project_id=c.project_id
                    AND p.episode_id=c.chapter_id
                    AND json_extract(p.document,'$.script_document.source_document_revision')=c.source_document_revision)
            ) ORDER BY c.chapter_number, c.chapter_id
            """)
    }

    func numberImportedChapters(_ chapters: [ChapterRecord], projectID: String) throws -> [ChapterRecord] {
        let published = try readProductionRows(ChapterRecord.self, projectID: projectID, sql: """
            SELECT c.document FROM chapters c JOIN podcast_plans p ON c.project_id=p.project_id AND c.chapter_id=p.episode_id
            WHERE c.project_id=?1 AND c.source_document_revision=json_extract(p.document,'$.script_document.source_document_revision')
            """)
        guard !published.isEmpty else { return chapters }
        let reservedIDs = Set(published.map(\.chapterID))
        let reservedNumbers = Set(published.map(\.chapterNumber))
        var prior = -1
        return try chapters.map { chapter in
            guard !reservedIDs.contains(chapter.chapterID) else {
                throw EngineSDKError.invalidInput("An existing podcast episode uses chapter ID \(chapter.chapterID)")
            }
            var number = max(chapter.chapterNumber, prior + 1)
            while reservedNumbers.contains(number) { number += 1 }
            prior = number
            return ChapterRecord(projectID: projectID, chapterID: chapter.chapterID, chapterNumber: number, title: chapter.title,
                                 sourceDocumentRevision: chapter.sourceDocumentRevision, sourceSpan: chapter.sourceSpan,
                                 originPath: chapter.originPath, originAnchor: chapter.originAnchor)
        }
    }

    func selectedProductionChapters(projectID: String, spec: String?) throws -> [ChapterRecord] {
        let chapters = try productionChapters(projectID: projectID)
        guard !chapters.isEmpty else { throw EngineSDKError.sourceNotImported(projectID) }
        return try ChapterSelection.select(from: chapters, spec: spec)
    }
}
