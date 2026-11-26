import AudioCore
import CryptoKit
import Darwin
import Foundation

enum ReleaseMedia {
    static func response(
        workspace: URL, release: PublishedReleaseRecord, path: [String], range: String?, ifRange: String?
    ) throws -> HTTPResponse {
        let pack = release.packRelativePath.components(separatedBy: "/")
        guard pack.allSatisfy(HTTPRequest.isSafeComponent), path.allSatisfy(HTTPRequest.isSafeComponent),
              let filename = path.last else { throw HTTPStatus.forbidden }

        // Pin each directory while opening its child. A rename or symlink swap between checks
        // cannot redirect an open relative to this descriptor.
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        var directory = open(workspace.path, directoryFlags)
        guard directory >= 0 else { throw HTTPStatus.internalError }
        defer { close(directory) }
        for component in pack + path.dropLast() {
            let child = openat(directory, component, directoryFlags | O_NOFOLLOW)
            guard child >= 0 else { throw fileError(errno) }
            close(directory)
            directory = child
        }
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fileError(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0
        else { throw HTTPStatus.forbidden }
        let size = UInt64(info.st_size)
        var headers = ["Accept-Ranges": "bytes"]
        let requested = range.flatMap { byteRange($0, size: size) }
        func unsatisfiable() -> HTTPResponse {
            HTTPResponse(status: .rangeNotSatisfiable, headers: ["Accept-Ranges": "bytes", "Content-Range": "bytes */\(size)"])
        }
        if range != nil && requested == nil && ifRange == nil { return unsatisfiable() }

        var hash = SHA256()
        while let data = try handle.read(upToCount: 128 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let etag = "\"" + hash.finalize().map { String(format: "%02x", $0) }.joined() + "\""
        headers["ETag"] = etag
        let partial = range != nil && (ifRange == nil || ifRange == etag)
        var selected = 0..<size
        if partial {
            guard let requested else { return unsatisfiable() }
            selected = requested
            headers["Content-Range"] = "bytes \(selected.lowerBound)-\(selected.upperBound - 1)/\(size)"
        }
        headers["Content-Type"] = switch (filename as NSString).pathExtension.lowercased() {
        case "json": "application/json"
        case "m4a", "m4b": "audio/mp4"
        default: "application/octet-stream"
        }
        try handle.seek(toOffset: selected.lowerBound)
        return HTTPResponse(status: partial ? .partialContent : .ok, headers: headers,
                            body: .file(handle, length: selected.upperBound - selected.lowerBound))
    }

    private static func fileError(_ code: Int32) -> HTTPStatus {
        switch code {
        case ENOENT: .notFound
        case ELOOP, ENOTDIR, EACCES, EPERM: .forbidden
        default: .internalError
        }
    }

    private static func byteRange(_ value: String, size: UInt64) -> Range<UInt64>? {
        guard size > 0, value.prefix(6).lowercased() == "bytes=" else { return nil }
        let bounds = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        func number(_ part: Substring) -> UInt64? {
            guard part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(part)
        }
        if bounds[0].isEmpty {
            guard let count = number(bounds[1]), count > 0 else { return nil }
            return (size - min(count, size))..<size
        }
        guard let start = number(bounds[0]), start < size else { return nil }
        if bounds[1].isEmpty { return start..<size }
        guard let end = number(bounds[1]), end >= start else { return nil }
        return start..<(min(end, size - 1) + 1)
    }
}
