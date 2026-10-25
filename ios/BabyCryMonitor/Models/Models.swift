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
    public let timestamp: Date
    public let dbFS: Double
    public init(timestamp: Date, dbFS: Double) { self.timestamp = timestamp; self.dbFS = dbFS }
}
public enum CryState: String, Codable, Sendable { case quiet, possibleCry, crying }
public struct CryEpisode: Identifiable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
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
    public var id: UUID { eventId }
    public init(eventId: UUID = UUID(), episodeId: UUID, listenerId: UUID, cryStartedAt: Date, durationSeconds: Double, createdAt: Date, isRepeat: Bool, isTest: Bool? = nil) {
        self.eventId = eventId; self.episodeId = episodeId; self.listenerId = listenerId
        self.type = "sustained_cry"; self.cryStartedAt = cryStartedAt; self.durationSeconds = durationSeconds
        self.createdAt = createdAt; self.isRepeat = isRepeat
        self.isTest = isTest
    }
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
        case configuration, history, current, pending, failedAlerts, lastObservedAt, wasMonitoring, timelineEvents, pendingTimelineIDs, timelineScope
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decode(MonitoringConfiguration.self, forKey: .configuration)
        history = try values.decode([CryEpisode].self, forKey: .history)
        current = try values.decodeIfPresent(CryEpisode.self, forKey: .current)
        pending = try values.decode([PendingAlert].self, forKey: .pending)
        failedAlerts = try values.decodeIfPresent([FailedAlert].self, forKey: .failedAlerts) ?? []
        lastObservedAt = try values.decodeIfPresent(Date.self, forKey: .lastObservedAt)
        wasMonitoring = try values.decode(Bool.self, forKey: .wasMonitoring)
        timelineScope = try values.decodeIfPresent(String.self, forKey: .timelineScope)
        timelineEvents = try values.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []
        pendingTimelineIDs = try values.decodeIfPresent([String].self, forKey: .pendingTimelineIDs) ?? []
    }
}
