import Foundation

/// All callers run on the main actor so applying an acknowledgement is a single
/// local operation. Keep its receipt after upload/Resume: WatchConnectivity may
/// deliver the queued copy after a newer episode, or after the phone relaunches.
@MainActor struct SilentCryAlarmSnooze {
    let defaults: UserDefaults

    func markHandled(_ eventID: UUID) {
        defaults.set(true, forKey: "silentCryAlarmSnoozed|\(eventID.uuidString)")
    }
    static func actedAtKey(_ eventID: UUID) -> String { "silentCryAlarmActedAt|\(eventID.uuidString)" }
    func actedAt(_ eventID: UUID) -> Date? { defaults.object(forKey: Self.actedAtKey(eventID)) as? Date }

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
        let cutoff = max(now, defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date ?? .distantPast)
        let until = max(now.addingTimeInterval(duration), defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date ?? .distantPast)
        defaults.set(cutoff, forKey: "silentCryAlarmStoppedBefore")
        defaults.set(until, forKey: "silentCryAlarmMutedUntil")
        defaults.set(now, forKey: Self.actedAtKey(eventID))
        pending.append(id)
        defaults.set(Array(pending.suffix(100)), forKey: "silentCryAlarmPendingAcknowledgements")
        markHandled(eventID)
        return true
    }
}

struct SilentCryAlarmRequest: Sendable {
    static let maximumPushAge: TimeInterval = 60
    enum Rejection: String, Error {
        case notRequested = "not_requested", malformed, stale
        case disabled, busy, acknowledgementPending = "acknowledgement_pending"
        case settingChanged = "setting_changed", serverDisabled = "server_disabled", unpaired
        case relevanceUnknown = "relevance_unknown", irrelevant, serverMuted = "server_muted"
        case staleStatus = "stale_status"
        case budgetExpired = "budget_expired"
        case locallyMuted = "locally_muted", stopped, unauthorized, missingAsset = "missing_asset"
        case methodDisabled = "method_disabled", noSnapshot = "no_snapshot"
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
        let flags: [String]
        init(payload: [AnyHashable: Any], now: Date = Date()) {
            receivedAt = now; start = .now; flags = AlarmAttempt.flags(in: payload)
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
    let isDisconnected: Bool
    let isMonitoringFailure: Bool
    /// A configured Test alert. It takes this same path and differs only where a
    /// test must: its own relevance, no snooze checks and no snooze on Stop.
    let isTest: Bool

    init?(payload: [AnyHashable: Any], now: Date = Date()) {
        guard case .success(let fields) = Self.parse(payload, now: now) else { return nil }
        eventID = fields.0; episodeID = fields.1; createdAt = fields.2
        isDisconnected = payload["type"] as? String == "listener_disconnected"
        isMonitoringFailure = payload["type"] as? String == CryAlert.monitoringFailedType
        cycleID = (payload["alarmCycleId"] as? String).flatMap(UUID.init(uuidString:))
        isTest = payload["isTest"] as? Bool == true
    }

    /// Explains rejected marked payloads without retaining payload text or arbitrary identifiers.
    static func payloadRejection(_ payload: [AnyHashable: Any], now: Date = Date()) -> Rejection? {
        if case .failure(let reason) = parse(payload, now: now) { return reason }
        return nil
    }

    private static func parse(_ payload: [AnyHashable: Any], now: Date) -> Result<(UUID, UUID, Date), Rejection> {
        // Either delivery method's marker: the app wake or the notification extension.
        guard payload["silentCryAlarm"] as? Bool == true || payload["alarmExtension"] as? Bool == true else { return .failure(.notRequested) }
        if let cycle = payload["alarmCycleId"], (cycle as? String).flatMap(UUID.init(uuidString:)) == nil { return .failure(.malformed) }
        guard let event = payload["eventId"] as? String, let eventID = UUID(uuidString: event),
              let episode = payload["episodeId"] as? String, let episodeID = UUID(uuidString: episode),
              let text = payload["createdAt"] as? String else { return .failure(.malformed) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return .failure(.malformed) }
        guard (-5...maximumPushAge).contains(now.timeIntervalSince(date)) else { return .failure(.stale) }
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
        if !(-5...Self.maximumPushAge).contains(now.timeIntervalSince(createdAt)) { return .stale }
        guard let relevance else { return .relevanceUnknown }
        if !relevance.contains(eventID: eventID, episodeID: episodeID, isTest: isTest) { return .irrelevant }
        // A test is a deliberate request; snoozing real alerts does not suppress it.
        if isTest { return nil }
        if !((mutedUntil ?? .distantPast) <= now) { return .serverMuted }
        if !((localMutedUntil ?? .distantPast) <= now) { return .locallyMuted }
        if !(createdAt > (stoppedBefore ?? .distantPast)) { return .stopped }
        return nil
    }

    /// A recent authenticated push is positive evidence from the service at send
    /// time. Never use it to override a local Snooze or a newer negative status.
    func fallbackIneligibilityReason(enabled: Bool, acknowledgementPending: Bool,
        localMutedUntil: Date?, stoppedBefore: Date?, evidence: ServerEvidence?, now: Date) -> Rejection? {
        if !enabled { return .disabled }
        if acknowledgementPending { return .acknowledgementPending }
        if !(-5...Self.maximumPushAge).contains(now.timeIntervalSince(createdAt)) { return .stale }
        if !isTest, (localMutedUntil ?? .distantPast) > now { return .locallyMuted }
        if !isTest, createdAt <= (stoppedBefore ?? .distantPast) { return .stopped }
        if let evidence, evidence.observedAt >= createdAt {
            if !evidence.paired { return .unpaired }
            if evidence.enabled == false { return .serverDisabled }
            if let relevance = evidence.relevance, !relevance.contains(eventID: eventID, episodeID: episodeID, isTest: isTest) { return .irrelevant }
            if !isTest, (evidence.mutedUntil ?? .distantPast) > now { return .serverMuted }
        }
        return nil
    }

    struct ServerEvidence: Codable, Equatable, Sendable {
        let observedAt: Date
        let paired: Bool
        let enabled: Bool?
        let relevance: NotificationRelevance?
        let mutedUntil: Date?

        func hasSameState(as other: Self) -> Bool {
            paired == other.paired && enabled == other.enabled && relevance == other.relevance && mutedUntil == other.mutedUntil
        }
    }

    static func allowsStatusFallback(for error: any Error) -> Bool {
        if let rejection = error as? Rejection {
            return rejection == .budgetExpired || rejection == .staleStatus
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return true
        default: return false // Cancellation, TLS failures and server rejections stay authoritative.
        }
    }

    static func allowsStatusFallback(forHTTPStatus status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }
}

/// A soft budget for status validation, not a scheduling deadline or an estimate
/// of iOS runtime. Expiry skips further network work and permits guarded fallback.
/// Includes sleep and actor/executor delays from notification callback entry.
struct SilentCryAlarmExecutionBudget: Sendable {
    static let maximumDuration: Duration = .seconds(5)
    static let schedulingReserve: Duration = .seconds(1)
    static let requestTimeout: TimeInterval = 2
    let startedAt: ContinuousClock.Instant

