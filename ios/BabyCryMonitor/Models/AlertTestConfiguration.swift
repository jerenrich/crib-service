import Foundation

/// Explicit test settings, independent of real crying-alert preferences.
struct AlertTestConfiguration: Codable, Equatable, Sendable {
    var alarmKit = false
    var phone = true
    var watch = true
    var repeatInterval = 5
    var count = 1
    var sharedCollapseIDs = false
    var distinctRequestIDs = false
    var coalesceRepeats = false
    var groupNotifications = true
    var phoneHeadStartMS = 0

    var hasDelivery: Bool { alarmKit || phone || watch }
    var isValid: Bool {
        hasDelivery && (1...20).contains(count) && [1, 2, 5, 10, 15, 30].contains(repeatInterval)
            && [0, 350, 500].contains(phoneHeadStartMS) && (phoneHeadStartMS == 0 || (phone && watch))
    }
}

struct AlertTestSession: Codable, Sendable {
    let id: UUID
    let configuration: AlertTestConfiguration
    let startsAt: Date
    let nextAt: Date?
    let completedCount: Int
    let state: String
    let message: String?

    var running: Bool { state == "scheduled" || state == "running" }
}

struct AlertTestResponse: Decodable, Sendable {
    let session: AlertTestSession?
}
