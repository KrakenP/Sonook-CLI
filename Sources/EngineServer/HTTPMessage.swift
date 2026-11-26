import Foundation
import Network

enum HTTPStatus: Int, Error {
    case ok = 200, noContent = 204, partialContent = 206
    case badRequest = 400, unauthorized = 401, forbidden = 403, notFound = 404, conflict = 409
    case payloadTooLarge = 413, rangeNotSatisfiable = 416, internalError = 500

    var reason: String {
        switch self {
        case .ok: "OK"
        case .partialContent: "Partial Content"
        case .noContent: "No Content"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .conflict: "Conflict"
        case .payloadTooLarge: "Payload Too Large"
        case .rangeNotSatisfiable: "Range Not Satisfiable"
        case .internalError: "Internal Server Error"
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: [String]
    let query: [URLQueryItem]
    let headers: [String: String]
    let body: Data

    static func read(from connection: NWConnection) async throws -> Self {
        let delimiter = Data("\r\n\r\n".utf8)
        let headerLimit = 16 * 1024
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            connection.cancel()
        }
        defer { timeout.cancel() }
        var buffer = Data()
        var boundary: Range<Int>?
        while boundary == nil {
            let previousEnd = buffer.endIndex
            buffer.append(try await connection.readBytes(maximum: 8192))
            boundary = buffer.range(of: delimiter, in: max(0, previousEnd - 3)..<buffer.endIndex)
            guard (boundary?.lowerBound ?? buffer.count) <= headerLimit else { throw HTTPStatus.payloadTooLarge }
        }
        guard let boundary, let head = String(data: buffer[..<boundary.lowerBound], encoding: .utf8)
        else { throw HTTPStatus.badRequest }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].components(separatedBy: " ")
        guard request.count == 3, request[2] == "HTTP/1.1", request[1].hasPrefix("/"),
              !request[1].contains("#") else { throw HTTPStatus.badRequest }

        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPStatus.badRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) }),
                  headers[name] == nil, !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 })
            else { throw HTTPStatus.badRequest }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty else { throw HTTPStatus.badRequest }

        let target = request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = try target[0].dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            guard let part = $0.removingPercentEncoding, isSafeComponent(part) else { throw HTTPStatus.badRequest }
            return part
        }
        var query = [URLQueryItem]()
        if target.count == 2 {
            for field in target[1].split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = pair[0].removingPercentEncoding,
                      let value = (pair.count == 2 ? pair[1] : "").removingPercentEncoding
                else { throw HTTPStatus.badRequest }
                query.append(URLQueryItem(name: name, value: value))
            }
        }

        let buffered = Data(buffer[boundary.upperBound...])
        var reader = HTTPBodyReader(connection: connection, buffer: buffered)
        let body = try await reader.read(headers: headers)
        return Self(method: request[0], path: path, query: query, headers: headers, body: body)
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.utf8.contains(0)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try JSONDecoder().decode(type, from: body) }
        catch { throw HTTPStatus.badRequest }
    }
}

/// Reads one bounded HTTP/1.1 message body, preserving bytes coalesced with the headers.
private struct HTTPBodyReader {
    let connection: NWConnection
    var buffer: Data

    mutating func read(headers: [String: String]) async throws -> Data {
        let limit = 4 * 1024 * 1024
        let transfer = headers["transfer-encoding"]?.lowercased()
        let rawLength = headers["content-length"]
        guard transfer == nil || (transfer == "chunked" && rawLength == nil) else { throw HTTPStatus.badRequest }
        let lengthText = rawLength ?? "0"
        guard lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText)
        else { throw HTTPStatus.badRequest }
        guard length <= limit else { throw HTTPStatus.payloadTooLarge }
        if headers["expect"]?.lowercased() == "100-continue" {
            try await connection.writeBytes(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        guard transfer == "chunked" else { return try await take(length) }

        var body = Data()
        var framingBudget = 64 * 1024
        while true {
            let line = try await readLine(budget: &framingBudget)
            let digits = line.prefix { $0 != 59 } // Optional chunk extensions follow ';'.
            let sizeText = String(decoding: digits, as: UTF8.self)
            guard !sizeText.isEmpty, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16)
            else { throw HTTPStatus.badRequest }
            guard size <= limit - body.count else { throw HTTPStatus.payloadTooLarge }
            if size == 0 {
                // Trailers do not override the original request headers or authorization.
                while !(try await readLine(budget: &framingBudget)).isEmpty {}
                return body
            }
            body.append(try await take(size))
            guard try await take(2) == Data([13, 10]) else { throw HTTPStatus.badRequest }
        }
    }

