import Foundation

/// Shared alert policy for independent detectors. Intervals are disjoint audio
/// observations, not callback counts; holes contribute no positive time. Keep
/// at most the longest supported wait, coalescing adjacent equivalent evidence.
struct SoundEvidenceWindow: Sendable {
    static let requiredFraction = 0.8
    static let recentDuration: TimeInterval = 5
    private struct Interval: Sendable { var start: Date; var end: Date; let positive: Bool }
    private var intervals: [Interval] = []
    private var head = 0
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    mutating func append(from start: Date, to end: Date, positive: Bool) {
        let start = max(start, endedAt ?? start)
        guard end > start else { return }
        if startedAt == nil { startedAt = start }
        if let last = intervals.last, last.end == start, last.positive == positive {
            intervals[intervals.count - 1].end = end
        } else { intervals.append(Interval(start: start, end: end, positive: positive)) }
        endedAt = end
        let cutoff = end.addingTimeInterval(-3600)
        while head < intervals.count, intervals[head].end <= cutoff { head += 1 }
        if head > 1024 {
            intervals.removeFirst(head); head = 0
        }
        if head < intervals.count { intervals[head].start = max(intervals[head].start, cutoff) }
    }

    func qualifies(at end: Date, duration: TimeInterval, onset: Date) -> Bool {
        guard let startedAt, endedAt == end,
              end.timeIntervalSince(max(startedAt, onset)) >= duration else { return false }
        return positiveDuration(from: end.addingTimeInterval(-duration), to: end) + 1e-9
            >= duration * Self.requiredFraction && hasRecentActivity(at: end)
    }

    /// Also used to renew episode activity. One isolated positive reading cannot
    /// keep resetting the settling grace period after a sustained burst ends.
    func hasRecentActivity(at end: Date) -> Bool {
        guard let startedAt, endedAt == end else { return false }
        let duration = min(Self.recentDuration, end.timeIntervalSince(startedAt))
        guard duration > 0 else { return false }
        return positiveDuration(from: end.addingTimeInterval(-duration), to: end) + 1e-9
            >= duration * Self.requiredFraction
    }

    private func positiveDuration(from start: Date, to end: Date) -> TimeInterval {
        var duration: TimeInterval = 0
        for interval in intervals[head...] where interval.positive && interval.end > start {
            duration += max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
        }
        return duration
    }
}

public protocol CryDetecting {
    mutating func consume(_ sample: AudioLevelSample, configuration: MonitoringConfiguration) -> CryState
}
/// Energy heuristic with a five-second onset check and bounded time evidence.
public struct CryDetector: CryDetecting, Sendable {
    public private(set) var state: CryState = .quiet
    public private(set) var quietSince: Date?
    /// First loud sample in the activity that passed confirmation. Confirmation
    /// validates this start; it must not add another delay to the alert timer.
    public private(set) var cryStartedAt: Date?
    private var frames: [(Date, Bool)] = []
    private var firstFrame: Date?
    private var activeSince: Date?
    private var lastTimestamp: Date?
    private var evidence = SoundEvidenceWindow()
    private var evidenceThreshold: Double?
    private var lastWindow: AudioLevelSample.Window?
    private var lastEvidenceTime: Date?
    private var quietEvidenceSince: Date?
    private var cryEvidenceSince: Date?
    private(set) var inputInterrupted = false
    public init() {}

    func accepts(_ sample: AudioLevelSample) -> Bool {
        guard sample.isValid, lastTimestamp.map({ sample.timestamp > $0 }) ?? true else { return false }
        if let window = sample.window, let lastWindow, window.captureID == lastWindow.captureID,
           window.sampleRate == lastWindow.sampleRate, window.endFrame <= lastWindow.endFrame { return false }
        return true
    }

    public mutating func consume(_ sample: AudioLevelSample, configuration: MonitoringConfiguration) -> CryState {
        guard accepts(sample) else { return state }
        inputInterrupted = false
        if lastTimestamp != nil {
            let continuous: Bool
            switch (lastWindow, sample.window) {
            case let (previous?, next?):
                continuous = previous.captureID == next.captureID && previous.sampleRate == next.sampleRate
                    && previous.endFrame == next.startFrame
            case (nil, nil): continuous = true
            default: continuous = false
            }
            if !continuous { self = CryDetector(); inputInterrupted = true }
        }
        let time = sample.window?.end ?? sample.timestamp
        if evidenceThreshold != configuration.absoluteThreshold {
            evidence = SoundEvidenceWindow(); evidenceThreshold = configuration.absoluteThreshold
        }
        if let window = sample.window {
            evidence.append(from: window.start, to: window.end,
                            positive: sample.dbFS >= configuration.absoluteThreshold)
        } else if let lastTimestamp {
            // Conservative compatibility for old exports and synthetic clients
            // without capture metadata. Native capture always supplies frames.
            evidence.append(from: max(lastTimestamp, sample.timestamp.addingTimeInterval(-0.25)),
                            to: sample.timestamp, positive: sample.dbFS >= configuration.absoluteThreshold)
        }
        lastTimestamp = sample.timestamp
        lastWindow = sample.window; lastEvidenceTime = time
        if firstFrame == nil { firstFrame = time }
        let loud = sample.dbFS >= configuration.absoluteThreshold
        frames.append((time, loud))
        frames.removeAll { time.timeIntervalSince($0.0) >= 5 }
        let proportion = Double(frames.filter { $0.1 }.count) / Double(max(1, frames.count))
        let renewsActivity = loud && (state != .crying || evidence.hasRecentActivity(at: time))
        if renewsActivity {
            quietSince = nil; quietEvidenceSince = nil
            if activeSince == nil { activeSince = time }
        } else {
            if quietEvidenceSince == nil { quietEvidenceSince = time; quietSince = sample.timestamp }
            // Short gaps can qualify a window, but cannot turn isolated noise into an episode.
            if let quietEvidenceSince, time.timeIntervalSince(quietEvidenceSince) >= 1 { activeSince = nil }
        }
        switch state {
        case .quiet:
            if let activeSince, time.timeIntervalSince(activeSince) >= 2 { state = .possibleCry }
        case .possibleCry:
            if let firstFrame, time.timeIntervalSince(firstFrame) >= 4.75, proportion >= 0.6, loud {
                cryEvidenceSince = activeSince ?? time
                // Only episode dates use the wall clock. Qualification itself
                // stays in the PCM clock, even during callback jitter/drift.
                cryStartedAt = sample.timestamp.addingTimeInterval(-time.timeIntervalSince(cryEvidenceSince!))
                state = .crying
            } else if let quietEvidenceSince, time.timeIntervalSince(quietEvidenceSince) >= 1 { state = .quiet }
        case .crying:
            if let quietEvidenceSince, time.timeIntervalSince(quietEvidenceSince) >= configuration.quietResetDuration {
                state = .quiet
                cryStartedAt = nil
                cryEvidenceSince = nil
                frames.removeAll(); activeSince = nil; firstFrame = time
                evidence = SoundEvidenceWindow()
            }
        }
        return state
    }
    func canAlert(at now: Date, configuration: MonitoringConfiguration) -> Bool {
        guard state == .crying, quietSince == nil, let cryEvidenceSince, let lastEvidenceTime,
              let lastTimestamp, (-1...2).contains(now.timeIntervalSince(lastTimestamp)) else { return false }
        return evidence.qualifies(at: lastEvidenceTime, duration: configuration.alertDuration, onset: cryEvidenceSince)
    }
    public mutating func reset() { self = CryDetector() }
}
