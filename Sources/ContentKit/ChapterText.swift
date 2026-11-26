import AudioCore
import Foundation

struct ChapterText {
    struct Heading {
        var offset: Int
        let title: String
        var path: String?
    }

    let text: String
    let headings: [Heading]

    init(text: String, headings: [Heading]) {
        self.text = text
        self.headings = headings
    }

    init(source: String, markdown: Bool) {
        let source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = [String]()
        var atx = [Heading]()
        var plain = [Heading]()
        var offset = 0
        var fence: (marker: Character, length: Int)?
        for input in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = input.trimmingCharacters(in: .whitespaces)
            var line = String(input)
            if markdown {
                let marker = stripped.first
                if marker == "`" || marker == "~", let marker {
                    let length = stripped.prefix(while: { $0 == marker }).count
                    if let open = fence {
                        if marker == open.marker, length >= open.length,
                           stripped.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                        continue
                    } else if length >= 3 {
                        fence = (marker, length)
                        continue
                    }
                }
                if fence != nil { continue }
                let hashes = stripped.prefix(while: { $0 == "#" }).count
                let tail = stripped.dropFirst(hashes)
                let isHeading = (1...6).contains(hashes) && tail.first?.isWhitespace == true
                if isHeading {
                    line = tail.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                }
                line = Self.inlineText(line)
                if isHeading, hashes <= 2 { atx.append(Heading(offset: offset, title: line)) }
            }
            let title = line.trimmingCharacters(in: .whitespaces)
            if title.range(of: #"^(第[零一二三四五六七八九十百千万两0-9]+[章回节卷]|(?i:Chapter\s+[0-9]+))"#,
                           options: .regularExpression) != nil {
                plain.append(Heading(offset: offset, title: title))
            }
            lines.append(line)
            offset += line.utf8.count + 1
        }
        self.init(text: lines.joined(separator: "\n"), headings: atx.isEmpty ? plain : atx)
    }

    private static func inlineText(_ line: String) -> String {
        var result = line.replacingOccurrences(of: #"\[([^\]]+)\]\((?:[^()\n]|\([^()\n]*\))*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "*", "_"] {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let pair = escaped + #"(?=\S)(.+?)(?<=\S)"# + escaped
            let pattern = marker.first == "_" ? "(?<![a-zA-Z0-9])" + pair + "(?![a-zA-Z0-9])" : pair
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    func records(fileName: String, projectID: String, revision: String) throws -> [ChapterRecord] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContentImportError.emptyContent }
        var entries = headings
        var firstNumber = 1
        if entries.isEmpty {
            let name = (fileName as NSString).lastPathComponent as NSString
            entries.append(Heading(offset: 0, title: name.deletingPathExtension.isEmpty ? "全文" : name.deletingPathExtension))
        } else if entries[0].offset > 0 {
            let prefix = String(decoding: text.utf8.prefix(entries[0].offset), as: UTF8.self)
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[0].offset = 0
            } else {
                entries.insert(Heading(offset: 0, title: "序"), at: 0)
                firstNumber = 0
            }
        }
        let byteCount = text.utf8.count
        return try entries.enumerated().map { index, entry in
            let number = index + firstNumber
            return ChapterRecord(projectID: projectID, chapterID: String(format: "ch_%03ld", number),
                                 chapterNumber: number, title: entry.title, sourceDocumentRevision: revision,
                                 sourceSpan: try SourceSpan(start: entry.offset,
                                                            endExclusive: index + 1 < entries.count ? entries[index + 1].offset : byteCount),
                                 originPath: entry.path)
        }
    }
}