    private mutating func take(_ count: Int) async throws -> Data {
        var data = Data(buffer.prefix(count))
        buffer.removeFirst(data.count)
        while data.count < count {
            data.append(try await connection.readBytes(maximum: min(count - data.count, 64 * 1024)))
        }
        return data
    }

    private mutating func readLine(budget: inout Int) async throws -> Data {
        let crlf = Data([13, 10])
        while true {
            if let newline = buffer.range(of: crlf) {
                let line = Data(buffer[..<newline.lowerBound])
                budget -= line.count + 2
                guard budget >= 0 else { throw HTTPStatus.payloadTooLarge }
                buffer.removeSubrange(..<newline.upperBound)
                return line
            }
            guard buffer.count < min(8192, budget) else { throw HTTPStatus.payloadTooLarge }
            buffer.append(try await connection.readBytes(maximum: 8192))
        }
    }
}

struct HTTPResponse {
    enum Body {
        case bytes(Data)
        case file(FileHandle, length: UInt64)
        case events(AsyncStream<ServerEventBus.Event>, authorize: @Sendable () async throws -> Void)
    }

    var status: HTTPStatus = .ok
    var headers: [String: String] = [:]
    var body: Body = .bytes(Data())

    static func json<T: Encodable>(_ value: T) throws -> Self {
        Self(headers: ["Content-Type": "application/json"], body: .bytes(try JSONEncoder().encode(value)))
    }

    static func failure(_ error: Error) -> Self {
        let status: HTTPStatus
        switch error {
        case EngineServerError.unauthorized: status = .unauthorized
        case EngineServerError.forbidden: status = .forbidden
        case EngineServerError.challengeConsumed: status = .conflict
        case let http as HTTPStatus: status = http
        default: status = .internalError
        }
        return Self(status: status, headers: status == .unauthorized ? ["WWW-Authenticate": "Bearer"] : [:])
    }

    func write(to connection: NWConnection) async throws {
        var fields = headers
        fields["Connection"] = "close"
        fields["Cache-Control"] = "no-store"
        switch body {
        case let .bytes(data):
            if status != .noContent { fields["Content-Length"] = String(data.count) }
        case let .file(_, length): fields["Content-Length"] = String(length)
        case .events: break // SSE is delimited by closing the connection.
        }
        let head = ["HTTP/1.1 \(status.rawValue) \(status.reason)"] + fields.map { "\($0.key): \($0.value)" }
        try await connection.writeBytes(Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        switch body {
        case let .bytes(data):
            if !data.isEmpty { try await connection.writeBytes(data) }
        case let .file(handle, length):
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty
                else { throw HTTPStatus.internalError }
                try await connection.writeBytes(data)
                remaining -= UInt64(data.count)
            }
        case let .events(stream, authorize):
            try await connection.writeBytes(Data(": connected\n\n".utf8))
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // EOF wakes an idle subscription even if no further event is published.
                    _ = try? await connection.readBytes(maximum: 1)
                }
                group.addTask {
                    do {
                        for await event in stream {
                            try await authorize()
                            try await connection.writeBytes(event.frame)
                        }
                    } catch { return }
                }
                await group.next()
                group.cancelAll()
                connection.cancel()
            }
        }
    }
}

extension NWConnection {
    func readBytes(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NWError.posix(.ECONNRESET)) }
            }
        }
    }

    func writeBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
