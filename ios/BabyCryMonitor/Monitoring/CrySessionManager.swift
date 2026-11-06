import Foundation

/// A deterministic value engine: the Listener owns all episode timing. Callers persist the
/// entire snapshot before making any network request so retries reuse their original UUID.
public struct CrySessionManager: Sendable {
    public private(set) var snapshot: SessionSnapshot
    public private(set) var detector = CryDetector()
    private(set) var confidenceDetector = CryConfidenceDetector()
    enum AlertTrigger { case volume, classifier }
    private(set) var lastAlertTrigger: AlertTrigger?
    var latestClassifierInputAt: Date? { confidenceDetector.latestInputAt }
    public var state: CryState {
        if detector.state == .crying || confidenceDetector.state == .crying
            || (snapshot.current != nil && confidenceDetector.retainsEpisode) { return .crying }
        if detector.state == .possibleCry || confidenceDetector.state == .possibleCry { return .possibleCry }
        return .quiet
    }
    public var quietSince: Date? {
        let confidenceActive = confidenceDetector.state == .crying
            || (snapshot.current != nil && confidenceDetector.retainsEpisode)
        let sources = [(detector.state, detector.quietSince),
                       (confidenceActive ? CryState.crying : confidenceDetector.state, confidenceDetector.quietSince)]
            .filter { $0.0 == .crying }
        guard !sources.isEmpty, sources.allSatisfy({ $0.1 != nil }) else { return nil }
        return sources.compactMap { $0.1 }.max()
    }
    private let clock: any ClockProviding
    private var lastVolumeInputAt: Date?
    public init(snapshot: SessionSnapshot = SessionSnapshot(), clock: any ClockProviding = SystemClock()) {
        self.snapshot = snapshot; self.clock = clock
        lastVolumeInputAt = snapshot.lastObservedAt
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
    /// Queue one persistent "monitoring stopped" alert for an unexpected stop. Its
    /// start is the stop time, so the server can tell a later monitoring heartbeat.
    @discardableResult public mutating func queueMonitoringFailure(listenerId: UUID, at date: Date) -> CryAlert? {
        guard !snapshot.pending.contains(where: { $0.alert.isMonitoringFailure }) else { return nil }
        let alert = CryAlert(episodeId: UUID(), listenerId: listenerId, cryStartedAt: date, durationSeconds: 0,
                             createdAt: date, isRepeat: false, type: CryAlert.monitoringFailedType)
        snapshot.pending.append(PendingAlert(alert: alert))
        return alert
    }
    /// Monitoring resumed or a person stopped it: an unsent stop alert is obsolete.
    public mutating func clearMonitoringFailures() {
        snapshot.pending.removeAll { $0.alert.isMonitoringFailure }
    }
    @discardableResult public mutating func consume(_ sample: AudioLevelSample, listenerId: UUID) -> [CryAlert] {
        if let last = snapshot.lastObservedAt, sample.timestamp <= last { return [] }
        guard sample.dbFS.isFinite, sample.timestamp.timeIntervalSinceReferenceDate.isFinite else { return [] }
        confidenceDetector.advance(to: sample.timestamp, configuration: snapshot.configuration)
        // A gap in delivered RMS levels invalidates volume confirmation, not
        // independently observed classifier audio or its shared alert episode.
        expireVolume(at: sample.timestamp)
        _ = detector.consume(sample, configuration: snapshot.configuration)
        snapshot.lastObservedAt = sample.timestamp
        lastVolumeInputAt = sample.timestamp
        recordDetection(at: sample.timestamp)
        let events = reconcile(at: sample.timestamp, listenerId: listenerId,
                               volumeIsLoud: sample.dbFS >= snapshot.configuration.absoluteThreshold)
        guard var episode = snapshot.current else { return [] }
        episode.sampleCount += 1
        episode.maximumDBFS = max(episode.maximumDBFS ?? sample.dbFS, sample.dbFS)
        episode.averageDBFS = (episode.averageDBFS ?? sample.dbFS) + (sample.dbFS - (episode.averageDBFS ?? sample.dbFS)) / Double(episode.sampleCount)
        snapshot.current = episode
        return events
    }

    @discardableResult mutating func consumeClassification(_ event: SoundClassificationEvent, at now: Date,
                                                          listenerId: UUID) -> [CryAlert] {
        confidenceDetector.consume(event, at: now, configuration: snapshot.configuration)
        if let inputAt = confidenceDetector.latestInputAt { recordDetection(at: min(inputAt, now)) }
        expireVolume(at: now)
        return reconcile(at: now, listenerId: listenerId, volumeIsLoud: false)
    }

    private mutating func recordDetection(at date: Date) {
        snapshot.lastDetectionAt = max(snapshot.lastDetectionAt ?? date, date)
    }

    private mutating func expireVolume(at now: Date) {
        guard let last = lastVolumeInputAt, now.timeIntervalSince(last) > 2 else { return }
        // Handle this loss once. Repeating it on every classifier callback would
        // close a healthy classifier episode after its eventual quiet reset.
        lastVolumeInputAt = nil
        if !confidenceDetector.retainsEpisode {
            end(at: max(last, snapshot.lastDetectionAt ?? last))
        }
        detector.reset()
    }

    private mutating func reconcile(at now: Date, listenerId: UUID, volumeIsLoud: Bool) -> [CryAlert] {
        guard state == .crying else {
            if snapshot.current != nil {
                let quiet = [detector.quietSince, confidenceDetector.quietSince].compactMap { $0 }.max() ?? now
                end(at: quiet, quietConfirmed: true)
            }
            return []
        }
        let starts = [detector.state == .crying ? detector.cryStartedAt : nil,
                      confidenceDetector.state == .crying ? confidenceDetector.cryStartedAt : nil].compactMap { $0 }
        let start = starts.min() ?? now
        if snapshot.current == nil {
            let episode = CryEpisode(startedAt: start)
            snapshot.current = episode
            appendTimeline(TimelineEvent(id: "cry:\(episode.id.uuidString.lowercased())", kind: "cry_started",
                                         occurredAt: start, episodeID: episode.id.uuidString.lowercased()))
        }
        guard var episode = snapshot.current else { return [] }
        if episode.alertQueuedAt == nil, start < episode.startedAt {
            episode.startedAt = start
            if let index = snapshot.timelineEvents.firstIndex(where: { $0.id == "cry:\(episode.id.uuidString.lowercased())" }) {
                snapshot.timelineEvents[index].occurredAt = start
            }
        }
        let volumeReady = volumeIsLoud && detector.state == .crying
            && detector.cryStartedAt.map { now.timeIntervalSince($0) >= snapshot.configuration.alertDuration } == true
        let classifierReady = confidenceDetector.canAlert(at: now, configuration: snapshot.configuration)
        // Once sustained quiet reaches reset, the episode above has already ended.
        // Defer a due alert during a quiet gap until sound resumes. If the gap
        // becomes a full reset, a baby that settled before the threshold sends none.
        // The server repeats until acknowledgement or a confirmed quiet reset.
        var alerts: [CryAlert] = []
        if episode.alertQueuedAt == nil && (volumeReady || classifierReady) {
            let alert = CryAlert(episodeId: episode.id, listenerId: listenerId, cryStartedAt: episode.startedAt,
                                 durationSeconds: max(snapshot.configuration.alertDuration, episode.duration(at: now)),
                                 createdAt: now, isRepeat: false)
            episode.alertQueuedAt = now
            episode.lastAlertQueuedAt = now
            lastAlertTrigger = volumeReady ? .volume : .classifier
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
        let last = [snapshot.lastObservedAt, snapshot.lastDetectionAt].compactMap { $0 }.max()
        end(at: last ?? clock.now); detector.reset(); confidenceDetector.reset(); lastVolumeInputAt = nil; snapshot.wasMonitoring = false
    }
    public mutating func recoverAfterRelaunch() { suspend(); snapshot.lastObservedAt = nil; snapshot.lastDetectionAt = nil }
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
