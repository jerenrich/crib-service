#if !canImport(MonitorCore)
import AVFoundation
import XCTest
@testable import BabyCryMonitor

final class BabyCryClassifierTests: XCTestCase {
    func testAppDeclaresBackgroundProcessingForBuiltInClassifier() throws {
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(modes.contains("audio"))
        XCTAssertTrue(modes.contains("processing"), "Physical iPhone testing reproduced operationFailed without this capability")
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SoundClassificationEvent] = []
        func append(_ event: SoundClassificationEvent) { lock.lock(); events.append(event); lock.unlock() }
        var scores: [SoundClassificationObservation] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .result(let score) = $0 { score } else { nil } }
        }
        var droppedBuffers: Int {
            lock.lock(); defer { lock.unlock() }
            return events.reduce(0) { sum, event in
                if case .droppedBuffers(let count, _) = event { return sum + count }
                return sum
            }
        }
        var unavailable: Bool {
            lock.lock(); defer { lock.unlock() }
            return events.contains { if case .unavailable = $0 { true } else { false } }
        }
        var startReasons: [SoundClassificationStartReason] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .started(_, _, _, _, let reason) = $0 { reason } else { nil } }
        }
    }
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(_ duration: Duration) { lock.lock(); instant = instant.advanced(by: duration); lock.unlock() }
    }
    private final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var stopped = 0
        private var failing = true
        private var analysisGate: DispatchSemaphore?
        private var gateClaimed = false
        private var enteredAnalysis = false
        var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return enteredAnalysis }
        func blockNextAnalysis() { lock.lock(); analysisGate = DispatchSemaphore(value: 0); gateClaimed = false; lock.unlock() }
        func releaseAnalysis() {
            lock.lock(); let gate = analysisGate; analysisGate = nil; lock.unlock(); gate?.signal()
        }
        private func beforeAnalysis() {
            lock.lock()
            let gate = gateClaimed ? nil : analysisGate
            if gate != nil { gateClaimed = true; enteredAnalysis = true }
            lock.unlock(); gate?.wait()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
        var stoppedCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
        func setHealthy() { lock.lock(); failing = false; lock.unlock() }
        func make(origin: Date, epoch: Int, control: SoundClassificationControl,
                  emit: @escaping @Sendable (SoundClassificationEvent) -> Void) -> any SoundClassifierStreaming {
            lock.lock(); attempts += 1; let fail = failing; lock.unlock()
            return Stream(origin: origin, epoch: epoch, control: control, emit: emit, failing: fail,
                          beforeAnalyze: { [self] in beforeAnalysis() }) { [self] in
                lock.lock(); stopped += 1; lock.unlock()
            }
        }
        private final class Stream: SoundClassifierStreaming {
            let id = UUID()
            var failure: SoundClassificationFailure?
            var hasProducedResult = false
            let origin: Date, epoch: Int, control: SoundClassificationControl
            let emit: @Sendable (SoundClassificationEvent) -> Void
            let failing: Bool
            let onStop: () -> Void
            let beforeAnalyze: () -> Void
            init(origin: Date, epoch: Int, control: SoundClassificationControl,
                 emit: @escaping @Sendable (SoundClassificationEvent) -> Void, failing: Bool,
                 beforeAnalyze: @escaping () -> Void, onStop: @escaping () -> Void) {
                self.origin = origin; self.epoch = epoch; self.control = control; self.emit = emit
                self.failing = failing; self.onStop = onStop; self.beforeAnalyze = beforeAnalyze
            }
            func analyze(_ buffer: AVAudioPCMBuffer) {
                beforeAnalyze()
                if failing { failure = .init(error: NSError(domain: "com.apple.SoundAnalysis", code: 2), stage: .analysis) }
                else if control.currentEpoch == epoch {
                    hasProducedResult = true
                    emit(.result(.init(captureID: id, windowStart: origin, windowEnd: origin.addingTimeInterval(2),
                                       confidence: 0.01, observedAt: Date())))
                }
            }
            func stop() { onStop() }
        }
    }
    func testHealthyForegroundTransitionsPreserveTheAnalysisWindow() async throws {
        let factory = Factory(), events = Events(), control = SoundClassificationControl()
        factory.setHealthy()
        let classifier = BabyCryClassifier(control: control, emit: events.append,
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        classifier.consume(buffer, at: .init(sampleTime: 0, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        let capture = events.scores.last?.captureID
        control.setAppActive(false); control.setAppActive(true)
        classifier.consume(buffer, at: .init(sampleTime: 1024, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        XCTAssertEqual(factory.count, 1)
        XCTAssertEqual(events.scores.last?.captureID, capture)
    }
    func testDelayedInvalidationCannotTearDownAResumedCapture() async throws {
        let factory = Factory(), events = Events(), control = SoundClassificationControl()
        factory.setHealthy()
        let classifier = BabyCryClassifier(control: control, emit: events.append,
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        classifier.consume(buffer, at: .init(sampleTime: 0, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        let oldEpoch = try XCTUnwrap(control.currentEpoch)
        control.setEnabled(false); control.setEnabled(true)
        classifier.consume(buffer, at: .init(sampleTime: 1024, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        let resumedID = events.scores.last?.captureID
        // Reproduce a reset notification delayed until after the new generation.
        classifier.invalidate(before: oldEpoch + 1)
        classifier.consume(buffer, at: .init(sampleTime: 2048, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        XCTAssertEqual(factory.count, 2)
        XCTAssertEqual(events.scores.last?.captureID, resumedID)
    }
    func testBufferOverflowDoesNotResetAlreadyQueuedContiguousAudio() async throws {
        let factory = Factory(), events = Events(), control = SoundClassificationControl()
        factory.setHealthy(); factory.blockNextAnalysis()
        let classifier = BabyCryClassifier(control: control, emit: events.append,
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { factory.releaseAnalysis(); classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        classifier.consume(buffer, at: .init(sampleTime: 0, atRate: 48_000), voiceProcessing: false)
        for _ in 0..<100 {
            if factory.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.isBlocked)
        for index in 1..<74 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1024), atRate: 48_000), voiceProcessing: false)
        }
        factory.releaseAnalysis(); await classifier.waitUntilIdle()
        XCTAssertEqual(factory.count, 1, "Future dropped input must not reset earlier queued audio")
        XCTAssertEqual(events.droppedBuffers, 0)
        classifier.consume(buffer, at: .init(sampleTime: 74 * 1024, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        XCTAssertEqual(factory.count, 2, "Reset once where the actual gap is encountered")
        XCTAssertEqual(events.droppedBuffers, 10)
    }
    func testStoppedInFlightFailureCannotPoisonItsReplacementControl() async throws {
        let factory = Factory(), events = Events(), control = SoundClassificationControl()
        factory.blockNextAnalysis()
        let classifier = BabyCryClassifier(control: control, emit: events.append,
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { factory.releaseAnalysis(); classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        classifier.consume(buffer, at: .init(sampleTime: 0, atRate: 48_000), voiceProcessing: false)
        for _ in 0..<100 {
            if factory.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.isBlocked)
        let epoch = control.currentEpoch
        classifier.stop(); factory.releaseAnalysis(); await classifier.waitUntilIdle()
        XCTAssertFalse(events.unavailable)
        control.setAppActive(false); control.setAppActive(true)
        XCTAssertEqual(control.currentEpoch, epoch, "An obsolete failure must not request recovery of the new pipeline")
    }
    func testHourOfFailuresAndInputGapsCannotRestartOnEveryBuffer() async throws {
        let clock = TestClock(), factory = Factory(), events = Events(), control = SoundClassificationControl()
        let classifier = BabyCryClassifier(control: control, emit: events.append, currentTime: { clock.now },
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true); control.setAppActive(false)
        var frame: AVAudioFramePosition = 0
        for index in 0..<14_400 {
            // Deliberate hardware discontinuities must NOT reset failure backoff.
            frame += index.isMultiple(of: 7) ? 2048 : 1024
            classifier.consume(buffer, at: .init(sampleTime: frame, atRate: 48_000), voiceProcessing: false)
            await classifier.waitUntilIdle()
            clock.advance(.milliseconds(250))
        }
        XCTAssertGreaterThan(factory.count, 110)
        XCTAssertLessThanOrEqual(factory.count, 125, "A persistent failure must not create thousands of model sessions")
        XCTAssertEqual(factory.count, factory.stoppedCount)
        XCTAssertTrue(events.scores.isEmpty)
        XCTAssertEqual(events.startReasons.first, .initial)
        XCTAssertTrue(events.startReasons.dropFirst().allSatisfy { $0 == .afterFailure },
                      "Audio gaps during backoff must preserve the logged failure-recovery reason")
        let count = factory.count
        factory.setHealthy()
        // Foregrounding must recover immediately, without waiting out a 30s retry.
        control.setAppActive(true)
        classifier.consume(buffer, at: .init(sampleTime: frame + 1024, atRate: 48_000), voiceProcessing: false)
        await classifier.waitUntilIdle()
        XCTAssertEqual(factory.count, count + 1)
        XCTAssertEqual(events.scores.count, 1)
        XCTAssertEqual(events.startReasons.last, .monitoringRestart)
    }
    func testInitializationFailuresRemainBackedOffDespiteSkippedFrames() async throws {
        let clock = TestClock(), factory = Factory(), events = Events(), control = SoundClassificationControl()
        let classifier = BabyCryClassifier(control: control, emit: events.append, currentTime: { clock.now },
            makeSession: { _, origin, epoch, control, emit in
                _ = factory.make(origin: origin, epoch: epoch, control: control, emit: emit)
                throw NSError(domain: "com.apple.SoundAnalysis", code: 4)
            })
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        for index in 0..<400 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 2048), atRate: 48_000), voiceProcessing: false)
            await classifier.waitUntilIdle(); clock.advance(.milliseconds(100))
        }
        XCTAssertEqual(factory.count, 6, "Expected attempts at 0,1,3,7,15,31 seconds, regardless of input gaps")
    }
    func testTenMinutesOfRealModelAudioAtDeviceFormatRemainContinuous() async throws {
        let events = Events(), control = SoundClassificationControl()
        let classifier = BabyCryClassifier(control: control, emit: events.append)
        defer { classifier.stop() }
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        for index in 0..<28_125 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1024), atRate: rate), voiceProcessing: false)
            await classifier.waitUntilIdle()
        }
        XCTAssertFalse(events.unavailable)
        XCTAssertGreaterThanOrEqual(events.scores.count, 595)
        XCTAssertEqual(Set(events.scores.map(\.captureID)).count, 1)
    }
    func testLiveBuffersProduceTimestampedScoresAndDisablingInvalidatesLateResults() async throws {
        let events = Events(), control = SoundClassificationControl()
        let classifier = BabyCryClassifier(control: control, emit: events.append)
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        control.setEnabled(true)
        for index in 0..<60 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: false)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where events.scores.isEmpty && !events.unavailable { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(events.unavailable, "The built-in model must accept live microphone-format buffers")
        let scores = events.scores
        XCTAssertFalse(scores.isEmpty)
        if let score = scores.first {
            XCTAssertTrue((0...1).contains(score.confidence))
            XCTAssertEqual(score.windowEnd.timeIntervalSince(score.windowStart), 2, accuracy: 0.001)
        }
        control.setEnabled(false)
        try await Task.sleep(for: .milliseconds(200))
        let count = events.scores.count
        for index in 60..<70 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: false)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.scores.count, count)
        control.setEnabled(true)
        for index in 100..<140 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: true)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where events.scores.count == count && !events.unavailable {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(events.scores.count, count)
        XCTAssertNotEqual(events.scores.last?.captureID, scores.first?.captureID,
                          "Resuming must start a fresh analysis window and capture identity")
    }
}
#endif
