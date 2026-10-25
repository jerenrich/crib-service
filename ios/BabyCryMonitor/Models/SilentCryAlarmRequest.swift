import Foundation

struct SilentCryAlarmRequest: Sendable {
    let eventID: UUID
    let episodeID: UUID
    let createdAt: Date

    init?(payload: [AnyHashable: Any], now: Date = Date()) {
        guard payload["silentCryAlarm"] as? Bool == true,
              payload["isTest"] as? Bool != true,
              let event = payload["eventId"] as? String, let eventID = UUID(uuidString: event),
              let episode = payload["episodeId"] as? String, let episodeID = UUID(uuidString: episode),
              let text = payload["createdAt"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              (-5...60).contains(now.timeIntervalSince(date)) else { return nil }
        self.eventID = eventID; self.episodeID = episodeID; createdAt = date
    }

    func isEligible(enabled: Bool, serverEnabled: Bool, paired: Bool, relevance: NotificationRelevance?,
                    mutedUntil: Date?, localMutedUntil: Date?, stoppedBefore: Date?, now: Date) -> Bool {
        enabled && serverEnabled && paired && (-5...60).contains(now.timeIntervalSince(createdAt))
        && relevance?.cryEpisodeIDs.contains(episodeID) == true
        && (mutedUntil ?? .distantPast) <= now && (localMutedUntil ?? .distantPast) <= now
        && createdAt > (stoppedBefore ?? .distantPast)
    }
}
