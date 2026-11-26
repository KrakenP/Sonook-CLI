import AudioCore

extension SQLiteWorkspaceStore {
    public func saveChapterMemory(_ memory: ChapterMemoryRecord) async throws {
        try db.transaction {
            try db.execute("""
                INSERT INTO chapter_memories(project_id, chapter_id, chapter_number, document) VALUES (?,?,?,?)
                ON CONFLICT(project_id, chapter_id) DO UPDATE SET chapter_number=excluded.chapter_number, document=excluded.document
                """, [memory.projectID, memory.chapterID, String(memory.chapterNumber), try encodedDocument(memory)])
        }
    }

    public func chapterMemory(projectID: String, chapterID: String) async throws -> ChapterMemoryRecord? {
        try db.query("SELECT document FROM chapter_memories WHERE project_id=? AND chapter_id=?", [projectID, chapterID]) {
            try $0.document(ChapterMemoryRecord.self)
        }.first
    }

    public func chapterMemoriesUpTo(projectID: String, maxChapterNumber: Int) async throws -> [ChapterMemoryRecord] {
        try db.query("""
            SELECT document FROM chapter_memories WHERE project_id=? AND chapter_number <= ?
            ORDER BY chapter_number ASC, chapter_id ASC
            """, [projectID, String(maxChapterNumber)]) { try $0.document(ChapterMemoryRecord.self) }
    }
}
