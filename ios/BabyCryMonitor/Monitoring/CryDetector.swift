import Foundation

public protocol CryDetecting {
    mutating func consume(_ sample: AudioLevelSample, configuration: MonitoringConfiguration) -> CryState
}
/// Energy heuristic, not a classifier. Keeps only a five-second ring of booleans locally.
public struct CryDetector: CryDetecting, Sendable {
    public private(set) var state: CryState = .quiet
    public private(set) var ambientDBFS: Double = -60
    public private(set) var effectiveThreshold: Double = -35
    public private(set) var quietSince: Date?
    private var frames: [(Date, Bool)] = []
    private var firstFrame: Date?
    private var activeSince: Date?
    private var lastTimestamp: Date?
    public init() {}

    public mutating func consume(_ sample: AudioLevelSample, configuration: MonitoringConfiguration) -> CryState {
        guard sample.dbFS.isFinite else { return state }
        if let lastTimestamp, sample.timestamp <= lastTimestamp { return state }
        let dt = min(1, max(0.01, sample.timestamp.timeIntervalSince(lastTimestamp ?? sample.timestamp.addingTimeInterval(-0.25))))
        lastTimestamp = sample.timestamp
        if firstFrame == nil { firstFrame = sample.timestamp }
        effectiveThreshold = max(configuration.absoluteThreshold, ambientDBFS + configuration.sensitivity.margin)
        let loud = sample.dbFS >= effectiveThreshold
        // Freeze the baseline during loud frames, possible cries, and confirmed episodes.
        if state == .quiet && !loud {
            ambientDBFS += (1 - exp(-dt / 30)) * (max(-100, sample.dbFS) - ambientDBFS)
        }
        frames.append((sample.timestamp, loud))
        frames.removeAll { sample.timestamp.timeIntervalSince($0.0) >= 5 }
        let proportion = Double(frames.filter { $0.1 }.count) / Double(max(1, frames.count))
        if loud {
            quietSince = nil
            if activeSince == nil { activeSince = sample.timestamp }
        } else {
            if quietSince == nil { quietSince = sample.timestamp }
            // Short gaps can qualify a window, but cannot turn isolated noise into an episode.
            if let quietSince, sample.timestamp.timeIntervalSince(quietSince) >= 1 { activeSince = nil }
        }
        switch state {
        case .quiet:
            if let activeSince, sample.timestamp.timeIntervalSince(activeSince) >= 2 { state = .possibleCry }
        case .possibleCry:
            if let firstFrame, sample.timestamp.timeIntervalSince(firstFrame) >= 4.75, proportion >= 0.6, loud {
                state = .crying
            } else if let quietSince, sample.timestamp.timeIntervalSince(quietSince) >= 1 { state = .quiet }
        case .crying:
            if let quietSince, sample.timestamp.timeIntervalSince(quietSince) >= configuration.quietResetDuration {
                state = .quiet
                frames.removeAll(); activeSince = nil; firstFrame = sample.timestamp
            }
        }
        return state
    }
    public mutating func reset() { self = CryDetector() }
}
