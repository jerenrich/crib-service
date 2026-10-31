import AVFoundation
import Foundation

enum AudioCaptureStatus {
    case stopped
    case active
    case recovering(String)
    case failed(String)
}

struct NurseryAudioFailure: Error {
    enum Stage: String, Sendable { case session, voiceProcessing = "voice_processing", input, synthesis, player, engine }
    let stage: Stage
    let underlying: any Error
}

/// Actor boundary is injectable so operation ordering and capture restoration can
/// be tested without a microphone or an audio route belonging to the test host.
protocol AudioCaptureDriving: Sendable {
    var isRunning: Bool { get async }
    var engineID: ObjectIdentifier { get async }
    func activate(generation: Int, clearSound: Bool) async throws
    func recoverConfiguration(generation: Int) async throws
    func setSound(_ state: NurserySoundState, capture: Bool, generation: Int) async throws
    func pause(generation: Int) async
    func stop(generation: Int) async
}

@MainActor protocol AudioLevelProviding: AnyObject {
    var levels: AsyncStream<AudioLevelSample> { get }
    var onStatus: ((AudioCaptureStatus) -> Void)? { get set }
    var onNurserySoundChange: ((NurserySoundState) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() async throws
    func stop()
    func setNurserySound(_ request: NurserySoundRequest, commandID: UUID?) async throws
}
extension AudioLevelProviding {
    func setNurserySound(_ request: NurserySoundRequest) async throws { try await setNurserySound(request, commandID: nil) }
}
/// Only the RMS scalar leaves the real-time callback. Buffers are never retained.
@MainActor final class AudioLevelMonitor: AudioLevelProviding {
    let levels: AsyncStream<AudioLevelSample>
    private let driver: any AudioCaptureDriving
    private let currentTime: () -> ContinuousClock.Instant
    private var observers: [NSObjectProtocol] = []
    private var wantsMonitoring = false
    private var generation = 0
    private var configuringGeneration: Int?
    private var configurationRecoveryAttempts = 0
    private var interrupted = false
    var onStatus: ((AudioCaptureStatus) -> Void)?
    var onNurserySoundChange: ((NurserySoundState) -> Void)?
    private var playback = NurserySoundPlayback()
    private var nurseryState: NurserySoundState { playback.state }
    private var soundTask: Task<Void, Never>?
    private var playbackID: UUID?
    private var playbackCommandID: UUID?
    private struct PlaybackLogContext {
        var state: NurserySoundState
        let playbackID: UUID?
        let commandID: UUID?
    }
    weak var log: DiagnosticLog?

