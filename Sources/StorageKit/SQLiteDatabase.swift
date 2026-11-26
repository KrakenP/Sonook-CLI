import AudioCore
import Foundation
import SQLite3

/// A connection belongs to a single workspace actor. Statements never escape a synchronous transaction.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(file: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw WorkflowStoreError.storageFailure("Cannot open workspace database")
        }
        handle = connection
        try executeScript("PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try transaction {
            try executeScript("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY)")
            let versions = try query("SELECT version FROM schema_migrations ORDER BY version") { $0.integer(0) }
            let migrations = [Self.schemaV1, Self.schemaV2, Self.schemaV3, Self.schemaV4, Self.schemaV5]
            // Historical workspaces can start at a later baseline, but never skip a version after it.
            let current = versions.last ?? 0
            if let first = versions.first {
                guard first >= 1, current <= migrations.count, versions.count == current - first + 1 else {
                    throw WorkflowStoreError.storageFailure("Unsupported workspace schema")
                }
            }
            for index in current..<migrations.count {
                try executeScript(migrations[index])
                try execute("INSERT INTO schema_migrations(version) VALUES (?)", [String(index + 1)])
            }
        }
    }

    deinit { sqlite3_close(handle) }

    private func failure() -> WorkflowStoreError {
        .storageFailure(String(cString: sqlite3_errmsg(handle)))
    }

    private func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    @discardableResult
    func transaction<T>(readOnly: Bool = false, _ work: () throws -> T) throws -> T {
        try executeScript(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let result = try work()
            try executeScript("COMMIT")
            return result
        } catch {
            try executeScript("ROLLBACK")
            throw error
        }
    }

    func query<T>(_ sql: String, _ values: [String?] = [], _ decode: (SQLiteRow) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == values.count else {
            throw WorkflowStoreError.storageFailure("SQL parameter count mismatch")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = value.map { string in
                string.withCString {
                    sqlite3_bind_text64(statement, index, $0, UInt64(string.utf8.count),
                                        unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
                }
            } ?? sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try decode(SQLiteRow(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    @discardableResult
    func execute(_ sql: String, _ values: [String?] = []) throws -> Int {
        _ = try query(sql, values) { _ in () }
        return Int(sqlite3_changes(handle))
    }

    private static let schemaV1 = """
        CREATE TABLE projects(project_id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL);
        CREATE TABLE models(model_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE voice_catalogs(project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects, document TEXT NOT NULL);
        CREATE TABLE scripts(project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL,
                            document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id));
        CREATE TABLE assets(asset_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects,
                            relative_path TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE jobs(
            job_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects, workflow_kind TEXT NOT NULL,
            status TEXT NOT NULL, priority INTEGER NOT NULL, cancel_requested INTEGER NOT NULL,
            config_json TEXT NOT NULL, summary TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE job_nodes(
            job_id TEXT NOT NULL REFERENCES jobs, node_id TEXT NOT NULL, kind TEXT NOT NULL,
            status TEXT NOT NULL, priority INTEGER NOT NULL, input_fingerprint TEXT NOT NULL, payload_json TEXT NOT NULL,
            attempt_count INTEGER NOT NULL, max_attempts INTEGER NOT NULL, next_retry_at TEXT, lease_owner TEXT,
            lease_generation INTEGER NOT NULL, lease_expires_at TEXT, output_asset_id TEXT REFERENCES assets,
            output_payload_json TEXT, last_error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY(job_id, node_id)
        );
        CREATE TABLE job_edges(
            job_id TEXT NOT NULL, from_node_id TEXT NOT NULL, to_node_id TEXT NOT NULL, requires_verified INTEGER NOT NULL,
            PRIMARY KEY(job_id, from_node_id, to_node_id),
            FOREIGN KEY(job_id, from_node_id) REFERENCES job_nodes(job_id, node_id),
            FOREIGN KEY(job_id, to_node_id) REFERENCES job_nodes(job_id, node_id)
        );
        CREATE INDEX nodes_by_status ON job_nodes(job_id, status, priority DESC, created_at, node_id);
        CREATE INDEX incoming_edges ON job_edges(job_id, to_node_id);
        """

    private static let schemaV2 = """
        CREATE TABLE source_documents(
            project_id TEXT NOT NULL REFERENCES projects, source_document_revision TEXT NOT NULL,
            imported_at TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, source_document_revision)
        );
        CREATE TABLE chapters(
            project_id TEXT NOT NULL REFERENCES projects, source_document_revision TEXT NOT NULL,
            chapter_id TEXT NOT NULL, chapter_number INTEGER NOT NULL, document TEXT NOT NULL,
            PRIMARY KEY(project_id, source_document_revision, chapter_id)
        );
        CREATE TABLE segment_approvals(
            project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL, segment_id TEXT NOT NULL,
            approved_asset_id TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id, segment_id)
        );
        CREATE INDEX newest_source ON source_documents(project_id, imported_at DESC, source_document_revision DESC);
        CREATE INDEX ordered_chapters ON chapters(project_id, source_document_revision, chapter_number, chapter_id);
        """

    private static let schemaV3 = """
        CREATE TABLE chapter_memories(
            project_id TEXT NOT NULL REFERENCES projects, chapter_id TEXT NOT NULL,
            chapter_number INTEGER NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id)
        );
        CREATE INDEX chapter_memories_by_number ON chapter_memories(project_id, chapter_number ASC, chapter_id);
        """

    private static let schemaV4 = """
        CREATE TABLE soundscape_plans(project_id TEXT NOT NULL, chapter_id TEXT NOT NULL,
            document TEXT NOT NULL, PRIMARY KEY(project_id, chapter_id));
        CREATE TABLE knowledge_sources(project_id TEXT NOT NULL, source_id TEXT NOT NULL,
            document TEXT NOT NULL, PRIMARY KEY(project_id, source_id));
        CREATE TABLE knowledge_chunks(project_id TEXT NOT NULL, source_id TEXT NOT NULL, chunk_id TEXT NOT NULL,
            sequence_index INTEGER NOT NULL, text TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(project_id, chunk_id));
        CREATE INDEX chunks_by_source ON knowledge_chunks(project_id, source_id, sequence_index);
        CREATE VIRTUAL TABLE knowledge_chunks_fts USING fts5(chunk_id UNINDEXED, project_id UNINDEXED,
            source_id UNINDEXED, text, tokenize='unicode61');
        CREATE TABLE podcast_plans(project_id TEXT NOT NULL, episode_id TEXT NOT NULL,
            document TEXT NOT NULL, PRIMARY KEY(project_id, episode_id));
        """

    private static let schemaV5 = """
        CREATE TABLE published_releases(release_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL,
            release_version INTEGER NOT NULL, created_at TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE pairing_challenges(challenge_id TEXT PRIMARY KEY NOT NULL, expires_at TEXT NOT NULL,
            consumed_at TEXT, document TEXT NOT NULL);
        CREATE TABLE paired_devices(device_id TEXT PRIMARY KEY NOT NULL, token_hash_sha256 TEXT NOT NULL UNIQUE,
            revoked_at TEXT, document TEXT NOT NULL);
        CREATE TABLE playback_events(device_id TEXT NOT NULL, event_id TEXT NOT NULL, project_id TEXT NOT NULL,
            occurred_at TEXT NOT NULL, device_sequence INTEGER NOT NULL, document TEXT NOT NULL, PRIMARY KEY(device_id, event_id));
        CREATE INDEX playback_events_by_project ON playback_events(project_id, occurred_at DESC, device_id, device_sequence DESC, event_id);
        CREATE TABLE playback_cursors(project_id TEXT PRIMARY KEY NOT NULL, updated_at TEXT NOT NULL, document TEXT NOT NULL);
        CREATE INDEX releases_by_project ON published_releases(project_id, release_version DESC, release_id);
        CREATE TABLE interactions(interaction_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, created_at TEXT NOT NULL, document TEXT NOT NULL);
        CREATE INDEX interactions_by_project ON interactions(project_id, created_at DESC, interaction_id);
        """
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func optionalText(_ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))),
                      as: UTF8.self)
    }

    func text(_ index: Int32) -> String { optionalText(index) ?? "" }
    func integer(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

    func document<T: Decodable>(_ type: T.Type, at index: Int32 = 0) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text(index).utf8))
    }
}

func encodedDocument(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
}
