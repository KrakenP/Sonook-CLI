import AudioCore
import Foundation

public enum DialogueAttributionValidator: Sendable {
    private static let narrator = "char_narrator"

    public static func validate(
        units: [NarrativeUnitInput], attributions: [NarrativeUnitAttribution], catalog: CharacterVoiceCatalog
    ) -> [NarrativeUnitAttribution] {
        let byIndex = Dictionary(grouping: attributions, by: \.index)
        var names = [(String, String)]()
        for card in catalog.cards where card.characterID != narrator {
            for name in [card.canonicalName] + card.aliases where !name.isEmpty {
                if catalog.resolveCharacter(namedOrAliased: name)?.characterID == card.characterID {
                    names.append((name, card.characterID))
                }
            }
        }
        names.sort { lhs, rhs in
            if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
            return lhs.0 < rhs.0
        }
        var turns = units.map { unit in
            let candidates = byIndex[unit.index] ?? []
            let attr = candidates.count == 1 ? candidates[0] : nil
            let speaker = attr.flatMap { catalog.resolveCharacter(namedOrAliased: $0.speakerID)?.characterID }
            let unresolved = unit.isQuotedDialogue && (speaker == nil || speaker == narrator)
            let confidence = attr.flatMap { (0...1).contains($0.confidence) ? $0.confidence : nil } ?? 0
            return Turn(speaker: unit.isQuotedDialogue ? speaker ?? narrator : narrator,
                        confidence: unit.isQuotedDialogue ? min(unresolved ? 0.45 : 1, max(0, confidence)) : 1,
                        evidence: attr?.evidence ?? [],
                        reason: unresolved ? "unresolved_dialogue_speaker" : (unit.isQuotedDialogue ? attr?.needsReviewReason : nil),
                        addressed: unit.isQuotedDialogue ? vocatives(unit.spokenText, names: names) : [],
                        prediction: attr)
        }

        var start = 0
        while start < units.count {
            guard units[start].isQuotedDialogue else { start += 1; continue }
            var end = start
            // Narration always breaks a sequence, including an explicit continuation such as 又道.
            var reliable = Set<String>()
            if start > 0 {
                let preceding = units[start - 1].sourceText
                for (name, id) in names where ["说", "道", "问", "喊", "答"].contains(where: { preceding.contains(name + $0) }) {
                    reliable.insert(id)
                }
            }
            var participants = reliable
            while end < units.count, units[end].isQuotedDialogue {
                if turns[end].speaker != narrator {
                    participants.insert(turns[end].speaker)
                    if turns[end].confidence >= 0.60, turns[end].reason == nil { reliable.insert(turns[end].speaker) }
                }
                participants.formUnion(turns[end].addressed)
                end += 1
            }
            var confirmed = participants.count == 2 && !reliable.isEmpty ? participants : []
            var seen = Set<String>()
            for i in start..<end {
                var turn = turns[i]
                if turn.speaker != narrator { seen.insert(turn.speaker) }
                seen.formUnion(turn.addressed)
                if turn.reason == nil, turn.addressed.contains(turn.speaker) {
                    let others = participants.subtracting(turn.addressed)
                    if participants.count == 2, others.count == 1, let other = others.first,
                       reliable.contains(other) {
                        turn.correct(to: other, rule: "vocative_exclusion")
                    } else {
                        turn.reason = "vocative_speaker_conflict"
                    }
                } else if turn.reason == nil, i > start, seen.count <= 2, turns[i - 1].reason == nil,
                          turn.speaker == turns[i - 1].speaker, confirmed.count == 2, confirmed.contains(turn.speaker),
                          let other = confirmed.first(where: { $0 != turn.speaker }), !turn.addressed.contains(other),
                          (turns[i - 1].addressed == [other] || isResponse(units[i].spokenText, to: units[i - 1].spokenText)) {
                    turn.correct(to: other, rule: "alternating_turn")
                }
                if turn.reason == nil, turn.confidence < 0.60 { turn.reason = "low_confidence_attribution" }
                if turn.reason == nil { confirmed.insert(turn.speaker) }
                else { confirmed.removeAll() }
                turns[i] = turn
            }
            start = end
        }
        return zip(units, turns).map { unit, turn in
            .init(index: unit.index, speakerID: turn.speaker, emotion: turn.prediction?.emotion ?? (unit.isQuotedDialogue ? "natural" : "calm"),
                  styleInstruction: turn.prediction?.styleInstruction ?? "", pauseAfterMs: turn.prediction?.pauseAfterMs ?? 350,
                  confidence: turn.confidence, evidence: turn.evidence, needsReviewReason: turn.reason)
        }
    }

    private struct Turn {
        var speaker: String
        var confidence: Double
        var evidence: [String]
        var reason: String?
        let addressed: Set<String>
        let prediction: NarrativeUnitAttribution?

        mutating func correct(to speaker: String, rule: String) {
            self.speaker = speaker
            confidence = max(confidence, 0.60)
            evidence.append("[validator:\(rule)]")
        }
    }

    private static func vocatives(_ text: String, names: [(String, String)]) -> Set<String> {
        var result = Set<String>()
        for clause in text.split(whereSeparator: { "，,、！!。？?：:".contains($0) }) {
            var word = clause.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            word = word.drop(while: { "哎欸诶喂嘿啊呀".contains($0) })
            var called = Set<String>()
            while let (name, id) = names.first(where: { word.hasPrefix($0.0) }) {
                word = word.dropFirst(name.count)
                called.insert(id)
            }
            if word.isEmpty { result.formUnion(called) }
        }
        return result
    }

    private static func isResponse(_ text: String, to previous: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["不", "别", "好", "对", "是的", "那就", "可我", "可是", "但是", "才没有", "没", "行", "嗯", "当然", "怎么会",
            "等等", "抱歉", "我的", "我错", "对不起", "给你", "凭什么", "什么叫", "哪有", "那你", "胡说", "算了",
            "我同意", "我拒绝", "谢谢"].contains(where: line.hasPrefix) { return true }
        let followsQuestion = previous.hasSuffix("？") || previous.hasSuffix("?")
        return followsQuestion && !line.hasSuffix("？") && !line.hasSuffix("?")
    }
}
