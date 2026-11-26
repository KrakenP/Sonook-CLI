import CryptoKit
import Foundation

// MARK: - Open Distribution Format (.audiopack)

public struct AudioPackChapterEntry: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let audioRelativePath: String
    public let transcriptRelativePath: String
    public let durationSeconds: Double
    public let sampleRate: Int
    public let byteSize: Int64
    public let fileSHA256: String

    public init(
        chapterID: String,
        chapterNumber: Int,
        title: String,
        audioRelativePath: String,
        transcriptRelativePath: String,
        durationSeconds: Double,
        sampleRate: Int,
        byteSize: Int64,
        fileSHA256: String
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.audioRelativePath = audioRelativePath
        self.transcriptRelativePath = transcriptRelativePath
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.byteSize = byteSize
        self.fileSHA256 = fileSHA256
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case title
        case audioRelativePath = "audio_relative_path"
        case transcriptRelativePath = "transcript_relative_path"
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case byteSize = "byte_size"
        case fileSHA256 = "file_sha256"
    }
}

public struct AudioPackManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let releaseID: String
    public let releaseVersion: Int
    public let projectID: String
    public let productionMode: ProductionMode
    public let audioMode: ExportAudioMode
    public let totalDurationSeconds: Double
    public let totalByteSize: Int64
    public let chapters: [AudioPackChapterEntry]
    public let requiredFiles: [String]
    public let optionalFiles: [String]
    public let requiredCapabilities: [String]
    public let createdAtISO8601: String

    public init(
        formatVersion: Int = AudioPackManifest.currentFormatVersion,
        releaseID: String,
        releaseVersion: Int,
        projectID: String,
        productionMode: ProductionMode,
        audioMode: ExportAudioMode = .dry,
        totalDurationSeconds: Double,
        totalByteSize: Int64,
        chapters: [AudioPackChapterEntry],
        requiredFiles: [String],
        optionalFiles: [String] = [],
        requiredCapabilities: [String] = ["audio.m4a", "sync.v1"],
        createdAtISO8601: String
    ) {
        self.formatVersion = formatVersion
        self.releaseID = releaseID
        self.releaseVersion = releaseVersion
        self.projectID = projectID
        self.productionMode = productionMode
        self.audioMode = audioMode
        self.totalDurationSeconds = totalDurationSeconds
        self.totalByteSize = totalByteSize
        self.chapters = chapters
        self.requiredFiles = requiredFiles
        self.optionalFiles = optionalFiles
        self.requiredCapabilities = requiredCapabilities
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case releaseID = "release_id"
        case releaseVersion = "release_version"
        case projectID = "project_id"
        case productionMode = "production_mode"
        case audioMode = "audio_mode"
        case totalDurationSeconds = "total_duration_seconds"
        case totalByteSize = "total_byte_size"
        case chapters
        case requiredFiles = "required_files"
        case optionalFiles = "optional_files"
        case requiredCapabilities = "required_capabilities"
        case createdAtISO8601 = "created_at"
    }
}

public struct AudioPackMetadata: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let title: String
    public let author: String?
    public let narrator: String?
    public let language: String
    public let summary: String?
    public let createdAtISO8601: String

    public init(
        title: String,
        author: String? = nil,
        narrator: String? = nil,
        language: String = "zh-CN",
        summary: String? = nil,
        createdAtISO8601: String
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.language = language
        self.summary = summary
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case title
        case author
        case narrator
        case language
        case summary
        case createdAtISO8601 = "created_at"
    }
}

public struct AudioPackTranscriptSegment: Codable, Equatable, Sendable {
    public let segmentID: String
    public let speakerID: String
    public let speakerName: String
    public let spokenText: String
    public let sourceSpan: SourceSpan
    public let startMs: Int
    public let endMs: Int

