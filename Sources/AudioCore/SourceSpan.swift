import Foundation

public enum OffsetUnit: String, Codable, Sendable {
    case utf8Byte = "utf8_byte"
}

public enum SourceSpanError: Error, Equatable, Sendable {
    case invalidRange, outOfBounds, splitsUnicodeScalar
}

/// Absolute byte offsets in an immutable, normalized UTF-8 document.
public struct SourceSpan: Codable, Equatable, Sendable {
    public let unit: OffsetUnit
    public let start: Int
    public let endExclusive: Int

    public init(unit: OffsetUnit = .utf8Byte, start: Int, endExclusive: Int) throws {
        guard start >= 0, endExclusive >= start else { throw SourceSpanError.invalidRange }
        self.unit = unit
        self.start = start
        self.endExclusive = endExclusive
    }

    enum CodingKeys: String, CodingKey {
        case unit, start, endExclusive = "end_exclusive"
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(unit: fields.decode(OffsetUnit.self, forKey: .unit),
                      start: fields.decode(Int.self, forKey: .start),
                      endExclusive: fields.decode(Int.self, forKey: .endExclusive))
    }

    public func slice(in text: String) throws -> String {
        let bytes = text.utf8
        guard let end = bytes.index(bytes.startIndex, offsetBy: endExclusive, limitedBy: bytes.endIndex)
        else { throw SourceSpanError.outOfBounds }
        let begin = bytes.index(bytes.startIndex, offsetBy: start)
        for index in [begin, end] where index != bytes.endIndex && bytes[index] & 0xC0 == 0x80 {
            throw SourceSpanError.splitsUnicodeScalar
        }
        return String(decoding: bytes[begin..<end], as: UTF8.self)
    }
}
