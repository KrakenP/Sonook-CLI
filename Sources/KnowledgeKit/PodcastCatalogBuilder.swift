import AudioCore

public enum PodcastCatalogBuilder {
    static func hostIDs(for format: PodcastFormat) -> [String] {
        format == .soloExplainer ? ["host_a"] : ["host_a", "host_b"]
    }

    /// Add missing host IDs without changing a user's casting, voice revisions, or locks.
    public static func build(projectID: String, format: PodcastFormat,
                             existing: CharacterVoiceCatalog? = nil) throws -> CharacterVoiceCatalog {
        if let existing, existing.projectID != projectID { throw KnowledgeError.invalidEpisode }
        var cards = existing?.cards ?? []
        for id in hostIDs(for: format) where !cards.contains(where: { $0.characterID == id }) {
            let lead = id == "host_a"
            cards.append(.init(characterID: id, canonicalName: lead ? "主讲" : "搭档",
                               voiceDesignPrompt: lead ? "普通话，沉稳清晰，像在向听众解释一个新概念。" : "普通话，明朗自然，提问时留出思考的停顿。"))
        }
        guard let existing else { return .init(projectID: projectID, cards: cards) }
        guard cards.count != existing.cards.count else { return existing }
        guard existing.revision < Int.max else { throw VoiceCatalogError.revisionOverflow }
        return .init(projectID: projectID, revision: existing.revision + 1, cards: cards)
    }
}
