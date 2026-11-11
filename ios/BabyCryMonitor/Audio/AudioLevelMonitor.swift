import AVFoundation
import Foundation
import UIKit

enum AudioCaptureStatus {
    case stopped
    case active
    case recovering(String)
    case failed(String)
    /// The microphone is running, but another app or system sound is playing on
    /// this iPhone. Its speaker output reaches the microphone, so detection pauses.
    case otherAudio
}

struct NurseryAudioFailure: Error {
    enum Stage: String, Sendable { case session, voiceProcessing = "voice_processing", input, synthesis, player, engine }
    let stage: Stage
    let underlying: any Error
    /// iOS refused to reconfigure the session while this app was in the
    /// background ('!int'). Measurement capture cannot switch to voice
    /// processing on a locked Listener; nursery sound must start on it instead.
    var blockedInBackground: Bool {
        let error = underlying as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
    }
}

/// Actor boundary is injectable so operation ordering and capture restoration can
/// be tested without a microphone or an audio route belonging to the test host.
protocol AudioCaptureDriving: Sendable {
    var isRunning: Bool { get async }
    var engineID: ObjectIdentifier { get async }
    /// Returns whether capture runs with voice processing (`.voiceChat`).
    func activate(generation: Int, clearSound: Bool, idleVoiceProcessing: Bool) async throws -> Bool
    func recoverConfiguration(generation: Int) async throws
    func stopSoundKeepingCapture(generation: Int) async throws -> Bool
    func setSound(_ state: NurserySoundState, capture: Bool, generation: Int) async throws
    func pause(generation: Int) async
    func stop(generation: Int) async
    func setCaptureTestMode(_ mode: AudioCaptureTestMode, generation: Int) async throws -> AudioCaptureTestResult
}
extension AudioCaptureDriving {
    func setCaptureTestMode(_ mode: AudioCaptureTestMode, generation: Int) async throws -> AudioCaptureTestResult {
        throw AudioError.unavailable
    }
}

