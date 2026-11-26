import AudioCore
import Foundation
import Testing

@Suite("P3 Contracts (Memory & Repair Policy)")
struct ChapterMemoryContractTests {
    @Test("ChapterMemoryRecord round-trips JSON with schema_version=1 and snake_case keys")
    func chapterMemoryCodableRoundTrip() throws {
        let record = ChapterMemoryRecord(
            projectID: "proj_p3_test",
            chapterID: "ch_003",
            chapterNumber: 3,
            sourceDocumentRevision: "doc_rev_1",
            summary: "顾辰在溪边棋盘旁苏醒，发现周围天地异变。",
            activeCharacterIDs: ["char_narrator", "char_001"],
            characterStates: [
                CharacterChapterState(
                    characterID: "char_001",
                    canonicalName: "顾辰",
                    statusSummary: "初醒虚弱但心智冷静",
                    location: "荒山破庙",
                    relationships: ["与山中老道初遇"],
                    lastSeenChapter: 3
                )
            ],
            openThreads: ["半局残棋的来历"],
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )
        let data = try JSONEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"schema_version\":1"))
        #expect(json.contains("\"active_character_ids\""))
        #expect(json.contains("\"last_seen_chapter\":3"))

        let decoded = try JSONDecoder().decode(ChapterMemoryRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("SegmentAutoRepairPolicy derives distinct deterministic seeds per repair round")
    func repairPolicyDeterministicSeeds() {
        let policy = SegmentAutoRepairPolicy(maxRepairRounds: 3, seedStride: 37)
        let s1 = policy.seed(forBaseSeed: 42, round: 1)
        let s2 = policy.seed(forBaseSeed: 42, round: 2)
        let s3 = policy.seed(forBaseSeed: 42, round: 3)
        #expect(s1 == 79)
        #expect(s2 == 116)
        #expect(s3 == 153)
        #expect(Set([UInt64(42), s1, s2, s3]).count == 4)
    }
}
