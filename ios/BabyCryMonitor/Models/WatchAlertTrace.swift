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
        var journalWriteMS: Int? = nil
        var fields: String {
            [("presentation_request_ms", presentationRequestMS), ("main_actor_wait_ms", mainActorWaitMS), ("app_handling_ms", handlingMS), ("journal_write_ms", journalWriteMS)]
                .compactMap { key, value in value.flatMap { (0...3_600_000).contains($0) ? " \(key)=\($0)" : nil } }.joined()
        }
    }
    enum CollapseScope: String, Sendable { case event, episode, other }
    enum HistorySource: String, Sendable { case foreground, cleanup }
    let presentationProfile: WatchNotificationPresentation?
    let callbackID: UUID?
    let collapseScope: CollapseScope?
    let historySource: HistorySource?
    let applicationState: ApplicationState?
    let timing: CallbackTiming?
    let interruptionLevel: Int?
    let alert: WatchCryAlert
    let phase: Phase
    let deliveredAt: Date?
    let observedAt: Date

    init(alert: WatchCryAlert, phase: Phase, deliveredAt: Date? = nil, observedAt: Date = Date(), applicationState: ApplicationState? = nil, timing: CallbackTiming? = nil, interruptionLevel: Int? = nil, callbackID: UUID? = nil, collapseScope: CollapseScope? = nil, historySource: HistorySource? = nil, presentationProfile: WatchNotificationPresentation? = nil) {
        self.alert = alert; self.phase = phase; self.deliveredAt = deliveredAt; self.observedAt = observedAt
        self.applicationState = applicationState; self.timing = timing; self.interruptionLevel = interruptionLevel
        // History can belong to a previously installed build; never label it
        // using the collecting process's presentation profile.
        self.presentationProfile = presentationProfile ?? (phase == .retained || phase == .snapshotReceived ? nil : .current)
        self.callbackID = callbackID; self.collapseScope = collapseScope; self.historySource = historySource
    }

    var key: String {
        var key = "\(phase.rawValue)|\(alert.eventId.uuidString.lowercased())"
        if DiagnosticCorrelation.reference(alert.diagnosticRef) != nil, let attempt = DiagnosticCorrelation.attempt(alert.deliveryAttempt) {
            key += "|\(attempt)"
        }
        if let callbackID { key += "|\(callbackID.uuidString.lowercased())" }
        return key
    }
    var entry: String? {
        guard let created = Self.milliseconds(alert.createdAt), let observed = Self.milliseconds(observedAt) else { return nil }
        var result = "watch_alert phase=\(phase.rawValue) event_id=\(alert.eventId.uuidString.lowercased()) episode_id=\(alert.episodeId.uuidString.lowercased()) created_at_ms=\(created) observed_at_ms=\(observed)"
        result += DiagnosticCorrelation.fields(reference: alert.diagnosticRef, attempt: alert.deliveryAttempt)
        if let deliveredAt {
            guard let delivered = Self.milliseconds(deliveredAt) else { return nil }
            result += " delivered_at_ms=\(delivered) delivery_age_ms=\(delivered - created)"
            let lagName: String
            switch phase {
            case .retained: lagName = "history_observation_lag_ms"
            case .opened, .acknowledged: lagName = "user_action_lag_ms"
            default: lagName = "callback_lag_ms"
            }
            result += " \(lagName)=\(observed - delivered)"
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
        if let presentationProfile { result += " presentation_profile=\(presentationProfile.rawValue)" }
        if let callbackID { result += " callback_id=\(callbackID.uuidString.lowercased())" }
        if let collapseScope { result += " collapse_scope=\(collapseScope.rawValue)" }
        if let historySource { result += " history_source=\(historySource.rawValue)" }
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
        if let callbackID = fields.first(where: { $0.hasPrefix("callback_id=") }).flatMap({ UUID(uuidString: String($0.dropFirst("callback_id=".count))) }) {
            key += "|\(callbackID.uuidString.lowercased())"
        }
        return key
    }
    private static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1000
        // Keep conversion and subtraction safe even for malformed dates.
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int64(value.rounded())
    }
}
