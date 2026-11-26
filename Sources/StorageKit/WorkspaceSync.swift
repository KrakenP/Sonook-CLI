import AudioCore

extension SQLiteWorkspaceStore: SyncStoreProtocol {
    public func appendPlaybackEvent(_ event: PlaybackEvent) async throws -> Bool {
        try db.execute("""
            INSERT OR IGNORE INTO playback_events(device_id, event_id, project_id, occurred_at, device_sequence, document)
            VALUES (?,?,?,?,?,?)
            """, [event.deviceID, event.eventID, event.projectID, event.occurredAtISO8601, String(event.deviceSequence), try encodedDocument(event)]) == 1
    }

    public func listPlaybackEvents(projectID: String, limit: Int) async throws -> [PlaybackEvent] {
        try db.query("""
            SELECT document FROM playback_events WHERE project_id=?
            ORDER BY occurred_at DESC, device_id, device_sequence DESC, event_id LIMIT ?
            """, [projectID, String(max(0, limit))]) { try $0.document(PlaybackEvent.self) }
    }

    public func savePlaybackCursor(_ cursor: PlaybackCursor) async throws {
        try db.execute("""
            INSERT INTO playback_cursors(project_id, updated_at, document) VALUES (?,?,?)
            ON CONFLICT(project_id) DO UPDATE SET updated_at=excluded.updated_at, document=excluded.document
            """, [cursor.projectID, cursor.updatedAtISO8601, try encodedDocument(cursor)])
    }

    public func loadPlaybackCursor(projectID: String) async throws -> PlaybackCursor? {
        try db.query("SELECT document FROM playback_cursors WHERE project_id=?", [projectID]) { try $0.document(PlaybackCursor.self) }.first
    }

    public func saveInteraction(_ record: InteractionRecord) async throws {
        try db.execute("""
            INSERT INTO interactions(interaction_id, project_id, created_at, document) VALUES (?,?,?,?)
            ON CONFLICT(interaction_id) DO UPDATE SET project_id=excluded.project_id, created_at=excluded.created_at, document=excluded.document
            """, [record.interactionID, record.projectID, record.createdAtISO8601, try encodedDocument(record)])
    }

    public func listInteractions(projectID: String, limit: Int) async throws -> [InteractionRecord] {
        try db.query("SELECT document FROM interactions WHERE project_id=? ORDER BY created_at DESC, interaction_id LIMIT ?",
                     [projectID, String(max(0, limit))]) { try $0.document(InteractionRecord.self) }
    }
}
