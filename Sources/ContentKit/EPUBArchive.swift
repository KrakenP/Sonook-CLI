import Compression
import Foundation

/// EPUB's single-disk ZIP container. Offsets are validated against the enclosing
/// record before any variable-length field or compressed payload is accessed.
struct EPUBArchive {
    private struct Entry {
        let path: String
        let method: Int
        let crc: UInt32
        let size: Int
        let payload: Range<Int>
        let record: Range<Int>
    }

    private static let fileLimit = 16 * 1024 * 1024
    private static let totalLimit = 64 * 1024 * 1024
    let files: [String: Data]

    init(_ data: Data) throws {
        let zip = data.startIndex == 0 ? data : Data(data)
        func malformed(_ field: String) -> ContentImportError { .malformedArchive("Invalid ZIP \(field)") }
        func u16(_ i: Int) -> Int { Int(zip[i]) | Int(zip[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard zip.count >= 22,
              let end = stride(from: zip.count - 22, through: max(0, zip.count - 65557), by: -1).first(where: {
                  u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == zip.count
              }) else { throw malformed("end record") }
        let count = u16(end + 10)
        guard count <= 2000 else { throw ContentImportError.archiveLimitExceeded("Entry count") }
        let directory = u32(end + 16)
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == count,
              directory + u32(end + 12) == end else { throw malformed("central directory") }

        var entries = [Entry]()
        var paths = Set<String>()
        var cursor = directory
        var total = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw malformed("directory entry") }
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = u32(cursor + 16), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            guard next <= end, u16(cursor + 34) == 0 else { throw malformed("entry bounds") }
            let name = zip[(cursor + 46)..<(cursor + 46 + nameLength)]
            guard let raw = String(bytes: name, encoding: .utf8) else { throw malformed("filename encoding") }
            let path = try Self.normalizedPath(raw)
            guard (u32(cursor + 38) >> 16) & 0o170000 != 0o120000, paths.insert(path).inserted else {
                throw ContentImportError.unsafeArchivePath(path)
            }
            guard flags & 0x2041 == 0 else { throw ContentImportError.unsupportedDRM(path) }
            guard [0, 8].contains(method), flags & ~0x080e == 0 else { throw malformed("compression method or flags") }
            total += size
            guard size <= Self.fileLimit, total <= Self.totalLimit,
                  compressed == 0 || size <= max(65536, compressed * 100) else {
                throw ContentImportError.archiveLimitExceeded("Declared size or expansion ratio")
            }

            let local = u32(cursor + 42)
            guard local + 30 <= directory, u32(local) == 0x04034b50,
                  u16(local + 4) == u16(cursor + 6), u16(local + 6) == flags, u16(local + 8) == method,
                  u32(local + 10) == u32(cursor + 12),
                  u16(local + 26) == nameLength else { throw malformed("local header") }
            let start = local + 30 + nameLength + u16(local + 28)
            var recordEnd = start + compressed
            guard recordEnd <= directory, zip[(local + 30)..<(local + 30 + nameLength)].elementsEqual(name) else {
                throw malformed("local filename or payload")
            }
            let descriptor = flags & 8 != 0
            for (offset, expected) in [(14, crc), (18, compressed), (22, size)] {
                let actual = u32(local + offset)
                guard actual == expected || (descriptor && actual == 0) else { throw malformed("local size or CRC") }
            }
            if descriptor {
                if recordEnd + 4 <= directory, u32(recordEnd) == 0x08074b50 { recordEnd += 4 }
                guard recordEnd + 12 <= directory, u32(recordEnd) == crc,
                      u32(recordEnd + 4) == compressed, u32(recordEnd + 8) == size else { throw malformed("data descriptor") }
                recordEnd += 12
            }
            entries.append(Entry(path: path, method: method, crc: UInt32(crc), size: size,
                                 payload: start..<(start + compressed), record: local..<recordEnd))
            cursor = next
        }
        guard cursor == end else { throw malformed("directory length") }
        var files = [String: Data]()
        var previousEnd = 0
        for entry in entries.sorted(by: { $0.record.lowerBound < $1.record.lowerBound }) {
            guard entry.record.lowerBound >= previousEnd else { throw malformed("overlapping entries") }
            previousEnd = entry.record.upperBound
            let payload = zip[entry.payload]
            let contents: Data
            if entry.method == 0 {
                guard payload.count == entry.size else { throw malformed("stored size") }
                contents = Data(payload)
            } else {
                contents = try Self.inflate(payload, size: entry.size)
            }
            guard Self.checksum(contents) == entry.crc else { throw malformed("CRC32") }
            files[entry.path] = contents
        }
        self.files = files
    }

    static func normalizedPath(_ raw: String) throws -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/").filter { $0 != "." }
        guard !path.hasPrefix("/"), !path.contains("\0"), !components.isEmpty, !components.contains(".."),
              components.first?.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw ContentImportError.unsafeArchivePath(raw)
        }
        return components.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private static func inflate(_ bytes: Data, size: Int) throws -> Data {
        guard !bytes.isEmpty else { throw ContentImportError.malformedArchive("Empty deflate stream") }
        let limit = min(fileLimit, max(65536, bytes.count * 100))
        return try bytes.withUnsafeBytes { raw in
            try withUnsafeTemporaryAllocation(of: compression_stream.self, capacity: 1) { streamBuffer in
                let stream = streamBuffer.baseAddress!
                guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                    throw ContentImportError.malformedArchive("Cannot initialize deflate")
                }
                defer { compression_stream_destroy(stream) }
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.src_size = raw.count
                var output = Data()
                return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32 * 1024) { chunk in
                    while true {
                        let previous = stream.pointee.src_size
                        stream.pointee.dst_ptr = chunk.baseAddress!
                        stream.pointee.dst_size = chunk.count
                        let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        let produced = chunk.count - stream.pointee.dst_size
                        guard output.count + produced <= limit else { throw ContentImportError.archiveLimitExceeded("Inflated size") }
                        guard output.count + produced <= size, status != COMPRESSION_STATUS_ERROR else {
                            throw ContentImportError.malformedArchive("Invalid deflate stream or size")
                        }
                        output.append(chunk.baseAddress!, count: produced)
                        if status == COMPRESSION_STATUS_END {
                            guard stream.pointee.src_size == 0, output.count == size else {
                                throw ContentImportError.malformedArchive("Deflate length mismatch")
                            }
                            return output
                        }
                        guard produced > 0 || stream.pointee.src_size < previous else {
                            throw ContentImportError.malformedArchive("Incomplete deflate stream")
                        }
                    }
                }
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }

    private static func checksum(_ bytes: Data) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crc, byte in (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
    }
}