    init(driver: (any AudioCaptureDriving)? = nil, currentTime: @escaping () -> ContinuousClock.Instant = { .now }) {
        let pair = AsyncStream<AudioLevelSample>.makeStream(bufferingPolicy: .bufferingNewest(16))
        levels = pair.stream; self.driver = driver ?? AudioCaptureDriver(continuation: pair.continuation)
        self.currentTime = currentTime
        observe(AVAudioSession.interruptionNotification)
        observe(AVAudioSession.routeChangeNotification)
        observe(AVAudioSession.mediaServicesWereResetNotification)
        observe(.AVAudioEngineConfigurationChange)
    }
    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func start() async throws {
        try Task.checkCancellation()
        guard !interrupted else { throw AudioError.unavailable }
        configurationRecoveryAttempts = 0
        wantsMonitoring = true; generation += 1
        let expected = generation
        configuringGeneration = expected
        defer { if configuringGeneration == expected { configuringGeneration = nil } }
        do {
            try await driver.activate(generation: expected, clearSound: false)
            guard generation == expected, wantsMonitoring else { throw CancellationError() }
            try Task.checkCancellation()
            if playback.expired(at: currentTime()) {
                let stopped = finishSound(reason: "timer_expired")
                try await driver.setSound(nurseryState, capture: true, generation: expected)
                guard generation == expected, wantsMonitoring else { throw CancellationError() }
                logStop(stopped, phase: "stopped", reason: "timer_expired")
            }
            armSoundTimer(generation: expected)
            logSound(phase: "audio_applied")
            onStatus?(.active)
        } catch {
            if generation == expected {
                logSound(phase: "audio_failed", reason: "start_failed", error: error)
                wantsMonitoring = false; let stopped = finishSound(reason: "start_failed")
                await driver.stop(generation: expected)
                if generation == expected { logStop(stopped, phase: "stopped", reason: "start_failed") }
            }
            // A newer start (e.g. route-change recovery) replaced this one; not a failure.
            if error is CancellationError { log?.record("monitoring_start_superseded") }
            else { log?.record("monitoring_start_failed", error: error) }
            throw error
        }
    }
    func stop() {
        wantsMonitoring = false; generation += 1
        let expected = generation
        let stopped = finishSound(reason: "microphone_stop")
        Task {
            await driver.stop(generation: expected)
            if generation == expected { logStop(stopped, phase: "stopped", reason: "microphone_stop") }
        }
        onStatus?(.stopped)
    }
    func setNurserySound(_ request: NurserySoundRequest, commandID: UUID? = nil) async throws {
        try await applyNurserySound(request, commandID: commandID, stopReason: "user_stop")
    }
    private func applyNurserySound(_ request: NurserySoundRequest, commandID: UUID?, stopReason: String) async throws {
        try Task.checkCancellation()
        guard request.settings.isValid, !interrupted || request.action == .stop else { throw AudioError.unavailable }
        if request.action == .play { configurationRecoveryAttempts = 0 }
        generation += 1; let expected = generation
        configuringGeneration = expected
        defer { if configuringGeneration == expected { configuringGeneration = nil } }
        var next = playback
        next.apply(request, at: currentTime())
        let started = ContinuousClock.now
        let previous = PlaybackLogContext(state: nurseryState, playbackID: playbackID, commandID: commandID ?? playbackCommandID)
        let newPlayback = next.state.playing && (request.action == .play || !nurseryState.playing)
        let nextPlaybackID = newPlayback ? UUID() : playbackID
        logSound(phase: "audio_applying", request: request, commandID: commandID, state: next.state, playbackID: nextPlaybackID)
        var reconfiguringCapture = wantsMonitoring && next.state.playing != nurseryState.playing
        if reconfiguringCapture { onStatus?(.recovering("Updating nursery speaker and microphone…")) }
        do {
            guard expected == generation else { throw CancellationError() }
            if interrupted { await driver.pause(generation: expected) }
            else { try await driver.setSound(next.state, capture: wantsMonitoring, generation: expected) }
            guard expected == generation else { throw CancellationError() }
            try Task.checkCancellation()
            // A settings edit may expire while synthesis or graph setup is in flight.
            if next.expired(at: currentTime()) {
                if wantsMonitoring, !reconfiguringCapture {
                    reconfiguringCapture = true
                    onStatus?(.recovering("Restoring microphone after nursery sound…"))
                    guard expected == generation else { throw CancellationError() }
                }
                next.update(at: currentTime())
                try await driver.setSound(next.state, capture: wantsMonitoring, generation: expected)
                guard expected == generation else { throw CancellationError() }
            }
            playback = next; armSoundTimer(generation: expected)
            if reconfiguringCapture, wantsMonitoring { onStatus?(.active) }
            guard expected == generation else { throw CancellationError() }
            if newPlayback, next.state.playing {
                if previous.state.playing { logStop(previous, phase: "stopped", reason: "replaced") }
                playbackID = nextPlaybackID; playbackCommandID = commandID
                logSound(phase: "started", request: request, commandID: commandID)
            }
            logSound(phase: "audio_applied", request: request, commandID: commandID, elapsedMS: DiagnosticTiming.elapsedMS(since: started))
            if previous.state.playing, !next.state.playing {
                let reason = request.action == .stop ? stopReason : "timer_expired"
                logStop(previous, phase: "stopped", reason: reason)
                playbackID = nil; playbackCommandID = nil
            }
            if reconfiguringCapture, wantsMonitoring, !next.state.playing {
                logSound(phase: "capture_restored", commandID: commandID, elapsedMS: DiagnosticTiming.elapsedMS(since: started))
            }
            publishSound()
        } catch {
            guard expected == generation else { throw error }
            logSound(phase: "audio_failed", request: request, commandID: commandID, playbackID: nextPlaybackID,
                     reason: error is CancellationError ? "superseded" : "playback_failed", elapsedMS: DiagnosticTiming.elapsedMS(since: started), error: error)
            let stopped = finishSound(reason: "playback_failed")
            do {
                // Cleanup also runs for a cancelled request. A newer operation
                // supersedes this restoration at both sides of the actor boundary.
                try await driver.setSound(nurseryState, capture: wantsMonitoring, generation: expected)
                if expected == generation {
                    logStop(stopped, phase: "stopped", reason: "playback_failed")
                    if wantsMonitoring { logSound(phase: "capture_restored", commandID: commandID); onStatus?(.active) }
                }
            } catch {
                if expected == generation, wantsMonitoring {
                    logSound(phase: "capture_restore_failed", commandID: commandID, error: error)
                    wantsMonitoring = false
                    onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring."))
                }
            }
            throw error
        }
    }
    private func armSoundTimer(generation expected: Int) {
        soundTask?.cancel(); soundTask = nil
        guard nurseryState.playing else { return }
        soundTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(0.25)) } catch { return }
                guard let self, self.generation == expected else { return }
                let now = self.currentTime()
                if self.playback.expired(at: now) {
                    try? await self.applyNurserySound(.init(settings: self.nurseryState.settings, action: .stop), commandID: nil, stopReason: "timer_expired")
                    return
                }
                self.playback.update(at: now); self.publishSound()
            }
        }
    }
    private func publishSound() {
        onNurserySoundChange?(nurseryState)
    }
    @discardableResult private func finishSound(reason: String) -> PlaybackLogContext? {
        let context = nurseryState.playing ? PlaybackLogContext(state: nurseryState, playbackID: playbackID, commandID: playbackCommandID) : nil
        logStop(context, phase: "stop_requested", reason: reason)
        soundTask?.cancel(); soundTask = nil
        playback.stop()
        playbackID = nil; playbackCommandID = nil
        onNurserySoundChange?(nurseryState)
        return context
    }
    private func logSound(phase: String, request: NurserySoundRequest? = nil, commandID: UUID? = nil,
                          state: NurserySoundState? = nil, playbackID: UUID? = nil, reason: String? = nil,
                          elapsedMS: Int? = nil, error: (any Error)? = nil) {
        let state = state ?? nurseryState
        let mode = wantsMonitoring ? (state.playing ? "voiceChat" : "measurement") : (state.playing ? "playback" : "inactive")
        log?.nurserySound(phase: phase, role: "listener", commandID: commandID ?? playbackCommandID,
            playbackID: playbackID ?? self.playbackID, action: request?.action.rawValue, sound: state.settings.sound.rawValue,
            timerMinutes: state.settings.timerMinutes, volume: state.settings.volume, playing: state.playing,
            remainingSeconds: state.remainingSeconds, reason: reason, elapsedMS: elapsedMS, captureMode: mode, error: error)
    }
    private func logStop(_ context: PlaybackLogContext?, phase: String, reason: String) {
        guard var context else { return }
        if phase == "stopped" { context.state.playing = false; context.state.remainingSeconds = 0 }
        logSound(phase: phase, commandID: context.commandID, state: context.state, playbackID: context.playbackID, reason: reason)
    }
    private func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                ?? notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let engineID = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in await self?.handle(name: name, type: type, options: options, reason: reason, engineID: engineID) }
        })
    }
    private func handle(name: Notification.Name, type: UInt?, options: UInt, reason: UInt?, engineID: ObjectIdentifier?) async {
        // Notifications can arrive while a rebuild is still awaiting its actor.
        // Let that operation publish its state before deciding what to recover.
        let notificationGeneration = generation
        let isConfigurationChange = name == .AVAudioEngineConfigurationChange ||
            (name == AVAudioSession.routeChangeNotification &&
             (reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue ||
              reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue))
        while isConfigurationChange && configuringGeneration == notificationGeneration {
            try? await Task.sleep(for: .milliseconds(20))
            guard generation == notificationGeneration else { return }
        }
        // Graph/category notifications from our own successful configuration are
        // not an external route change and must not stop a newly started sound.
        // Only configuration notifications consult the actor before reserving
        // a generation. A real interruption/route removal must supersede pending
        // work synchronously, rather than being discarded after an actor await.
        if isConfigurationChange {
            guard !interrupted else { return }
            let observedGeneration = generation
            if name == .AVAudioEngineConfigurationChange, let engineID {
                let currentEngineID = await driver.engineID
                guard observedGeneration == generation, engineID == currentEngineID else { return }
            }
            let running = await driver.isRunning
            guard observedGeneration == generation else { return }
            if running { return }
        } else if name == AVAudioSession.routeChangeNotification,
                  reason == AVAudioSession.RouteChangeReason.override.rawValue {
            // The speaker override does not represent a disconnected device.
            return
        }
        // Changing between measurement and voice processing can itself cause a
        // category or route-configuration notification and stop the engine. In
        // that case restore the existing graph, including sound, rather than
        // treating our own transition as a disconnected audio device.
        if isConfigurationChange {
            guard wantsMonitoring || nurseryState.playing else { return }
            generation += 1; let expected = generation
            configuringGeneration = expected
            defer { if configuringGeneration == expected { configuringGeneration = nil } }
            log?.record(name == .AVAudioEngineConfigurationChange ? "audio_engine_changed" : "audio_route_changed",
                        code: reason.map { Int($0) })
            if configurationRecoveryAttempts >= 2 {
                let stopped = finishSound(reason: "engine_configuration_changed")
                log?.record("audio_recovery_limit", code: configurationRecoveryAttempts)
                // Do not enter another graph rebuild from the failure path.
                // Stop visibly if the existing graph cannot remain running.
                await driver.stop(generation: expected)
                guard generation == expected else { return }
                logStop(stopped, phase: "stopped", reason: "engine_configuration_changed")
                if wantsMonitoring {
                    wantsMonitoring = false
                    onStatus?(.failed("Audio recovery failed. Open the app to restart monitoring."))
                }
                return
            }
            configurationRecoveryAttempts += 1
            if wantsMonitoring { onStatus?(.recovering("Recovering speaker and microphone…")) }
            do {
                try await driver.recoverConfiguration(generation: expected)
                guard generation == expected else { return }
                armSoundTimer(generation: expected)
                if wantsMonitoring { onStatus?(.active) }
            } catch {
                guard generation == expected else { return }
                log?.record("audio_interrupted", error: error)
                let stopped = finishSound(reason: "route_change")
                await driver.stop(generation: expected)
                guard generation == expected else { return }
                logStop(stopped, phase: "stopped", reason: "route_change")
                if wantsMonitoring { wantsMonitoring = false; onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring.")) }
            }
            return
        }
        // Never resume a lullaby automatically after a call or route change.
        // Its timer cannot be extended by an interruption or a device reconnect.
        let stopReason = name == AVAudioSession.interruptionNotification ? "interruption" :
            name == AVAudioSession.routeChangeNotification ? "route_change" :
            name == AVAudioSession.mediaServicesWereResetNotification ? "media_services_reset" : "engine_configuration_changed"
        if name == AVAudioSession.interruptionNotification {
            interrupted = type == AVAudioSession.InterruptionType.began.rawValue
        }
        generation += 1; let expected = generation
        let stopped = finishSound(reason: stopReason)
        // Playback-only sessions need the same interruption evidence as capture.
        if name == AVAudioSession.interruptionNotification {
            let began = type == AVAudioSession.InterruptionType.began.rawValue
            log?.record(began ? "audio_interruption_began" : "audio_interruption_ended", code: began ? reason.map { Int($0) } : Int(options))
        } else if name == AVAudioSession.routeChangeNotification { log?.record("audio_route_changed", code: reason.map { Int($0) }) }
        else if name == AVAudioSession.mediaServicesWereResetNotification { log?.record("audio_services_reset") }
        else if name == .AVAudioEngineConfigurationChange { log?.record("audio_engine_changed") }
        guard wantsMonitoring else {
            do {
                try await driver.setSound(nurseryState, capture: false, generation: expected)
                if expected == generation { logStop(stopped, phase: "stopped", reason: stopReason) }
            } catch {
                if expected == generation { logSound(phase: "audio_failed", reason: stopReason, error: error) }
            }
            return
        }
        // Codes: began → AVAudioSession.InterruptionReason, ended → InterruptionOptions
        // (1 = shouldResume; without it one restart is still tried), route → RouteChangeReason.
        if interrupted {
            onStatus?(.recovering("Audio interrupted. Waiting for microphone…"))
            guard expected == generation else { return }
            await driver.pause(generation: expected)
            if generation == expected { logStop(stopped, phase: "stopped", reason: stopReason) }
            return
        }
        // Without shouldResume the system makes no promise, but a background
        // record session can often reactivate anyway. Try once; an activation
        // error reports the failure, and a silent engine trips the stall check.
        let unprompted = name == AVAudioSession.interruptionNotification
            && !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        // End the last observed episode before restarting; no interruption counts as crying.
        onStatus?(.recovering("Audio route changed. Recovering microphone…"))
        guard expected == generation else { return }
        do {
            try await driver.activate(generation: expected, clearSound: true)
            guard generation == expected, wantsMonitoring else { return }
            logStop(stopped, phase: "stopped", reason: stopReason)
            logSound(phase: "capture_restored")
            onStatus?(.active)
        } catch {
            guard generation == expected, wantsMonitoring else { return }
            log?.record("audio_interrupted", code: unprompted ? 1 : 0, error: error)
            wantsMonitoring = false
            onStatus?(.failed(unprompted ? "Audio could not resume. Open the app to restart monitoring."
                                         : "Microphone unavailable. Open the app to restart monitoring."))
        }
    }
}
/// Audio session activation is blocking on older iOS releases; actor isolation keeps
/// acquisition, reconfiguration, and teardown off the main UI executor.
private actor AudioCaptureDriver: AudioCaptureDriving {
    private var engine = AVAudioEngine()
    private let captureTap: AudioCaptureTap
    private var sessionActive = false
    private var generation = 0
    private var captureEnabled = false
    private var sound: NurserySoundSettings?
    private var player: AVAudioPlayerNode?
    private var buffers: [NurserySound: AVAudioPCMBuffer] = [:]
    init(continuation: AsyncStream<AudioLevelSample>.Continuation) {
        captureTap = AudioCaptureTap(continuation: continuation)
    }
    var isRunning: Bool { engine.isRunning }
    var engineID: ObjectIdentifier { ObjectIdentifier(engine) }
    func recoverConfiguration(generation requested: Int) throws {
        guard requested >= generation else { throw CancellationError() }; generation = requested
        try Task.checkCancellation()
        // A configuration notification stops the engine but retains its graph.
        // Restart that graph without replacing Voice Processing I/O or changing
        // the session category, which can itself trigger another notification.
        try AudioGraphLifecycle.restart(engine: engine, captureTap: captureEnabled ? captureTap : nil) {
            if let sound, let player {
                player.stop()
                player.scheduleBuffer(try buffer(for: sound.sound), at: nil, options: .loops)
            }
        }
        player?.play()
    }

    func activate(generation requested: Int, clearSound: Bool) throws {
        try Task.checkCancellation()
        guard requested >= generation else { throw CancellationError() }; generation = requested
        if clearSound { sound = nil }
        captureEnabled = true
        try rebuild()
    }
    private func rebuild(cancellable: Bool = true) throws {
        tearDown()
        // Release the old input/output graph before changing the session or
        // enabling voice processing on a new engine.
        engine = AVAudioEngine()
        let session = AVAudioSession.sharedInstance()
        var stage = NurseryAudioFailure.Stage.session
        do {
            if captureEnabled {
                try session.setCategory(.playAndRecord, mode: sound == nil ? .measurement : .voiceChat, options: [.defaultToSpeaker])
            } else { try session.setCategory(.playback, mode: .default, options: []) }
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true); sessionActive = true
            if captureEnabled {
                let input = engine.inputNode
                // Playback goes through this engine's output so Voice Processing
                // receives its echo reference. Never connect the mic to the mixer.
                stage = .voiceProcessing
                if sound != nil { try input.setVoiceProcessingEnabled(true); input.isVoiceProcessingAGCEnabled = false }
                stage = .input
                try captureTap.replace(on: input)
            }
            stage = .player
            if let sound { try preparePlayer(sound) }
            if cancellable { try Task.checkCancellation() }
            stage = .engine
            engine.prepare(); try engine.start(); player?.play()
        } catch {
            tearDown(); deactivateSession()
            if error is CancellationError || error is NurseryAudioFailure { throw error }
            throw NurseryAudioFailure(stage: stage, underlying: error)
        }
    }
    func setSound(_ state: NurserySoundState, capture: Bool, generation requested: Int) throws {
        guard requested >= generation else { throw CancellationError() }; generation = requested
        if state.playing { try Task.checkCancellation() }
        guard state.isValid else { throw AudioError.unavailable }
        let previous = sound
        let captureChanged = captureEnabled != capture
        captureEnabled = capture
        sound = state.playing ? state.settings : nil
        do {
            if !state.playing {
                player?.stop()
                if capture {
                    if captureChanged || previous != nil || !engine.isRunning || AVAudioSession.sharedInstance().mode != .measurement || engine.inputNode.isVoiceProcessingEnabled {
                        try rebuild(cancellable: false)
                    }
                } else { tearDown(); deactivateSession() }
            } else if !captureChanged, previous != nil, engine.isRunning, let player {
                if previous?.sound != sound?.sound {
                    player.stop()
                    let buffer = try buffer(for: state.settings.sound)
                    try Task.checkCancellation()
                    player.scheduleBuffer(buffer, at: nil, options: .loops); player.play()
                }
            } else { try rebuild() }
        } catch { sound = nil; throw error }
    }
    private func buffer(for sound: NurserySound) throws -> AVAudioPCMBuffer {
        if let buffer = buffers[sound] { return buffer }
        let samples = sound.samples()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw NurseryAudioFailure(stage: .synthesis, underlying: AudioError.unavailable) }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in if let base = source.baseAddress { channel.update(from: base, count: samples.count) } }
        buffers[sound] = buffer; return buffer
    }
    private func preparePlayer(_ settings: NurserySoundSettings) throws {
        let buffer = try buffer(for: settings.sound)
        let player = AVAudioPlayerNode(); engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        // The system volume is the only user-facing volume control.
        player.volume = 1; player.scheduleBuffer(buffer, at: nil, options: .loops)
        self.player = player
    }
    func pause(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested; tearDown()
        sound = nil
    }
    func stop(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested
        captureEnabled = false; sound = nil
        tearDown(); deactivateSession()
    }
    private func tearDown() {
        AudioGraphLifecycle.tearDown(engine: engine, captureTap: captureTap, player: player)
        player = nil
    }
    private func deactivateSession() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }
}
private enum AudioError: LocalizedError, CustomNSError {
    static var errorDomain: String { "CribService.Audio" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "Microphone unavailable."] }
    case unavailable
    var errorDescription: String? { "Microphone unavailable. Check the audio input and try again." }
}
/// Shared by the device driver and native-engine integration tests. Reinstalling
/// with no pinned format lets the input follow the hardware after a route change.
final class AudioCaptureTap {
    private weak var node: AVAudioInputNode?
    private let continuation: AsyncStream<AudioLevelSample>.Continuation
    init(continuation: AsyncStream<AudioLevelSample>.Continuation) { self.continuation = continuation }
    func replace(on input: AVAudioInputNode) throws {
        remove()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw NurseryAudioFailure(stage: .input, underlying: AudioError.unavailable)
        }
        let reducer = RMSReducer(continuation: continuation)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in reducer.consume(buffer) }
        node = input
    }
    func remove() {
        node?.removeTap(onBus: 0)
        node = nil
    }
}

