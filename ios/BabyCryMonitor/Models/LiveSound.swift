import Foundation

/// The same 32 quarter-second RMS readings displayed by the nursery chart.
/// This transient frame is never included in persisted history or alert payloads.
public struct SoundLevelFrame: Codable, Equatable, Sendable {
    public static let barCount = 32
    public var type = "levels"
    public var sampledAt: TimeInterval
    public var levels: [Double]
    public var threshold: Double
    public var state: CryState
    public var episodeStartedAt: TimeInterval?
    public var alertDuration: TimeInterval
    public var requestID: String?

    public var isValid: Bool {
        type == "levels" && sampledAt.isFinite && (0...32_503_680_000).contains(sampledAt) && levels.count == Self.barCount
        && levels.allSatisfy { $0.isFinite && (-100...0).contains($0) }
        && threshold.isFinite && (-60 ... -10).contains(threshold)
        && alertDuration.isFinite && (5...3600).contains(alertDuration)
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
