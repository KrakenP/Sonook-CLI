import AudioCore
import Foundation

public enum PlaybackSyncError: Error, Equatable, Sendable {
    case invalidEvent(String)
    case releaseMismatch
    case chapterUnavailable(String)
    case ambiguousSegment(String)
}

/// Reuse the engine across reconnects to avoid rescanning durable history.
public struct PlaybackSyncEngine: Sendable {
    private let store: any SyncStoreProtocol
    private let engineID = UUID()

    public init(store: any SyncStoreProtocol) {
        self.store = store
    }

    /// For a multi-project batch, cursor belongs to the project of the causally last input.
    public func ingest(_ events: [PlaybackEvent]) async throws -> SyncMergeReport {
        let ordered = try events.map { event in
            guard event.positionMs >= 0, event.deviceSequence >= 0, !event.projectID.isEmpty,
                  !event.releaseID.isEmpty, !event.chapterID.isEmpty, !event.deviceID.isEmpty, !event.eventID.isEmpty else {
                throw PlaybackSyncError.invalidEvent(event.eventID)
            }
            return (key: try EventOrder(event), event: event)
        }.sorted { $0.key < $1.key }
        var accepted = 0
        var rewinds = 0
        var cursor: PlaybackCursor?
        let groups = Dictionary(grouping: ordered, by: { $0.event.projectID })
        for (projectID, group) in groups {
            let report = try await PlaybackMergeCoordinator.shared.merge(group, projectID: projectID, store: store, engineID: engineID)
            accepted += report.acceptedCount
            rewinds += report.rewindPreservedCount
            if projectID == ordered.last?.event.projectID { cursor = report.cursor }
        }
        return SyncMergeReport(acceptedCount: accepted, duplicateCount: events.count - accepted,
                               rewindPreservedCount: rewinds, cursor: cursor)
    }

    public static func migrateCursor(_ cursor: PlaybackCursor, from old: AudioPackReader,
                                                 to new: AudioPackReader) throws -> PlaybackCursor {
        guard cursor.projectID == old.manifest.projectID, cursor.projectID == new.manifest.projectID,
              cursor.releaseID == old.manifest.releaseID, new.manifest.releaseVersion >= old.manifest.releaseVersion,
              let original = old.transcripts[cursor.chapterID] else { throw PlaybackSyncError.releaseMismatch }

        let position = max(0, cursor.positionMs)
        let source: AudioPackTranscriptSegment?
        if let id = cursor.segmentID {
            guard let segment = original.segments.first(where: { $0.segmentID == id }) else {
                throw PlaybackSyncError.invalidEvent(cursor.lastEventID)
            }
            source = segment
        } else {
            source = original.segments.first { $0.startMs <= position && position < $0.endMs }
        }
        var chapterID = cursor.chapterID
        var segmentID: String?
        let migratedPosition: Int
        if let source, let (chapter, segment) = try destination(of: source.segmentID, chapterID: chapterID, from: old, to: new) {
            chapterID = chapter
            segmentID = segment.segmentID
            let offset = max(0, position - source.startMs)
            migratedPosition = segment.startMs + min(offset, segment.endMs - segment.startMs)
        } else {
            guard let marker = new.timeline.chapters.first(where: { $0.chapterID == chapterID }) else {
                throw PlaybackSyncError.chapterUnavailable(chapterID)
            }
            migratedPosition = try min(position, marker.localMs(marker.endFrameExclusive))
            segmentID = new.transcripts[chapterID]?.segments.first {
                $0.startMs <= migratedPosition && migratedPosition < $0.endMs
            }?.segmentID
        }
        return PlaybackCursor(projectID: cursor.projectID, releaseID: new.manifest.releaseID,
                              chapterID: chapterID, segmentID: segmentID, positionMs: migratedPosition,
                              lastEventID: cursor.lastEventID, lastDeviceID: cursor.lastDeviceID,
                              lastDeviceSequence: cursor.lastDeviceSequence, lastEventType: cursor.lastEventType,
                              updatedAtISO8601: cursor.updatedAtISO8601)
    }

    private static func destination(of id: String, chapterID: String, from old: AudioPackReader,
                                    to new: AudioPackReader) throws -> (String, AudioPackTranscriptSegment)? {
        // AudioRenderKit permits chapter-local IDs. Prefer the original chapter;
        // an ID that moved between chapters must identify a unique segment in both releases.
        if let segment = new.transcripts[chapterID]?.segments.first(where: { $0.segmentID == id }) {
            return (chapterID, segment)
        }
        var moved: (String, AudioPackTranscriptSegment)?
        for transcript in new.transcripts.values {
            guard let segment = transcript.segments.first(where: { $0.segmentID == id }) else { continue }
            // A same-named segment that already belonged to this other chapter did not move there.
            if old.transcripts[transcript.chapterID]?.segments.contains(where: { $0.segmentID == id }) == true { continue }
            guard moved == nil else { throw PlaybackSyncError.ambiguousSegment(id) }
            moved = (transcript.chapterID, segment)
        }
        if moved != nil, old.transcripts.values.contains(where: {
            $0.chapterID != chapterID && $0.segments.contains(where: { $0.segmentID == id })
        }) { throw PlaybackSyncError.ambiguousSegment(id) }
        return moved
    }
}

