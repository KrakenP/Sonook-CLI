import AudioCore
import CryptoKit
import Darwin
import Foundation

extension SQLiteWorkspaceStore {
    private var assetsDirectory: URL { rootDirectory.appendingPathComponent("assets", isDirectory: true) }
    private var stagingDirectory: URL { rootDirectory.appendingPathComponent(".tmp", isDirectory: true) }

    private static func fileType(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard try fileType(url) == S_IFDIR else { throw WorkflowStoreError.storageFailure("Invalid workspace directory") }
    }

    // Stagers share the directory lock; GC takes it exclusively. This covers both the
    // live temp file and the rename-to-INSERT gap without holding SQLite's writer during I/O.
    private func withAssetLock<T>(_ mode: Int32, _ work: () throws -> T) throws -> T {
        let fd = open(stagingDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkflowStoreError.storageFailure("Cannot open staging directory") }
        defer { close(fd) }
        while flock(fd, mode) != 0 {
            if errno != EINTR { throw WorkflowStoreError.storageFailure("Cannot lock staging directory") }
        }
        return try work()
    }

    private static func validExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ url: URL) throws -> (hash: String, size: Int64) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
            count += Int64(chunk.count)
        }
        return (hex(hash.finalize()), count)
    }

    public func commitBytes(_ data: Data, projectID: String, kind: AssetKind, fileExtension: String,
                            sampleRate: Int?, frameCount: Int?, provenance: AssetProvenance) async throws -> AssetRecord {
        let ext = fileExtension.lowercased()
        guard Self.validExtension(ext) else { throw WorkflowStoreError.invalidStateTransition("Invalid file extension") }
        return try withAssetLock(LOCK_SH) {
            let id = UUID().uuidString
            let temp = stagingDirectory.appendingPathComponent("\(id).tmp")
            let handle = try Self.createTemp(at: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            try handle.write(contentsOf: data)
            guard fsync(handle.fileDescriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.close()

            let (hash, size) = try Self.digest(temp)
            guard size == data.count, hash == Self.hex(SHA256.hash(data: data)) else {
                throw WorkflowStoreError.assetIntegrityFailure(assetID: id, reason: "Staged bytes differ from input")
            }
            let relativePath = "assets/\(kind.rawValue)/\(hash).\(ext)"
            let destination = rootDirectory.appendingPathComponent(relativePath)
            try Self.ensureDirectory(assetsDirectory)
            try Self.ensureDirectory(destination.deletingLastPathComponent())
            // RENAME_EXCL is a same-volume atomic publish, including when two workers race on the same hash.
            if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard try Self.fileType(destination) == S_IFREG, try Self.digest(destination) == (hash, size) else {
                    throw WorkflowStoreError.assetIntegrityFailure(assetID: id, reason: "Existing content-addressed file is damaged")
                }
            }
            let record = AssetRecord(assetID: id, projectID: projectID, kind: kind, relativePath: relativePath,
                                     fileExtension: ext, fileSHA256: hash, byteSize: size, sampleRate: sampleRate,
                                     frameCount: frameCount, provenance: provenance, createdAtISO8601: timestamp(Date()))
            try db.transaction {
                try db.execute("INSERT INTO assets(asset_id, project_id, relative_path, document) VALUES (?,?,?,?)",
                               [id, projectID, relativePath, try encodedDocument(record)])
            }
            return record
        }
    }

    public func asset(id: String) async throws -> AssetRecord? {
        try readAsset(id)
    }

    public func listAssets(projectID: String, kind: AssetKind?) async throws -> [AssetRecord] {
        let all = try db.query("SELECT document FROM assets WHERE project_id=? ORDER BY asset_id", [projectID]) {
            try $0.document(AssetRecord.self)
        }
        guard let kind else { return all }
        return all.filter { $0.kind == kind }
    }

    private func readAsset(_ id: String) throws -> AssetRecord? {
        try db.query("SELECT document FROM assets WHERE asset_id=?", [id]) { try $0.document(AssetRecord.self) }.first
    }

    private func checkedURL(_ asset: AssetRecord) throws -> URL {
        let hash = asset.fileSHA256
        let ext = asset.fileExtension
        let expected = "assets/\(asset.kind.rawValue)/\(hash).\(ext)"
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.validExtension(ext), asset.relativePath == expected else {
            throw WorkflowStoreError.assetIntegrityFailure(assetID: asset.assetID, reason: "Invalid asset path")
        }
        let url = rootDirectory.appendingPathComponent(expected)
        for directory in [assetsDirectory, url.deletingLastPathComponent()] {
            if let type = try Self.fileType(directory), type != S_IFDIR {
                throw WorkflowStoreError.assetIntegrityFailure(assetID: asset.assetID, reason: "Invalid asset directory")
            }
        }
        if let type = try Self.fileType(url), type != S_IFREG {
            throw WorkflowStoreError.assetIntegrityFailure(assetID: asset.assetID, reason: "Invalid asset file")
        }
        return url
    }

    public func resolveFileURL(for assetID: String) async throws -> URL {
        guard let record = try readAsset(assetID) else { throw WorkflowStoreError.notFound(assetID) }
        return try checkedURL(record)
    }

    public func readVerifiedData(for assetID: String) async throws -> Data {
        guard let record = try readAsset(assetID) else {
            throw WorkflowStoreError.assetIntegrityFailure(assetID: assetID, reason: "Missing asset record")
        }
        let url = try checkedURL(record)
        guard let data = try? Data(contentsOf: url), data.count == record.byteSize,
              Self.hex(SHA256.hash(data: data)) == record.fileSHA256 else {
            throw WorkflowStoreError.assetIntegrityFailure(assetID: assetID, reason: "Missing or damaged asset")
        }
        return data
    }

    public func verifyAssetIntegrity(assetID: String) async throws -> Bool {
        guard let record = try readAsset(assetID) else { return false }
        return integrity(of: record) == .valid
    }

    private enum Integrity { case valid, missing, corrupt }

    private func integrity(of record: AssetRecord) -> Integrity {
        do {
            let url = try checkedURL(record)
            guard try Self.fileType(url) != nil else { return .missing }
            let digest = try Self.digest(url)
            return digest == (record.fileSHA256, record.byteSize) ? .valid : .corrupt
        } catch {
            return .corrupt
        }
    }

    public func runStartupReconciliation() async throws -> OrphanGCReport {
        try withAssetLock(LOCK_EX) {
            let tempCount = try removeUnreferenced(in: stagingDirectory, prefix: "", keeping: [])
            let (records, orphanCount) = try db.transaction {
                let records = try db.query("SELECT document, relative_path FROM assets ORDER BY asset_id") { row in
                    let record = try row.document(AssetRecord.self)
                    guard row.text(1) == record.relativePath else {
                        throw WorkflowStoreError.storageFailure("Inconsistent asset path in database")
                    }
                    return record
                }
                let caseSensitive = try assetsDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames == true
                let paths = Set(records.map { caseSensitive ? $0.relativePath : $0.relativePath.lowercased() })
                let removed = try removeUnreferenced(in: assetsDirectory, prefix: "assets/", keeping: paths,
                                                     caseSensitive: caseSensitive)
                return (records, removed)
            }
            var missing: [String] = []
            var corrupt: [String] = []
            for record in records {
                switch integrity(of: record) {
                case .valid: break
                case .missing: missing.append(record.assetID)
                case .corrupt: corrupt.append(record.assetID)
                }
            }
            return OrphanGCReport(removedTempFiles: tempCount, removedOrphanAssets: orphanCount,
                                  missingReferencedAssetIDs: missing, corruptedAssetIDs: corrupt)
        }
    }

    private func removeUnreferenced(in directory: URL, prefix: String, keeping paths: Set<String>,
                                    caseSensitive: Bool = true) throws -> Int {
        guard try Self.fileType(directory) == S_IFDIR else {
            throw WorkflowStoreError.storageFailure("Invalid workspace directory during reconciliation")
        }
        var count = 0
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent
            let path = prefix + (caseSensitive ? name : name.lowercased())
            if paths.contains(path) { continue }
            if try Self.fileType(child) == S_IFDIR {
                count += try removeUnreferenced(in: child, prefix: path + "/", keeping: paths, caseSensitive: caseSensitive)
            } else if !paths.contains(where: { $0.hasPrefix(path + "/") }) {
                try FileManager.default.removeItem(at: child)
                count += 1
            }
        }
        return count
    }

    private static func createTemp(at url: URL) throws -> FileHandle {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
