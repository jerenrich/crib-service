import Foundation

public struct TimelineEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var occurredAt: Date
    public var endAt: Date?
    public var episodeID: String?
    public var target: String?
    public var count: Int?
    public var status: String?
    public init(id: String = UUID().uuidString.lowercased(), kind: String, occurredAt: Date,
                endAt: Date? = nil, episodeID: String? = nil, target: String? = nil, count: Int? = nil, status: String? = nil) {
        self.id = id; self.kind = kind; self.occurredAt = occurredAt; self.endAt = endAt
        self.episodeID = episodeID; self.target = target; self.count = count; self.status = status
    }
    public var category: TimelineCategory {
        switch kind {
        case "cry_started", "cry_ended": .crying
        case "alert", "alert_acknowledged", "test_alert", "test_acknowledged", "connection_alert": .alerts
        case "heartbeat_missing", "connection_restored", "network_lost", "network_restored": .connection
        case "power_connected", "power_disconnected", "battery_low": .device
        default: .monitoring
        }
    }
    public var isObservation: Bool { kind == "coverage_active" || kind == "coverage_stopped" }
    public var coverageState: TimelineCoverage.State? {
        switch kind {
        case "monitoring_started", "audio_resumed", "monitoring_observed", "coverage_active": .monitoring
        case "monitoring_stopped", "audio_interrupted", "stopped_observed", "coverage_stopped": .stopped
        case "heartbeat_missing", "monitoring_unverified": .unknown
        // Only the fresh monitoring observation establishes active capture on reconnect.
        default: nil
        }
    }
}
public enum TimelineCategory: String, CaseIterable, Sendable {
    case all = "All events", crying = "Crying-like sound", alerts = "Alerts", connection = "Connection", monitoring = "Monitoring", device = "Power & device"
}
public struct TimelineResponse: Codable, Sendable {
    public var paired: Bool
    public var serverTime: Date
    public var availableSince: Date
    public var events: [TimelineEvent]
    public var truncated: Bool
    public var lastHeartbeat: Date? = nil
}
public struct TimelineCoverage: Identifiable, Equatable, Sendable {
    public enum State: Sendable { case monitoring, stopped, unknown }
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let state: State

    /// Unknown intervals begin at the last heartbeat, not the later outage-detection
    /// time. Missing history is never painted as quiet or active monitoring.
    public static func segments(events: [TimelineEvent], from start: Date, to end: Date, availableSince: Date) -> [Self] {
        guard end > start else { return [] }
        var transitions = events.compactMap { e -> (Date, State, String)? in
            guard let state = e.coverageState else { return nil }
            return (e.kind == "heartbeat_missing" ? e.endAt ?? e.occurredAt : e.occurredAt, state, e.id)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            func priority(_ state: State) -> Int { switch state { case .monitoring: 0; case .stopped: 1; case .unknown: 2 } }
            if $0.1 != $1.1 { return priority($0.1) < priority($1.1) }
            return $0.2 < $1.2
        }
        transitions.append((end, .unknown, "end"))
        var result: [Self] = [], cursor = start, state: State = .unknown
        for (date, next, _) in transitions {
            if date < availableSince { continue }
            if date <= start { state = next; continue }
            let boundary = min(end, max(start, date))
            if boundary > cursor {
                result.append(Self(start: cursor, end: boundary, state: cursor < availableSince ? .unknown : state))
                cursor = boundary
            }
            state = next
            if cursor >= end { break }
        }
        return result
    }
}
