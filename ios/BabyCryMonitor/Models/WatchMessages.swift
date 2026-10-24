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
    var state: CryState?
    var alertDuration: Double = 5
    var watchPushRegistered = false
    var snoozeDuration: Double?
    var alertsMutedUntil: Date?
    var acknowledgedEventId: UUID?
    // Terminal queue resolution, distinct from an acknowledgement/snooze.
    var discardedAcknowledgementEventId: UUID?
    var alert: WatchCryAlert?
    var message: String?
    // An absolute deadline from a successful Parent server check. An unrelated
    // snapshot, Bluetooth reconnection or failed refresh must not postpone it.
    var connectionWarningSupported: Bool?
    var connectionWarningDeadline: Date?

    var localConnectionDeadline: Date? {
        guard connectionWarningSupported == true, parentMode, paired else { return nil }
        return connectionWarningDeadline
    }

    func nurseryOnline(at now: Date) -> Bool {
        guard parentMode, paired, monitoring, let lastHeartbeat else { return false }
        return (-5...150).contains(now.timeIntervalSince(lastHeartbeat))
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
    var id: UUID { eventId }
    func isRecent(at now: Date) -> Bool { (-5...300).contains(now.timeIntervalSince(createdAt)) }
}

struct WatchCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case refresh, registerToken, acknowledge }
    let kind: Kind
    var issuedAt = Date()
    var token: String?
    var eventId: UUID?
}
