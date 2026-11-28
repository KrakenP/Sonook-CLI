import AudioCore
import Foundation
import Testing

@Suite struct ReaderContractsTests {
    private func segment(_ id: String, start: Double?, end: Double?) throws -> ReaderSegment {
        ReaderSegment(segmentID: id, chapterID: "ch_2", speakerID: "c", speakerName: "林",
            sourceSpan: try SourceSpan(start: 20, endExclusive: 30), chapterUTF8Start: 4, chapterUTF8EndExclusive: 14,
            sourceText: "“📖”", spokenText: "📖", status: .needsReview, startSeconds: start, endSeconds: end,
            segmentAudioPath: "segment.wav", qualityReasons: [.highCER])
    }

    @Test func summaryWireFormat() throws {
        let summary = ProjectSummary(projectID: "p", name: "书", projectType: .audiobook, createdAtISO8601: "2026-01-01T00:00:00Z",
            chapterCount: 2, analyzedChapterCount: 1, needsReviewCount: 3, latestJobID: "j", latestJobStatus: .needsReview,
            latestAudioPath: "book.m4a", latestTimelinePath: "book.timeline.json")
        let data = try JSONEncoder().encode(summary)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schema_version", "project_id", "name", "project_type", "created_at", "chapter_count",
                                   "analyzed_chapter_count", "needs_review_count", "latest_job_id", "latest_job_status",
                                   "latest_audio_path", "latest_timeline_path"])
        #expect(json["schema_version"] as? Int == 1)
        #expect(try JSONDecoder().decode(ProjectSummary.self, from: data) == summary)
        var future = json
        future["schema_version"] = 2
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectSummary.self, from: JSONSerialization.data(withJSONObject: future))
        }
    }

    @Test func readerWireFormat() throws {
        let seg = try segment("s", start: 4, end: 5)
        let reader = ReaderChapterPayload(projectID: "p", chapterID: seg.chapterID, chapterNumber: 2, title: "章",
            chapterText: "章\n“📖”", chapterStartUTF8Byte: 16, audioFilePath: "book.m4a",
            timelinePath: "book.timeline.json", audioDurationSeconds: 5, segments: [seg])
        let data = try JSONEncoder().encode(reader)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schema_version", "project_id", "chapter_id", "chapter_number", "title", "chapter_text",
                                   "chapter_start_utf8_byte", "audio_file_path", "timeline_path", "audio_duration_seconds", "segments"])
        #expect(json["schema_version"] as? Int == 1)
        let entry = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["segment_id", "chapter_id", "speaker_id", "speaker_name", "source_span", "chapter_utf8_start",
                                    "chapter_utf8_end_exclusive", "source_text", "spoken_text", "status", "start_seconds",
                                    "end_seconds", "segment_audio_path", "quality_reasons"])
        #expect(entry["quality_reasons"] as? [String] == ["highCER"])
        #expect(seg.id == seg.segmentID)
        #expect(try JSONDecoder().decode(ReaderChapterPayload.self, from: data) == reader)
    }

    @Test func timelineBoundariesAndPauses() throws {
        let untimed = try segment("u", start: nil, end: nil)
        let segments = try [untimed, segment("a", start: 1, end: 2), segment("u2", start: 2, end: nil),
                            segment("b", start: 2.2, end: 3), segment("c", start: 3, end: 4), untimed]
        let cases: [(Double, Int?)] = [(-1, nil), (0, nil), (0.949, nil), (0.95, 1), (1, 1), (1.5, 1),
                                       (2, 1), (2.1, 1), (2.2, 3), (2.99, 3), (3, 4), (4, 4), (20, 4), (.nan, nil)]
        for (time, expected) in cases {
            #expect(ReaderTimelineMatcher.activeSegmentIndex(atSeconds: time, in: segments) == expected)
        }
        #expect(ReaderTimelineMatcher.activeSegmentIndex(atSeconds: 0, in: []) == nil)
        #expect(ReaderTimelineMatcher.activeSegmentIndex(atSeconds: 2, in: [untimed]) == nil)
        #expect(try ReaderTimelineMatcher.activeSegmentIndex(atSeconds: 0, in: [segment("a", start: 0, end: 0)]) == 0)
        let overlap = try [segment("a", start: 0, end: 2), segment("b", start: 1, end: 3)]
        #expect(ReaderTimelineMatcher.activeSegmentIndex(atSeconds: 1, in: overlap) == 1)
        #expect(try ReaderTimelineMatcher.activeSegmentIndex(atSeconds: -0.01, in: [segment("a", start: 0, end: 1)]) == nil)
    }

    @Test func utf16UsesScalarBoundaries() {
        let text = "A“中📖”\ne\u{301}"
        let cases = [(0, 1, 0, 1), (1, 4, 1, 1), (4, 7, 2, 1), (7, 11, 3, 2), (11, 15, 5, 2),
                     (1, 15, 1, 6), (16, 18, 8, 1), (18, 18, 9, 0)]
        for (start, end, location, length) in cases {
            #expect(ReaderTimelineMatcher.utf16Range(forUTF8Start: start, endExclusive: end, in: text)
                    == UTF16TextRange(location: location, length: length))
        }
        #expect(ReaderTimelineMatcher.utf16Range(forUTF8Start: 0, endExclusive: 0, in: "") == .init(location: 0, length: 0))
        for (start, end) in [(-1, 3), (4, 1), (19, 19), (0, Int.max), (Int.min, 0), (5, 7), (7, 8), (9, 9)] {
            #expect(ReaderTimelineMatcher.utf16Range(forUTF8Start: start, endExclusive: end, in: text) == nil)
        }
    }
}
