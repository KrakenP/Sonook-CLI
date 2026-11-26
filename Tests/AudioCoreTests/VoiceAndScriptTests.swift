import AudioCore
import Foundation
import Testing

@Suite struct VoiceAndScriptTests {
    let bindings = ["舟:1": ProviderVoiceBinding(providerID: "ferry", speakerID: "舟",
                                                 baseInstruction: "轻，慢。\n保留停顿", speakingRate: 0.91875,
                                                 extraParameters: ["声*线": " \"柔\" | \\ "])]
    var locked: CharacterVoiceCard {
        .init(characterID: "wen", canonicalName: "闻舟", aliases: [" 舟师傅 "], gender: "男", ageBand: "中年",
              personaSummary: "守夜渡", speechHabits: ["慢声", "听。"], evidenceExcerpts: ["\n## Character\n", "看：\t水尺"],
              voiceDesignPrompt: "低声\n第二行", providerBindings: bindings, revision: 3, locked: true)
    }

    @Test func jsonAndEditableMarkdownRoundTrip() throws {
        var wen = locked
        wen.providerBindings["another"] = .init(providerID: "other", speakerID: "boat")
        let catalog = CharacterVoiceCatalog(projectID: "渡口", revision: 4, cards: [wen, .init(characterID: "mu", canonicalName: "穆青")])
        let data = try catalog.encodeJSON()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\n"))
        #expect(json.contains("\"voice_design_prompt\""))
        #expect(try CharacterVoiceCatalog.decodeJSON(data) == catalog)
        #expect(try CharacterVoiceCatalog.decodeJSON(data).encodeJSON() == data)
        let md = try catalog.renderMarkdown()
        #expect(try CharacterVoiceCatalog.parseMarkdown(md) == catalog)
        #expect(try CharacterVoiceCatalog.parseMarkdown(md.replacingOccurrences(of: "\n", with: "\r\n")) == catalog)
        let edited = md.replacingOccurrences(of: "- canonical_name: \"闻舟\"", with: "- canonical_name: \"老舟\"")
            .replacingOccurrences(of: "- speaking_rate: 0.91875", with: "- speaking_rate: 1.125")
        let changed = try CharacterVoiceCatalog.parseMarkdown(edited)
        #expect(changed.cards[0].canonicalName == "老舟")
        #expect(changed.cards[0].providerBindings["舟:1"]?.speakingRate == 1.125)
        #expect(changed.cards[0].evidenceExcerpts == wen.evidenceExcerpts)
        let empty = CharacterVoiceCatalog(projectID: "")
        #expect(try CharacterVoiceCatalog.parseMarkdown(empty.renderMarkdown()) == empty)
    }

    @Test func catalogRefusesDamagedEditsAndUnknownVersions() throws {
        let catalog = CharacterVoiceCatalog(projectID: "p", cards: [locked])
        let markdown = try catalog.renderMarkdown()
        for edit in [markdown + "- speaker_id: \"dup\"", markdown + "- typo: true",
                     markdown + "- invalid", markdown.replacingOccurrences(of: "## Character\n", with: ""),
                     markdown.replacingOccurrences(of: "- schema_version: 1", with: "- schema_version: 7")] {
            #expect(throws: (any Error).self) { try CharacterVoiceCatalog.parseMarkdown(edit) }
        }
        let json = String(decoding: try catalog.encodeJSON(), as: UTF8.self)
        for modified in [json.replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 0"),
                         json.replacingOccurrences(of: "\"schema_version\"", with: "\"version\"")] {
            #expect(throws: DecodingError.self) { try CharacterVoiceCatalog.decodeJSON(Data(modified.utf8)) }
        }
    }