    func requireTime(at now: ContinuousClock.Instant = .now) throws {
        let elapsed = startedAt.duration(to: now)
        guard elapsed >= .zero, elapsed < Self.maximumDuration - Self.schedulingReserve else {
            throw SilentCryAlarmRequest.Rejection.budgetExpired
        }
        try Task.checkCancellation()
    }

    func remainingMilliseconds(at now: ContinuousClock.Instant = .now) -> Int {
        let remaining = now.duration(to: startedAt.advanced(by: Self.maximumDuration)).components
        return Int(max(0, min(5_000, remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)))
    }
}

/// Measure from before the request, including time suspended before its result is
/// processed. A newly resumed URLSession completion can contain an old snapshot.
struct SilentCryAlarmStatusSnapshot<Value: Sendable>: Sendable {
    static var maximumAge: Duration { .seconds(5) }
    let value: Value
    let checkedAt: Date
    private let startedAt: ContinuousClock.Instant

    func isFresh(at now: ContinuousClock.Instant = .now) -> Bool {
        (.zero...Self.maximumAge).contains(startedAt.duration(to: now))
    }

    /// One short read per callback. Discard a resumed old response; the caller may
    /// use the recent push for guarded fallback without another round trip.
    @MainActor static func load(
        budget: SilentCryAlarmExecutionBudget,
        clock: () -> ContinuousClock.Instant = { .now },
        date: () -> Date = { Date() },
        fetch: () async throws -> Value
    ) async throws -> Self {
        try budget.requireTime(at: clock())
        let checkedAt = date(), startedAt = clock()
        let value = try await fetch()
        try budget.requireTime(at: clock())
        let snapshot = Self(value: value, checkedAt: checkedAt, startedAt: startedAt)
        guard snapshot.isFresh(at: clock()) else { throw SilentCryAlarmRequest.Rejection.staleStatus }
        return snapshot
    }
}
