import Foundation

public enum NurserySound: String, Codable, CaseIterable, Sendable {
    case whiteNoise, twinkleTwinkle
    public var title: String { self == .whiteNoise ? "White noise" : "Twinkle Twinkle" }
    public var symbol: String { self == .whiteNoise ? "waveform" : "sparkles" }

    /// Generate the locally synthesized white-noise loop.
    public func samples(sampleRate: Double = 22_050) -> [Float] {
        guard self == .whiteNoise, sampleRate.isFinite, (8_000...48_000).contains(sampleRate) else { return [] }
        var random: UInt64 = 0xC81B5EED
        return (0..<Int(sampleRate * 4)).map { _ in
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return (Float(random >> 40) / Float(0xFFFFFF) * 2 - 1) * 0.18
        }
    }
}

public struct NurserySoundSettings: Codable, Equatable, Sendable {
    public static let timerOptions = [5, 10, 20, 30, 60]
    public var sound: NurserySound = .whiteNoise
    public var volume: Double = 0.3
    public var timerMinutes: Int = 20
    public init(sound: NurserySound = .whiteNoise, volume: Double = 0.3, timerMinutes: Int = 20) {
        self.sound = sound; self.volume = volume; self.timerMinutes = timerMinutes
    }
    public var isValid: Bool { volume.isFinite && (0...1).contains(volume) && Self.timerOptions.contains(timerMinutes) }
}

public struct NurserySoundState: Codable, Equatable, Sendable {
    public var settings = NurserySoundSettings()
    public var playing = false
    /// Duration rather than a wall-clock deadline: the phones need not agree on time.
    public var remainingSeconds: Double = 0
    public init(settings: NurserySoundSettings = .init(), playing: Bool = false, remainingSeconds: Double = 0) {
        self.settings = settings; self.playing = playing; self.remainingSeconds = remainingSeconds
    }
    public var isValid: Bool {
        settings.isValid && remainingSeconds.isFinite && (0...Double(settings.timerMinutes * 60)).contains(remainingSeconds)
        && (playing ? remainingSeconds > 0 : remainingSeconds == 0)
    }
}

public struct NurserySoundRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case play, stop, updateSettings }
    public var settings: NurserySoundSettings
    public var action: Action
    /// Changing sound or volume preserves the current deadline; choosing a timer restarts it.
    public var restartTimer: Bool
    public init(settings: NurserySoundSettings, action: Action, restartTimer: Bool = false) {
        self.settings = settings; self.action = action; self.restartTimer = restartTimer
    }
}

/// A monotonic deadline is owned by the Listener, including while locked or offline.
struct NurserySoundPlayback {
    private(set) var state = NurserySoundState()
    private var deadline: ContinuousClock.Instant?
    mutating func apply(_ request: NurserySoundRequest, at now: ContinuousClock.Instant) {
        guard request.settings.isValid else { return }
        // Expire before applying an edit: an in-flight settings update is never Play.
        update(at: now)
        let reset = request.action == .play || (state.playing &&
            (request.restartTimer || state.settings.timerMinutes != request.settings.timerMinutes))
        state.settings = request.settings
        if request.action == .stop { stop(); return }
        if request.action == .play { state.playing = true }
        if reset { deadline = now.advanced(by: .seconds(request.settings.timerMinutes * 60)) }
        update(at: now)
    }
    func expired(at now: ContinuousClock.Instant) -> Bool { state.playing && deadline.map { now >= $0 } == true }
    mutating func update(at now: ContinuousClock.Instant) {
        guard state.playing, let deadline else { return }
        if now >= deadline { stop(); return }
        let duration = now.duration(to: deadline).components
        state.remainingSeconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
    mutating func stop() { state.playing = false; state.remainingSeconds = 0; deadline = nil }
}

struct NurserySoundCommand: Codable, Equatable, Sendable {
    var type = "nurserySoundCommand"
    var id: UUID
    var controlToken: UUID
    var request: NurserySoundRequest
}

struct NurserySoundUpdate: Codable, Equatable, Sendable {
    var type = "nurserySoundState"
    var state: NurserySoundState
    var requestID: String?
    var requestIDs: [String]?
    var controlToken: UUID
    var commandID: UUID?
    var failure: String?
    var isValid: Bool {
        type == "nurserySoundState" && state.isValid
        && (requestID.map { UUID(uuidString: $0) != nil } ?? true)
        && (requestIDs?.count ?? 0) <= 16
        && (requestIDs ?? []).allSatisfy { UUID(uuidString: $0) != nil }
        && (failure.map { ["playbackFailed", "expired", "unavailable"].contains($0) } ?? true)
    }
}

struct RemoteNurserySound: Sendable {
    private(set) var update: NurserySoundUpdate?
    private(set) var receivedAt: Date?
    mutating func receive(_ value: NurserySoundUpdate, at now: Date) {
        guard value.isValid else { return }
        update = value; receivedAt = now
    }
    mutating func disconnect() { receivedAt = nil }
    func isLive(at now: Date) -> Bool {
        receivedAt.map { (0..<3).contains(now.timeIntervalSince($0)) } ?? false
    }
    func state(at now: Date) -> NurserySoundState? {
        guard let update else { return nil }
        var state = update.state
        // Expiry on the Parent is presentation only, never a playback confirmation.
        if state.playing, isLive(at: now), let receivedAt {
            state.remainingSeconds = max(0, state.remainingSeconds - now.timeIntervalSince(receivedAt))
        }
        return state
    }
}

/// Listener-issued capabilities bound commands to a recent end-to-end exchange.
/// Buffered commands cannot unexpectedly start sound after a reconnect or a local action.
struct NurserySoundControlTokens {
    private var issued: [UUID: Date] = [:]
    mutating func issue(at now: Date) -> UUID {
        issued = issued.filter { (0..<5).contains(now.timeIntervalSince($0.value)) }
        let token = UUID(); issued[token] = now; return token
    }
    func accepts(_ token: UUID, at now: Date) -> Bool {
        issued[token].map { (0..<5).contains(now.timeIntervalSince($0)) } ?? false
    }
}