@MainActor protocol AudioLevelProviding: AnyObject {
    var calibrationAudio: CalibrationAudioRecording? { get }
    var levels: AsyncStream<AudioLevelSample> { get }
    var onStatus: ((AudioCaptureStatus) -> Void)? { get set }
    var onNurserySoundChange: ((NurserySoundState) -> Void)? { get set }
    var onClassification: ((SoundClassificationEvent) -> Void)? { get set }
    /// During an `.otherAudio` pause: whether that sound is still playing, rather
    /// than having stopped while detection waits out the quiet period to resume.
    var otherAudioPlayingNow: Bool { get }
    func setClassificationEnabled(_ enabled: Bool)
    func setClassificationAppActive(_ active: Bool)
    func requestPermission() async -> Bool
    /// `idleVoiceProcessing` keeps capture ready for a remote nursery sound
    /// while locked. Calibration passes false to measure the unprocessed room.
    func start(idleVoiceProcessing: Bool) async throws
    func stop()
    func setNurserySound(_ request: NurserySoundRequest, commandID: UUID?) async throws
    /// Diagnostics A/B test only. nil restores the mode the last Start chose.
    func setCaptureTestMode(_ mode: AudioCaptureTestMode?) async throws -> AudioCaptureTestResult
}
extension AudioLevelProviding {
    func setCaptureTestMode(_ mode: AudioCaptureTestMode?) async throws -> AudioCaptureTestResult { throw AudioError.unavailable }
    var calibrationAudio: CalibrationAudioRecording? { nil }
    var onClassification: ((SoundClassificationEvent) -> Void)? { get { nil } set {} }
    var otherAudioPlayingNow: Bool { false }
    func setClassificationEnabled(_ enabled: Bool) {}
    func setClassificationAppActive(_ active: Bool) {}
    func setNurserySound(_ request: NurserySoundRequest) async throws { try await setNurserySound(request, commandID: nil) }
    func start() async throws { try await start(idleVoiceProcessing: false) }
}
/// RMS levels feed the existing detector. Bounded transient buffer copies feed
/// an independent classifier and optional, local calibration recorder.
@MainActor final class AudioLevelMonitor: AudioLevelProviding {
    let levels: AsyncStream<AudioLevelSample>
    let calibrationAudio: CalibrationAudioRecording?
    private let driver: any AudioCaptureDriving
    private let classificationControl = SoundClassificationControl()
    private var classificationTask: Task<Void, Never>?
    var onClassification: ((SoundClassificationEvent) -> Void)?
    func setClassificationEnabled(_ enabled: Bool) { classificationControl.setEnabled(enabled) }
    func setClassificationAppActive(_ active: Bool) { classificationControl.setAppActive(active) }
    private let currentTime: () -> ContinuousClock.Instant
    private var observers: [NSObjectProtocol] = []
    private var wantsMonitoring = false
    private var generation = 0
    private var configuringGeneration: Int?
    private var configurationRecoveryAttempts = 0
    private var configurationRecoveryWindowStarted: ContinuousClock.Instant?
    private var interrupted = false
    /// What this monitor last told AppModel about capture. Other-audio polling
    /// only toggles between live capture and its own pause, never overriding an
    /// interruption, recovery or failure status.
    private enum ReportedCapture { case live, otherAudio, other }
    private var reported = ReportedCapture.other
    private let otherAudioPlaying: @MainActor () -> Bool
    private let otherAudioPollInterval: Duration
    private let otherAudioResumeDelay: Duration
    private let reactivationRetryDelays: [Duration]
    private let isForeground: @MainActor () -> Bool
    /// The last Start asked for voice-processing capture. Recovery keeps it
    /// only in the foreground: a locked Listener reactivates in .measurement,
    /// the configuration known to activate in the background.
    private var wantsIdleVoiceProcessing = false
    private var otherAudioTask: Task<Void, Never>?
    /// When other audio was last seen while paused. Resume needs a quiet stretch,
    /// since sounds such as Find My pulse and would otherwise flap detection.
    private var otherAudioLastSeen: ContinuousClock.Instant?
    var otherAudioPlayingNow: Bool {
        guard reported == .otherAudio, let seen = otherAudioLastSeen else { return false }
        return seen.duration(to: currentTime()) < .seconds(1)
    }
    nonisolated static let otherAudioMessage = "Another sound is playing on this iPhone. Detection paused."
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

