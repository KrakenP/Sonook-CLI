import AudioCore
import Foundation

public enum StorageKitInfo: Sendable {
    public static let schemaVersion = 5
}

public actor SQLiteWorkspaceStore: WorkspaceStoreProtocol {
    public nonisolated let rootDirectory: URL
    let db: SQLiteDatabase

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        for name in [SonookWorkspaceLayout.outputsFolderName, SonookWorkspaceLayout.assetsFolderName, SonookWorkspaceLayout.tempFolderName] {
            try Self.ensureDirectory(rootDirectory.appendingPathComponent(name))
        }
        db = try SQLiteDatabase(file: rootDirectory.appendingPathComponent("sonook.sqlite"))
    }

    public func saveProject(_ project: ProjectRecord) async throws {
        try db.transaction {
            try db.execute("""
                INSERT INTO projects(project_id, document) VALUES (?,?)
                ON CONFLICT(project_id) DO UPDATE SET document=excluded.document
                """, [project.projectID, try encodedDocument(project)])
        }
    }

    public func project(id: String) async throws -> ProjectRecord? {
        try db.query("SELECT document FROM projects WHERE project_id=?", [id]) { try $0.document(ProjectRecord.self) }.first
    }

    public func listProjects() async throws -> [ProjectRecord] {
        try db.query("SELECT document FROM projects ORDER BY project_id") { try $0.document(ProjectRecord.self) }
    }

    public func upsertModel(_ entry: ModelRegistryEntry) async throws {
        try db.transaction { try writeModel(entry) }
    }

    private func writeModel(_ entry: ModelRegistryEntry) throws {
        try db.execute("""
            INSERT INTO models(model_id, kind, document) VALUES (?,?,?)
            ON CONFLICT(model_id) DO UPDATE SET kind=excluded.kind, document=excluded.document
            """, [entry.modelID, entry.kind.rawValue, try encodedDocument(entry)])
    }

    private func readModel(_ id: String) throws -> ModelRegistryEntry? {
        try db.query("SELECT document FROM models WHERE model_id=?", [id]) { try $0.document(ModelRegistryEntry.self) }.first
    }

    public func model(id: String) async throws -> ModelRegistryEntry? { try readModel(id) }

    public func listModels(kind: ModelKind?) async throws -> [ModelRegistryEntry] {
        try db.query("SELECT document FROM models WHERE (?1 IS NULL OR kind=?1) ORDER BY model_id", [kind?.rawValue]) {
            try $0.document(ModelRegistryEntry.self)
        }
    }

    public func updateMeasuredPeakBytes(modelID: String, peakBytes: UInt64) async throws {
        try db.transaction {
            guard var entry = try readModel(modelID) else { throw WorkflowStoreError.notFound(modelID) }
            entry.measuredPeakBytes = peakBytes
            try writeModel(entry)
        }
    }

    public func saveCatalog(_ catalog: CharacterVoiceCatalog) async throws {
        try db.transaction {
            try db.execute("""
                INSERT INTO voice_catalogs(project_id, document) VALUES (?,?)
                ON CONFLICT(project_id) DO UPDATE SET document=excluded.document
                """, [catalog.projectID, try encodedDocument(catalog)])
        }
    }

    public func loadCatalog(projectID: String) async throws -> CharacterVoiceCatalog? {
        try db.query("SELECT document FROM voice_catalogs WHERE project_id=?", [projectID]) {
            try $0.document(CharacterVoiceCatalog.self)
        }.first
    }

    public func saveScript(_ script: ScriptDocument, projectID: String) async throws {
        try db.transaction {
            try db.execute("""
                INSERT INTO scripts(project_id, chapter_id, document) VALUES (?,?,?)
                ON CONFLICT(project_id, chapter_id) DO UPDATE SET document=excluded.document
                """, [projectID, script.chapterID, try encodedDocument(script)])
        }
    }

    public func loadScript(projectID: String, chapterID: String) async throws -> ScriptDocument? {
        try db.query("SELECT document FROM scripts WHERE project_id=? AND chapter_id=?", [projectID, chapterID]) {
            try $0.document(ScriptDocument.self)
        }.first
    }

    public func listScripts(projectID: String) async throws -> [ScriptDocument] {
        try db.query("SELECT document FROM scripts WHERE project_id=? ORDER BY chapter_id", [projectID]) {
            try $0.document(ScriptDocument.self)
        }
    }

    public func locateSegment(projectID: String, segmentID: String) async throws -> LocatedSegment? {
        for script in try await listScripts(projectID: projectID) {
            if let seg = script.segments.first(where: { $0.segmentID == segmentID }) {
                return LocatedSegment(chapterID: script.chapterID, segment: seg)
            }
        }
        return nil
    }

}
