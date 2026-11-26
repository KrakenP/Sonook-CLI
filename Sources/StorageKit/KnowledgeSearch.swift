import AudioCore
import Foundation

extension SQLiteWorkspaceStore {
    public func searchKnowledge(projectID: String, query: String, limit: Int) async throws -> [KnowledgeSearchHit] {
        guard limit > 0 else { return [] }
        guard query.utf8.count <= 4096 else { throw WorkflowStoreError.invalidStateTransition("Knowledge query too long") }
        let terms = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !terms.isEmpty else { return [] }
        let runs = query.split { !$0.isCJK }.map(String.init)
        // Each term is a literal. Punctuation and FTS operators in user input cannot change the expression.
        let expression = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try db.transaction(readOnly: true) {
            let matches = try db.query("""
                SELECT chunk_id, rank FROM knowledge_chunks_fts WHERE knowledge_chunks_fts MATCH ? AND project_id=?
                ORDER BY rank, chunk_id LIMIT ?
                """, [expression, projectID, String(runs.isEmpty ? limit : -1)]) { ($0.text(0), -$0.double(1)) }
            var scores: [String: Double] = [:]
            if let best = matches.first?.1, best > 0 {
                for (id, rank) in matches { scores[id] = rank / best }
            }
            if !runs.isEmpty {
                try addCJKScores(projectID: projectID, runs: runs, scores: &scores)
            }
            let ranked = scores.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            return try ranked.prefix(limit).compactMap { id, score in
                try db.query("""
                    SELECT c.document, s.document FROM knowledge_chunks c JOIN knowledge_sources s USING(project_id, source_id)
                    WHERE c.project_id=? AND c.chunk_id=?
                    """, [projectID, id]) { row in
                    let chunk = try row.document(KnowledgeChunk.self)
                    let source = try row.document(KnowledgeSourceRecord.self, at: 1)
                    return KnowledgeSearchHit(chunk: chunk, sourceTitle: source.title, ingestedAtISO8601: source.ingestedAtISO8601,
                                              score: score, snippet: Self.snippet(chunk.text, terms: terms + runs))
                }.first
            }
        }
    }

    private struct TermCounts {
        let id: String
        let length: Int
        let frequencies: [String: Int]
        let exactRuns: Int
    }

    // unicode61 can index a whole Chinese sentence as one token. Score characters and adjacent pairs
    // against the entire project even when a different chunk happened to match as a whole FTS token.
    private func addCJKScores(projectID: String, runs: [String], scores: inout [String: Double]) throws {
        var weights: [String: Double] = [:]
        for run in runs {
            for ch in run { weights[String(ch)] = 0.25 }
            for (a, b) in zip(run, run.dropFirst()) { weights[String(a) + String(b)] = 1 }
        }
        let phrases = Set(runs)
        var docFrequency: [String: Int] = [:]
        let documents = try db.query("SELECT chunk_id, text FROM knowledge_chunks WHERE project_id=?", [projectID]) { row in
            let text = row.text(1)
            var frequencies: [String: Int] = [:]
            var previous: Character?
            for ch in text {
                if ch.isCJK {
                    let term = String(ch)
                    if weights[term] != nil { frequencies[term, default: 0] += 1 }
                    if let previous {
                        let pair = String(previous) + term
                        if weights[pair] != nil { frequencies[pair, default: 0] += 1 }
                    }
                    previous = ch
                } else {
                    previous = nil
                }
            }
            for term in frequencies.keys { docFrequency[term, default: 0] += 1 }
            return TermCounts(id: row.text(0), length: text.count, frequencies: frequencies,
                              exactRuns: phrases.filter { text.contains($0) }.count)
        }
        guard !documents.isEmpty else { return }
        let count = Double(documents.count)
        let meanLength = max(1, documents.reduce(0.0) { $0 + Double($1.length) } / count)
        for doc in documents where !doc.frequencies.isEmpty {
            let lengthPenalty = 1.2 * (0.25 + 0.75 * Double(doc.length) / meanLength)
            var bm25 = 0.0
            for (term, frequency) in doc.frequencies.sorted(by: { $0.key < $1.key }) {
                let df = Double(docFrequency[term, default: 0])
                let idf = log1p((count - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                bm25 += weights[term, default: 0] * idf * tf * 2.2 / (tf + lengthPenalty)
            }
            // Bounded lexical and n-gram scores keep complete phrases ahead of scattered characters.
            scores[doc.id, default: 0] += 2 * Double(doc.exactRuns) + bm25 / (1 + bm25)
        }
    }

    private static func snippet(_ text: String, terms: [String]) -> String {
        guard text.count > 160 else { return text }
        let match = terms.lazy.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let start = text.index(match?.lowerBound ?? text.startIndex, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(160))
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D, // Kana
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: // Hangul
            return true
        default:
            return scalar.properties.isIdeographic
        }
    }
}
