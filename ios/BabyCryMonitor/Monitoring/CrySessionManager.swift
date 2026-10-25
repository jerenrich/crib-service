import Foundation

/// A deterministic value engine: the Listener owns all episode timing. Callers persist the
/// entire snapshot before making any network request so retries reuse their original UUID.
public struct CrySessionManager: Sendable {
    public private(set) var snapshot: SessionSnapshot
    public private(set) var detector = CryDetector()
    private let clock: any ClockProviding
    public init(snapshot: SessionSnapshot = SessionSnapshot(), clock: any ClockProviding = SystemClock()) {
        self.snapshot = snapshot; self.clock = clock
    }
    public mutating func configure(_ configuration: MonitoringConfiguration) {
        guard configuration.isValid else { return }; snapshot.configuration = configuration
    }
    /// Queue a synthetic threshold event through the normal durable delivery path.
    /// Its separate episode leaves microphone detection and live episode timing untouched.
    @discardableResult public mutating func queueTestAlert(listenerId: UUID) -> CryAlert {
        let now = clock.now
        let duration = snapshot.configuration.alertDuration
        let alert = CryAlert(episodeId: UUID(), listenerId: listenerId,
                             cryStartedAt: now.addingTimeInterval(-duration), durationSeconds: duration,
                             createdAt: now, isRepeat: false, isTest: true)
        snapshot.pending.append(PendingAlert(alert: alert))
        return alert
    }
    @discardableResult public mutating func consume(_ sample: AudioLevelSample, listenerId: UUID) -> [CryAlert] {
        if let last = snapshot.lastObservedAt, sample.timestamp <= last { return [] }
        guard sample.dbFS.isFinite else { return [] }
        // An unobserved interval must never count as verified crying (e.g. engine stall/call).
        if let last = snapshot.lastObservedAt, sample.timestamp.timeIntervalSince(last) > 2 {
            end(at: last); detector.reset()
        }
        let previous = detector.state
        let state = detector.consume(sample, configuration: snapshot.configuration)
        snapshot.lastObservedAt = sample.timestamp
        if state == .crying && previous != .crying {
            snapshot.current = CryEpisode(startedAt: sample.timestamp)
            if let episode = snapshot.current {
                appendTimeline(TimelineEvent(id: "cry:\(episode.id.uuidString.lowercased())", kind: "cry_started",
                                             occurredAt: episode.startedAt, episodeID: episode.id.uuidString.lowercased()))
            }
        }
        if previous == .crying && state == .quiet {
            end(at: detector.quietSince ?? sample.timestamp, quietConfirmed: true)
        }
        guard var episode = snapshot.current else { return [] }
        episode.sampleCount += 1
        episode.maximumDBFS = max(episode.maximumDBFS ?? sample.dbFS, sample.dbFS)
        episode.averageDBFS = (episode.averageDBFS ?? sample.dbFS) + (sample.dbFS - (episode.averageDBFS ?? sample.dbFS)) / Double(episode.sampleCount)
        var alerts: [CryAlert] = []
        let initial = episode.alertQueuedAt == nil && episode.duration(at: sample.timestamp) >= snapshot.configuration.alertDuration
        // Once sustained quiet reaches reset, the episode above has already ended.
        // Defer a due alert during a quiet gap until sound resumes. If the gap
        // becomes a full reset, a baby that settled before the threshold sends none.
        // The server repeats until acknowledgement or a confirmed quiet reset.
        if initial && sample.dbFS >= snapshot.configuration.absoluteThreshold {
            let alert = CryAlert(episodeId: episode.id, listenerId: listenerId, cryStartedAt: episode.startedAt,
                                 durationSeconds: episode.duration(at: sample.timestamp), createdAt: sample.timestamp, isRepeat: !initial)
            if initial { episode.alertQueuedAt = sample.timestamp }
            episode.lastAlertQueuedAt = sample.timestamp
            snapshot.pending.append(PendingAlert(alert: alert)); alerts.append(alert)
        }
        snapshot.current = episode
        return alerts
    }
    public mutating func scopeTimeline(to scope: String) {
        guard snapshot.timelineScope != scope else { return }
        snapshot.timelineEvents = []; snapshot.pendingTimelineIDs = []; snapshot.timelineScope = scope
    }
    public mutating func recordTimeline(_ kind: String, at date: Date) {
        appendTimeline(TimelineEvent(kind: kind, occurredAt: date))
    }
    private mutating func appendTimeline(_ event: TimelineEvent) {
        guard !snapshot.timelineEvents.contains(where: { $0.id == event.id }) else { return }
        snapshot.timelineEvents.append(event); snapshot.pendingTimelineIDs.append(event.id)
        let cutoff = event.occurredAt.addingTimeInterval(-24 * 3600)
        snapshot.timelineEvents = Array(snapshot.timelineEvents.filter { $0.occurredAt >= cutoff }.suffix(1000))
        let retained = Set(snapshot.timelineEvents.map(\.id))
        snapshot.pendingTimelineIDs.removeAll { !retained.contains($0) }
    }
    public mutating func uploadedTimeline(_ ids: Set<String>) {
        snapshot.pendingTimelineIDs.removeAll { ids.contains($0) }
    }
    public mutating func markMonitoring(_ active: Bool) { snapshot.wasMonitoring = active }
    public mutating func end(at date: Date? = nil, quietConfirmed: Bool = false) {
        if var episode = snapshot.current {
            let endedAt = max(episode.startedAt, date ?? clock.now)
            episode.endedAt = endedAt
            episode.quietConfirmed = quietConfirmed
            appendTimeline(TimelineEvent(id: "cry-end:\(episode.id.uuidString.lowercased())", kind: "cry_ended",
                                         occurredAt: endedAt, endAt: episode.startedAt, episodeID: episode.id.uuidString.lowercased()))
            snapshot.history.insert(episode, at: 0)
            snapshot.history = Array(snapshot.history.prefix(100))
            snapshot.current = nil
        }
    }
    public mutating func suspend() {
        end(at: snapshot.lastObservedAt ?? clock.now); detector.reset(); snapshot.wasMonitoring = false
    }
    public mutating func recoverAfterRelaunch() { suspend(); snapshot.lastObservedAt = nil }
    public mutating func delivered(_ id: UUID, at date: Date) {
        guard let item = snapshot.pending.first(where: { $0.id == id }) else { return }
        if !item.alert.isRepeat {
            if snapshot.current?.id == item.alert.episodeId { snapshot.current?.alertSentAt = date }
            if let index = snapshot.history.firstIndex(where: { $0.id == item.alert.episodeId }) { snapshot.history[index].alertSentAt = date }
        }
        snapshot.pending.removeAll { $0.id == id }
    }
    public mutating func failed(_ id: UUID, at date: Date) {
        if let index = snapshot.pending.firstIndex(where: { $0.id == id }) { snapshot.pending[index].failed(at: date) }
    }
    public mutating func acknowledged(_ id: UUID) {
        snapshot.pending.removeAll { $0.id == id }
    }
    public mutating func permanentlyFailed(_ id: UUID, at date: Date) {
        guard let item = snapshot.pending.first(where: { $0.id == id }) else { return }
        snapshot.failedAlerts.insert(FailedAlert(alert: item.alert, failedAt: date), at: 0)
        snapshot.failedAlerts = Array(snapshot.failedAlerts.prefix(100))
        snapshot.pending.removeAll { $0.id == id }
    }
}
private extension PendingAlert { var id: UUID { alert.eventId } }