enum AudioGraphLifecycle {
    static func tearDown(engine: AVAudioEngine, captureTap: AudioCaptureTap, player: AVAudioPlayerNode?) {
        engine.stop()
        player?.stop()
        captureTap.remove()
        if let player { engine.disconnectNodeOutput(player); engine.detach(player) }
    }

    static func restart(engine: AVAudioEngine, captureTap: AudioCaptureTap?,
                        reschedulePlayback: () throws -> Void) throws {
        guard !engine.isRunning else { return }
        // Input taps carry the previous hardware format. Refresh the tap before
        // restarting; the main mixer's default output connection tracks hardware.
        if let captureTap { try captureTap.replace(on: engine.inputNode) }
        try reschedulePlayback()
        do { try engine.start() }
        catch { throw NurseryAudioFailure(stage: .engine, underlying: error) }
    }
}

/// Single audio callback queue owns these accumulators; lock protects overlap.
final class RMSReducer: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleRate = 0.0
    private var channelCount = 0
    private var windowFrames = 1
    private let continuation: AsyncStream<AudioLevelSample>.Continuation
    private var sum = 0.0
    private var count = 0
    init(continuation: AsyncStream<AudioLevelSample>.Continuation) { self.continuation = continuation }
    func consume(_ buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        let numberOfChannels = Int(format.channelCount)
        if sampleRate != format.sampleRate || channelCount != numberOfChannels {
            sampleRate = format.sampleRate; channelCount = numberOfChannels
            windowFrames = max(1, Int(sampleRate * 0.25))
            sum = 0; count = 0
        }
        for index in 0..<Int(buffer.frameLength) {
            var energy = 0.0
            for channel in 0..<numberOfChannels {
                let value = Double(format.isInterleaved ? channels[0][index * numberOfChannels + channel] : channels[channel][index])
                energy += value * value
            }
            sum += energy / Double(numberOfChannels); count += 1
            if count >= windowFrames {
                let rms = sqrt(sum / Double(count))
                continuation.yield(AudioLevelSample(timestamp: Date(), dbFS: min(0, max(-100, 20 * log10(max(rms, 0.00001))))))
                count = 0; sum = 0
            }
        }
    }
}