    init(driver: (any AudioCaptureDriving)? = nil, currentTime: @escaping () -> ContinuousClock.Instant = { .now },
         sampleStream: AsyncStream<AudioLevelSample>? = nil, otherAudioPlaying: (@MainActor () -> Bool)? = nil,
         otherAudioPollInterval: Duration = .milliseconds(250), otherAudioResumeDelay: Duration = .seconds(5),
         reactivationRetryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)],
         isForeground: (@MainActor () -> Bool)? = nil) {
        let pair = AsyncStream<AudioLevelSample>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let classifications = AsyncStream<SoundClassificationEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        levels = sampleStream ?? pair.stream
        let recording = CalibrationAudioRecording()
        calibrationAudio = recording
        self.driver = driver ?? AudioCaptureDriver(continuation: pair.continuation,
            classificationControl: classificationControl, classificationEvents: classifications.continuation,
            recording: recording.writer)
        self.currentTime = currentTime
        // An injected driver has no real session, so it never sees other audio.
        if let otherAudioPlaying { self.otherAudioPlaying = otherAudioPlaying }
        else if driver == nil { self.otherAudioPlaying = { AVAudioSession.sharedInstance().isOtherAudioPlaying } }
        else { self.otherAudioPlaying = { false } }
        self.otherAudioPollInterval = otherAudioPollInterval
        self.otherAudioResumeDelay = otherAudioResumeDelay
        self.reactivationRetryDelays = reactivationRetryDelays
        // An injected driver has no real session; tests opt in explicitly.
        if let isForeground { self.isForeground = isForeground }
        else if driver == nil { self.isForeground = { UIApplication.shared.applicationState == .active } }
        else { self.isForeground = { false } }
        classificationTask = Task { [weak self] in
            for await event in classifications.stream {
                guard !Task.isCancelled else { break }
                self?.onClassification?(event)
            }
        }
        observe(AVAudioSession.interruptionNotification)
        observe(AVAudioSession.routeChangeNotification)
        observe(AVAudioSession.mediaServicesWereResetNotification)
        observe(.AVAudioEngineConfigurationChange)
        // Delivered only while this app is in the foreground; polling covers a
        // locked Listener. Either way the pause starts at the first sign.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollOtherAudio() }
        })
    }
    deinit { classificationTask?.cancel(); otherAudioTask?.cancel() }
    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func start(idleVoiceProcessing: Bool) async throws {
        try Task.checkCancellation()
        wantsIdleVoiceProcessing = idleVoiceProcessing
        // iOS does not guarantee an interruption-ended notification. A person's
        // Start tries to reactivate; activation fails while the interruption lasts.
        configurationRecoveryAttempts = 0
        wantsMonitoring = true; generation += 1
        let expected = generation
        configuringGeneration = expected
        defer { if configuringGeneration == expected { configuringGeneration = nil } }
        do {
            let voiceProcessing = try await driver.activate(generation: expected, clearSound: false,
                                                            idleVoiceProcessing: idleVoiceProcessing && isForeground())
            logCaptureMode(voiceProcessing, requested: idleVoiceProcessing)
            guard generation == expected, wantsMonitoring else { throw CancellationError() }
            try Task.checkCancellation()
            // Any interruption that began during activation bumped the generation.
            interrupted = false
            if playback.expired(at: currentTime()) {
                let stopped = finishSound(reason: "timer_expired")
                try await driver.setSound(nurseryState, capture: true, generation: expected)
                guard generation == expected, wantsMonitoring else { throw CancellationError() }
                logStop(stopped, phase: "stopped", reason: "timer_expired")
            }
            armSoundTimer(generation: expected)
            logSound(phase: "audio_applied")
            reportActive()
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
        otherAudioTask?.cancel(); otherAudioTask = nil
        let expected = generation
        let stopped = finishSound(reason: "microphone_stop")
        Task {
            await driver.stop(generation: expected)
            if generation == expected { logStop(stopped, phase: "stopped", reason: "microphone_stop") }
        }
        report(.stopped)
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
        var reconfiguringCapture = false
        do {
            guard expected == generation else { throw CancellationError() }
            let retainedCapture: Bool
            if wantsMonitoring, nurseryState.playing, !next.state.playing, !interrupted {
                retainedCapture = try await driver.stopSoundKeepingCapture(generation: expected)
                guard expected == generation else { throw CancellationError() }
            } else { retainedCapture = false }
            if !retainedCapture {
                reconfiguringCapture = wantsMonitoring && next.state.playing != nurseryState.playing
                if reconfiguringCapture { report(.recovering("Updating nursery speaker and microphone…")) }
                if interrupted { await driver.pause(generation: expected) }
                else { try await driver.setSound(next.state, capture: wantsMonitoring, generation: expected) }
            }
            guard expected == generation else { throw CancellationError() }
            try Task.checkCancellation()
            // A settings edit may expire while synthesis or graph setup is in flight.
            if next.expired(at: currentTime()) {
                next.update(at: currentTime())
                let keptCapture = wantsMonitoring && !interrupted
                    ? try await driver.stopSoundKeepingCapture(generation: expected) : false
                guard expected == generation else { throw CancellationError() }
                if !keptCapture, wantsMonitoring, !reconfiguringCapture {
                    reconfiguringCapture = true
                    report(.recovering("Restoring microphone after nursery sound…"))
                    guard expected == generation else { throw CancellationError() }
                }
                if !keptCapture { try await driver.setSound(next.state, capture: wantsMonitoring, generation: expected) }
                guard expected == generation else { throw CancellationError() }
            }
            playback = next; armSoundTimer(generation: expected)
            if reconfiguringCapture, wantsMonitoring { reportActive() }
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
            if wantsMonitoring, previous.state.playing, !next.state.playing {
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
                    if wantsMonitoring { logSound(phase: "capture_restored", commandID: commandID); reportActive() }
                }
            } catch {
                if expected == generation, wantsMonitoring {
                    logSound(phase: "capture_restore_failed", commandID: commandID, error: error)
                    wantsMonitoring = false
                    report(.failed("Microphone unavailable. Open the app to restart monitoring."))
                }
            }
            throw error
        }
    }
    func setCaptureTestMode(_ mode: AudioCaptureTestMode?) async throws -> AudioCaptureTestResult {
        // Never reconfigure under a sound, an interruption or another operation.
        guard wantsMonitoring, !interrupted, !nurseryState.playing, configuringGeneration == nil else { throw AudioError.unavailable }
        generation += 1; let expected = generation
        configuringGeneration = expected
        defer { if configuringGeneration == expected { configuringGeneration = nil } }
        let target = mode ?? (wantsIdleVoiceProcessing ? .voiceProcessing : .measurement)
        let result = try await driver.setCaptureTestMode(target, generation: expected)
        guard generation == expected, wantsMonitoring else { throw CancellationError() }
        return result
    }
    private var recoveryVoiceProcessing: Bool { wantsIdleVoiceProcessing && isForeground() }
    /// Code 1: voice processing, ready for remote sound while locked.
    /// 0 after asking for it: measurement, so remote Play needs the nursery
    /// iPhone until sound is started there. Not recorded for calibration.
    private func logCaptureMode(_ voiceProcessing: Bool, requested: Bool) {
        guard requested else { return }
        log?.record("audio_capture_mode", code: voiceProcessing ? 1 : 0)
    }
    private func report(_ status: AudioCaptureStatus) {
        reported = .other
        onStatus?(status)
    }
    /// The mixable capture session keeps recording while another app plays,
    /// and that playback reaches the microphone. Detection must not score it.
    private func reportActive() {
        let paused = otherAudioPlaying()
        if paused { log?.record("audio_other_playing"); otherAudioLastSeen = currentTime() }
        onStatus?(paused ? .otherAudio : .active)
        reported = paused ? .otherAudio : .live
        watchOtherAudio()
    }
    private func watchOtherAudio() {
        guard otherAudioTask == nil else { return }
        let interval = otherAudioPollInterval
        otherAudioTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                guard self.wantsMonitoring else { self.otherAudioTask = nil; return }
                self.pollOtherAudio()
            }
        }
    }
    private func pollOtherAudio() {
        // Interruptions and in-flight reconfiguration publish their own status.
        guard !interrupted, configuringGeneration == nil else { return }
        let playing = otherAudioPlaying(), now = currentTime()
        switch reported {
        case .live where playing:
            log?.record("audio_other_playing"); otherAudioLastSeen = now
            onStatus?(.otherAudio); reported = .otherAudio
        case .otherAudio where playing:
            otherAudioLastSeen = now
        case .otherAudio:
            guard let seen = otherAudioLastSeen, seen.duration(to: now) >= otherAudioResumeDelay else { return }
            log?.record("audio_other_stopped"); otherAudioLastSeen = nil
            onStatus?(.active); reported = .live
        default: break
        }
    }
    /// When an interruption ends, the other session may not have released
    /// audio yet. Retry briefly under background time instead of giving up,
    /// since a locked Listener otherwise stays deaf until someone opens it.
    private func retryReactivation(generation expected: Int) async -> Bool {
        guard !reactivationRetryDelays.isEmpty else { return false }
        let grant = BackgroundTimeGrant.begin("AudioReactivation") {}
        defer { grant.end() }
        for (index, delay) in reactivationRetryDelays.enumerated() {
            do { try await Task.sleep(for: delay) } catch { return false }
            guard generation == expected, wantsMonitoring else { return false }
            do {
                let voiceProcessing = try await driver.activate(generation: expected, clearSound: true,
                                                                idleVoiceProcessing: recoveryVoiceProcessing)
                guard generation == expected, wantsMonitoring else { return false }
                logCaptureMode(voiceProcessing, requested: wantsIdleVoiceProcessing)
                log?.record("audio_reactivation_recovered", code: index + 1)
                return true
            } catch {
                guard generation == expected, wantsMonitoring else { return false }
                log?.record("audio_reactivation_failed", code: index + 1, error: error)
            }
        }
        return false
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
        // With capture active the graph may retain voice processing after the
        // player stops, so its mode cannot be inferred from playback state.
        let mode: String? = wantsMonitoring ? (state.playing ? "voiceChat" : nil) : (state.playing ? "playback" : "inactive")
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
            let now = currentTime()
            if let window = configurationRecoveryWindowStarted, window.duration(to: now) >= .seconds(60) {
                configurationRecoveryAttempts = 0
            }
            if configurationRecoveryAttempts == 0 { configurationRecoveryWindowStarted = now }
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
                    report(.failed("Audio recovery failed. Open the app to restart monitoring."))
                }
                return
            }
            configurationRecoveryAttempts += 1
            if wantsMonitoring { report(.recovering("Recovering speaker and microphone…")) }
            do {
                try await driver.recoverConfiguration(generation: expected)
                guard generation == expected else { return }
                armSoundTimer(generation: expected)
                if wantsMonitoring { reportActive() }
            } catch {
                guard generation == expected else { return }
                log?.record("audio_interrupted", error: error)
                let stopped = finishSound(reason: "route_change")
                await driver.stop(generation: expected)
                guard generation == expected else { return }
                logStop(stopped, phase: "stopped", reason: "route_change")
                if wantsMonitoring { wantsMonitoring = false; report(.failed("Microphone unavailable. Open the app to restart monitoring.")) }
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
        } else if name == AVAudioSession.mediaServicesWereResetNotification {
            // A reset invalidates every session; no earlier interruption survives it.
            interrupted = false
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
            report(.recovering("Audio interrupted. Waiting for microphone…"))
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
        report(.recovering("Audio route changed. Recovering microphone…"))
        guard expected == generation else { return }
        do {
            let voiceProcessing = try await driver.activate(generation: expected, clearSound: true,
                                                            idleVoiceProcessing: recoveryVoiceProcessing)
            guard generation == expected, wantsMonitoring else { return }
            logCaptureMode(voiceProcessing, requested: wantsIdleVoiceProcessing)
            logStop(stopped, phase: "stopped", reason: stopReason)
            logSound(phase: "capture_restored")
            reportActive()
        } catch {
            guard generation == expected, wantsMonitoring else { return }
            log?.record("audio_interrupted", code: unprompted ? 1 : 0, error: error)
            if await retryReactivation(generation: expected) {
                logStop(stopped, phase: "stopped", reason: stopReason)
                logSound(phase: "capture_restored")
                reportActive()
                return
            }
            guard generation == expected, wantsMonitoring else { return }
            wantsMonitoring = false
            report(.failed(unprompted ? "Audio could not resume. Open the app to restart monitoring."
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
    /// Keep capture in voice processing (.voiceChat) with an idle player even
    /// when no sound plays. iOS refuses to switch a locked Listener from
    /// .measurement to .voiceChat ('!int'), but a remote Play into an existing
    /// voice-processing graph only schedules a buffer and needs no session change.
    private var idleVoiceProcessing = false
    private var voiceProcessing: Bool { sound != nil || (captureEnabled && idleVoiceProcessing) }
    init(continuation: AsyncStream<AudioLevelSample>.Continuation,
         classificationControl: SoundClassificationControl,
         classificationEvents: AsyncStream<SoundClassificationEvent>.Continuation,
         recording: CalibrationAudioWriter) {
        captureTap = AudioCaptureTap(continuation: continuation, classificationControl: classificationControl,
                                    classificationEvents: classificationEvents, recording: recording)
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

    func activate(generation requested: Int, clearSound: Bool, idleVoiceProcessing requestedVoiceProcessing: Bool) throws -> Bool {
        try Task.checkCancellation()
        guard requested >= generation else { throw CancellationError() }; generation = requested
        if clearSound { sound = nil }
        captureEnabled = true; idleVoiceProcessing = requestedVoiceProcessing
        try rebuild()
        return voiceProcessing
    }
    private func rebuild(cancellable: Bool = true) throws {
        do { try build(cancellable: cancellable) }
        catch where sound == nil && captureEnabled && idleVoiceProcessing && !(error is CancellationError) {
            // Measurement capture is the configuration known to activate while
            // locked. Monitoring matters more than remote sound start.
            idleVoiceProcessing = false
            try build(cancellable: cancellable)
        }
    }
    private func build(cancellable: Bool) throws {
        tearDown()
        // Release the old input/output graph before changing the session or
        // enabling voice processing on a new engine.
        engine = AVAudioEngine()
        let session = AVAudioSession.sharedInstance()
        var stage = NurseryAudioFailure.Stage.session
        do {
            if captureEnabled {
                try session.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .measurement,
                                        options: AudioSessionPolicy.captureOptions)
            } else { try session.setCategory(.playback, mode: .default, options: AudioSessionPolicy.playbackOptions) }
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true); sessionActive = true
            if captureEnabled {
                let input = engine.inputNode
                // Playback goes through this engine's output so Voice Processing
                // receives its echo reference. Never connect the mic to the mixer.
                stage = .voiceProcessing
                if voiceProcessing { try input.setVoiceProcessingEnabled(true); input.isVoiceProcessingAGCEnabled = false }
                stage = .input
                try captureTap.replace(on: input)
            }
            stage = .player
            if let sound { try preparePlayer(sound) } else if voiceProcessing { try preparePlayer(nil) }
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
                    // Keep the running capture graph and active session when a
                    // sound ends. Rebuilding it in the background can lose the
                    // audio assertion and iOS can refuse to reactivate it.
                    // Voice processing remains enabled until the next rebuild.
                    if captureChanged || !engine.isRunning {
                        try rebuild(cancellable: false)
                    }
                } else { tearDown(); deactivateSession() }
            } else if !captureChanged, engine.isRunning, let player {
                // A sound needs echo cancellation; end any A/B-test bypass.
                if capture, engine.inputNode.isVoiceProcessingEnabled { engine.inputNode.isVoiceProcessingBypassed = false }
                if previous?.sound != sound?.sound {
                    player.stop()
                    let buffer = try buffer(for: state.settings.sound)
                    try Task.checkCancellation()
                    player.scheduleBuffer(buffer, at: nil, options: .loops); player.play()
                }
            } else { try rebuild() }
        } catch { sound = nil; throw error }
    }
    func stopSoundKeepingCapture(generation requested: Int) throws -> Bool {
        guard requested >= generation else { throw CancellationError() }; generation = requested
        // This check and stop share the driver's actor, so no newer operation
        // can replace the graph between checking and stopping the player.
        guard captureEnabled, sound != nil, engine.isRunning, let player else { return false }
        player.stop(); sound = nil
        return true
    }
    func setCaptureTestMode(_ mode: AudioCaptureTestMode, generation requested: Int) throws -> AudioCaptureTestResult {
        guard requested >= generation else { throw CancellationError() }; generation = requested
        guard captureEnabled, sound == nil else { throw AudioError.unavailable }
        let processing = engine.isRunning && engine.inputNode.isVoiceProcessingEnabled
        var rebuilt = false, failure: String?
        switch mode {
        case .measurement:
            if processing || !engine.isRunning { idleVoiceProcessing = false; try build(cancellable: false); rebuilt = true }
        case .voiceProcessing, .bypassed:
            if !processing {
                idleVoiceProcessing = true; rebuilt = true
                do { try build(cancellable: false) } catch {
                    // Expected while locked ('!int'). Keep monitoring in measurement.
                    let underlying = ((error as? NurseryAudioFailure)?.underlying ?? error) as NSError
                    failure = "\(underlying.domain):\(underlying.code)"
                    idleVoiceProcessing = false; try build(cancellable: false)
                }
            }
            if engine.inputNode.isVoiceProcessingEnabled { engine.inputNode.isVoiceProcessingBypassed = mode == .bypassed }
        }
        let input = engine.inputNode
        return AudioCaptureTestResult(voiceProcessing: input.isVoiceProcessingEnabled,
                                      bypassed: input.isVoiceProcessingEnabled && input.isVoiceProcessingBypassed,
                                      rebuilt: rebuilt, failure: failure)
    }
    private func buffer(for sound: NurserySound) throws -> AVAudioPCMBuffer {
        if let buffer = buffers[sound] { return buffer }
        if sound == .twinkleTwinkle {
            guard let url = Bundle.main.url(forResource: "TwinkleTwinkleOtoLogic", withExtension: "mp3") else {
                throw NurseryAudioFailure(stage: .synthesis, underlying: AudioError.unavailable)
            }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.length <= Int64(UInt32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw NurseryAudioFailure(stage: .synthesis, underlying: AudioError.unavailable)
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw NurseryAudioFailure(stage: .synthesis, underlying: AudioError.unavailable) }
            buffers[sound] = buffer
            return buffer
        }
        // Match the bundled recording's stereo 44.1 kHz format so the player
        // can switch sounds without rebuilding the active capture graph.
        let samples = sound.samples(sampleRate: 44_100)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { throw NurseryAudioFailure(stage: .synthesis, underlying: AudioError.unavailable) }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channels[0].update(from: base, count: samples.count)
                channels[1].update(from: base, count: samples.count)
            }
        }
        buffers[sound] = buffer; return buffer
    }
    /// Without settings the player is connected but silent, ready for a later
    /// Play to schedule a buffer without rebuilding the graph. Both sounds
    /// share one format, so the white-noise format fits either.
    private func preparePlayer(_ settings: NurserySoundSettings?) throws {
        let buffer = try buffer(for: settings?.sound ?? .whiteNoise)
        let player = AVAudioPlayerNode(); engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        // The system volume is the only user-facing volume control.
        player.volume = 1
        if settings != nil { player.scheduleBuffer(buffer, at: nil, options: .loops) }
        self.player = player
    }
    func pause(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested; tearDown()
        sound = nil
    }
    func stop(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested
        captureEnabled = false; sound = nil; idleVoiceProcessing = false
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
    private let classificationControl: SoundClassificationControl?
    private let classificationEvents: AsyncStream<SoundClassificationEvent>.Continuation?
    private var classifier: BabyCryClassifier?
    private let recording: CalibrationAudioWriter?
    private var recordingCaptureID: UUID?
    init(continuation: AsyncStream<AudioLevelSample>.Continuation,
         classificationControl: SoundClassificationControl? = nil,
         classificationEvents: AsyncStream<SoundClassificationEvent>.Continuation? = nil,
         recording: CalibrationAudioWriter? = nil) {
        self.continuation = continuation; self.classificationControl = classificationControl
        self.classificationEvents = classificationEvents
        self.recording = recording
    }
    func replace(on input: AVAudioInputNode) throws {
        remove()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw NurseryAudioFailure(stage: .input, underlying: AudioError.unavailable)
        }
        let reducer = RMSReducer(continuation: continuation)
        let classifier: BabyCryClassifier?
        if let classificationControl, let classificationEvents {
            let delivery = SoundClassificationEventDelivery(classificationEvents)
            classifier = BabyCryClassifier(control: classificationControl, emit: delivery.emit)
        } else { classifier = nil }
        self.classifier = classifier
        let voiceProcessing = input.isVoiceProcessingEnabled
        let recording = self.recording
        let recordingCaptureID = recording?.beginCapture()
        self.recordingCaptureID = recordingCaptureID
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            reducer.consume(buffer, at: time)
            classifier?.consume(buffer, at: time, voiceProcessing: voiceProcessing)
            if let recordingCaptureID {
                recording?.consume(buffer, at: time, captureID: recordingCaptureID, voiceProcessing: voiceProcessing)
            }
        }
        node = input
    }
    func remove() {
        if let recordingCaptureID { recording?.endCapture(recordingCaptureID) }
        recordingCaptureID = nil
        node?.removeTap(onBus: 0)
        classifier?.stop(); classifier = nil
        node = nil
    }
}

