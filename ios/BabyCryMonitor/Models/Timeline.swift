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
    public var isObservation: Bool { kind == "coverage_active" || kind == "coverage_stopped" || kind == "coverage_standby" }
    public var coverageState: TimelineCoverage.State? {
        switch kind {
        case "monitoring_started", "audio_resumed", "monitoring_observed", "coverage_active": .monitoring
        case "monitoring_paused", "standby_observed", "coverage_standby": .standby
        case "monitoring_stopped", "audio_interrupted", "stopped_observed", "coverage_stopped": .stopped
        case "heartbeat_missing": .updatesMissing
        case "monitoring_unverified": .unverified
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
    public enum State: String, CaseIterable, Sendable {
        case monitoring, standby, stopped, noHistory, updatesMissing, unavailable, unverified

        public var title: String {
            switch self {
            case .monitoring: "Monitoring reported"
            case .standby: "Standby"
            case .stopped: "Stopped"
            case .noHistory: "No history recorded"
            case .updatesMissing: "Listener updates missing"
            case .unavailable: "Status unavailable"
            case .unverified: "Monitoring unverified"
            }
        }
    }
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let state: State

    /// A backend outage cannot establish a Listener disconnection. Preserve the
    /// fetched history and mark only time since that fetch as unavailable.
    public static func segments(events: [TimelineEvent], from start: Date, to end: Date, availableSince: Date,
                                statusUnavailableSince: Date? = nil, historyTruncated: Bool = false) -> [Self] {
        guard end > start else { return [] }
        var transitions = historyTruncated ? [] : events.compactMap { e -> (Date, State, String)? in
            guard let state = e.coverageState else { return nil }
            let date = e.kind == "heartbeat_missing" ? e.endAt ?? e.occurredAt : e.occurredAt
            guard date >= availableSince else { return nil }
            return (date, state, e.id)
        }
        // Keep the history boundary explicit, even if the first known state
        // arrives later. Events before logging began cannot fill that history.
        transitions.append((availableSince, .noHistory, "history-boundary"))
        transitions.sort {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            func priority(_ state: State) -> Int {
                switch state {
                case .noHistory: 0
                case .monitoring: 1
                case .standby: 2
                case .stopped: 3
                case .unverified: 4
                case .updatesMissing: 5
                case .unavailable: 6
                }
            }
            if $0.1 != $1.1 { return priority($0.1) < priority($1.1) }
            return $0.2 < $1.2
        }
        if let unavailable = statusUnavailableSince {
            transitions.removeAll { $0.0 >= unavailable }
            transitions.append((unavailable, .unavailable, "refresh-unavailable"))
        }
        transitions.append((end, .noHistory, "end"))
        var result: [Self] = [], cursor = start, state: State = .noHistory
        for (date, next, _) in transitions {
            if date <= start { state = next; continue }
            let boundary = min(end, date)
            if boundary > cursor {
                if let previous = result.last, previous.state == state {
                    result[result.count - 1] = Self(start: previous.start, end: boundary, state: state)
                } else {
                    result.append(Self(start: cursor, end: boundary, state: state))
                }
                cursor = boundary
            }
            state = next
            if cursor >= end { break }
        }
        return result
    }
}
