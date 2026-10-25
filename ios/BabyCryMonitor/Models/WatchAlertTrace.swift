import Foundation

/// Local diagnostic metadata only. A callback time is not a delivery time.
struct WatchAlertTrace: Sendable {
    enum Phase: String, Sendable {
        case foreground, presented, opened, acknowledged, retained, hapticRequested = "haptic_requested"
        case controllerReceived = "controller_received", viewAppeared = "view_appeared", snapshotReceived = "snapshot_received"
    }
    let alert: WatchCryAlert
    let phase: Phase
    let deliveredAt: Date?
    let observedAt: Date

    init(alert: WatchCryAlert, phase: Phase, deliveredAt: Date? = nil, observedAt: Date = Date()) {
        self.alert = alert; self.phase = phase; self.deliveredAt = deliveredAt; self.observedAt = observedAt
    }

    var key: String { "\(phase.rawValue)|\(alert.eventId.uuidString.lowercased())" }
    var entry: String? {
        guard let created = Self.milliseconds(alert.createdAt), let observed = Self.milliseconds(observedAt) else { return nil }
        var result = "watch_alert phase=\(phase.rawValue) event_id=\(alert.eventId.uuidString.lowercased()) episode_id=\(alert.episodeId.uuidString.lowercased()) created_at_ms=\(created) observed_at_ms=\(observed)"
        if let deliveredAt {
            guard let delivered = Self.milliseconds(deliveredAt) else { return nil }
            result += " delivered_at_ms=\(delivered) delivery_age_ms=\(delivered - created) callback_lag_ms=\(observed - delivered)"
            if delivered < created || observed < delivered { result += " clock_order=check" }
        }
        return result
    }

    /// Rebuild the bounded deduplication set from the existing ring after relaunch.
    static func key(in line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 4, fields[1] == "watch_alert",
              fields[2].hasPrefix("phase="), let phase = Phase(rawValue: String(fields[2].dropFirst(6))),
              fields[3].hasPrefix("event_id="), let id = UUID(uuidString: String(fields[3].dropFirst(9))) else { return nil }
        return "\(phase.rawValue)|\(id.uuidString.lowercased())"
    }
    private static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1000
        // Keep conversion and subtraction safe even for malformed dates.
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int64(value.rounded())
    }
}
