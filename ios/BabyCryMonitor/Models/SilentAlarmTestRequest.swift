import Foundation

struct SilentAlarmTestRequest: Sendable {
    let eventID: UUID
    let createdAt: Date
    let schedulingDelay: TimeInterval

    init?(payload: [AnyHashable: Any], now: Date = Date()) {
        guard payload["silentAlarmTest"] as? Bool == true,
              payload["isTest"] as? Bool == true,
              let rawID = payload["eventId"] as? String, let id = UUID(uuidString: rawID),
              let rawDate = payload["createdAt"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: rawDate) ?? ISO8601DateFormatter().date(from: rawDate)
        guard let date, (-5...60).contains(now.timeIntervalSince(date)) else { return nil }
        eventID = id
        createdAt = date
        // Configured tests already waited ten seconds on the service. Starting
        // promptly also lets one- and two-second test rounds actually alert.
        schedulingDelay = payload["configuredAlertTest"] as? Bool == true ? 0.5 : 3
    }
}