    public init(
        segmentID: String,
        speakerID: String,
        speakerName: String,
        spokenText: String,
        sourceSpan: SourceSpan,
        startMs: Int,
        endMs: Int
    ) {
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.spokenText = spokenText
        self.sourceSpan = sourceSpan
        self.startMs = startMs
        self.endMs = endMs
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case speakerID = "speaker_id"
        case speakerName = "speaker_name"
        case spokenText = "spoken_text"
        case sourceSpan = "source_span"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

public struct AudioPackChapterTranscript: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let chapterID: String
    public let chapterNumber: Int
    public let title: String
    public let segments: [AudioPackTranscriptSegment]

    public init(chapterID: String, chapterNumber: Int, title: String, segments: [AudioPackTranscriptSegment]) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.title = title
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case title
        case segments
    }
}

/// Public character metadata packaged inside .audiopack; deliberately excludes raw voice-clone audio and local paths.
public struct AudioPackCharacterSummary: Codable, Equatable, Sendable {
    public let characterID: String
    public let canonicalName: String
    public let aliases: [String]
    public let personaSummary: String
    public let firstAppearedChapter: Int?

    public init(
        characterID: String,
        canonicalName: String,
        aliases: [String] = [],
        personaSummary: String,
        firstAppearedChapter: Int? = nil
    ) {
        self.characterID = characterID
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.personaSummary = personaSummary
        self.firstAppearedChapter = firstAppearedChapter
    }

    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case canonicalName = "canonical_name"
        case aliases
        case personaSummary = "persona_summary"
        case firstAppearedChapter = "first_appeared_chapter"
    }
}

public struct AudioPackChecksums: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let algorithm: String
    public var files: [String: String]

    public init(algorithm: String = "sha256", files: [String: String]) {
        self.algorithm = algorithm
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case algorithm
        case files
    }
}

public struct PublishedReleaseRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let releaseID: String
    public let projectID: String
    public let releaseVersion: Int
    public let title: String
    public let packRelativePath: String
    public let manifestSHA256: String
    public let chapterCount: Int
    public let totalDurationSeconds: Double
    public let totalByteSize: Int64
    public let createdAtISO8601: String

    public init(
        releaseID: String,
        projectID: String,
        releaseVersion: Int,
        title: String,
        packRelativePath: String,
        manifestSHA256: String,
        chapterCount: Int,
        totalDurationSeconds: Double,
        totalByteSize: Int64,
        createdAtISO8601: String
    ) {
        self.releaseID = releaseID
        self.projectID = projectID
        self.releaseVersion = releaseVersion
        self.title = title
        self.packRelativePath = packRelativePath
        self.manifestSHA256 = manifestSHA256
        self.chapterCount = chapterCount
        self.totalDurationSeconds = totalDurationSeconds
        self.totalByteSize = totalByteSize
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case releaseID = "release_id"
        case projectID = "project_id"
        case releaseVersion = "release_version"
        case title
        case packRelativePath = "pack_relative_path"
        case manifestSHA256 = "manifest_sha256"
        case chapterCount = "chapter_count"
        case totalDurationSeconds = "total_duration_seconds"
        case totalByteSize = "total_byte_size"
        case createdAtISO8601 = "created_at"
    }
}

// MARK: - Pairing & Least-Privilege Auth Contracts

public enum AuthScope: String, Codable, CaseIterable, Sendable {
    case readCatalog = "catalog:read"
    case downloadMedia = "media:download"
    case syncPlayback = "playback:sync"
    case queryContext = "context:query"
    case manageJobs = "jobs:manage"
    case admin = "admin"
}

public struct PairingChallengeRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let challengeID: String
    public let codeHashSHA256: String
    public let scopes: [AuthScope]
    public let expiresAtISO8601: String
    public var consumedAtISO8601: String?
    public let createdAtISO8601: String

    public init(
        challengeID: String,
        codeHashSHA256: String,
        scopes: [AuthScope],
        expiresAtISO8601: String,
        consumedAtISO8601: String? = nil,
        createdAtISO8601: String
    ) {
        self.challengeID = challengeID
        self.codeHashSHA256 = codeHashSHA256
        self.scopes = scopes
        self.expiresAtISO8601 = expiresAtISO8601
        self.consumedAtISO8601 = consumedAtISO8601
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case challengeID = "challenge_id"
        case codeHashSHA256 = "code_hash_sha256"
        case scopes
        case expiresAtISO8601 = "expires_at"
        case consumedAtISO8601 = "consumed_at"
        case createdAtISO8601 = "created_at"
    }
}

