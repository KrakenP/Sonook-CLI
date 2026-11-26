import AudioCore
import Foundation
import Testing

@Suite("Engine & Progression Contracts")
struct EngineAndProgressionTests {
    @Test func timbreAnchorAndTwoChapterVoiceProgressionPreserveContinuityAndCacheBoundary() throws {
        let anchor = VoiceTimbreAnchor(
            anchorID: "anc_protagonist_v1",
            assetID: "ast_audition_001",
            fileSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            generatorProviderID: "qwen3-tts-voice-design",
            generatorModelID: "Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16",
            designPrompt: "标准普通话青年男声，清亮自然",
            auditionText: "今天天气不错，大家先把事情商量清楚。",
            sampleRate: 24_000,
            createdAtISO8601: "2026-11-25T00:00:00Z"
        )

        let earlyStage = VoiceDeliveryStage(
            stageID: "stage_youth",
            effectiveFromChapter: 1,
            revision: 1,
            stageLabel: "初入江湖",
            deliveryBaseline: "语速轻快略带朝气",
            speakingRate: 1.03,
            evidence: "第一章初出场"
        )
        let matureStage = VoiceDeliveryStage(
            stageID: "stage_mature",
            effectiveFromChapter: 20,
            revision: 1,
            stageLabel: "历经沧桑",
            deliveryBaseline: "语气沉稳从容，呼吸更缓",
            speakingRate: 0.94,
            evidence: "第二十章后心态沉淀"
        )

        let card = CharacterVoiceCard(
            characterID: "char_hero",
            canonicalName: "林青",
            aliases: ["青哥"],
            gender: "男",
            ageBand: "青年",
            personaSummary: "成长型主角",
            voiceDesignPrompt: "标准普通话青年男声，清亮自然",
            timbreAnchor: anchor,
            deliveryStages: [matureStage, earlyStage],
            revision: 1,
            locked: true
        )

        // Active delivery stage switches by chapter while keeping the exact same timbre anchor
        #expect(card.activeDeliveryStage(forChapter: 1)?.stageID == "stage_youth")
        #expect(card.activeDeliveryStage(forChapter: 19)?.stageID == "stage_youth")
        #expect(card.activeDeliveryStage(forChapter: 20)?.stageID == "stage_mature")
        #expect(card.activeDeliveryStage(forChapter: 100)?.stageID == "stage_mature")

        let dir = SegmentDirection(emotion: "calm", rate: 1.0, pauseAfterMs: 300, styleInstruction: "微微停顿")
        let fpCh1 = card.synthesisFingerprint(
            chapterIndex: 1,
            spokenText: "前面有雾，慢些走。",
            direction: dir,
            providerID: "voxcpm2-mlx",
            modelID: "VoxCPM2-8bit",
            modelRevision: "local"
        )
        let fpCh20 = card.synthesisFingerprint(
            chapterIndex: 20,
            spokenText: "前面有雾，慢些走。",
            direction: dir,
            providerID: "voxcpm2-mlx",
            modelID: "VoxCPM2-8bit",
            modelRevision: "local"
        )
        #expect(fpCh1 != fpCh20)

        // Absorbing new aliases & evidence excerpts MUST NOT invalidate chapter 1 synthesis fingerprint!
        let catalogV1 = CharacterVoiceCatalog(projectID: "proj_prog", revision: 1, cards: [card])
        let metadataOnlyUpdate = CharacterVoiceCard(
            characterID: "char_hero",
            canonicalName: "林青",
            aliases: ["林先生", "青少侠"],
            evidenceExcerpts: ["第十二章旁人称他林先生"],
            voiceDesignPrompt: "试图覆盖已锁定声线",
            locked: true
        )
        let catalogV2 = try catalogV1.merging(incomingCards: [metadataOnlyUpdate])
        let updatedHero = try #require(catalogV2.resolveCharacter(namedOrAliased: "林先生"))
        #expect(updatedHero.timbreAnchor == anchor)
        #expect(updatedHero.voiceDesignPrompt == card.voiceDesignPrompt)
        let fpCh1AfterMeta = updatedHero.synthesisFingerprint(
            chapterIndex: 1,
            spokenText: "前面有雾，慢些走。",
            direction: dir,
            providerID: "voxcpm2-mlx",
            modelID: "VoxCPM2-8bit",
            modelRevision: "local"
        )
        #expect(fpCh1AfterMeta == fpCh1)

        // Markdown and JSON round-trip preserve timbreAnchor and deliveryStages losslessly
        let md = try catalogV2.renderMarkdown()
        let reparsed = try CharacterVoiceCatalog.parseMarkdown(md)
        #expect(reparsed == catalogV2)
        let jsonReparsed = try CharacterVoiceCatalog.decodeJSON(try catalogV2.encodeJSON())
        #expect(jsonReparsed == catalogV2)
    }

    @Test func legacyP0VoiceCatalogWithoutProgressionFieldsDecodesCleanly() throws {
        let legacyJSON = """
        {
          "schema_version": 1,
          "project_id": "legacy_p0",
          "revision": 2,
          "cards": [
            {
              "schema_version": 1,
              "character_id": "char_narrator",
              "canonical_name": "旁白",
              "aliases": ["narrator"],
              "gender": "男",
              "age_band": "中年",
              "persona_summary": "稳重叙述者",
              "speech_habits": ["平稳"],
              "evidence_excerpts": [],
              "voice_design_prompt": "标准普通话中年男声",
              "provider_bindings": {},
              "revision": 1,
              "locked": true
            }
          ]
        }
        """
        let catalog = try CharacterVoiceCatalog.decodeJSON(Data(legacyJSON.utf8))
        let narrator = try #require(catalog.resolveCharacter(namedOrAliased: "旁白"))
        #expect(narrator.timbreAnchor == nil)
        #expect(narrator.deliveryStages.isEmpty)
        #expect(narrator.activeDeliveryStage(forChapter: 1) == nil)
    }

    @Test func optionalAmbientConfigHashesIntoRenderKeyOnly() throws {
        let dryConfig = ChapterRenderConfig(chapterID: "ch_001", sampleRate: 48_000, ambientTrack: nil)
        let ambientConfig = ChapterRenderConfig(
            chapterID: "ch_001",
            sampleRate: 48_000,
            ambientTrack: AmbientTrackSpec(assetID: "ast_rain_01", presetName: "light_rain", gainDB: -26.0, duckingDB: -10.0)
        )
        let segHashes = ["hash_seg_1", "hash_seg_2"]
        #expect(dryConfig.renderFingerprint(segmentAssetHashes: segHashes) != ambientConfig.renderFingerprint(segmentAssetHashes: segHashes))

        // Default ProjectRecord keeps ambient disabled unless explicitly opted in
        let project = ProjectRecord(projectID: "proj_1", name: "测试书目", createdAtISO8601: "2026-11-25T00:00:00Z")
        #expect(project.options.ambientAudioEnabled == false)
        #expect(project.options.ambientTrack == nil)
    }
}
