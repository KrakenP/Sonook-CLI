public struct ProjectSummary: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let name: String
    public let projectType: ProjectType
    public let createdAtISO8601: String
    public let chapterCount: Int
    public let analyzedChapterCount: Int
    public let needsReviewCount: Int
    public let latestJobID: String?
    public let latestJobStatus: JobStatus?
    public let latestAudioPath: String?
    public let latestTimelinePath: String?

    public init(projectID: String, name: String, projectType: ProjectType, createdAtISO8601: String,
                chapterCount: Int, analyzedChapterCount: Int, needsReviewCount: Int,
                latestJobID: String? = nil, latestJobStatus: JobStatus? = nil,
                latestAudioPath: String? = nil, latestTimelinePath: String? = nil) {
        self.projectID = projectID
        self.name = name
        self.projectType = projectType
        self.createdAtISO8601 = createdAtISO8601
        self.chapterCount = chapterCount
        self.analyzedChapterCount = analyzedChapterCount
        self.needsReviewCount = needsReviewCount
        self.latestJobID = latestJobID
        self.latestJobStatus = latestJobStatus
        self.latestAudioPath = latestAudioPath
        self.latestTimelinePath = latestTimelinePath
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", projectID = "project_id", name, projectType = "project_type"
        case createdAtISO8601 = "created_at", chapterCount = "chapter_count"
        case analyzedChapterCount = "analyzed_chapter_count", needsReviewCount = "needs_review_count"
        case latestJobID = "latest_job_id", latestJobStatus = "latest_job_status"
        case latestAudioPath = "latest_audio_path", latestTimelinePath = "latest_timeline_path"
    }
}

public struct ReaderSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String { segmentID }
    public let segmentID: String
    public let chapterID: String
    public let speakerID: String
    public let speakerName: String
    public let sourceSpan: SourceSpan
    /// Half-open UTF-8 offsets relative to the start of the chapter text.
    public let chapterUTF8Start: Int
    public let chapterUTF8EndExclusive: Int
    public let sourceText: String
    public let spokenText: String
    public let status: SegmentStatus
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let segmentAudioPath: String?
    public let qualityReasons: [QualityReason]

    public init(segmentID: String, chapterID: String, speakerID: String, speakerName: String,
                sourceSpan: SourceSpan, chapterUTF8Start: Int, chapterUTF8EndExclusive: Int,
                sourceText: String, spokenText: String, status: SegmentStatus,
                startSeconds: Double? = nil, endSeconds: Double? = nil,
                segmentAudioPath: String? = nil, qualityReasons: [QualityReason] = []) {
        self.segmentID = segmentID
        self.chapterID = chapterID
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.sourceSpan = sourceSpan
        self.chapterUTF8Start = chapterUTF8Start
        self.chapterUTF8EndExclusive = chapterUTF8EndExclusive
        self.sourceText = sourceText
        self.spokenText = spokenText
        self.status = status
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.segmentAudioPath = segmentAudioPath
        self.qualityReasons = qualityReasons
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id", chapterID = "chapter_id", speakerID = "speaker_id", speakerName = "speaker_name"
        case sourceSpan = "source_span", chapterUTF8Start = "chapter_utf8_start", chapterUTF8EndExclusive = "chapter_utf8_end_exclusive"
        case sourceText = "source_text", spokenText = "spoken_text", status
        case startSeconds = "start_seconds", endSeconds = "end_seconds", segmentAudioPath = "segment_audio_path"
        case qualityReasons = "quality_reasons"
    }
}

public struct ReaderChapterPayload: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let chapterText: String
    public let chapterStartUTF8Byte: Int
    public let audioFilePath: String?
    public let timelinePath: String?
    public let audioDurationSeconds: Double?
    public let segments: [ReaderSegment]

    public init(projectID: String, chapterID: String, chapterNumber: Int, title: String,
                chapterText: String, chapterStartUTF8Byte: Int, audioFilePath: String? = nil,
                timelinePath: String? = nil, audioDurationSeconds: Double? = nil, segments: [ReaderSegment]) {
        self.projectID = projectID
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.chapterText = chapterText
        self.chapterStartUTF8Byte = chapterStartUTF8Byte
        self.audioFilePath = audioFilePath
        self.timelinePath = timelinePath
        self.audioDurationSeconds = audioDurationSeconds
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version", projectID = "project_id", chapterID = "chapter_id", chapterNumber = "chapter_number"
        case title, chapterText = "chapter_text", chapterStartUTF8Byte = "chapter_start_utf8_byte"
        case audioFilePath = "audio_file_path", timelinePath = "timeline_path", audioDurationSeconds = "audio_duration_seconds", segments
    }
}

public struct UTF16TextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum ReaderTimelineMatcher: Sendable {
    /// Timeline entries are in playback order. Hold the preceding highlight through pauses and after playback ends.
    public static func activeSegmentIndex(atSeconds time: Double, in segments: [ReaderSegment]) -> Int? {
        guard time.isFinite, time >= 0 else { return nil }
        var previous: Int?
        for (index, segment) in segments.enumerated() {
            guard let start = segment.startSeconds, let end = segment.endSeconds,
                  start.isFinite, end.isFinite, start >= 0, end >= start else { continue }
            if time < start { return previous ?? (time + 0.05 >= start ? index : nil) }
            previous = index
        }
        return previous
    }

    public static func utf16Range(forUTF8Start startByte: Int, endExclusive endByte: Int, in text: String) -> UTF16TextRange? {
        let bytes = text.utf8
        guard startByte >= 0, startByte <= endByte, endByte <= bytes.count else { return nil }
        let start = bytes.index(bytes.startIndex, offsetBy: startByte)
        let end = bytes.index(start, offsetBy: endByte - startByte)
        let units = text.utf16
        guard let lower = start.samePosition(in: units), let upper = end.samePosition(in: units) else { return nil }
        return UTF16TextRange(location: units.distance(from: units.startIndex, to: lower),
                              length: units.distance(from: lower, to: upper))
    }
}