/// SyncStoreProtocol exposes separate append/load/save calls. Serialize a project's
/// writes even when overlapping requests use different engines in this process.
private actor PlaybackMergeCoordinator {
    static let shared = PlaybackMergeCoordinator()
    private var lastEngine: [String: UUID] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func merge(_ group: [(key: EventOrder, event: PlaybackEvent)], projectID: String,
               store: any SyncStoreProtocol, engineID: UUID) async throws -> SyncMergeReport {
        // Store calls suspend. Keep the entire read/append/project operation serial per book.
        if waiters[projectID] == nil {
            waiters[projectID] = []
        } else {
            await withCheckedContinuation { waiters[projectID, default: []].append($0) }
        }
        defer {
            if waiters[projectID]?.isEmpty == false {
                waiters[projectID]?.removeFirst().resume()
            } else {
                waiters.removeValue(forKey: projectID)
            }
        }

        let previous = try await store.loadPlaybackCursor(projectID: projectID)
        var cursor = previous
        var key = try previous.map(EventOrder.init)
        // Insertion and cursor projection are separate durable writes. On first use or
        // after an interrupted merge, recover from the stored originals, never from a retry's payload.
        if lastEngine.removeValue(forKey: projectID) != engineID {
            for event in try await store.listPlaybackEvents(projectID: projectID, limit: Int.max) {
                let candidate = try EventOrder(event)
                if key.map({ $0 < candidate }) ?? true {
                    key = candidate
                    cursor = event.cursor
                }
            }
        }
        var accepted = 0
        var rewinds = 0
        for item in group {
            guard try await store.appendPlaybackEvent(item.event) else { continue }
            accepted += 1
            guard key.map({ $0 < item.key }) ?? true else { continue }
            if item.event.eventType == .rewind ||
                (item.event.eventType == .seek && cursor?.chapterID == item.event.chapterID &&
                 cursor?.releaseID == item.event.releaseID && item.event.positionMs < (cursor?.positionMs ?? 0)) {
                rewinds += 1
            }
            key = item.key
            cursor = item.event.cursor
        }
        if let cursor, cursor != previous { try await store.savePlaybackCursor(cursor) }
        lastEngine[projectID] = engineID
        return SyncMergeReport(acceptedCount: accepted, duplicateCount: group.count - accepted,
                               rewindPreservedCount: rewinds, cursor: cursor)
    }
}

private struct EventOrder: Comparable {
    let seconds: Date
    let fraction: String
    let sequence: Int64
    let eventID: String
    let deviceID: String

    init(_ event: PlaybackEvent) throws {
        try self.init(event.occurredAtISO8601, event.deviceSequence, event.eventID, event.deviceID)
    }

    init(_ cursor: PlaybackCursor) throws {
        try self.init(cursor.updatedAtISO8601, cursor.lastDeviceSequence, cursor.lastEventID, cursor.lastDeviceID)
    }

    private init(_ timestamp: String, _ sequence: Int64, _ eventID: String, _ deviceID: String) throws {
        // Compare actual instants across offsets. Keep fractional seconds exact, even
        // when two timestamps would round to the same floating-point Foundation Date.
        var whole = timestamp
        if let dot = timestamp.firstIndex(of: ".") {
            let digits = timestamp[timestamp.index(after: dot)...].prefix { $0 >= "0" && $0 <= "9" }
            guard !digits.isEmpty else { throw PlaybackSyncError.invalidEvent(eventID) }
            fraction = String(digits.reversed().drop(while: { $0 == "0" }).reversed())
            whole.removeSubrange(dot..<digits.endIndex)
        } else {
            fraction = ""
        }
        guard let date = try? Date.ISO8601FormatStyle().parse(whole) else { throw PlaybackSyncError.invalidEvent(eventID) }
        seconds = date
        self.sequence = sequence
        self.eventID = eventID
        self.deviceID = deviceID
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.fraction, lhs.sequence, lhs.eventID, lhs.deviceID) <
        (rhs.seconds, rhs.fraction, rhs.sequence, rhs.eventID, rhs.deviceID)
    }
}

private extension PlaybackEvent {
    var cursor: PlaybackCursor {
        PlaybackCursor(projectID: projectID, releaseID: releaseID, chapterID: chapterID, segmentID: segmentID,
                       positionMs: positionMs, lastEventID: eventID, lastDeviceID: deviceID,
                       lastDeviceSequence: deviceSequence, lastEventType: eventType, updatedAtISO8601: occurredAtISO8601)
    }
}