public struct PairedDeviceRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let deviceID: String
    public let deviceName: String
    public let tokenHashSHA256: String
    public let scopes: [AuthScope]
    public let pairedAtISO8601: String
    public var lastSeenAtISO8601: String?
    public var revokedAtISO8601: String?

    public init(
        deviceID: String,
        deviceName: String,
        tokenHashSHA256: String,
        scopes: [AuthScope],
        pairedAtISO8601: String,
        lastSeenAtISO8601: String? = nil,
        revokedAtISO8601: String? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.tokenHashSHA256 = tokenHashSHA256
        self.scopes = scopes
        self.pairedAtISO8601 = pairedAtISO8601
        self.lastSeenAtISO8601 = lastSeenAtISO8601
        self.revokedAtISO8601 = revokedAtISO8601
    }

    public var isRevoked: Bool { revokedAtISO8601 != nil }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case tokenHashSHA256 = "token_hash_sha256"
        case scopes
        case pairedAtISO8601 = "paired_at"
        case lastSeenAtISO8601 = "last_seen_at"
        case revokedAtISO8601 = "revoked_at"
    }
}

// MARK: - Offline Playback Events & Sync Contracts

public enum PlaybackEventType: String, Codable, CaseIterable, Sendable {
    case play
    case pause
    case progress
    case seek
    case rewind
    case complete
}

public struct PlaybackEvent: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let eventID: String
    public let deviceID: String
    public let projectID: String
    public let releaseID: String
    public let chapterID: String
    public let segmentID: String?
    public let positionMs: Int
    public let eventType: PlaybackEventType
    public let deviceSequence: Int64
    public let occurredAtISO8601: String

    public init(
        eventID: String,
        deviceID: String,
        projectID: String,
        releaseID: String,
        chapterID: String,
        segmentID: String? = nil,
        positionMs: Int,
        eventType: PlaybackEventType,
        deviceSequence: Int64,
        occurredAtISO8601: String
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.projectID = projectID
        self.releaseID = releaseID
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.positionMs = positionMs
        self.eventType = eventType
        self.deviceSequence = deviceSequence
        self.occurredAtISO8601 = occurredAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case eventID = "event_id"
        case deviceID = "device_id"
        case projectID = "project_id"
        case releaseID = "release_id"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case positionMs = "position_ms"
        case eventType = "event_type"
        case deviceSequence = "device_sequence"
        case occurredAtISO8601 = "occurred_at"
    }
}

public struct PlaybackCursor: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let projectID: String
    public let releaseID: String
    public let chapterID: String
    public let segmentID: String?
    public let positionMs: Int
    public let lastEventID: String
    public let lastDeviceID: String
    public let lastDeviceSequence: Int64
    public let lastEventType: PlaybackEventType
    public let updatedAtISO8601: String

    public init(
        projectID: String,
        releaseID: String,
        chapterID: String,
        segmentID: String? = nil,
        positionMs: Int,
        lastEventID: String,
        lastDeviceID: String,
        lastDeviceSequence: Int64,
        lastEventType: PlaybackEventType,
        updatedAtISO8601: String
    ) {
        self.projectID = projectID
        self.releaseID = releaseID
        self.chapterID = chapterID
        self.segmentID = segmentID
        self.positionMs = positionMs
        self.lastEventID = lastEventID
        self.lastDeviceID = lastDeviceID
        self.lastDeviceSequence = lastDeviceSequence
        self.lastEventType = lastEventType
        self.updatedAtISO8601 = updatedAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case projectID = "project_id"
        case releaseID = "release_id"
        case chapterID = "chapter_id"
        case segmentID = "segment_id"
        case positionMs = "position_ms"
        case lastEventID = "last_event_id"
        case lastDeviceID = "last_device_id"
        case lastDeviceSequence = "last_device_sequence"
        case lastEventType = "last_event_type"
        case updatedAtISO8601 = "updated_at"
    }
}