    @Test func crossChapterAliasesPreserveLockedVoiceAndBumpOnlyOnChange() throws {
        let base = CharacterVoiceCatalog(projectID: "p", revision: 5, cards: [locked])
        for query in [" wen ", "\n闻舟", "舟师傅 "] {
            #expect(base.resolveCharacter(namedOrAliased: query) == locked)
        }
        #expect(base.resolveCharacter(namedOrAliased: " ") == nil)
        let discovery = CharacterVoiceCard(characterID: "new-wen", canonicalName: "舟师傅", aliases: ["船家", "船家"],
                                          speechHabits: ["慢声", "反问"], evidenceExcerpts: ["手搭船篙"],
                                          voiceDesignPrompt: "尖亮", providerBindings: ["改": .init(providerID: "改", speakerID: "X")])
        let later = try base.merging(incomingCards: [discovery, discovery, .init(characterID: "cen", canonicalName: "岑禾")])
        let merged = try #require(later.resolveCharacter(namedOrAliased: "船家"))
        #expect(merged.characterID == "wen")
        #expect(merged.canonicalName == "闻舟")
        #expect(merged.locked && merged.voiceDesignPrompt == locked.voiceDesignPrompt)
        #expect(merged.providerBindings == bindings)
        #expect(merged.aliases == [" 舟师傅 ", "船家"])
        #expect(merged.evidenceExcerpts == locked.evidenceExcerpts + ["手搭船篙"])
        #expect(merged.revision == 4 && later.revision == 6)
        #expect(later.cards.count == 2)
        #expect(try later.merging(incomingCards: [discovery]) == later)
        var attempted = discovery
        attempted.voiceDesignPrompt = "换声"
        #expect(try later.merging(incomingCards: [attempted]) == later)
    }

    @Test func unlockedUpdatesAndAmbiguousTitles() throws {
        let a = CharacterVoiceCard(characterID: "a", canonicalName: "穆青", aliases: ["掌柜"])
        let b = CharacterVoiceCard(characterID: "b", canonicalName: "岑禾", aliases: ["掌柜"])
        let catalog = CharacterVoiceCatalog(projectID: "p", cards: [a, b])
        #expect(catalog.resolveCharacter(namedOrAliased: "掌柜") == nil)
        #expect(throws: VoiceCatalogError.ambiguousCharacter) {
            try catalog.merging(incomingCards: [.init(characterID: "c", canonicalName: "掌柜")])
        }
        var update = a
        update.locked = true
        update.voiceDesignPrompt = "轻快"
        update.providerBindings = bindings
        let next = try catalog.merging(incomingCards: [update])
        #expect(next.cards[0].locked && next.cards[0].providerBindings == bindings)
        #expect(next.cards[0].voiceDesignPrompt == "轻快")
        #expect(next.cards[1] == b)
    }

    @Test func architectureExampleAndAllScriptFields() throws {
        let example = """
        {"schema_version":1,"segment_id":"s","chapter_id":"ch_003","source_document_revision":"doc_rev_1",
         "source_span":{"unit":"utf8_byte","start":1820,"end_exclusive":1844},
         "source_text":"你终于回来了。","spoken_text":"你终于回来了。","speaker_id":"char_007",
         "voice_profile_revision":"voice_007_rev_1","direction":{"emotion":"restrained_relief","rate":0.92,"pause_after_ms":500},
         "script_revision":1,"audio_artifact_id":null,"status":"pending"}
        """
        var segment = try JSONDecoder().decode(ScriptSegment.self, from: Data(example.utf8))
        #expect(segment.schemaVersion == 1 && segment.status == .pending && segment.audioArtifactID == nil)
        #expect(segment.direction == .init(emotion: "restrained_relief", rate: 0.92, pauseAfterMs: 500))
        #expect(segment.attributionEvidence.isEmpty)
        let pendingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segment)) as? [String: Any]
        #expect(pendingJSON?["audio_artifact_id"] is NSNull)
        segment.direction.styleInstruction = "低声"
        segment.attributionConfidence = 0.97
        segment.attributionEvidence = ["同一段对白"]
        segment.normalizationNote = "保留原文"
        segment.audioArtifactID = "asset-1"
        for status in SegmentStatus.allCases {
            segment.status = status
            let script = ScriptDocument(chapterID: segment.chapterID, sourceDocumentRevision: segment.sourceDocumentRevision,
                                        scriptRevision: 1, segments: [segment])
            let data = try JSONEncoder().encode(script)
            #expect(try JSONDecoder().decode(ScriptDocument.self, from: data) == script)
            let json = String(decoding: data, as: UTF8.self)
            for key in ["schema_version", "normalization_note", "attribution_confidence", "attribution_evidence", "style_instruction"] {
                #expect(json.contains("\"" + key + "\""))
            }
            let changed = json.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ScriptDocument.self, from: Data(changed.utf8)) }
        }
    }
}
