import AudioCore
import Foundation

extension SQLiteWorkspaceStore: SoundscapeStoreProtocol {
    public func saveSoundscapePlan(_ plan: ChapterSoundscapePlan, projectID: String) async throws {
        try db.execute("""
            INSERT INTO soundscape_plans(project_id, chapter_id, document) VALUES (?,?,?)
            ON CONFLICT(project_id, chapter_id) DO UPDATE SET document=excluded.document
            """, [projectID, plan.chapterID, try encodedDocument(plan)])
    }

    public func loadSoundscapePlan(projectID: String, chapterID: String) async throws -> ChapterSoundscapePlan? {
        try db.query("SELECT document FROM soundscape_plans WHERE project_id=? AND chapter_id=?", [projectID, chapterID]) {
            try $0.document(ChapterSoundscapePlan.self)
        }.first
    }

    public func listSoundscapePlans(projectID: String) async throws -> [ChapterSoundscapePlan] {
        try db.query("SELECT document FROM soundscape_plans WHERE project_id=? ORDER BY chapter_id", [projectID]) {
            try $0.document(ChapterSoundscapePlan.self)
        }
    }
}

extension SQLiteWorkspaceStore: KnowledgeStoreProtocol {
    public func upsertKnowledgeSource(_ source: KnowledgeSourceRecord, chunks: [KnowledgeChunk]) async throws {
        guard source.chunkCount == chunks.count else {
            throw WorkflowStoreError.storageFailure("Knowledge source chunk count mismatch")
        }
        let key = [source.projectID, source.sourceID]
        try db.transaction {
            try db.execute("""
                INSERT INTO knowledge_sources(project_id, source_id, document) VALUES (?,?,?)
                ON CONFLICT(project_id, source_id) DO UPDATE SET document=excluded.document
                """, key + [try encodedDocument(source)])
            try db.execute("DELETE FROM knowledge_chunks_fts WHERE project_id=? AND source_id=?", key)
            try db.execute("DELETE FROM knowledge_chunks WHERE project_id=? AND source_id=?", key)
            for chunk in chunks {
                guard chunk.projectID == source.projectID, chunk.sourceID == source.sourceID,
                      chunk.sourceSpan.endExclusive - chunk.sourceSpan.start == chunk.text.utf8.count else {
                    throw WorkflowStoreError.storageFailure("Knowledge chunk source or UTF-8 span mismatch")
                }
                try db.execute("""
                    INSERT INTO knowledge_chunks(project_id, source_id, chunk_id, sequence_index, text, document)
                    VALUES (?,?,?,?,?,?)
                    """, key + [chunk.chunkID, String(chunk.sequenceIndex), chunk.text, try encodedDocument(chunk)])
            }
            try db.execute("""
                INSERT INTO knowledge_chunks_fts(chunk_id, project_id, source_id, text)
                SELECT chunk_id, project_id, source_id, text FROM knowledge_chunks WHERE project_id=? AND source_id=?
                """, key)
        }
    }

    public func listKnowledgeSources(projectID: String) async throws -> [KnowledgeSourceRecord] {
        try db.query("SELECT document FROM knowledge_sources WHERE project_id=? ORDER BY source_id", [projectID]) {
            try $0.document(KnowledgeSourceRecord.self)
        }
    }

    public func loadKnowledgeChunks(projectID: String, sourceID: String? = nil) async throws -> [KnowledgeChunk] {
        try db.query("""
            SELECT document FROM knowledge_chunks WHERE project_id=?1 AND (?2 IS NULL OR source_id=?2)
            ORDER BY source_id, sequence_index, chunk_id
            """, [projectID, sourceID]) { try $0.document(KnowledgeChunk.self) }
    }

    public func savePodcastPlan(_ plan: PodcastEpisodePlan) async throws {
        try db.execute("""
            INSERT INTO podcast_plans(project_id, episode_id, document) VALUES (?,?,?)
            ON CONFLICT(project_id, episode_id) DO UPDATE SET document=excluded.document
            """, [plan.projectID, plan.episodeID, try encodedDocument(plan)])
    }

    public func loadPodcastPlan(projectID: String, episodeID: String) async throws -> PodcastEpisodePlan? {
        try db.query("SELECT document FROM podcast_plans WHERE project_id=? AND episode_id=?", [projectID, episodeID]) {
            try $0.document(PodcastEpisodePlan.self)
        }.first
    }

    public func listPodcastPlans(projectID: String) async throws -> [PodcastEpisodePlan] {
        try db.query("SELECT document FROM podcast_plans WHERE project_id=? ORDER BY episode_id", [projectID]) {
            try $0.document(PodcastEpisodePlan.self)
        }
    }
}
