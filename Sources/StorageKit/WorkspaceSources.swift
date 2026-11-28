import AudioCore
import Foundation

extension SQLiteWorkspaceStore {
    public func saveSourceDocument(_ document: SourceDocumentRecord, chapters: [ChapterRecord]) async throws {
        let key = [document.projectID, document.sourceDocumentRevision]
        try db.transaction {
            try db.execute("""
                INSERT INTO source_documents(project_id,source_document_revision,imported_at,document) VALUES (?,?,?,?)
                ON CONFLICT(project_id,source_document_revision)
                DO UPDATE SET imported_at=excluded.imported_at, document=excluded.document
                """, key + [document.importedAtISO8601, try encodedDocument(document)])
            try db.execute("DELETE FROM chapters WHERE project_id=? AND source_document_revision=?", key)
            for chapter in chapters {
                guard chapter.projectID == document.projectID,
                      chapter.sourceDocumentRevision == document.sourceDocumentRevision else {
                    throw WorkflowStoreError.storageFailure("Chapter belongs to a different source document")
                }
                try db.execute("""
                    INSERT INTO chapters(project_id,source_document_revision,chapter_id,chapter_number,document)
                    VALUES (?,?,?,?,?)
                    """, key + [chapter.chapterID, String(chapter.chapterNumber), try encodedDocument(chapter)])
            }
        }
    }

    private static let latestRevision = """
        SELECT source_document_revision FROM source_documents WHERE project_id=?1
        ORDER BY imported_at DESC, source_document_revision DESC LIMIT 1
        """

    public func latestSourceDocument(projectID: String) async throws -> SourceDocumentRecord? {
        try db.query("""
            SELECT document FROM source_documents WHERE project_id=?1 AND source_document_revision=(\(Self.latestRevision))
            """, [projectID]) { try $0.document(SourceDocumentRecord.self) }.first
    }

    package func sourceDocument(projectID: String, revision: String) throws -> SourceDocumentRecord? {
        try db.query("SELECT document FROM source_documents WHERE project_id=? AND source_document_revision=?",
                     [projectID, revision]) { try $0.document(SourceDocumentRecord.self) }.first
    }

    public func listChapters(projectID: String, sourceDocumentRevision: String?) async throws -> [ChapterRecord] {
        try db.query("""
            SELECT document FROM chapters WHERE project_id=?1 AND source_document_revision=COALESCE(?2,(\(Self.latestRevision)))
            ORDER BY chapter_number, chapter_id
            """, [projectID, sourceDocumentRevision]) { try $0.document(ChapterRecord.self) }
    }

    /// The guard needs future titles, but only chapters inside the boundary are decoded as records.
    fileprivate func readContextChapters(projectID: String, maxChapterNumber: Int) throws -> (allowed: [ChapterRecord], futureTitles: [String]) {
        let scope = "project_id=?1 AND source_document_revision=(\(Self.latestRevision))"
        let values = [projectID, String(maxChapterNumber)]
        return try db.transaction(readOnly: true) {
            let allowed = try db.query("""
                SELECT document FROM chapters WHERE \(scope) AND chapter_number<=?2 ORDER BY chapter_number, chapter_id
                """, values) { try $0.document(ChapterRecord.self) }
            let titles = try db.query("""
                SELECT json_extract(document, '$.title') FROM chapters WHERE \(scope) AND chapter_number>?2
                """, values) { $0.text(0) }
            return (allowed, titles)
        }
    }

    public func chapter(projectID: String, chapterID: String) async throws -> ChapterRecord? {
        try db.query("""
            SELECT document FROM chapters WHERE project_id=?1 AND chapter_id=?2 AND source_document_revision=(\(Self.latestRevision))
            """, [projectID, chapterID]) { try $0.document(ChapterRecord.self) }.first
    }

    public func saveSegmentApproval(_ approval: SegmentApprovalRecord) async throws {
        try db.execute("""
            INSERT INTO segment_approvals(project_id,chapter_id,segment_id,approved_asset_id,document) VALUES (?,?,?,?,?)
            ON CONFLICT(project_id,chapter_id,segment_id)
            DO UPDATE SET approved_asset_id=excluded.approved_asset_id, document=excluded.document
            """, [approval.projectID, approval.chapterID, approval.segmentID, approval.approvedAssetID, try encodedDocument(approval)])
    }

    public func segmentApprovals(projectID: String, chapterID: String) async throws -> [SegmentApprovalRecord] {
        try db.query("""
            SELECT document FROM segment_approvals WHERE project_id=? AND chapter_id=? ORDER BY segment_id
            """, [projectID, chapterID]) { try $0.document(SegmentApprovalRecord.self) }
    }
}

public extension WorkspaceStoreProtocol {
    func contextChapters(projectID: String, maxChapterNumber: Int) async throws -> (allowed: [ChapterRecord], futureTitles: [String]) {
        if let sqlite = self as? SQLiteWorkspaceStore {
            return try await sqlite.readContextChapters(projectID: projectID, maxChapterNumber: maxChapterNumber)
        }
        // Other stores expose chapter metadata through the index. Never enumerate their scripts or memories here.
        let index = try await listChapters(projectID: projectID, sourceDocumentRevision: nil)
        return (index.filter { $0.chapterNumber <= maxChapterNumber }, index.filter { $0.chapterNumber > maxChapterNumber }.map(\.title))
    }
}
