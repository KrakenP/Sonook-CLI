import AudioCore
import Foundation

public struct ChapterMemoryTracker: Sendable {
    private let past: [ChapterMemoryRecord]

    init(_ memories: [ChapterMemoryRecord], before chapter: Int, projectID: String? = nil) {
        past = memories.filter {
            $0.chapterNumber < chapter && (projectID == nil || $0.projectID == projectID)
        }.sorted {
            ($0.chapterNumber, $0.chapterID) < ($1.chapterNumber, $1.chapterID)
        }
    }

    public static func selectRelevantRoster(
        catalog: CharacterVoiceCatalog,
        chapterNumber: Int,
        chapterText: String,
        priorMemories: [ChapterMemoryRecord],
        maxCharacters: Int = 20
    ) -> [CharacterVoiceCard] {
        ChapterMemoryTracker(priorMemories, before: chapterNumber, projectID: catalog.projectID)
            .selectRelevantRoster(catalog: catalog, chapterText: chapterText, maxCharacters: maxCharacters)
    }

    func selectRelevantRoster(catalog: CharacterVoiceCatalog, chapterText: String, maxCharacters: Int) -> [CharacterVoiceCard] {
        let limit = max(2, maxCharacters)
        let byID = Dictionary(catalog.cards.map { ($0.characterID, $0) }, uniquingKeysWith: { first, _ in first })
        let narrator = byID["char_narrator"] ?? NarrativeAnalyzer.defaultNarratorCard()
        var roster = [narrator]
        var selected: Set<String> = [narrator.characterID]
        func include(_ card: CharacterVoiceCard) {
            if roster.count < limit, selected.insert(card.characterID).inserted { roster.append(card) }
        }

        for card in catalog.cards {
            if ([card.canonicalName] + card.aliases).contains(where: { !$0.isEmpty && chapterText.contains($0) }) {
                include(card)
            }
        }
        for memory in past.suffix(3).reversed() {
            for id in memory.activeCharacterIDs {
                if let card = byID[id] { include(card) }
            }
        }
        if roster.count == limit { return roster }

        var appearances = [String: Int]()
        for memory in past {
            for id in Set(memory.activeCharacterIDs) { appearances[id, default: 0] += 1 }
        }
        let recurring = appearances.filter { $0.value > 1 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        for (id, _) in recurring {
            if let card = byID[id] { include(card) }
        }
        for card in catalog.cards where card.locked { include(card) }
        return roster
    }

    public static func buildPriorMemoryPrompt(
        priorMemories: [ChapterMemoryRecord],
        beforeChapter: Int,
        maxRecentChapters: Int = 3
    ) -> String {
        ChapterMemoryTracker(priorMemories, before: beforeChapter).buildPriorMemoryPrompt(maxRecentChapters: maxRecentChapters)
    }

    func buildPriorMemoryPrompt(maxRecentChapters: Int = 3, rosterIDs: Set<String>? = nil) -> String {
        let recent = past.suffix(max(0, maxRecentChapters))
        guard !recent.isEmpty else { return "" }
        var lines = ["前章记忆（仅供分析）："]
        for memory in recent {
            lines.append("第\(memory.chapterNumber)章：\(memory.summary)")
            if !memory.openThreads.isEmpty { lines.append("未决线索：" + memory.openThreads.joined(separator: "；")) }
        }
        var active = Set(recent.flatMap(\.activeCharacterIDs))
        if let rosterIDs { active.formIntersection(rosterIDs) }
        let latest = latestStates(for: active)
        for state in latest.values.sorted(by: { $0.characterID < $1.characterID }) {
            var details = [state.statusSummary]
            if let location = state.location { details.append(location) }
            details += state.relationships
            lines.append("\(state.canonicalName)（第\(state.lastSeenChapter)章）：\(details.joined(separator: "；"))")
        }
        return lines.joined(separator: "\n")
    }

    func latestStates(for active: Set<String>) -> [String: CharacterChapterState] {
        var latest = [String: CharacterChapterState]()
        for memory in past {
            for state in memory.characterStates where active.contains(state.characterID) && state.lastSeenChapter <= memory.chapterNumber {
                if let previous = latest[state.characterID], previous.lastSeenChapter > state.lastSeenChapter { continue }
                latest[state.characterID] = state
            }
        }
        return latest
    }
}