enum AudioSessionPolicy {
    /// Sessions must be mixable. iOS refuses to activate a non-mixable session
    /// from the background (AVAudioSession error '!int', 560557684), so a locked
    /// Listener lost its microphone permanently after a Find My sound ended,
    /// even though the system offered shouldResume. Calls, alarms, Find My and
    /// non-mixable recording still interrupt; ordinary playback from other apps
    /// mixes instead, so AudioLevelMonitor pauses detection while it plays.
    /// Nursery sound plays alongside other audio rather than taking it over.
    static let captureOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
    static let playbackOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]
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
    private var captureID = UUID()
    private var receivedFrames: Int64 = 0
    private var expectedInputFrame: AVAudioFramePosition?
    private var lastInputAt: Date?
    private var lastEmittedAt: Date?
    init(continuation: AsyncStream<AudioLevelSample>.Continuation) { self.continuation = continuation }
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime? = nil, capturedAt: Date = Date()) {
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        let numberOfChannels = Int(format.channelCount)
        let inputFrame = time.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil }
        let discontinuity = inputFrame.flatMap { frame in expectedInputFrame.map { frame != $0 } } ?? false
        let unclockedGap = inputFrame == nil && lastInputAt.map { capturedAt.timeIntervalSince($0) > 2 } == true
        // Do not turn a real backward wall-clock change into future-dated audio.
        // The consumer retains its existing rejection of out-of-order dates.
        if let lastInputAt, capturedAt < lastInputAt { lastEmittedAt = nil }
        if sampleRate != format.sampleRate || channelCount != numberOfChannels || discontinuity || unclockedGap {
            sampleRate = format.sampleRate; channelCount = numberOfChannels
            windowFrames = max(1, Int(sampleRate * 0.25))
            sum = 0; count = 0
            captureID = UUID(); receivedFrames = 0
        }
        expectedInputFrame = inputFrame.map { $0 + AVAudioFramePosition(buffer.frameLength) }
        lastInputAt = capturedAt
        for index in 0..<Int(buffer.frameLength) {
            var energy = 0.0
            for channel in 0..<numberOfChannels {
                let value = Double(format.isInterleaved ? channels[0][index * numberOfChannels + channel] : channels[channel][index])
                energy += value * value
            }
            sum += energy / Double(numberOfChannels); count += 1
            if count >= windowFrames {
                let rms = sqrt(sum / Double(count))
                let endFrame = receivedFrames + Int64(index) + 1
                let window = AudioLevelSample.Window(captureID: captureID, startFrame: endFrame - Int64(windowFrames),
                                                     endFrame: endFrame, sampleRate: sampleRate)
                // Input-buffer arrival maps freshness to wall time; the covered
                // sample frames provide duration, including multiple windows
                // completed in one callback. Never infer coverage from arrival.
                let estimatedEndAt = capturedAt.addingTimeInterval(-Double(Int(buffer.frameLength) - index - 1) / sampleRate)
                // Tail projections can reverse during catch-up callbacks. Keep
                // ordering with the smallest representable Date increment, not
                // a synthetic audio-duration step; PCM frames still own timing.
                let next = lastEmittedAt.map { Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.nextUp) }
                let endAt = max(estimatedEndAt, next ?? estimatedEndAt)
                lastEmittedAt = endAt
                let rmsDB = 20 * log10(max(rms, 0.00001))
                let dbFS = min(0, max(-100, rmsDB))
                continuation.yield(AudioLevelSample(timestamp: endAt, dbFS: dbFS, window: window))
                count = 0; sum = 0
            }
        }
        receivedFrames += Int64(buffer.frameLength)
    }
}
