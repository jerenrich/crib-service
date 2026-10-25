import Foundation

enum WatchNotification {
    static let category = "BABY_CRY_ALERT"
    static let acknowledge = "ACKNOWLEDGE_CRY"
}

/// Only status and alert metadata cross Watch Connectivity. Never audio or credentials.
struct WatchSnapshot: Codable, Equatable, Sendable {
    var updatedAt = Date()
    var parentMode = false
    var paired = false
    var statusAvailable = false
    var lastHeartbeat: Date?
    var monitoring = false
    // Presentation evidence never changes warning deadlines or command confirmation.
    var monitoringDisplayState: String? = nil
    var monitoringObservedAt: Date? = nil
    var state: CryState?
    var alertDuration: Double = 5
    var watchPushRegistered = false
    var snoozeDuration: Double?
    var alertsMutedUntil: Date?
    var acknowledgedEventId: UUID?
    // Terminal queue resolution, distinct from an acknowledgement/snooze.
    var discardedAcknowledgementEventId: UUID?
    var notificationRelevance: NotificationRelevance?
    var notificationsCheckedAt: Date?
    var alert: WatchCryAlert?
    var message: String?
    // An absolute deadline from a successful Parent server check. An unrelated
    // snapshot, Bluetooth reconnection or failed refresh must not postpone it.
    var connectionWarningSupported: Bool?
    // Missing on older phones/cached snapshots: require explicit opt-in.
    var localConnectionWarningEnabled: Bool?
    var connectionWarningDeadline: Date?
    var diagnosticClock: DiagnosticClockSample?

    var localConnectionDeadline: Date? {
        guard connectionWarningSupported == true, localConnectionWarningEnabled == true, parentMode, paired else { return nil }
        return connectionWarningDeadline
    }

    func nurseryDisplayState(at now: Date) -> String? {
        guard parentMode, paired, let monitoringDisplayState,
              let observation = monitoringObservedAt,
              (-5...150).contains(now.timeIntervalSince(observation)),
              (-5...45).contains(now.timeIntervalSince(updatedAt)) else { return nil }
        return monitoringDisplayState
    }

    func nurseryOnline(at now: Date) -> Bool {
        let active = monitoringDisplayState.map { $0 == "Monitoring" } ?? monitoring
        let observation = monitoringObservedAt ?? lastHeartbeat
        guard parentMode, paired, active, let observation else { return false }
        return (-5...150).contains(now.timeIntervalSince(observation))
            && (-5...45).contains(now.timeIntervalSince(updatedAt))
    }
}

struct WatchCryAlert: Codable, Equatable, Identifiable, Sendable {
    let eventId: UUID
    let episodeId: UUID
    let startedAt: Date
    let createdAt: Date
    let duration: Double
    let isTest: Bool
    var diagnosticRef: String? = nil
    var deliveryAttempt: Int? = nil
    var id: UUID { eventId }
    func isRecent(at now: Date) -> Bool { (-5...300).contains(now.timeIntervalSince(createdAt)) }
}

struct WatchCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case refresh, registerToken, acknowledge, resumeAlerts }
    let kind: Kind
    var issuedAt = Date()
    var token: String?
    var eventId: UUID?
    var snoozeDeadline: Date?
    var isTest: Bool?
}