public struct SyncMergeReport: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let acceptedCount: Int
    public let duplicateCount: Int
    public let rewindPreservedCount: Int
    public let cursor: PlaybackCursor?

    public init(
        acceptedCount: Int,
        duplicateCount: Int,
        rewindPreservedCount: Int,
        cursor: PlaybackCursor?
    ) {
        self.acceptedCount = acceptedCount
        self.duplicateCount = duplicateCount
        self.rewindPreservedCount = rewindPreservedCount
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
        case rewindPreservedCount = "rewind_preserved_count"
        case cursor
    }
}

// MARK: - Spoiler-Safe Context Query & Interaction Contracts

public struct SpoilerSafeContextRequest: Codable, Equatable, Sendable {
    public let projectID: String
    public let maxChapterNumber: Int
    public let maxSegmentID: String?
    public let query: String
    public let allowSpoilers: Bool
    public let releaseID: String?
    public let resumePositionMs: Int?

    public init(
        projectID: String,
        maxChapterNumber: Int,
        maxSegmentID: String? = nil,
        query: String,
        allowSpoilers: Bool = false,
        releaseID: String? = nil,
        resumePositionMs: Int? = nil
    ) {
        self.projectID = projectID
        self.maxChapterNumber = maxChapterNumber
        self.maxSegmentID = maxSegmentID
        self.query = query
        self.allowSpoilers = allowSpoilers
        self.releaseID = releaseID
        self.resumePositionMs = resumePositionMs
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case maxChapterNumber = "max_chapter_number"
        case maxSegmentID = "max_segment_id"
        case query
        case allowSpoilers = "allow_spoilers"
        case releaseID = "release_id"
        case resumePositionMs = "resume_position_ms"
    }
}

public struct ContextEvidenceSnippet: Codable, Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    public let segmentID: String?
    public let speakerName: String?
    public let excerpt: String
    public let sourceSpan: SourceSpan?

    public init(
        chapterID: String,
        chapterNumber: Int,
        segmentID: String? = nil,
        speakerName: String? = nil,
        excerpt: String,
        sourceSpan: SourceSpan? = nil
    ) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.segmentID = segmentID
        self.speakerName = speakerName
        self.excerpt = excerpt
        self.sourceSpan = sourceSpan
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterNumber = "chapter_number"
        case segmentID = "segment_id"
        case speakerName = "speaker_name"
        case excerpt
        case sourceSpan = "source_span"
    }
}

public struct SpoilerSafeContextResponse: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let interactionID: String
    public let projectID: String
    public let maxChapterNumber: Int
    public let allowSpoilers: Bool
    public let answer: String
    public let spoilerFilterTriggered: Bool
    public let withheldFutureChapters: Int
    public let knownCharacters: [AudioPackCharacterSummary]
    public let evidence: [ContextEvidenceSnippet]
    public let resumeAnchor: PlaybackCursor?
    public let createdAtISO8601: String

    public init(
        interactionID: String,
        projectID: String,
        maxChapterNumber: Int,
        allowSpoilers: Bool,
        answer: String,
        spoilerFilterTriggered: Bool,
        withheldFutureChapters: Int,
        knownCharacters: [AudioPackCharacterSummary],
        evidence: [ContextEvidenceSnippet],
        resumeAnchor: PlaybackCursor? = nil,
        createdAtISO8601: String
    ) {
        self.interactionID = interactionID
        self.projectID = projectID
        self.maxChapterNumber = maxChapterNumber
        self.allowSpoilers = allowSpoilers
        self.answer = answer
        self.spoilerFilterTriggered = spoilerFilterTriggered
        self.withheldFutureChapters = withheldFutureChapters
        self.knownCharacters = knownCharacters
        self.evidence = evidence
        self.resumeAnchor = resumeAnchor
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case interactionID = "interaction_id"
        case projectID = "project_id"
        case maxChapterNumber = "max_chapter_number"
        case allowSpoilers = "allow_spoilers"
        case answer
        case spoilerFilterTriggered = "spoiler_filter_triggered"
        case withheldFutureChapters = "withheld_future_chapters"
        case knownCharacters = "known_characters"
        case evidence
        case resumeAnchor = "resume_anchor"
        case createdAtISO8601 = "created_at"
    }
}

