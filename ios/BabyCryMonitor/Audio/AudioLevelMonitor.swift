import AVFoundation
import Foundation

enum AudioCaptureStatus {
    case stopped
    case active
    case recovering(String)
    case failed(String)
}

@MainActor protocol AudioLevelProviding: AnyObject {
    var levels: AsyncStream<AudioLevelSample> { get }
    var onStatus: ((AudioCaptureStatus) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() async throws
    func stop()
}
/// Only the RMS scalar leaves the real-time callback. Buffers are never retained.
@MainActor final class AudioLevelMonitor: AudioLevelProviding {
    let levels: AsyncStream<AudioLevelSample>
    private let driver: AudioCaptureDriver
    private var observers: [NSObjectProtocol] = []
    private var wantsMonitoring = false
    private var generation = 0
    var onStatus: ((AudioCaptureStatus) -> Void)?
    weak var log: DiagnosticLog?

    init() {
        let pair = AsyncStream<AudioLevelSample>.makeStream(bufferingPolicy: .bufferingNewest(16))
        levels = pair.stream; driver = AudioCaptureDriver(continuation: pair.continuation)
        observe(AVAudioSession.interruptionNotification)
        observe(AVAudioSession.routeChangeNotification)
        observe(AVAudioSession.mediaServicesWereResetNotification)
        observe(.AVAudioEngineConfigurationChange)
    }
    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func start() async throws {
        wantsMonitoring = true; generation += 1
        let expected = generation
        do {
            try await driver.activate(generation: expected)
            guard generation == expected, wantsMonitoring else { throw CancellationError() }
            onStatus?(.active)
        } catch {
            if generation == expected { wantsMonitoring = false }
            log?.record("monitoring_start_failed", error: error)
            throw error
        }
    }
    func stop() {
        wantsMonitoring = false; generation += 1
        let expected = generation
        Task { await driver.stop(generation: expected) }
        onStatus?(.stopped)
    }
    private func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in await self?.handle(name: name, type: type, options: options) }
        })
    }
    private func handle(name: Notification.Name, type: UInt?, options: UInt) async {
        guard wantsMonitoring else { return }
        if name == AVAudioSession.interruptionNotification { log?.record(type == AVAudioSession.InterruptionType.began.rawValue ? "audio_interruption_began" : "audio_interruption_ended") }
        else if name == AVAudioSession.routeChangeNotification { log?.record("audio_route_changed") }
        else if name == AVAudioSession.mediaServicesWereResetNotification { log?.record("audio_services_reset") }
        else if name == .AVAudioEngineConfigurationChange { log?.record("audio_engine_changed") }
        if name == .AVAudioEngineConfigurationChange, await driver.isRunning { return }
        guard wantsMonitoring else { return }
        if name == AVAudioSession.interruptionNotification, type == AVAudioSession.InterruptionType.began.rawValue {
            generation += 1; let expected = generation
            onStatus?(.recovering("Audio interrupted. Waiting for microphone…"))
            await driver.pause(generation: expected); return
        }
        if name == AVAudioSession.interruptionNotification,
           !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            onStatus?(.failed("Audio could not resume. Open the app to restart monitoring.")); return
        }
        generation += 1; let expected = generation
        // End the last observed episode before restarting; no interruption counts as crying.
        onStatus?(.recovering("Audio route changed. Recovering microphone…"))
        do {
            try await driver.activate(generation: expected)
            guard generation == expected, wantsMonitoring else { return }
            onStatus?(.active)
        } catch {
            guard generation == expected, wantsMonitoring else { return }
            log?.record("audio_interrupted", error: error)
            onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring."))
        }
    }
}
/// Audio session activation is blocking on older iOS releases; actor isolation keeps
/// acquisition, reconfiguration, and teardown off the main UI executor.
private actor AudioCaptureDriver {
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var sessionActive = false
    private var generation = 0
    private let continuation: AsyncStream<AudioLevelSample>.Continuation
    init(continuation: AsyncStream<AudioLevelSample>.Continuation) { self.continuation = continuation }
    var isRunning: Bool { engine.isRunning }
    func activate(generation requested: Int) throws {
        guard requested >= generation else { throw CancellationError() }; generation = requested
        tearDown()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true); sessionActive = true
            engine = AVAudioEngine()
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.unavailable }
            let reducer = RMSReducer(sampleRate: format.sampleRate, continuation: continuation)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in reducer.consume(buffer) }
            tapInstalled = true; engine.prepare(); try engine.start()
        } catch { tearDown(); deactivateSession(); throw error }
    }
    func pause(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested; tearDown()
    }
    func stop(generation requested: Int) {
        guard requested >= generation else { return }; generation = requested
        tearDown(); deactivateSession()
    }
    private func tearDown() {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
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
/// Single audio callback queue owns these accumulators; lock protects reconfiguration overlap.
private final class RMSReducer: @unchecked Sendable {
    private let lock = NSLock()
    private let windowFrames: Int
    private let continuation: AsyncStream<AudioLevelSample>.Continuation
    private var sum = 0.0
    private var count = 0
    init(sampleRate: Double, continuation: AsyncStream<AudioLevelSample>.Continuation) {
        windowFrames = max(1, Int(sampleRate * 0.25)); self.continuation = continuation
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        let channelCount = Int(buffer.format.channelCount)
        for index in 0..<Int(buffer.frameLength) {
            var energy = 0.0
            for channel in 0..<channelCount { let value = Double(channels[channel][index]); energy += value * value }
            sum += energy / Double(channelCount); count += 1
            if count >= windowFrames {
                let rms = sqrt(sum / Double(count))
                continuation.yield(AudioLevelSample(timestamp: Date(), dbFS: max(-100, 20 * log10(max(rms, 0.00001)))))
                count = 0; sum = 0
            }
        }
    }
}
