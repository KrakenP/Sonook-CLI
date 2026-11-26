import AudioCore
import Foundation

public struct PodcastScriptPlanner: Sendable {
    private let llm: (any LLMProvider)?

    /// The caller manages the injected provider's lifecycle, as in the audiobook workflow.
    public init(llm: (any LLMProvider)? = nil) { self.llm = llm }

    /// Segment spans address the episode transcript (segment source texts joined by a newline).
    /// Citations separately address the original, immutable UTF-8 chunks.
    /// Supply hits in retrieval order. The planner uses up to twelve to bound its evidence context.
    public func plan(projectID: String, episodeID: String, topicQuery: String, format: PodcastFormat,
                     hits: [KnowledgeSearchHit], catalog: CharacterVoiceCatalog? = nil,
                     createdAt: Date = Date()) async throws -> PodcastEpisodePlan {
        guard !episodeID.isEmpty, !topicQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeError.invalidEpisode
        }
        guard !hits.isEmpty else { throw KnowledgeError.noEvidence }
        guard hits.allSatisfy({ $0.chunk.projectID == projectID }) else { throw KnowledgeError.invalidEvidence }
        let hosts = PodcastCatalogBuilder.hostIDs(for: format)
        let cast = try PodcastCatalogBuilder.build(projectID: projectID, format: format, existing: catalog)
        let evidence = try hits.prefix(12).enumerated().map { try Evidence(index: $0.offset, hit: $0.element) }
        var turns: [Turn]?
        if let llm {
            let request = try PodcastPrompt.request(topic: topicQuery, hosts: hosts, evidence: evidence, capabilities: llm.capabilities)
            let response = try await llm.generate(request)
            turns = PodcastPrompt.validate(response.text, hosts: hosts, evidence: evidence)
        }
        try Task.checkCancellation()
        let lines = turns ?? Self.offline(evidence: evidence, hosts: hosts, topic: topicQuery)
        let revision = knowledgeDigest(lines.map(\.spokenText).joined(separator: "\n"))
        var segments: [ScriptSegment] = []
        var outline: [PodcastOutlineItem] = []
        var citations: [KnowledgeCitation] = []
        var offset = 0
        for (index, line) in lines.enumerated() {
            let sequence = String(format: "%04d", index + 1)
            let text = line.spokenText
            let end = offset + text.utf8.count
            var references: [KnowledgeCitation] = []
            if let quote = line.quote {
                let hit = line.evidence.hit
                let citation = KnowledgeCitation(citationID: "\(episodeID)_cite_\(sequence)", sourceID: hit.chunk.sourceID,
                                                 sourceTitle: hit.sourceTitle, chunkID: hit.chunk.chunkID, sourceSpan: hit.chunk.sourceSpan,
                                                 quotedExcerpt: quote, ingestedAtISO8601: hit.ingestedAtISO8601, isInference: line.isInference)
                references.append(citation)
                citations.append(citation)
                outline.append(.init(itemID: "\(episodeID)_item_\(sequence)", topic: hit.chunk.sectionHeading ?? hit.sourceTitle,
                                     keyPoints: [text], citations: references))
            }
            guard let card = cast.cards.first(where: { $0.characterID == line.speaker }) else { throw KnowledgeError.invalidEpisode }
            segments.append(.init(segmentID: "\(episodeID)_seg_\(sequence)", chapterID: episodeID, sourceDocumentRevision: revision,
                                  sourceSpan: try .init(start: offset, endExclusive: end), sourceText: text, spokenText: text,
                                  speakerID: line.speaker, voiceProfileRevision: "\(card.characterID)_rev_\(card.revision)",
                                  scriptRevision: 1, attributionEvidence: references.map(\.citationID)))
            offset = end + 1
        }
        let script = ScriptDocument(chapterID: episodeID, sourceDocumentRevision: revision, scriptRevision: 1, segments: segments)
        return .init(projectID: projectID, episodeID: episodeID, title: topicQuery, topicQuery: topicQuery, format: format,
                     hostSpeakerIDs: hosts, outline: outline, citations: citations, scriptDocument: script,
                     createdAtISO8601: createdAt.ISO8601Format())
    }

    private static func offline(evidence: [Evidence], hosts: [String], topic: String) -> [Turn] {
        var turns: [Turn] = []
        let terms = topic.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (index, item) in evidence.enumerated() {
            let quote = item.offlineQuote(terms: terms)
            if hosts.count == 2 {
                let question = "《\(item.hit.sourceTitle)》里是怎么说的？"
                turns.append(.init(speaker: hosts[index % 2], text: question, evidence: item, quote: nil, isInference: false))
            }
            let spoken = Self.spokenMarkdownCleanup(quote)
            turns.append(.init(speaker: hosts[(index + 1) % hosts.count], text: spoken, evidence: item, quote: quote, isInference: false))
        }
        return turns
    }

    static func spokenMarkdownCleanup(_ raw: String) -> String {
        var s = raw
        // Convert Markdown links [label](url) -> label so TTS never tries to speak file paths or URLs.
        s = s.replacing(/\[([^\]]+)\]\([^\)]+\)/) { String($0.output.1) }
        // Strip inline code ticks, bold/italic markers, leading blockquote/list/table pipes.
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacing(/^\s*[#>\-*+|]+\s*/, with: "")
        s = s.replacing(/\s*\|\s*/, with: "，")
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|，")))
        return trimmed.isEmpty ? raw : trimmed
    }
}

struct Evidence {
    let id: String
    let hit: KnowledgeSearchHit
    let excerpt: String

    init(index: Int, hit: KnowledgeSearchHit) throws {
        let chunk = hit.chunk
        guard !chunk.chunkID.isEmpty, !chunk.sourceID.isEmpty,
              chunk.sourceSpan.endExclusive - chunk.sourceSpan.start == chunk.text.utf8.count else {
            throw KnowledgeError.invalidEvidence
        }
        let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = !snippet.isEmpty && chunk.text.range(of: snippet, options: .literal) != nil ? snippet : chunk.text
        self.excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        guard !excerpt.isEmpty else { throw KnowledgeError.invalidEvidence }
        self.id = "E\(index + 1)"
        self.hit = hit
    }

    func offlineQuote(terms: [String]) -> String {
        // Select from the original lines. A display snippet can start halfway through a fact.
        let lines = hit.chunk.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for line in lines where terms.contains(where: { line.range(of: $0, options: .caseInsensitive) != nil }) {
            return line
        }
        return lines.first ?? excerpt
    }
}

struct Turn {
    let speaker: String
    let text: String
    let evidence: Evidence
    let quote: String?
    let isInference: Bool
    var spokenText: String { isInference ? "我的推测是，" + text : text }
}