public struct InteractionRecord: Codable, Equatable, Sendable {
    private var version = SchemaVersion.v1
    public var schemaVersion: Int { version.rawValue }
    public let interactionID: String
    public let projectID: String
    public let query: String
    public let answer: String
    public let maxChapterNumber: Int
    public let allowSpoilers: Bool
    public let spoilerFilterTriggered: Bool
    public let resumeReleaseID: String?
    public let resumeChapterID: String?
    public let resumeSegmentID: String?
    public let resumePositionMs: Int?
    public let createdAtISO8601: String

    public init(
        interactionID: String,
        projectID: String,
        query: String,
        answer: String,
        maxChapterNumber: Int,
        allowSpoilers: Bool,
        spoilerFilterTriggered: Bool,
        resumeReleaseID: String? = nil,
        resumeChapterID: String? = nil,
        resumeSegmentID: String? = nil,
        resumePositionMs: Int? = nil,
        createdAtISO8601: String
    ) {
        self.interactionID = interactionID
        self.projectID = projectID
        self.query = query
        self.answer = answer
        self.maxChapterNumber = maxChapterNumber
        self.allowSpoilers = allowSpoilers
        self.spoilerFilterTriggered = spoilerFilterTriggered
        self.resumeReleaseID = resumeReleaseID
        self.resumeChapterID = resumeChapterID
        self.resumeSegmentID = resumeSegmentID
        self.resumePositionMs = resumePositionMs
        self.createdAtISO8601 = createdAtISO8601
    }

    enum CodingKeys: String, CodingKey {
        case version = "schema_version"
        case interactionID = "interaction_id"
        case projectID = "project_id"
        case query
        case answer
        case maxChapterNumber = "max_chapter_number"
        case allowSpoilers = "allow_spoilers"
        case spoilerFilterTriggered = "spoiler_filter_triggered"
        case resumeReleaseID = "resume_release_id"
        case resumeChapterID = "resume_chapter_id"
        case resumeSegmentID = "resume_segment_id"
        case resumePositionMs = "resume_position_ms"
        case createdAtISO8601 = "created_at"
    }
}

// MARK: - Store Protocols for P5 Distribution, Sync, Pairing & Interactions

public protocol DistributionStoreProtocol: Sendable {
    func savePublishedRelease(_ release: PublishedReleaseRecord) async throws
    func publishedRelease(id: String) async throws -> PublishedReleaseRecord?
    func listPublishedReleases(projectID: String?) async throws -> [PublishedReleaseRecord]
}

public protocol AuthStoreProtocol: Sendable {
    func savePairingChallenge(_ challenge: PairingChallengeRecord) async throws
    func pairingChallenge(id: String) async throws -> PairingChallengeRecord?
    func consumePairingChallenge(id: String, consumedAtISO8601: String) async throws -> Bool
    func savePairedDevice(_ device: PairedDeviceRecord) async throws
    func pairedDevice(id: String) async throws -> PairedDeviceRecord?
    func pairedDevice(tokenHashSHA256: String) async throws -> PairedDeviceRecord?
    func listPairedDevices() async throws -> [PairedDeviceRecord]
    func revokePairedDevice(id: String, revokedAtISO8601: String) async throws -> Bool
}

public protocol SyncStoreProtocol: Sendable {
    /// Returns true if inserted newly, false if `(deviceID, eventID)` already existed (idempotent dedup).
    func appendPlaybackEvent(_ event: PlaybackEvent) async throws -> Bool
    func listPlaybackEvents(projectID: String, limit: Int) async throws -> [PlaybackEvent]
    func savePlaybackCursor(_ cursor: PlaybackCursor) async throws
    func loadPlaybackCursor(projectID: String) async throws -> PlaybackCursor?
    func saveInteraction(_ record: InteractionRecord) async throws
    func listInteractions(projectID: String, limit: Int) async throws -> [InteractionRecord]
}
