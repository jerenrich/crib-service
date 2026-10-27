import Foundation

/// All callers run on the main actor so applying an acknowledgement is a single
/// local operation. Keep its receipt after upload/Resume: WatchConnectivity may
/// deliver the queued copy after a newer episode, or after the phone relaunches.
@MainActor struct SilentCryAlarmSnooze {
    let defaults: UserDefaults

    func markHandled(_ eventID: UUID) {
        defaults.set(true, forKey: "silentCryAlarmSnoozed|\(eventID.uuidString)")
    }

    @discardableResult func apply(eventID: UUID, duration: TimeInterval, now: Date) -> Bool {
        let id = eventID.uuidString
        let receiptKey = "silentCryAlarmSnoozed|\(id)"
        guard !defaults.bool(forKey: receiptKey) else { return false }
        var pending = defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements") ?? []
        if pending.contains(id) {
            // A pre-upgrade pending acknowledgement already applied its snooze.
            markHandled(eventID)
            return false
        }
        defaults.set(now, forKey: "silentCryAlarmStoppedBefore")
        defaults.set(now.addingTimeInterval(duration), forKey: "silentCryAlarmMutedUntil")
        pending.append(id)
        defaults.set(Array(pending.suffix(100)), forKey: "silentCryAlarmPendingAcknowledgements")
        markHandled(eventID)
        return true
    }
}

struct SilentCryAlarmRequest: Sendable {
    enum Rejection: String, Error {
        case notRequested = "not_requested", test, malformed, stale
        case disabled, busy, acknowledgementPending = "acknowledgement_pending"
        case settingChanged = "setting_changed", serverDisabled = "server_disabled", unpaired
        case relevanceUnknown = "relevance_unknown", irrelevant, serverMuted = "server_muted"
        case locallyMuted = "locally_muted", stopped, unauthorized, missingAsset = "missing_asset"
    }
    enum Source: String { case foregroundNotification = "foreground_notification", remoteNotification = "remote_notification" }
    enum Stage: String { case callback, preflight, acknowledgements, status, eligibility, alarmLookup = "alarm_lookup", schedule, cancel }
    enum ObservationSource: String { case appLoop = "app_loop", backgroundRefresh = "background_refresh", settingChange = "setting_change", foreground }
    enum Authorization: String { case authorized, denied, notDetermined = "not_determined", unknown }
    /// Capture typed values at callback entry, before crossing to the main actor.
    /// The original notification dictionary never crosses that boundary or enters a log.
    struct Callback: Sendable {
        let eventID: UUID?
        let episodeID: UUID?
        let request: SilentCryAlarmRequest?
        let rejection: Rejection?
        let receivedAt: Date
        let start: ContinuousClock.Instant
        init(payload: [AnyHashable: Any], now: Date = Date()) {
            receivedAt = now; start = .now
            eventID = (payload["eventId"] as? String).flatMap(UUID.init(uuidString:))
            episodeID = (payload["episodeId"] as? String).flatMap(UUID.init(uuidString:))
            request = SilentCryAlarmRequest(payload: payload, now: now)
            rejection = request == nil ? SilentCryAlarmRequest.payloadRejection(payload, now: now) : nil
        }
    }
    let eventID: UUID
    let episodeID: UUID
    let createdAt: Date
    let cycleID: UUID?

    init?(payload: [AnyHashable: Any], now: Date = Date()) {
        guard case .success(let fields) = Self.parse(payload, now: now) else { return nil }
        eventID = fields.0; episodeID = fields.1; createdAt = fields.2
        cycleID = (payload["alarmCycleId"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Explains rejected marked payloads without retaining payload text or arbitrary identifiers.
    static func payloadRejection(_ payload: [AnyHashable: Any], now: Date = Date()) -> Rejection? {
        if case .failure(let reason) = parse(payload, now: now) { return reason }
        return nil
    }

    private static func parse(_ payload: [AnyHashable: Any], now: Date) -> Result<(UUID, UUID, Date), Rejection> {
        guard payload["silentCryAlarm"] as? Bool == true else { return .failure(.notRequested) }
        guard payload["isTest"] as? Bool != true else { return .failure(.test) }
        if let cycle = payload["alarmCycleId"], (cycle as? String).flatMap(UUID.init(uuidString:)) == nil { return .failure(.malformed) }
        guard let event = payload["eventId"] as? String, let eventID = UUID(uuidString: event),
              let episode = payload["episodeId"] as? String, let episodeID = UUID(uuidString: episode),
              let text = payload["createdAt"] as? String else { return .failure(.malformed) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return .failure(.malformed) }
        guard (-5...60).contains(now.timeIntervalSince(date)) else { return .failure(.stale) }
        return .success((eventID, episodeID, date))
    }

    func isEligible(enabled: Bool, serverEnabled: Bool, paired: Bool, relevance: NotificationRelevance?,
                    mutedUntil: Date?, localMutedUntil: Date?, stoppedBefore: Date?, now: Date) -> Bool {
        ineligibilityReason(enabled: enabled, serverEnabled: serverEnabled, paired: paired, relevance: relevance,
            mutedUntil: mutedUntil, localMutedUntil: localMutedUntil, stoppedBefore: stoppedBefore, now: now) == nil
    }

    func ineligibilityReason(enabled: Bool, serverEnabled: Bool, paired: Bool, relevance: NotificationRelevance?,
                             mutedUntil: Date?, localMutedUntil: Date?, stoppedBefore: Date?, now: Date) -> Rejection? {
        if !enabled { return .disabled }
        if !serverEnabled { return .serverDisabled }
        if !paired { return .unpaired }
        if !(-5...60).contains(now.timeIntervalSince(createdAt)) { return .stale }
        guard let relevance else { return .relevanceUnknown }
        if !relevance.cryEpisodeIDs.contains(episodeID) { return .irrelevant }
        if !((mutedUntil ?? .distantPast) <= now) { return .serverMuted }
        if !((localMutedUntil ?? .distantPast) <= now) { return .locallyMuted }
        if !(createdAt > (stoppedBefore ?? .distantPast)) { return .stopped }
        return nil
    }
}
