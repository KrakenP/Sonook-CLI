import Foundation

public struct ProviderVoiceBinding: Codable, Equatable, Sendable {
    public var providerID: String
    public var speakerID: String
    public var baseInstruction: String
    public var speakingRate: Double
    public var extraParameters: [String: String]

    public init(providerID: String, speakerID: String, baseInstruction: String = "",
                speakingRate: Double = 1, extraParameters: [String: String] = [:]) {
        self.providerID = providerID
        self.speakerID = speakerID
        self.baseInstruction = baseInstruction
        self.speakingRate = speakingRate
        self.extraParameters = extraParameters
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id", speakerID = "speaker_id", baseInstruction = "base_instruction"
        case speakingRate = "speaking_rate", extraParameters = "extra_parameters"
    }
}

public struct CharacterVoiceCard: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let characterID: String
    public var canonicalName: String
    public var aliases: [String]
    public var gender: String
    public var ageBand: String
    public var personaSummary: String
    public var speechHabits: [String]
    public var evidenceExcerpts: [String]
    public var voiceDesignPrompt: String
    public var providerBindings: [String: ProviderVoiceBinding]
    /// Immutable reference voice anchor locking core vocal timbre across long novels.
    public var timbreAnchor: VoiceTimbreAnchor?
    /// Chapter-indexed vocal delivery stages capturing character growth while preserving timbre continuity.
    public var deliveryStages: [VoiceDeliveryStage]
    public var revision: Int
    public var locked: Bool

    public init(characterID: String, canonicalName: String, aliases: [String] = [], gender: String = "",
                ageBand: String = "", personaSummary: String = "", speechHabits: [String] = [],
                evidenceExcerpts: [String] = [], voiceDesignPrompt: String = "",
                providerBindings: [String: ProviderVoiceBinding] = [:],
                timbreAnchor: VoiceTimbreAnchor? = nil,
                deliveryStages: [VoiceDeliveryStage] = [],
                revision: Int = 1, locked: Bool = false) {
        self.characterID = characterID
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.gender = gender
        self.ageBand = ageBand
        self.personaSummary = personaSummary
        self.speechHabits = speechHabits
        self.evidenceExcerpts = evidenceExcerpts
        self.voiceDesignPrompt = voiceDesignPrompt
        self.providerBindings = providerBindings
        self.timbreAnchor = timbreAnchor
        self.deliveryStages = deliveryStages.sorted { $0.effectiveFromChapter < $1.effectiveFromChapter }
        self.revision = revision
        self.locked = locked
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", characterID = "character_id", canonicalName = "canonical_name"
        case aliases, gender, ageBand = "age_band", personaSummary = "persona_summary", speechHabits = "speech_habits"
        case evidenceExcerpts = "evidence_excerpts", voiceDesignPrompt = "voice_design_prompt"
        case providerBindings = "provider_bindings", timbreAnchor = "timbre_anchor", deliveryStages = "delivery_stages"
        case revision, locked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(SchemaVersion.self, forKey: .version)
        try self.init(
            characterID: c.decode(String.self, forKey: .characterID),
            canonicalName: c.decode(String.self, forKey: .canonicalName),
            aliases: c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            gender: c.decodeIfPresent(String.self, forKey: .gender) ?? "",
            ageBand: c.decodeIfPresent(String.self, forKey: .ageBand) ?? "",
            personaSummary: c.decodeIfPresent(String.self, forKey: .personaSummary) ?? "",
            speechHabits: c.decodeIfPresent([String].self, forKey: .speechHabits) ?? [],
            evidenceExcerpts: c.decodeIfPresent([String].self, forKey: .evidenceExcerpts) ?? [],
            voiceDesignPrompt: c.decodeIfPresent(String.self, forKey: .voiceDesignPrompt) ?? "",
            providerBindings: c.decodeIfPresent([String: ProviderVoiceBinding].self, forKey: .providerBindings) ?? [:],
            timbreAnchor: c.decodeIfPresent(VoiceTimbreAnchor.self, forKey: .timbreAnchor),
            deliveryStages: c.decodeIfPresent([VoiceDeliveryStage].self, forKey: .deliveryStages) ?? [],
            revision: c.decodeIfPresent(Int.self, forKey: .revision) ?? 1,
            locked: c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(characterID, forKey: .characterID)
        try c.encode(canonicalName, forKey: .canonicalName)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(gender, forKey: .gender)
        try c.encode(ageBand, forKey: .ageBand)
        try c.encode(personaSummary, forKey: .personaSummary)
        try c.encode(speechHabits, forKey: .speechHabits)
        try c.encode(evidenceExcerpts, forKey: .evidenceExcerpts)
        try c.encode(voiceDesignPrompt, forKey: .voiceDesignPrompt)
        try c.encode(providerBindings, forKey: .providerBindings)
        try c.encodeIfPresent(timbreAnchor, forKey: .timbreAnchor)
        if !deliveryStages.isEmpty {
            try c.encode(deliveryStages, forKey: .deliveryStages)
        }
        try c.encode(revision, forKey: .revision)
        try c.encode(locked, forKey: .locked)
    }

    /// Returns the most recent vocal progression stage active at `chapterIndex`, preserving core timbre continuity.
    public func activeDeliveryStage(forChapter chapterIndex: Int) -> VoiceDeliveryStage? {
        deliveryStages
            .filter { $0.effectiveFromChapter <= chapterIndex }
            .max { lhs, rhs in
                if lhs.effectiveFromChapter != rhs.effectiveFromChapter {
                    return lhs.effectiveFromChapter < rhs.effectiveFromChapter
                }
                return lhs.revision < rhs.revision
            }
    }

    /// Composes the effective delivery instruction layering character stage progression + local segment direction.
    public func effectiveControlInstruction(forChapter chapterIndex: Int, direction: SegmentDirection) -> String {
        var parts: [String] = []
        if let stage = activeDeliveryStage(forChapter: chapterIndex) {
            let trimmedStage = trimmed(stage.deliveryBaseline)
            if !trimmedStage.isEmpty { parts.append(trimmedStage) }
        }
        if let local = direction.styleInstruction.map(trimmed), !local.isEmpty {
            parts.append(local)
        }
        return parts.joined(separator: "，")
    }

    /// Synthesis cache fingerprint depends ONLY on timbre anchor, active delivery stage, segment direction,
    /// spoken text, and model identity — NOT on card metadata like aliases or evidence excerpts.
    public func synthesisFingerprint(
        chapterIndex: Int,
        spokenText: String,
        direction: SegmentDirection,
        providerID: String,
        modelID: String,
        modelRevision: String
    ) -> String {
        let anchorKey = timbreAnchor.map { "\($0.anchorID):\($0.fileSHA256)" } ?? "design:\(voiceDesignPrompt)"
        let stage = activeDeliveryStage(forChapter: chapterIndex)
        let stageRate = stage?.speakingRate.map { String($0) } ?? ""
        let stageKey = stage.map { "\($0.stageID):r\($0.revision):\($0.deliveryBaseline):\(stageRate)" } ?? "base"
        let dirRate = direction.rate.map { String($0) } ?? ""
        let dirKey = "\(direction.emotion ?? "")|\(dirRate)|\(direction.styleInstruction ?? "")"
        let payload = "synth_v1|\(characterID)|\(anchorKey)|\(stageKey)|\(dirKey)|\(providerID)|\(modelID)|\(modelRevision)|\(spokenText)"
        return sha256Digest(Data(payload.utf8))
    }

    fileprivate mutating func absorb(_ incoming: Self) {
        func appendNew(_ values: [String], to list: inout [String]) {
            var seen = Set(list.map(trimmed))
            for value in values where !trimmed(value).isEmpty && seen.insert(trimmed(value)).inserted {
                list.append(value)
            }
        }
        let names = [incoming.canonicalName] + incoming.aliases
        appendNew(names.filter { trimmed($0) != trimmed(canonicalName) }, to: &aliases)
        appendNew(incoming.evidenceExcerpts, to: &evidenceExcerpts)
        appendNew(incoming.speechHabits, to: &speechHabits)
        if !incoming.gender.isEmpty { gender = incoming.gender }
        if !incoming.ageBand.isEmpty { ageBand = incoming.ageBand }
        if !incoming.personaSummary.isEmpty { personaSummary = incoming.personaSummary }
        if !locked {
            if !incoming.voiceDesignPrompt.isEmpty { voiceDesignPrompt = incoming.voiceDesignPrompt }
            providerBindings.merge(incoming.providerBindings) { _, new in new }
            if let anchor = incoming.timbreAnchor { timbreAnchor = anchor }
        } else if timbreAnchor == nil, let anchor = incoming.timbreAnchor {
            // Setting the initial timbre anchor for a locked card does not alter its voice design identity.
            timbreAnchor = anchor
        }
        if !incoming.deliveryStages.isEmpty {
            var byKey: [String: VoiceDeliveryStage] = Dictionary(uniqueKeysWithValues: deliveryStages.map { ($0.stageID, $0) })
            for stage in incoming.deliveryStages {
                if let existing = byKey[stage.stageID], existing.revision > stage.revision {
                    continue
                }
                byKey[stage.stageID] = stage
            }
            deliveryStages = byKey.values.sorted {
                if $0.effectiveFromChapter != $1.effectiveFromChapter {
                    return $0.effectiveFromChapter < $1.effectiveFromChapter
                }
                return $0.stageID < $1.stageID
            }
        }
        locked = locked || incoming.locked
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum VoiceCatalogError: Error, Equatable, Sendable {
    case ambiguousCharacter
    case invalidMarkdown(line: Int)
    case revisionOverflow
}

public struct CharacterVoiceCatalog: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public private(set) var revision: Int
    public private(set) var cards: [CharacterVoiceCard]

    public init(projectID: String, revision: Int = 1, cards: [CharacterVoiceCard] = []) {
        self.projectID = projectID
        self.revision = revision
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", projectID = "project_id", revision, cards
    }

    private func matchingIndices(_ name: String) -> [Int] {
        let key = trimmed(name)
        guard !key.isEmpty else { return [] }
        let ids = cards.indices.filter { trimmed(cards[$0].characterID) == key }
        if !ids.isEmpty { return ids }
        let names = cards.indices.filter { trimmed(cards[$0].canonicalName) == key }
        if !names.isEmpty { return names }
        return cards.indices.filter { cards[$0].aliases.contains { trimmed($0) == key } }
    }

    /// A shared title alone cannot identify a speaker.
    public func resolveCharacter(namedOrAliased name: String) -> CharacterVoiceCard? {
        let matches = matchingIndices(name)
        return matches.count == 1 ? cards[matches[0]] : nil
    }

    public func merging(incomingCards: [CharacterVoiceCard]) throws -> Self {
        var merged = self
        for incoming in incomingCards {
            var matches = merged.matchingIndices(incoming.characterID)
            if matches.isEmpty { matches = merged.matchingIndices(incoming.canonicalName) }
            if matches.isEmpty {
                matches = Array(Set(incoming.aliases.flatMap { merged.matchingIndices($0) }))
            }
            guard matches.count <= 1 else { throw VoiceCatalogError.ambiguousCharacter }
            if let index = matches.first {
                merged.cards[index].absorb(incoming)
            } else {
                merged.cards.append(incoming)
            }
        }
        guard merged.cards != cards else { return self }
        guard revision < Int.max else { throw VoiceCatalogError.revisionOverflow }
        merged.revision += 1
        for index in cards.indices where cards[index] != merged.cards[index] {
            guard cards[index].revision < Int.max else { throw VoiceCatalogError.revisionOverflow }
            merged.cards[index].revision += 1
        }
        return merged
    }

    public func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Each Markdown bullet edits one JSON value. Quoting preserves literal
    /// punctuation, newlines, and whitespace even in names and provider keys.
    public func renderMarkdown() throws -> String {
        typealias Card = CharacterVoiceCard.CodingKeys
        typealias Binding = ProviderVoiceBinding.CodingKeys
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func row(_ key: String, _ value: some Encodable) throws -> String {
            "- " + key + ": " + String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var lines = try ["# Character voice catalog", "", row(CodingKeys.version.rawValue, schemaVersion),
                         row(CodingKeys.projectID.rawValue, projectID), row(CodingKeys.revision.rawValue, revision)]
        for card in cards {
            lines += try ["", "## Character", "", row(Card.version.rawValue, card.schemaVersion),
                          row(Card.characterID.rawValue, card.characterID), row(Card.canonicalName.rawValue, card.canonicalName),
                          row(Card.aliases.rawValue, card.aliases), row(Card.gender.rawValue, card.gender),
                          row(Card.ageBand.rawValue, card.ageBand), row(Card.personaSummary.rawValue, card.personaSummary),
                          row(Card.speechHabits.rawValue, card.speechHabits), row(Card.evidenceExcerpts.rawValue, card.evidenceExcerpts),
                          row(Card.voiceDesignPrompt.rawValue, card.voiceDesignPrompt), row(Card.revision.rawValue, card.revision),
                          row(Card.locked.rawValue, card.locked)]
            if let anchor = card.timbreAnchor {
                lines.append(try row(Card.timbreAnchor.rawValue, anchor))
            }
            if !card.deliveryStages.isEmpty {
                lines.append(try row(Card.deliveryStages.rawValue, card.deliveryStages))
            }
            for (key, binding) in card.providerBindings.sorted(by: { $0.key < $1.key }) {
                lines += try ["", "### Provider binding", "", row("key", key), row(Binding.providerID.rawValue, binding.providerID),
                              row(Binding.speakerID.rawValue, binding.speakerID), row(Binding.baseInstruction.rawValue, binding.baseInstruction),
                              row(Binding.speakingRate.rawValue, binding.speakingRate), row(Binding.extraParameters.rawValue, binding.extraParameters)]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseMarkdown(_ markdown: String) throws -> Self {
        enum Section { case catalog, character, binding }
        var section: Section = .catalog
        typealias Fields = [String: String]
        var catalog: Fields = [:]
        var cards: [String] = []
        var card: Fields = [:]
        var bindings: Fields = [:]
        var fields: Fields = [:]

        // Values have already been parsed as single JSON fragments; preserve their exact numeric spelling.
        func object(_ fields: Fields) throws -> String {
            let members = try fields.map { key, value in
                String(decoding: try JSONEncoder().encode(key), as: UTF8.self) + ":" + value
            }
            return "{" + members.joined(separator: ",") + "}"
        }
        func finishBinding(at line: Int) throws {
            guard section == .binding else { return }
            guard let literal = fields.removeValue(forKey: "key"),
                  let key = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)), bindings[key] == nil else {
                throw VoiceCatalogError.invalidMarkdown(line: line)
            }
            bindings[key] = try object(fields)
            fields = [:]
        }
        func finishCard(at line: Int) throws {
            guard section != .catalog else { return }
            try finishBinding(at: line)
            card["provider_bindings"] = try object(bindings)
            cards.append(try object(card))
            card = [:]
            bindings = [:]
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "# Character voice catalog" else { throw VoiceCatalogError.invalidMarkdown(line: 1) }
        for (index, raw) in lines.enumerated().dropFirst() {
            let line = trimmed(raw)
            let number = index + 1
            if line.isEmpty { continue }
            switch line {
            case "## Character":
                try finishCard(at: number)
                section = .character
            case "### Provider binding" where section != .catalog:
                try finishBinding(at: number)
                section = .binding
            default:
                guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else {
                    throw VoiceCatalogError.invalidMarkdown(line: number)
                }
                let key = String(line.dropFirst(2).prefix(upTo: colon))
                let value = String(line.suffix(from: line.index(after: colon)))
                guard (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) != nil else {
                    throw VoiceCatalogError.invalidMarkdown(line: number)
                }
                let valid: Bool
                switch section {
                case .catalog:
                    valid = CodingKeys(rawValue: key) != nil && key != "cards" && catalog.updateValue(value, forKey: key) == nil
                case .character:
                    valid = CharacterVoiceCard.CodingKeys(rawValue: key) != nil && key != "provider_bindings"
                        && card.updateValue(value, forKey: key) == nil
                case .binding:
                    valid = (key == "key" || ProviderVoiceBinding.CodingKeys(rawValue: key) != nil)
                        && fields.updateValue(value, forKey: key) == nil
                }
                guard valid else { throw VoiceCatalogError.invalidMarkdown(line: number) }
            }
        }
        try finishCard(at: lines.count)
        catalog["cards"] = "[" + cards.joined(separator: ",") + "]"
        return try decodeJSON(Data(object(catalog).utf8))
    }
}
