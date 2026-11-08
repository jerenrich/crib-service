import Foundation

/// Independent of microphone volume, with the same 80%-of-time alert policy.
/// Each overlapping result labels only its newly covered audio suffix. Low
/// scores consume the tolerance; discontinuities clear evidence. Episode grace
/// and alert qualification remain separate.
struct CryConfidenceDetector: Sendable {
    static let threshold = 0.6
    static var thresholdDescription: String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), threshold)
    }
    static let windowDuration: TimeInterval = 4
    static let resultStep: TimeInterval = 1
    static let overlapFactor = 1 - resultStep / windowDuration
    static let windowDurationRange = (windowDuration - 0.1)...(windowDuration + 0.1)
    static let maximumWindowStep = resultStep + 0.5
    static let maximumResultAge: TimeInterval = 3
    private(set) var captureID: UUID?
    private(set) var observationStartedAt: Date?
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
    private var lastPositiveCapturedAt: Date?
    /// The latest sustained positive run: its first window's start (reported
    /// onset) and where its own evidence began (checked for 80% coverage).
    private var run: (windowStart: Date, evidenceStart: Date)?
    /// Only explicitly input-stamped, validated results can prove microphone
    /// liveness; legacy sample-clock dates are sufficient only for test replay.
    private(set) var latestInputAt: Date?
    private var confirmed = false
    private var evidence = SoundEvidenceWindow()
    private var latestPositive = false
    private var settled = false

    var state: CryState { confirmed ? .crying : observationStartedAt == nil ? .quiet : .possibleCry }

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
                  Self.windowDurationRange.contains(windowDuration),
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
            // The first result covers its full analysis window; subsequent results
            // contribute only the suffix after the preceding window endpoint.
            // Low results never get overwritten by a later overlapping high one.
            let evidenceStart = max(score.windowStart, evidence.endedAt ?? score.windowStart)
            latestPositive = score.confidence >= Self.threshold
            evidence.append(from: evidenceStart, to: score.windowEnd, positive: latestPositive)
            lastWindowEnd = score.windowEnd; lastObservationAt = score.observedAt; lastCapturedWindowEndAt = capturedEnd
            if latestPositive {
                lastPositiveCapturedAt = capturedEnd
                if observationStartedAt == nil { observationStartedAt = score.windowStart; run = nil }
                // Isolated positives can keep a candidate open without being a cry.
                // Report the onset of the latest sustained run; the alert gate
                // still uses the candidate's start, so qualification is unchanged.
                if !confirmed, run.map({ !evidence.sustains(since: $0.evidenceStart, at: score.windowEnd) }) ?? true {
                    run = (score.windowStart, evidenceStart)
                }
                if evidence.hasRecentActivity(at: score.windowEnd) {
                    retainsEpisode = true; quietSince = nil; settled = false
                } else if quietSince == nil { quietSince = capturedEnd }
                if let start = observationStartedAt,
                   evidence.qualifies(at: score.windowEnd, duration: configuration.alertDuration, onset: start) {
                    if !confirmed {
                        let onset = max(start, run?.windowStart ?? start)
                        cryStartedAt = capturedEnd.addingTimeInterval(-score.windowEnd.timeIntervalSince(onset))
                    }
                    confirmed = true
                }
            } else {
                if quietSince == nil { quietSince = capturedEnd }
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
        if !settled, let quietSince, now.timeIntervalSince(quietSince) >= configuration.quietResetDuration {
            confirmed = false; cryStartedAt = nil; retainsEpisode = false
            // Keep recent negative observations: a lone positive result at the
            // settling boundary must not look like a fresh all-positive capture.
            observationStartedAt = nil; latestPositive = false
            settled = true
        }
        // Once settled, the reset above no longer runs, so an unconfirmed
        // candidate must expire on its own: otherwise a lone positive holds
        // Sound detected through hours of quiet and backdates the next cry.
        if !confirmed, observationStartedAt != nil, let lastPositiveCapturedAt,
           now.timeIntervalSince(lastPositiveCapturedAt) >= configuration.quietResetDuration {
            observationStartedAt = nil
        }
    }

    func canAlert(at now: Date, configuration: MonitoringConfiguration) -> Bool {
        guard confirmed, latestPositive, quietSince == nil, let observationStartedAt, let lastWindowEnd, let lastObservationAt,
              let lastCapturedWindowEndAt,
              (-1...Self.maximumResultAge).contains(now.timeIntervalSince(lastObservationAt)),
              (-1...Self.maximumResultAge).contains(now.timeIntervalSince(lastCapturedWindowEndAt)) else { return false }
        return evidence.qualifies(at: lastWindowEnd, duration: configuration.alertDuration, onset: observationStartedAt)
    }

    private mutating func interrupt(at date: Date) {
        observationStartedAt = nil
        evidence = SoundEvidenceWindow(); latestPositive = false
        if retainsEpisode, quietSince == nil { quietSince = date }
    }

    mutating func reset() { self = Self() }

}
