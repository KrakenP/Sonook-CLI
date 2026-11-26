import AudioCore
import Foundation

/// Patterns are matched against individual clauses. English word boundaries avoid
/// finding "rain" in "train"; excerpts retain the spelling of the source.
private struct CuePattern: Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    func range(in text: String) -> Range<String.Index>? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }
    }

    func excerpt(in text: String) -> String? {
        range(in: text).map { String(text[$0]) }
    }
}

struct SoundscapeEvidence {
    struct Scene {
        let preset: SceneAtmospherePreset
        let excerpt: String
    }

    struct Effect {
        let prompt: String
        let excerpt: String
    }

    // Order resolves simultaneous signals in a single clause.
    private static let scenes: [(SceneAtmospherePreset, CuePattern)] = [
        (.campfireHearth, .init(#"火堆|火苗|打火石|篝火|炉火|壁炉|\b(campfire|hearth|fireplace|flint)\b"#)),
        (.templeQuiet, .init(#"山神庙|破庙|古寺|寺庙|庙里|\btemple\b"#)),
        (.tavernCrowd, .init(#"酒馆|客栈|嘈杂|\b(tavern|inn|pub)\b"#)),
        (.stormThunder, .init(#"雷声|雷鸣|轰隆隆|闪电|\b(thunder(clap|storm|ed|ing)?|lightning)\b"#)),
        (.rainHeavy, .init(#"大雨|暴雨|倾盆|瓢泼|\b(heavy rain|pouring rain|downpour|deluge)\b"#)),
        (.rainLight, .init(#"雨点|春雨|细雨|小雨|下雨|雨滴|雨声|\b(drizzl(e|ing)|rain(drops?|ing)?)\b"#)),
        (.streamWater, .init(#"小溪|溪水|溪流|流水潺潺|\b(stream|brook|creek)\b"#)),
        (.nightInsects, .init(#"夜深|虫鸣|月光|\b(crickets?|moonlight|late at night)\b"#)),
        (.forestWind, .init(#"山林|鸟语|树林|林间|森林|\b(forest|woods|woodland|birdsong)\b"#)),
        (.cityStreet, .init(#"街道|闹市|\bcity street\b"#)),
        (.indoorRoom, .init(#"室内|屋里|屋内|房间|\b(indoors|inside the room)\b"#))
    ]

    private static let effects: [(String, CuePattern)] = [
        ("thunderclap", .init(#"轰隆隆|雷声|雷鸣|闪电|\b(thunder(clap|ed|ing)?|lightning)\b"#)),
        ("single pattering tap", .init(#"啪嗒|\b(pitter-patter|raindrop)\b"#)),
        ("flint strike", .init(#"打火石|啪(?:[，,、\s]*啪){2}|\bflint\b"#)),
        ("fire crackling", .init(#"火堆|火苗|篝火|\bcrackling fire\b"#)),
        ("pot lid rattling", .init(#"乒乒乓乓|锅盖|\bpot lid\b"#)),
        ("door knock", .init(#"敲门|叩门|\b(knock(ed|ing)? (on|at) the door|door knock)\b"#)),
        ("door opening", .init(#"推门|\b(open(ed|ing)?|push(ed|ing)? open) the door\b"#)),
        ("sword unsheathing", .init(#"拔剑|剑|\b(unsheath(ed|ing)? (a |the |his |her )?sword|drew (a |the |his |her )sword)\b"#))
    ]

    private static let weather: Set<SceneAtmospherePreset> = [.rainLight, .rainHeavy, .stormThunder]
    private static let clearSky = CuePattern(#"晴天|晴朗|放晴|天晴|阳光|雨停|雨过天晴|\b(sunny|sunshine|cleared up)\b"#)
    private static let soundWords = CuePattern(
        #"声|响|鸣|吱呀|咔嚓|嗡嗡|叮当|\b(rang|rang out|clanged|creaked|toll(ed|ing)?|buzz(ed|ing)?|hiss(ed|ing)?)\b"#
    )

    private static let hypothetical = CuePattern(
        #"若是|假如|如果|想起|回忆|昨日的|仿佛|明天会|盼着|\b(if|remembered|tomorrow|yesterday)\b"#
    )
    private static let negation = CuePattern(#"没有|并无|未曾|听不到|\b(no|without|never)\b"#)
    private static let cessation = CuePattern(#"不再|雨停|雨过天晴|雨已经停|熄灭|\b(stopped|ceased)\b"#)

    static let effectPrompts = effects.map { $0.0 }

    static func isSoundExcerpt(_ excerpt: String, in source: String) -> Bool {
        guard soundWords.excerpt(in: excerpt) != nil else { return false }
        return source.components(separatedBy: CharacterSet(charactersIn: "，,。！？.!?；;\n")).contains {
            assertedClause($0).text.contains(excerpt)
        }
    }

    /// Return the affirmed part and any explicitly negated setting. Remembering
    /// yesterday's storm neither introduces nor ends a storm in the current scene.
    private static func assertedClause(_ clause: String) -> (text: String, absent: String?) {
        let current = hypothetical.range(in: clause).map { String(clause[..<$0.lowerBound]) } ?? clause
        if cessation.range(in: current) != nil { return ("", current) }
        if let range = negation.range(in: current) {
            return (String(current[..<range.lowerBound]), String(current[range.lowerBound...]))
        }
        return (current, nil)
    }

    var excluded = Set<SceneAtmospherePreset>()
    var preferred: Scene?
    var scenesByPreset: [SceneAtmospherePreset: String] = [:]
    var effects: [Effect] = []

    init(_ text: String) {
        // Keep comma-separated onomatopoeia intact for point effects.
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？.!?；;\n"))
        var foundPrompts = Set<String>()
        for sentence in sentences {
            for part in sentence.components(separatedBy: CharacterSet(charactersIn: "，,")) {
                let (clause, absent) = Self.assertedClause(part)
                if let absent {
                    let mentioned = Set(Self.sceneMatches(in: absent).map(\.preset))
                    let weatherEnded = !mentioned.isDisjoint(with: Self.weather) || Self.clearSky.range(in: absent) != nil
                    exclude(weatherEnded ? mentioned.union(Self.weather) : mentioned)
                }
                var matches = Self.sceneMatches(in: clause)
                if Self.clearSky.range(in: clause) != nil {
                    exclude(Self.weather)
                    matches.removeAll { Self.weather.contains($0.preset) }
                }
                if let first = matches.first {
                    preferred = first.preset == .indoorRoom ? Scene(preset: .none, excerpt: first.excerpt) : first
                    scenesByPreset.removeAll()
                    for match in matches {
                        excluded.remove(match.preset)
                        scenesByPreset[match.preset] = match.excerpt
                    }
                }
                for (prompt, pattern) in Self.effects {
                    if let excerpt = pattern.excerpt(in: clause), foundPrompts.insert(prompt).inserted {
                        effects.append(Effect(prompt: prompt, excerpt: excerpt))
                    }
                }
            }
            if !foundPrompts.contains("flint strike"), let excerpt = Self.flintTaps.excerpt(in: Self.assertedClause(sentence).text) {
                effects.append(Effect(prompt: "flint strike", excerpt: excerpt))
                foundPrompts.insert("flint strike")
            }
        }
    }

    private static func sceneMatches(in clause: String) -> [Scene] {
        scenes.compactMap { preset, rule in
            rule.excerpt(in: clause).map { Scene(preset: preset, excerpt: $0) }
        }
    }

    private mutating func exclude(_ presets: Set<SceneAtmospherePreset>) {
        excluded.formUnion(presets)
        for preset in presets { scenesByPreset.removeValue(forKey: preset) }
        if let preset = preferred?.preset, presets.contains(preset) { preferred = nil }
    }

    private static let flintTaps = CuePattern(#"啪(?:[，,、\s]*啪){2}"#)
}
