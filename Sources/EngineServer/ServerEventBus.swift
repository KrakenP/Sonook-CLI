import Foundation

public actor ServerEventBus {
    public struct Event: Sendable {
        public let eventType: String
        public let payloadJSON: String

        var frame: Data {
            let lines = payloadJSON.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            let fields = (["event: \(eventType)"] + lines.map { "data: \($0)" }).joined(separator: "\n")
            return Data((fields + "\n\n").utf8)
        }
    }

    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    var subscriberCount: Int { subscribers.count }

    public init() {}

    public func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    public func publish(eventType: String, payloadJSON: String) {
        guard !eventType.isEmpty, !eventType.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return }
        let event = Event(eventType: eventType, payloadJSON: payloadJSON)
        for subscriber in subscribers.values {
            if case .dropped = subscriber.yield(event) {
                // A slow client can reconnect and refresh from the authoritative catalog/cursor.
                subscriber.finish()
            }
        }
    }

    private func remove(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
