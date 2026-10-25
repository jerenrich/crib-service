import Foundation

/// The same 120 quarter-second RMS readings displayed by the nursery chart.
/// This transient frame is never included in persisted history or alert payloads.
public struct SoundLevelFrame: Codable, Equatable, Sendable {
    public static let barCount = 120
    public static let windowDuration: TimeInterval = 30
    public var type = "levels"
    public var sampledAt: TimeInterval
    public var levels: [Double]
    public var threshold: Double
    public var state: CryState
    public var episodeStartedAt: TimeInterval?
    public var alertDuration: TimeInterval
    public var requestID: String?
    /// Unix timestamps of alert notifications created within the visible chart window.
    public var notificationTimes: [TimeInterval]?

    public var isValid: Bool {
        type == "levels" && sampledAt.isFinite && (0...32_503_680_000).contains(sampledAt) && levels.count == Self.barCount
        && levels.allSatisfy { $0.isFinite && (-100...0).contains($0) }
        && threshold.isFinite && (-60 ... -10).contains(threshold)
        && alertDuration.isFinite && (5...3600).contains(alertDuration)
        && (notificationTimes?.count ?? 0) <= 32
        && (notificationTimes ?? []).allSatisfy { $0.isFinite && $0 >= sampledAt - Self.windowDuration && $0 <= sampledAt }
        && (episodeStartedAt.map { $0.isFinite && $0 >= 0 && $0 <= sampledAt } ?? true)
        && (requestID.map { UUID(uuidString: $0) != nil } ?? true)
    }
    public var episodeDuration: TimeInterval? { episodeStartedAt.map { max(0, sampledAt - $0) } }
}

/// A Parent-issued challenge bounds end-to-end age without requiring the two
/// phones' clocks to agree. Delayed TCP packets cannot revive an old chart.
public struct LiveSoundRequests: Sendable {
    private var issued: [String: Date] = [:]
    public init() {}
    public mutating func issue(at now: Date) -> String {
        issued = issued.filter { (0..<3).contains(now.timeIntervalSince($0.value)) }
        let id = UUID().uuidString.lowercased(); issued[id] = now
        return id
    }
    public func accepts(_ frame: SoundLevelFrame, at now: Date) -> Bool {
        guard let id = frame.requestID, let sent = issued[id] else { return false }
        return (0..<3).contains(now.timeIntervalSince(sent))
    }
}

public struct RemoteSoundState: Sendable {
    public private(set) var frame: SoundLevelFrame?
    public private(set) var receivedAt: Date?
    public init() {}
    public mutating func receive(_ value: SoundLevelFrame, at now: Date) {
        guard value.isValid, frame.map({ value.sampledAt > $0.sampledAt }) ?? true else { return }
        frame = value; receivedAt = now
    }
    public mutating func disconnected() { receivedAt = nil }
    public func isLive(at now: Date) -> Bool {
        guard let receivedAt else { return false }
        return (0..<3).contains(now.timeIntervalSince(receivedAt))
    }
}

/// One presentation state for every Parent screen. This is deliberately separate
/// from server confirmation of commands, notification delivery and warning timers.
public enum ParentMonitoringDisplayState: String, Codable, Sendable {
    case monitoring = "Monitoring", standby = "Standby", stopped = "Stopped"
    case unavailable = "Status unavailable", connectionLost = "Connection lost"
    case unpaired = "Not paired", starting = "Starting…", pausing = "Pausing…"
    case unverified = "Monitoring unverified"
}

public struct ParentMonitoringEvidence: Sendable {
    private struct Heartbeat: Sendable {
        var state: ParentMonitoringDisplayState
        var version: Date
        var observedAt: Date
    }
    private var heartbeat: Heartbeat?
    private var liveAt: Date?
    private var heartbeatBeforeLive: Date?
    private var ignoreLiveUntil: Date?
    public init() {}

    public mutating func receiveHeartbeat(monitoring: Bool, microphoneActive: Bool,
                                         version: Date, observedAt: Date) {
        guard heartbeat.map({ version >= $0.version }) ?? true else { return }
        // Re-reading a cached heartbeat must never renew its freshness.
        let time = heartbeat.flatMap { $0.version == version ? min($0.observedAt, observedAt) : nil } ?? observedAt
        heartbeat = Heartbeat(state: monitoring ? .monitoring : microphoneActive ? .standby : .stopped,
                              version: version, observedAt: time)
    }
    public func acceptsLive(at now: Date) -> Bool {
        ignoreLiveUntil.map { now >= $0 } ?? true
    }
    public mutating func receiveLive(at now: Date) {
        guard acceptsLive(at: now) else { return }
        liveAt = now
        // A previously known stopped heartbeat cannot undo this newer reading,
        // even if a subsequent status fetch returns that same cached heartbeat.
        heartbeatBeforeLive = heartbeat?.version
    }
    public mutating func pause(at now: Date) {
        liveAt = nil; heartbeatBeforeLive = nil
        // All challenges issued before confirmation expire within three seconds.
        ignoreLiveUntil = now.addingTimeInterval(3)
    }
    public func state(at now: Date, statusAvailable: Bool) -> ParentMonitoringDisplayState {
        if let liveAt {
            let age = now.timeIntervalSince(liveAt)
            let newerStop = heartbeat.map {
                $0.state != .monitoring && $0.version > (heartbeatBeforeLive ?? .distantPast)
            } ?? false
            // Let the bounded lifetime of any in-flight level packet pass before
            // accepting a newer stopped heartbeat. Continuing levels supersede it.
            if newerStop && age >= 3 { return heartbeatState(at: now, available: statusAvailable) }
            if (0...150).contains(age) { return .monitoring }
            // Do not resurrect the old Standby/Stopped state when live evidence expires.
            if heartbeat?.state != .monitoring { return statusAvailable ? .connectionLost : .unavailable }
        }
        return heartbeatState(at: now, available: statusAvailable)
    }
    private func heartbeatState(at now: Date, available: Bool) -> ParentMonitoringDisplayState {
        guard available, let heartbeat else { return .unavailable }
        return (-5...150).contains(now.timeIntervalSince(heartbeat.observedAt)) ? heartbeat.state : .connectionLost
    }
    public func canResume(at now: Date, statusAvailable: Bool) -> Bool {
        state(at: now, statusAvailable: statusAvailable) == .standby &&
        heartbeat.map { (-5...30).contains(now.timeIntervalSince($0.observedAt)) } == true
    }
    public var lastObservationAt: Date? {
        [liveAt, heartbeat?.observedAt].compactMap { $0 }.max()
    }
}
