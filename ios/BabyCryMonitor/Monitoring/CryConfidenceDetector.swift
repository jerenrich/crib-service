import Foundation

/// Independent of microphone volume. Consecutive overlapping high-confidence
/// audio windows must cover the configured alert duration; missing results do
/// not count as more crying. An already confirmed episode has the normal quiet
/// grace period, allowing both detectors to share one episode and one outbox.
struct CryConfidenceDetector: Sendable {
    static let threshold = 0.8
    static let windowDuration: TimeInterval = 2
    static let maximumWindowStep: TimeInterval = 1.5
    static let maximumResultAge: TimeInterval = 3
    private(set) var captureID: UUID?
    private(set) var streakStartedAt: Date?
    private(set) var cryStartedAt: Date?
    private(set) var quietSince: Date?
    // Positive classifier evidence can keep an existing volume episode open
    // while its own (possibly longer) alert timer is still qualifying.
    private(set) var retainsEpisode = false
    private var captureStartedAt = Date.distantPast
    private var minimumCapturedWindowStart = Date.distantPast
    private var lastWindowEnd: Date?
    private var lastObservationAt: Date?
    private var lastCapturedWindowEndAt: Date?
    /// Only explicitly input-stamped, validated results can prove microphone
    /// liveness; legacy sample-clock dates are sufficient only for test replay.
    private(set) var latestInputAt: Date?
    private var confirmed = false

    var state: CryState { confirmed ? .crying : streakStartedAt == nil ? .quiet : .possibleCry }

    mutating func consume(_ event: SoundClassificationEvent, at now: Date, configuration: MonitoringConfiguration) {
        advance(to: now, configuration: configuration)
        switch event {
        case let .started(id, at, _, _, _):
            guard at.timeIntervalSinceReferenceDate.isFinite, at <= now.addingTimeInterval(1),
                  at >= captureStartedAt, id != captureID else { return }
            interrupt(at: at)
            captureID = id; captureStartedAt = at; minimumCapturedWindowStart = .distantPast
            lastWindowEnd = nil; lastObservationAt = nil; lastCapturedWindowEndAt = nil
            latestInputAt = nil
        case .result(let score):
            guard score.captureID == captureID,
                  score.windowStart.timeIntervalSinceReferenceDate.isFinite,
                  score.windowEnd.timeIntervalSinceReferenceDate.isFinite,
                  score.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  lastWindowEnd.map({ score.windowEnd > $0 }) ?? true else { return }
            let windowDuration = score.windowEnd.timeIntervalSince(score.windowStart)
            let capturedEnd = score.audioWindowEndAt ?? score.windowEnd
            // The audio timestamp comes from input-buffer arrival, independently
            // of inference completion. Bound total age, including both inference
            // and callback handling; never recalibrate old audio to a late reply.
            guard score.confidence.isFinite, (0...1).contains(score.confidence),
                  (1.9...2.1).contains(windowDuration),
                  score.windowStart >= captureStartedAt,
                  capturedEnd.timeIntervalSinceReferenceDate.isFinite,
                  (-1...Self.maximumResultAge).contains(now.timeIntervalSince(score.observedAt)),
                  (-1...Self.maximumResultAge).contains(now.timeIntervalSince(capturedEnd)) else {
                interrupt(at: now); return
            }
            if score.audioWindowEndAt != nil {
                latestInputAt = max(latestInputAt ?? capturedEnd, capturedEnd)
            }
            // Gaps are stamped in wall time. Window dates are in the model's
            // sample clock, so compare their mapped input onset to that cutoff.
            guard capturedEnd.addingTimeInterval(-windowDuration) >= minimumCapturedWindowStart else {
                interrupt(at: now); return
            }
            if let previous = lastWindowEnd,
               score.windowEnd.timeIntervalSince(previous) > Self.maximumWindowStep
                || lastObservationAt.map({ score.observedAt.timeIntervalSince($0) > Self.maximumResultAge }) == true {
                interrupt(at: lastCapturedWindowEndAt ?? now)
            }
            lastWindowEnd = score.windowEnd; lastObservationAt = score.observedAt; lastCapturedWindowEndAt = capturedEnd
            if score.confidence >= Self.threshold {
                retainsEpisode = true; quietSince = nil
                if streakStartedAt == nil { streakStartedAt = score.windowStart }
                if let start = streakStartedAt, score.windowEnd.timeIntervalSince(start) >= configuration.alertDuration {
                    if !confirmed { cryStartedAt = capturedEnd.addingTimeInterval(-score.windowEnd.timeIntervalSince(start)) }
                    confirmed = true
                }
            } else {
                interrupt(at: capturedEnd)
            }
        case let .stopped(id, at):
            guard id == captureID else { return }
            interrupt(at: min(at, now)); captureID = nil
        case let .unavailable(at, failure, id, _, _):
            let failedCapture = id ?? failure?.captureID
            guard failedCapture == nil || failedCapture == captureID else { return }
            interrupt(at: min(at, now)); captureID = nil
        case let .droppedEvents(at), let .droppedBuffers(_, at):
            interrupt(at: min(at, now))
            minimumCapturedWindowStart = max(minimumCapturedWindowStart, min(at, now))
        case let .unmappedResult(id, windowEnd, at):
            // A late or retired result is not a new hole in current audio.
            guard id == captureID, windowEnd.timeIntervalSinceReferenceDate.isFinite,
                  lastWindowEnd.map({ windowEnd > $0 }) ?? true else { return }
            interrupt(at: min(at, now))
            minimumCapturedWindowStart = max(minimumCapturedWindowStart, min(at, now))
        }
        advance(to: now, configuration: configuration)
    }

    mutating func advance(to now: Date, configuration: MonitoringConfiguration) {
        if let lastCapturedWindowEndAt, now.timeIntervalSince(lastCapturedWindowEndAt) > Self.maximumResultAge {
            interrupt(at: lastCapturedWindowEndAt)
        }
        if retainsEpisode, let quietSince, now.timeIntervalSince(quietSince) >= configuration.quietResetDuration {
            confirmed = false; cryStartedAt = nil; retainsEpisode = false
        }
    }

    func canAlert(at now: Date, configuration: MonitoringConfiguration) -> Bool {
        guard confirmed, quietSince == nil, let streakStartedAt, let lastWindowEnd, let lastObservationAt,
              let lastCapturedWindowEndAt,
              (-1...Self.maximumResultAge).contains(now.timeIntervalSince(lastObservationAt)),
              (-1...Self.maximumResultAge).contains(now.timeIntervalSince(lastCapturedWindowEndAt)) else { return false }
        return lastWindowEnd.timeIntervalSince(streakStartedAt) >= configuration.alertDuration
    }

    private mutating func interrupt(at date: Date) {
        streakStartedAt = nil
        if retainsEpisode, quietSince == nil { quietSince = date }
    }

    mutating func reset() { self = Self() }

}
