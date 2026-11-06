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
        var failures: [SoundClassificationFailure] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .unavailable(_, let failure, _, _, _) = $0 { failure } else { nil } }
        }
        var retryDelays: [Int] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .unavailable(_, _, _, let delay, _) = $0 { delay } else { nil } }
        }
    }
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(_ duration: Duration) { lock.lock(); instant = instant.advanced(by: duration); lock.unlock() }
    }
    private final class Factory: @unchecked Sendable {
        enum ResultMode { case advancing, silent, repeated }
        private let lock = NSLock()
        private var attempts = 0
        private var stopped = 0
        private var failing = true
        private var resultMode = ResultMode.advancing
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
        func setResultMode(_ mode: ResultMode) { lock.lock(); resultMode = mode; lock.unlock() }
        func make(origin: Date, epoch: Int, control: SoundClassificationControl,
                  emit: @escaping @Sendable (SoundClassificationEvent) -> Void) -> any SoundClassifierStreaming {
            lock.lock(); attempts += 1; let fail = failing; lock.unlock()
            return Stream(origin: origin, epoch: epoch, control: control, emit: emit, failing: fail,
                          resultMode: { [self] in lock.lock(); defer { lock.unlock() }; return resultMode },
                          beforeAnalyze: { [self] in beforeAnalysis() }) { [self] in
                lock.lock(); stopped += 1; lock.unlock()
            }
        }
        private final class Stream: SoundClassifierStreaming {
            let id = UUID()
            var failure: SoundClassificationFailure?
            var latestResultWindowEnd: TimeInterval?
            let origin: Date, epoch: Int, control: SoundClassificationControl
            let emit: @Sendable (SoundClassificationEvent) -> Void
            let failing: Bool
            let onStop: () -> Void
            let beforeAnalyze: () -> Void
            let resultMode: () -> ResultMode
            init(origin: Date, epoch: Int, control: SoundClassificationControl,
                 emit: @escaping @Sendable (SoundClassificationEvent) -> Void, failing: Bool,
                 resultMode: @escaping () -> ResultMode,
                 beforeAnalyze: @escaping () -> Void, onStop: @escaping () -> Void) {
                self.origin = origin; self.epoch = epoch; self.control = control; self.emit = emit
                self.failing = failing; self.onStop = onStop; self.beforeAnalyze = beforeAnalyze
                self.resultMode = resultMode
            }
            func analyze(_ buffer: AVAudioPCMBuffer, capturedAt: Date) {
                beforeAnalyze()
                if failing { failure = .init(error: NSError(domain: "com.apple.SoundAnalysis", code: 2), stage: .analysis) }
                else if control.currentEpoch == epoch {
                    let mode = resultMode()
                    guard mode != .silent else { return }
                    if latestResultWindowEnd == nil || mode == .advancing {
                        latestResultWindowEnd = (latestResultWindowEnd ?? 3) + 1
                    }
                    let end = latestResultWindowEnd!
                    emit(.result(.init(captureID: id, windowStart: origin.addingTimeInterval(end - 4), windowEnd: origin.addingTimeInterval(end),
                                       confidence: 0.01, observedAt: Date(), audioWindowEndAt: capturedAt)))
                }
            }
            func stop() { onStop() }
        }
    }
    private struct StallFixture {
        let clock = TestClock(), factory = Factory(), events = Events(), control = SoundClassificationControl()
        let classifier: BabyCryClassifier
        let buffer: AVAudioPCMBuffer
        private var frame: AVAudioFramePosition = 0
        init() throws {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
            factory.setHealthy(); control.setEnabled(true)
            classifier = BabyCryClassifier(control: control, emit: events.append, currentTime: { [clock] in clock.now },
                makeSession: { [factory] _, origin, epoch, control, emit in
                    factory.make(origin: origin, epoch: epoch, control: control, emit: emit)
                })
        }
        mutating func feed(after duration: Duration = .zero, gap: Bool = false) async {
            clock.advance(duration)
            if gap { frame += 1024 }
            classifier.consume(buffer, at: .init(sampleTime: frame, atRate: 48_000), voiceProcessing: false)
            frame += 1024
            await classifier.waitUntilIdle()
        }
    }

    func testMissingFirstResultTimesOutAndRepeatedStallsBackOffAcrossInputGaps() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        s.factory.setResultMode(.silent)
        await s.feed()
        await s.feed(after: .milliseconds(9_999))
        XCTAssertFalse(s.events.unavailable, "Allow model startup before declaring a stall")
        await s.feed(after: .milliseconds(1))
        XCTAssertEqual(s.factory.stoppedCount, 1)
        XCTAssertEqual(s.events.retryDelays, [1])
        let startup = try XCTUnwrap(s.events.failures.last?.stallContext)
        XCTAssertEqual(startup.timeoutMS, 10_000)
        XCTAssertEqual(startup.sessionAgeMS, 10_000)
        XCTAssertEqual(startup.noProgressMS, 10_000)
        XCTAssertEqual(startup.inputBuffers, 3)
        XCTAssertEqual(startup.receivedAudioMS, 64)
        XCTAssertNil(startup.lastResultWindowEndMS)
        await s.feed(after: .milliseconds(999), gap: true)
        XCTAssertEqual(s.factory.count, 1, "A hardware gap must not bypass stall backoff")
        await s.feed(after: .milliseconds(1))
        XCTAssertEqual(s.factory.count, 2)
        await s.feed(after: .seconds(10))
        XCTAssertEqual(s.events.retryDelays, [1, 2])
        await s.feed(after: .milliseconds(1_999), gap: true)
        XCTAssertEqual(s.factory.count, 2)
        await s.feed(after: .milliseconds(1))
        XCTAssertEqual(s.factory.count, 3)
        XCTAssertEqual(s.events.startReasons, [.initial, .afterFailure, .afterFailure])
    }

    func testPreviouslySuccessfulClassifierCannotStayHealthyWithoutNewResults() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        await s.feed()
        let capture = try XCTUnwrap(s.events.scores.last?.captureID)
        s.factory.setResultMode(.silent)
        await s.feed(after: .milliseconds(9_999))
        XCTAssertFalse(s.events.unavailable)
        await s.feed(after: .milliseconds(1))
        XCTAssertEqual(s.factory.stoppedCount, 1)
        XCTAssertEqual(s.events.failures.last?.captureID, capture)
        XCTAssertEqual(s.events.failures.last?.reason, .resultTimeout)
        XCTAssertEqual(s.events.failures.last?.stallContext?.lastResultWindowEndMS, 4_000)
        XCTAssertEqual(s.events.retryDelays, [1])
        s.factory.setResultMode(.advancing)
        await s.feed(after: .seconds(1))
        XCTAssertEqual(s.factory.count, 2)
        XCTAssertNotEqual(s.events.scores.last?.captureID, capture)
        s.factory.setResultMode(.silent)
        await s.feed(after: .seconds(10))
        XCTAssertEqual(s.events.retryDelays, [1, 1], "Fresh results reset the failure streak")
    }

    func testRepeatedWindowCallbacksCannotKeepAStalledClassifierAlive() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        await s.feed()
        s.factory.setResultMode(.repeated)
        for _ in 0..<10 { await s.feed(after: .seconds(1)) }
        XCTAssertEqual(s.events.scores.count, 11, "Callbacks alone do not prove advancing audio")
        XCTAssertEqual(s.factory.stoppedCount, 1)
        XCTAssertEqual(s.events.retryDelays, [1])
    }

    func testWatchdogDoesNotRunWithoutMoreMicrophoneInput() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        s.factory.setResultMode(.silent)
        await s.feed()
        s.clock.advance(.seconds(60))
        await s.classifier.waitUntilIdle()
        XCTAssertFalse(s.events.unavailable)
        XCTAssertEqual(s.factory.count, 1)
        XCTAssertEqual(s.factory.stoppedCount, 0)
        await s.feed()
        XCTAssertEqual(s.events.retryDelays, [1], "Check the expired deadline only when input resumes")
    }

    func testAdvancingQuietResultsKeepWatchdogHealthyAcrossForegroundTransitions() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        await s.feed()
        for index in 0..<30 {
            s.control.setAppActive(index.isMultiple(of: 2))
            await s.feed(after: .seconds(1))
        }
        XCTAssertTrue(s.events.scores.allSatisfy { $0.confidence < CryConfidenceDetector.threshold })
        XCTAssertFalse(s.events.unavailable)
        XCTAssertEqual(s.factory.count, 1)
        XCTAssertEqual(s.factory.stoppedCount, 0)
    }

    func testAudioGapAndMonitoringRestartGiveReplacementItsOwnStartupDeadline() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        s.factory.setResultMode(.silent)
        await s.feed()
        await s.feed(after: .seconds(9), gap: true)
        await s.feed(after: .seconds(9))
        XCTAssertFalse(s.events.unavailable)
        s.control.setEnabled(false); await s.classifier.waitUntilIdle()
        s.clock.advance(.seconds(60))
        await s.feed()
        XCTAssertEqual(s.factory.count, 2, "Disabled capture must not run a watchdog or retry")
        s.control.setEnabled(true)
        await s.feed()
        await s.feed(after: .milliseconds(9_999))
        XCTAssertFalse(s.events.unavailable)
        await s.feed(after: .milliseconds(1))
        XCTAssertEqual(s.events.retryDelays, [1])
        XCTAssertEqual(s.events.startReasons, [.initial, .audioGap, .monitoringRestart])
    }

    func testForegroundCanRecoverAStallImmediatelyAndStopCannotRestartIt() async throws {
        var s = try StallFixture(); defer { s.classifier.stop() }
        s.control.setAppActive(false); s.factory.setResultMode(.silent)
        await s.feed()
        await s.feed(after: .seconds(10))
        s.control.setAppActive(true); s.factory.setResultMode(.advancing)
        await s.feed()
        XCTAssertEqual(s.factory.count, 2, "Foreground recovery need not wait for the pending retry")
        XCTAssertEqual(s.events.startReasons.last, .monitoringRestart)
        s.classifier.stop(); await s.classifier.waitUntilIdle()
        await s.feed(after: .seconds(60))
        XCTAssertEqual(s.factory.count, 2)
        XCTAssertEqual(s.events.retryDelays, [1])
    }
    func testQueuedInferenceKeepsItsOriginalAudioCaptureStamp() async throws {
        let factory = Factory(), events = Events(), control = SoundClassificationControl()
        factory.setHealthy(); factory.blockNextAnalysis()
        let classifier = BabyCryClassifier(control: control, emit: events.append,
            makeSession: { _, origin, epoch, control, emit in factory.make(origin: origin, epoch: epoch, control: control, emit: emit) })
        defer { factory.releaseAnalysis(); classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        control.setEnabled(true)
        let submittedAt = Date()
        classifier.consume(buffer, at: .init(sampleTime: 0, atRate: 48_000), voiceProcessing: false)
        for _ in 0..<100 {
            if factory.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.isBlocked)
        let releasedAt = Date()
        factory.releaseAnalysis(); await classifier.waitUntilIdle()
        let score = try XCTUnwrap(events.scores.first)
        let captured = try XCTUnwrap(score.audioWindowEndAt)
        XCTAssertGreaterThanOrEqual(captured, submittedAt)
        XCTAssertLessThan(captured, releasedAt)
        XCTAssertGreaterThanOrEqual(score.observedAt, releasedAt)
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
        XCTAssertTrue(events.scores.allSatisfy { $0.audioWindowEndAt != nil })
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
        XCTAssertGreaterThanOrEqual(scores.count, 2, "Four-second windows must still produce one result per second")
        for (previous, next) in zip(scores, scores.dropFirst()) {
            XCTAssertEqual(next.windowEnd.timeIntervalSince(previous.windowEnd), 1, accuracy: 0.001)
        }
        if let score = scores.first {
            XCTAssertTrue((0...1).contains(score.confidence))
            XCTAssertEqual(score.windowEnd.timeIntervalSince(score.windowStart), 4, accuracy: 0.001)
            let captured = try XCTUnwrap(score.audioWindowEndAt)
            XCTAssertLessThanOrEqual(captured, score.observedAt)
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
        for index in 100..<160 {
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
