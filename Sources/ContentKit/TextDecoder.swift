import CoreFoundation
import Foundation

enum TextDecoder {
    static func decode(_ data: Data, explicit: ExplicitTextEncoding?) throws -> (String, String) {
        let markers: [(ExplicitTextEncoding, [UInt8])] = [
            (.utf8, [0xef, 0xbb, 0xbf]), (.utf16LE, [0xff, 0xfe]), (.utf16BE, [0xfe, 0xff])
        ]
        let marker = markers.first { data.starts(with: $0.1) }
        if let encoding = explicit ?? marker?.0 {
            let marked = encoding == marker?.0
            let body = data.dropFirst(marked ? marker?.1.count ?? 0 : 0)
            guard let text = strict(body, encoding) else { throw ContentImportError.encodingError(encoding.rawValue) }
            return (text, marked && encoding == .utf8 ? "utf-8-bom" : encoding.rawValue)
        }
        if !data.contains(0), let text = strict(data, .utf8) { return (text, ExplicitTextEncoding.utf8.rawValue) }
        let candidates = [ExplicitTextEncoding.gb18030, .utf16LE, .utf16BE].compactMap { encoding in
            strict(data, encoding).map { (text: $0, encoding: encoding, score: plausibility($0)) }
        }.sorted { $0.score > $1.score }
        guard let first = candidates.first else { throw ContentImportError.encodingError("No valid text encoding") }
        if let second = candidates.dropFirst().first, first.score - second.score < 0.45 {
            throw ContentImportError.ambiguousEncoding("\(first.encoding.rawValue), \(second.encoding.rawValue)")
        }
        return (first.text, first.encoding.rawValue)
    }

    private static func strict(_ bytes: Data, _ encoding: ExplicitTextEncoding) -> String? {
        switch encoding {
        case .utf8:
            let text = String(decoding: bytes, as: UTF8.self)
            return text.utf8.elementsEqual(bytes) ? text : nil
        case .utf16LE, .utf16BE:
            guard bytes.count.isMultiple(of: 2) else { return nil }
            var units = [UInt16]()
            units.reserveCapacity(bytes.count / 2)
            var iterator = bytes.makeIterator()
            while let a = iterator.next(), let b = iterator.next() {
                let (hi, lo) = encoding == .utf16BE ? (a, b) : (b, a)
                units.append(UInt16(hi) << 8 | UInt16(lo))
            }
            let text = String(decoding: units, as: UTF16.self)
            return text.utf16.elementsEqual(units) ? text : nil
        case .gb18030:
            // Reject incomplete sequences and unmapped bytes even on permissive system converters.
            var input = bytes.makeIterator()
            while let lead = input.next() {
                if lead < 0x80 { continue }
                guard (0x81...0xfe).contains(lead), let trail = input.next() else { return nil }
                if (0x30...0x39).contains(trail) {
                    guard let third = input.next(), (0x81...0xfe).contains(third),
                          let fourth = input.next(), (0x30...0x39).contains(fourth) else { return nil }
                } else if !(0x40...0xfe).contains(trail) || trail == 0x7f { return nil }
            }
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let charset = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            guard let text = String(data: bytes, encoding: charset),
                  text.data(using: charset, allowLossyConversion: false) == bytes else { return nil }
            return text
        }
    }

    private static let common = Set("的一是在了不有人我你他她们这那来去道说章回节卷序上下来中大小天地年月日风雨水山门声看着到和也".unicodeScalars)
    private static func plausibility(_ text: String) -> Double {
        var score = 0
        var count = 0
        for scalar in text.unicodeScalars {
            count += 1
            if common.contains(scalar) { score += 6; continue }
            switch scalar.value {
            case 9, 10, 13, 32...126, 0x3000...0x303f, 0xff01...0xff60: score += 5
            case 0x3400...0x9fff, 0x20000...0x323af: score += 3
            case 0...31, 127...159, 0xe000...0xf8ff, 0xfffd...0xffff: score -= 15
            default: break
            }
        }
        return Double(score) / Double(max(1, count))
    }
}
