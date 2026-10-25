import Foundation

/// Local diagnostic metadata only. A callback time is not a delivery time.
struct WatchAlertTrace: Sendable {
    enum Phase: String, Sendable {
        case foreground, presented, opened, acknowledged, retained, hapticRequested = "haptic_requested"
        case controllerActivated = "controller_activated", controllerDeactivated = "controller_deactivated"
        case controllerReceived = "controller_received", viewAppeared = "view_appeared", snapshotReceived = "snapshot_received"
    }
    enum ApplicationState: String, Sendable { case active, inactive, background, unknown }
    struct CallbackTiming: Sendable {
        var presentationRequestMS: Int? = nil
        var mainActorWaitMS: Int? = nil
        var handlingMS: Int? = nil
        var fields: String {
            [("presentation_request_ms", presentationRequestMS), ("main_actor_wait_ms", mainActorWaitMS), ("app_handling_ms", handlingMS)]
                .compactMap { key, value in value.flatMap { (0...3_600_000).contains($0) ? " \(key)=\($0)" : nil } }.joined()
        }
    }
    let applicationState: ApplicationState?
    let timing: CallbackTiming?
    let interruptionLevel: Int?
    let alert: WatchCryAlert
    let phase: Phase
    let deliveredAt: Date?
    let observedAt: Date

    init(alert: WatchCryAlert, phase: Phase, deliveredAt: Date? = nil, observedAt: Date = Date(), applicationState: ApplicationState? = nil, timing: CallbackTiming? = nil, interruptionLevel: Int? = nil) {
        self.alert = alert; self.phase = phase; self.deliveredAt = deliveredAt; self.observedAt = observedAt
        self.applicationState = applicationState; self.timing = timing; self.interruptionLevel = interruptionLevel
    }

    var key: String {
        var key = "\(phase.rawValue)|\(alert.eventId.uuidString.lowercased())"
        if DiagnosticCorrelation.reference(alert.diagnosticRef) != nil, let attempt = DiagnosticCorrelation.attempt(alert.deliveryAttempt) {
            key += "|\(attempt)"
        }
        return key
    }
    var entry: String? {
        guard let created = Self.milliseconds(alert.createdAt), let observed = Self.milliseconds(observedAt) else { return nil }
        var result = "watch_alert phase=\(phase.rawValue) event_id=\(alert.eventId.uuidString.lowercased()) episode_id=\(alert.episodeId.uuidString.lowercased()) created_at_ms=\(created) observed_at_ms=\(observed)"
        result += DiagnosticCorrelation.fields(reference: alert.diagnosticRef, attempt: alert.deliveryAttempt)
        if let deliveredAt {
            guard let delivered = Self.milliseconds(deliveredAt) else { return nil }
            result += " delivered_at_ms=\(delivered) delivery_age_ms=\(delivered - created) callback_lag_ms=\(observed - delivered)"
            if delivered < created || observed < delivered { result += " clock_order=check" }
        }
        switch phase {
        case .controllerReceived, .controllerActivated, .controllerDeactivated, .viewAppeared: result += " callback_scope=long_look"
        case .foreground: result += " callback_scope=foreground_delegate"
        case .opened, .acknowledged: result += " callback_scope=user_action"
        case .retained: result += " callback_scope=history_observation"
        case .snapshotReceived: result += " callback_scope=phone_bridge"
        case .hapticRequested: result += " callback_scope=app_haptic_request"
        case .presented: break
        }
        if let applicationState { result += " app_state=\(applicationState.rawValue)" }
        if let timing { result += timing.fields }
        if let interruptionLevel, (0...3).contains(interruptionLevel) { result += " interruption_level=\(interruptionLevel)" }
        return result
    }

    /// Rebuild the bounded deduplication set from the existing ring after relaunch.
    static func key(in line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 4, fields[1] == "watch_alert",
              fields[2].hasPrefix("phase="), let phase = Phase(rawValue: String(fields[2].dropFirst(6))),
              fields[3].hasPrefix("event_id="), let id = UUID(uuidString: String(fields[3].dropFirst(9))) else { return nil }
        let attempt = fields.first { $0.hasPrefix("delivery_attempt=") }.flatMap { Int($0.dropFirst("delivery_attempt=".count)) }
        let reference = fields.first { $0.hasPrefix("diagnostic_ref=") }.map { String($0.dropFirst("diagnostic_ref=".count)) }
        var key = "\(phase.rawValue)|\(id.uuidString.lowercased())"
        if DiagnosticCorrelation.reference(reference) != nil, let attempt = DiagnosticCorrelation.attempt(attempt) { key += "|\(attempt)" }
        return key
    }
    private static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1000
        // Keep conversion and subtraction safe even for malformed dates.
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int64(value.rounded())
    }
}
