import Foundation

public enum DeviceRole: String, Codable, CaseIterable, Sendable { case listener, parent }
public struct MonitoringConfiguration: Codable, Equatable, Sendable {
    public static let soundThresholds = Array(stride(from: -60.0, through: -10.0, by: 5.0))
    public var alertDuration: TimeInterval = 5
    public static let snoozeDurations: [TimeInterval] = [60, 120, 300, 600, 900]
    public var snoozeDuration: TimeInterval = 60
    public var quietResetDuration: TimeInterval = 20
    public static let repeatIntervals: [TimeInterval] = [5, 2]
    public var repeatInterval: TimeInterval? = 5
    public var absoluteThreshold: Double = -35
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case alertDuration, quietResetDuration, repeatInterval, absoluteThreshold, snoozeDuration
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alertDuration = try values.decode(TimeInterval.self, forKey: .alertDuration)
        quietResetDuration = try values.decode(TimeInterval.self, forKey: .quietResetDuration)
        absoluteThreshold = try values.decode(Double.self, forKey: .absoluteThreshold)
        snoozeDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .snoozeDuration) ?? 60
        // The server now owns reminders. Migrate the retired Off/15-second/2/5-minute choices.
        let savedRepeat = try values.decodeIfPresent(TimeInterval.self, forKey: .repeatInterval)
        repeatInterval = savedRepeat == 2 ? 2 : 5
    }
    public var isValid: Bool {
        alertDuration.isFinite && (5...3600).contains(alertDuration) && [10.0, 20, 30, 60].contains(quietResetDuration)
        && Self.repeatIntervals.contains(repeatInterval ?? 0) && Self.snoozeDurations.contains(snoozeDuration)
        && absoluteThreshold.isFinite && (-60 ... -10).contains(absoluteThreshold)
    }
}
public protocol ClockProviding: Sendable { var now: Date { get } }
public struct SystemClock: ClockProviding { public init() {}; public var now: Date { Date() } }
public struct AudioLevelSample: Sendable {
    /// Disjoint PCM coverage, independent of callback scheduling and wall time.
    /// A new capture ID starts after format changes or input-frame discontinuity.
    public struct Window: Sendable {
        public let captureID: UUID
        public let startFrame: Int64
        public let endFrame: Int64
        public let sampleRate: Double
        public init(captureID: UUID, startFrame: Int64, endFrame: Int64, sampleRate: Double) {
            self.captureID = captureID; self.startFrame = startFrame
            self.endFrame = endFrame; self.sampleRate = sampleRate
        }
        var isValid: Bool {
            sampleRate.isFinite && (1...384_000).contains(sampleRate)
                && startFrame >= 0 && endFrame > startFrame
                && endFrame - startFrame == max(1, Int64(sampleRate * 0.25))
        }
        var start: Date { Date(timeIntervalSince1970: Double(startFrame) / sampleRate) }
        var end: Date { Date(timeIntervalSince1970: Double(endFrame) / sampleRate) }
    }
    public let timestamp: Date
    public let dbFS: Double
    public let window: Window?
    public init(timestamp: Date, dbFS: Double, window: Window? = nil) {
        self.timestamp = timestamp; self.dbFS = dbFS; self.window = window
    }
    var isValid: Bool {
        timestamp.timeIntervalSinceReferenceDate.isFinite && dbFS.isFinite && (window?.isValid ?? true)
    }
}
public enum CryState: String, Codable, Sendable { case quiet, possibleCry, crying }
public struct CryEpisode: Identifiable, Codable, Sendable {
    public let id: UUID
    public internal(set) var startedAt: Date
    public var endedAt: Date?
    public var quietConfirmed: Bool?
    public var alertQueuedAt: Date?
    public var alertSentAt: Date?
    public var lastAlertQueuedAt: Date?
    public var maximumDBFS: Double?
    public var averageDBFS: Double?
    public var sampleCount: Int = 0
    public init(id: UUID = UUID(), startedAt: Date) { self.id = id; self.startedAt = startedAt }
    public func duration(at now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }
}
/// Deliberately excludes sound levels and all audio-derived features.
public struct CryAlert: Identifiable, Codable, Equatable, Sendable {
    public let eventId: UUID
    public let episodeId: UUID
    public let listenerId: UUID
    public let type: String
    public let cryStartedAt: Date
    public let durationSeconds: Double
    public let createdAt: Date
    public let isRepeat: Bool
    public let isTest: Bool?
    /// Why monitoring stopped, for a monitoring-failure alert; nil for an unknown
    /// or hardware cause. Sent only to servers that advertise support.
    public let reason: String?
    // Persisted locally only. Missing on an old outbox entry preserves its old
    // second-rounded wire metadata, so an upgrade cannot break UUID deduplication.
    let wireTimestampVersion: Int?
    public var id: UUID { eventId }
    /// The Listener stopped listening without a person's Stop. The server repeats
    /// it like crying until the Listener reports monitoring again.
    public static let monitoringFailedType = "monitoring_failed"
    public var isMonitoringFailure: Bool { type == Self.monitoringFailedType }
    /// Another app or system sound is playing on the Listener, so detection is paused.
    public static let otherAudioReason = "other_audio"
    public init(eventId: UUID = UUID(), episodeId: UUID, listenerId: UUID, cryStartedAt: Date, durationSeconds: Double, createdAt: Date, isRepeat: Bool, isTest: Bool? = nil, type: String = "sustained_cry", reason: String? = nil) {
        self.eventId = eventId; self.episodeId = episodeId; self.listenerId = listenerId
        self.type = type; self.cryStartedAt = cryStartedAt; self.durationSeconds = durationSeconds
        self.createdAt = createdAt; self.isRepeat = isRepeat
        self.isTest = isTest
        self.reason = reason
        self.wireTimestampVersion = 1
    }
}
/// Shared wording for a monitoring-stopped alert caused by other audio on the
/// Listener. Matches the server's push text so every surface says the same thing.
public enum DetectionPauseCopy {
    public static let title = "Crying detection paused"
    public static let body = "Another sound is playing on the nursery iPhone, so crying is not being detected. Detection resumes by itself when the sound stops."
}
public struct PendingAlert: Codable, Sendable {
    public let alert: CryAlert
    public var attempts: Int = 0
    public var nextAttemptAt: Date
    public init(alert: CryAlert) { self.alert = alert; nextAttemptAt = alert.createdAt }
    public mutating func failed(at now: Date) {
        attempts += 1
        nextAttemptAt = now.addingTimeInterval(min(300, pow(2, Double(min(attempts, 9)))))
    }
}
public struct FailedAlert: Identifiable, Codable, Sendable {
    public let alert: CryAlert
    public let failedAt: Date
    public var id: UUID { alert.eventId }
    public init(alert: CryAlert, failedAt: Date) { self.alert = alert; self.failedAt = failedAt }
}
public enum EpisodeAlertStatus: Sendable { case notQueued, pending, failed, sent, acknowledged }
public struct SessionSnapshot: Codable, Sendable {
    public var configuration = MonitoringConfiguration()
    public var history: [CryEpisode] = []
    public var current: CryEpisode?
    public var pending: [PendingAlert] = []
    public var failedAlerts: [FailedAlert] = []
    public var lastObservedAt: Date?
    /// Latest validated audio evidence from either detector. Keep RMS continuity
    /// in lastObservedAt so classifier callbacks cannot disguise missing levels.
    public var lastDetectionAt: Date?
    public var timelineScope: String?
    public var timelineEvents: [TimelineEvent] = []
    public var pendingTimelineIDs: [String] = []
    public var wasMonitoring = false
    public init() {}
    public func alertStatus(for episode: CryEpisode) -> EpisodeAlertStatus {
        if pending.contains(where: { $0.alert.episodeId == episode.id }) { return .pending }
        let latestQueuedAt = episode.lastAlertQueuedAt ?? episode.alertQueuedAt
        if failedAlerts.contains(where: { $0.alert.episodeId == episode.id && $0.alert.createdAt == latestQueuedAt }) { return .failed }
        if episode.alertSentAt != nil { return .sent }
        return episode.alertQueuedAt == nil ? .notQueued : .acknowledged
    }
    private enum CodingKeys: String, CodingKey {
        case configuration, history, current, pending, failedAlerts, lastObservedAt, lastDetectionAt, wasMonitoring, timelineEvents, pendingTimelineIDs, timelineScope
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decode(MonitoringConfiguration.self, forKey: .configuration)
        history = try values.decode([CryEpisode].self, forKey: .history)
        current = try values.decodeIfPresent(CryEpisode.self, forKey: .current)
        pending = try values.decode([PendingAlert].self, forKey: .pending)
        failedAlerts = try values.decodeIfPresent([FailedAlert].self, forKey: .failedAlerts) ?? []
        lastObservedAt = try values.decodeIfPresent(Date.self, forKey: .lastObservedAt)
        lastDetectionAt = try values.decodeIfPresent(Date.self, forKey: .lastDetectionAt)
        wasMonitoring = try values.decode(Bool.self, forKey: .wasMonitoring)
        timelineScope = try values.decodeIfPresent(String.self, forKey: .timelineScope)
        timelineEvents = try values.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []
        pendingTimelineIDs = try values.decodeIfPresent([String].self, forKey: .pendingTimelineIDs) ?? []
    }
}
