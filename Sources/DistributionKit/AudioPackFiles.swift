import CryptoKit
import Darwin
import Foundation

public enum AudioPackError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case unsafePath(String)
    case sizeLimitExceeded
    case checksumMismatch(String)
    case invalidPack(String)
}

enum PackPath {
    static let core = ["manifest.json", "metadata.json", "timeline.json", "characters.json", "checksums.json"]

    // V1 publishes only chapter audio, transcripts, and the public sidecars in §11.2.
    static func check(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.utf8.contains(0), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              !path.lowercased().contains("voice_audition") else { throw AudioPackError.unsafePath(path) }
        if core.contains(path) || path == "artwork.jpg" || path == "references.json" { return }
        if parts.count == 2 {
            let ext = (String(parts[1]) as NSString).pathExtension
            if parts[0] == "chapters", ["m4a", "wav"].contains(ext) { return }
            if parts[0] == "transcripts", ext == "json" { return }
        }
        throw AudioPackError.unsafePath(path)
    }
}

func packDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// Pin the root for the whole inspection. Kernel-enforced no-follow applies to
/// intermediate components too, including when a directory is swapped mid-read.
struct PackDirectory {
    private let directory: FileHandle

    init(_ root: URL) throws {
        var path = root.path
        guard root.isFileURL, !path.utf8.contains(0) else { throw AudioPackError.unsafePath(root.absoluteString) }
        // A trailing slash can make open(2) follow a final symlink despite O_NOFOLLOW.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AudioPackError.unsafePath(root.lastPathComponent) }
        directory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func openFile(_ path: String) throws -> (handle: FileHandle, size: Int64) {
        try PackPath.check(path)
        let fd = openat(directory.fileDescriptor, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AudioPackError.unsafePath(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0 else { throw AudioPackError.unsafePath(path) }
        return (handle, info.st_size)
    }

    func fileSizes(maxFile: Int64, maxTotal: Int64) throws -> (files: [String: Int64], total: Int64) {
        var files: [String: Int64] = [:]
        var total: Int64 = 0
        func visit(_ folder: String) throws {
            let fd = openat(directory.fileDescriptor, folder.isEmpty ? "." : folder,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw AudioPackError.unsafePath(folder) }
            guard let stream = fdopendir(fd) else {
                close(fd)
                throw AudioPackError.invalidPack("Cannot enumerate pack")
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw AudioPackError.invalidPack("Cannot enumerate pack") }
                    break
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                    String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
                }
                guard let name else { throw AudioPackError.invalidPack("Non-UTF-8 filename") }
                if name == "." || name == ".." { continue }
                if folder.isEmpty && (name == "chapters" || name == "transcripts") {
                    try visit(name)
                    continue
                }
                let path = folder.isEmpty ? name : folder + "/" + name
                let file = try openFile(path)
                guard file.size <= maxFile, file.size <= maxTotal - total,
                      files.count < 100_000 else { throw AudioPackError.sizeLimitExceeded }
                guard files.updateValue(file.size, forKey: path) == nil else {
                    throw AudioPackError.invalidPack("Duplicate filename")
                }
                total += file.size
            }
        }
        guard maxFile >= 0, maxTotal >= 0 else { throw AudioPackError.sizeLimitExceeded }
        try visit("")
        return (files, total)
    }

    /// Reads exactly the inspected length, with bounded allocations even if the file grows.
    func read(_ path: String, size: Int64, collect: Bool = false) throws -> (data: Data, digest: String) {
        let file = try openFile(path)
        guard file.size == size else { throw AudioPackError.invalidPack("Changed file: \(path)") }
        var remaining = size
        var data = Data()
        var hash = SHA256()
        while remaining > 0 {
            let count = Int(min(remaining, 256 * 1024))
            guard let chunk = try file.handle.read(upToCount: count), !chunk.isEmpty else {
                throw AudioPackError.invalidPack("Truncated file: \(path)")
            }
            hash.update(data: chunk)
            if collect { data.append(chunk) }
            remaining -= Int64(chunk.count)
        }
        guard try file.handle.read(upToCount: 1)?.isEmpty != false else {
            throw AudioPackError.invalidPack("File grew: \(path)")
        }
        return (data, packDigest(hash.finalize()))
    }
}
