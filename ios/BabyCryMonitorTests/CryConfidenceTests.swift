import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class CryConfidenceTests: XCTestCase {
    struct Simulation {
        var engine = CrySessionManager()
        let origin = Date(timeIntervalSince1970: 1000)
        let listener = UUID()
        var capture = UUID()
        var elapsed = 0.0
        var alerts: [CryAlert] = []
        init(duration: Double = 5) {
            var config = MonitoringConfiguration(); config.alertDuration = duration
            engine.configure(config)
            startCapture()
        }
        func date(_ second: Double) -> Date { origin.addingTimeInterval(second) }
        mutating func levels(to end: Double, dbfs: Double = -80) {
            while elapsed < end {
                elapsed += 0.25
                alerts += engine.consume(.init(timestamp: date(elapsed), dbFS: dbfs), listenerId: listener)
            }
        }
        mutating func startCapture(at second: Double = 0) {
            alerts += engine.consumeClassification(.started(id: capture, at: date(second), sampleRate: 48_000,
                voiceProcessing: false), at: date(second), listenerId: listener)
        }
        mutating func score(_ confidence: Double = 0.6, end: Double, volume: Double = -80,
                            observed: Double? = nil, captureID: UUID? = nil, captured: Double? = nil) {
            let now = observed ?? end
            levels(to: now, dbfs: volume)
            alerts += engine.consumeClassification(.result(.init(captureID: captureID ?? capture,
                windowStart: date(end - 4), windowEnd: date(end), confidence: confidence, observedAt: date(now),
                audioWindowEndAt: captured.map(date))),
                at: date(now), listenerId: listener)
        }
        mutating func classifierOnlyScore(_ confidence: Double, end: Double) {
            alerts += engine.consumeClassification(.result(.init(captureID: capture,
                windowStart: date(end - 4), windowEnd: date(end), confidence: confidence,
                observedAt: date(end), audioWindowEndAt: date(end))), at: date(end), listenerId: listener)
        }
    }

    func testStaleVolumeCannotLatchAnEpisodeOrSuppressALaterClassifierCry() throws {
        var s = Simulation()
        s.levels(to: 6, dbfs: -20)
        let first = try XCTUnwrap(s.engine.snapshot.current?.id)
        XCTAssertEqual(s.alerts.count, 1)
        for end in 7...90 { s.classifierOnlyScore(0, end: Double(end)) }
        XCTAssertEqual(s.engine.detector.state, .quiet)
        XCTAssertEqual(s.engine.state, .quiet)
        XCTAssertNil(s.engine.snapshot.current)
        XCTAssertEqual(s.engine.snapshot.history.first?.id, first)
        XCTAssertEqual(s.engine.snapshot.history.first?.quietConfirmed, false, "Missing RMS is an interruption, not proof of quiet")
        for end in 91...94 { s.classifierOnlyScore(0.95, end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 2)
        XCTAssertNotEqual(s.engine.snapshot.current?.id, first)
        XCTAssertEqual(s.alerts.last?.createdAt, s.date(94))
    }

    func testClassifierHandoffAcrossVolumeLossStillQuietResolvesExactlyOnce() throws {
        var s = Simulation()
        s.levels(to: 6, dbfs: -20)
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        for end in 7...15 { s.classifierOnlyScore(0.95, end: Double(end)) }
        XCTAssertEqual(s.engine.detector.state, .quiet)
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertEqual(s.alerts.count, 1)
        for end in 16...35 { s.classifierOnlyScore(0, end: Double(end)) }
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        s.classifierOnlyScore(0, end: 36)
        XCTAssertNil(s.engine.snapshot.current)
        XCTAssertEqual(s.engine.snapshot.history.count, 1)
        XCTAssertEqual(s.engine.snapshot.history.first?.quietConfirmed, true)
        s.elapsed = 36; s.levels(to: 37)
        XCTAssertEqual(s.engine.snapshot.history.count, 1)
        XCTAssertEqual(s.engine.snapshot.history.first?.quietConfirmed, true)
    }

    func testSuspensionAndRelaunchUsePersistedClassifierInputWithoutChangingRMSContinuity() throws {
        var s = Simulation()
        s.levels(to: 1)
        for end in 24...27 { s.classifierOnlyScore(0.95, end: Double(end)) }
        XCTAssertEqual(s.engine.snapshot.lastObservedAt, s.date(1))
        XCTAssertEqual(s.engine.snapshot.lastDetectionAt, s.date(27))
        let data = try JSONEncoder().encode(s.engine.snapshot)
        var restored = CrySessionManager(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
        restored.recoverAfterRelaunch()
        s.engine.suspend()
        for snapshot in [restored.snapshot, s.engine.snapshot] {
            XCTAssertEqual(snapshot.history.first?.startedAt, s.date(20))
            XCTAssertEqual(snapshot.history.first?.endedAt, s.date(27))
            XCTAssertEqual(snapshot.history.first?.quietConfirmed, false)
            XCTAssertEqual(snapshot.pending.count, 1)
            XCTAssertEqual(snapshot.timelineEvents.first { $0.kind == "cry_ended" }?.occurredAt, s.date(27))
        }
        XCTAssertNil(restored.snapshot.lastObservedAt)
        XCTAssertNil(restored.snapshot.lastDetectionAt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "lastDetectionAt")
        XCTAssertNil(try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).lastDetectionAt)
    }

    func testInvalidClassifierInputCannotMoveThePersistedEpisodeEnd() {
        var s = Simulation()
        for end in 4...5 { s.classifierOnlyScore(0.95, end: Double(end)) }
        _ = s.engine.consumeClassification(.result(.init(captureID: UUID(), windowStart: s.date(98),
            windowEnd: s.date(100), confidence: 1, observedAt: s.date(100), audioWindowEndAt: s.date(100))),
            at: s.date(100), listenerId: s.listener)
        XCTAssertEqual(s.engine.snapshot.lastDetectionAt, s.date(5))
        s.engine.suspend()
        XCTAssertLessThanOrEqual(s.engine.snapshot.history[0].endedAt!, s.date(5))
    }

    func testEarlierClassifierConfirmationCorrectsAnAlreadyPublishedVolumeOnset() throws {
        var s = Simulation(duration: 30)
        for end in 4...29 { s.score(0.95, end: Double(end), volume: end <= 20 ? -80 : -20, captured: Double(end)) }
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        let journalID = "cry:\(id.uuidString.lowercased())"
        XCTAssertEqual(s.engine.snapshot.current?.startedAt, s.date(20.25))
        s.engine.uploadedTimeline([journalID])
        s.score(0.95, end: 30, volume: -20, captured: 30)
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertEqual(s.engine.snapshot.current?.startedAt, s.origin)
        XCTAssertEqual(s.engine.snapshot.timelineEvents.first { $0.id == journalID }?.occurredAt, s.origin)
        let alert = try XCTUnwrap(s.alerts.first)
        XCTAssertEqual(alert.cryStartedAt, s.origin)
        XCTAssertEqual(alert.durationSeconds, alert.createdAt.timeIntervalSince(alert.cryStartedAt))
    }

    func testEventOverflowReplaysCaptureIdentityAndRequiresFreshPostGapAudio() async {
        let s = Simulation(), pair = AsyncStream<SoundClassificationEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let at = s.date(80)
        let delivery = SoundClassificationEventDelivery(pair.continuation, currentTime: { at })
        delivery.emit(.started(id: s.capture, at: s.origin, sampleRate: 48_000, voiceProcessing: false))
        for end in 4...80 {
            delivery.emit(.result(.init(captureID: s.capture, windowStart: s.date(Double(end - 4)),
                windowEnd: s.date(Double(end)), confidence: 1, observedAt: s.date(Double(end)), audioWindowEndAt: s.date(Double(end)))))
        }
        pair.continuation.finish()
        var engine = CrySessionManager(), gaps = 0
        for await event in pair.stream {
            if case .droppedEvents = event { gaps += 1 }
            _ = engine.consumeClassification(event, at: at, listenerId: s.listener)
        }
        XCTAssertGreaterThan(gaps, 0)
        XCTAssertEqual(engine.confidenceDetector.captureID, s.capture)
        XCTAssertTrue(engine.snapshot.pending.isEmpty)
        for end in 81...84 {
            _ = engine.consumeClassification(.result(.init(captureID: s.capture,
                windowStart: s.date(Double(end - 4)), windowEnd: s.date(Double(end)), confidence: 1,
                observedAt: s.date(Double(end)), audioWindowEndAt: s.date(Double(end)))),
                at: s.date(Double(end)), listenerId: s.listener)
            XCTAssertTrue(engine.snapshot.pending.isEmpty)
        }
        _ = engine.consumeClassification(.result(.init(captureID: s.capture, windowStart: s.date(81),
            windowEnd: s.date(85), confidence: 1, observedAt: s.date(85), audioWindowEndAt: s.date(85))),
            at: s.date(85), listenerId: s.listener)
        XCTAssertEqual(engine.snapshot.pending.count, 1)
        XCTAssertEqual(engine.snapshot.pending.first?.alert.cryStartedAt, s.date(80))
    }

    func testOverflowDoesNotResurrectStoppedOrFailedCapture() async {
        for failed in [false, true] {
            let s = Simulation(), pair = AsyncStream<SoundClassificationEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
            let at = s.date(10)
            let delivery = SoundClassificationEventDelivery(pair.continuation, currentTime: { at })
            delivery.emit(.started(id: s.capture, at: s.origin, sampleRate: 48_000, voiceProcessing: false))
            for _ in 0..<10 { delivery.emit(.droppedBuffers(count: 1, at: at)) }
            delivery.emit(failed ? .unavailable(at: at, captureID: s.capture) : .stopped(id: s.capture, at: at))
            pair.continuation.finish()
            var engine = CrySessionManager()
            for await event in pair.stream { _ = engine.consumeClassification(event, at: at, listenerId: s.listener) }
            XCTAssertNil(engine.confidenceDetector.captureID)
        }
    }

    func testOnlyFreshValidatedInputTimestampsProveMicrophoneLiveness() {
        var s = Simulation()
        s.score(0, end: 4)
        XCTAssertNil(s.engine.latestClassifierInputAt, "An inferred sample-clock date is not input evidence")
        s.score(0, end: 5, captured: 5)
        XCTAssertEqual(s.engine.latestClassifierInputAt, s.date(5), "Quiet audio also proves capture is alive")
        s.score(1, end: 6, captureID: UUID(), captured: 6)
        s.score(.nan, end: 6, captured: 6)
        s.score(1, end: 4, observed: 6, captured: 6)
        s.score(1, end: 6, observed: 10, captured: 6)
        s.score(1, end: 7, observed: 10, captured: 12)
        XCTAssertEqual(s.engine.latestClassifierInputAt, s.date(5), "Foreign, invalid, reordered, stale and future input must not postpone a stall")
        s.score(0, end: 10, captured: 10)
        XCTAssertEqual(s.engine.latestClassifierInputAt, s.date(10))
    }

    func testGapRecoveryUsesMappedInputTimeWithEitherDirectionOfClockDrift() {
        for offset in [-4.0, 4.0] {
            for bufferGap in [false, true] {
                var s = Simulation()
                s.score(0, end: 104 + offset, observed: 104, captured: 104)
                let gap: SoundClassificationEvent = bufferGap
                    ? .droppedBuffers(count: 1, at: s.date(104)) : .droppedEvents(at: s.date(104))
                _ = s.engine.consumeClassification(gap, at: s.date(104), listenerId: s.listener)
                for now in 105...108 {
                    s.score(1, end: Double(now) + offset, observed: Double(now), captured: Double(now))
                    XCTAssertTrue(s.alerts.isEmpty, "A window crossing the gap cannot count toward the timer")
                }
                s.score(1, end: 109 + offset, observed: 109, captured: 109)
                XCTAssertEqual(s.alerts.count, 1, "Fresh post-gap audio must qualify despite sample-clock drift")
                XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(104))
                XCTAssertEqual(s.alerts.first?.createdAt, s.date(109))
            }
        }
    }

    func testEvictedOldWindowAndRetiredCaptureCannotInterruptNewerEvidence() {
        var clock = SoundClassificationAudioClock(sampleRate: 48_000)
        for frame in 1...1200 { clock.receive(through: Int64(frame * 1024), at: Date(timeIntervalSince1970: Double(frame))) }
        XCTAssertNil(clock.capturedWindowEnd(at: 1), "Reproduce an old callback whose input anchor was evicted")
        var s = Simulation()
        s.score(end: 24, captured: 24)
        for (id, end) in [(s.capture, 1.0), (s.capture, 24.0), (UUID(), 25.0)] {
            _ = s.engine.consumeClassification(.unmappedResult(captureID: id, windowEnd: s.date(end), at: s.date(24)),
                at: s.date(24), listenerId: s.listener)
        }
        s.score(end: 25, captured: 25)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(20))
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(25))
    }

    func testUnmappedNewWindowStillRequiresACompletePostGapStreak() {
        var s = Simulation()
        s.score(end: 4, captured: 4)
        _ = s.engine.consumeClassification(.unmappedResult(captureID: s.capture, windowEnd: s.date(5), at: s.date(5)),
            at: s.date(5), listenerId: s.listener)
        XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
        for end in 6...9 { s.score(end: Double(end), captured: Double(end)); XCTAssertTrue(s.alerts.isEmpty) }
        s.score(end: 10, captured: 10)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(5))
    }

    func testSixtyPercentConfidenceRequiresFullWindowEvenBelowVolumeThreshold() throws {
        var s = Simulation()
        s.score(end: 4); XCTAssertTrue(s.alerts.isEmpty)
        s.levels(to: 4.75)
        XCTAssertTrue(s.alerts.isEmpty, "The first four-second result cannot complete a five-second observation")
        s.score(end: 5)
        let alert = try XCTUnwrap(s.alerts.first)
        XCTAssertEqual(alert.createdAt, s.date(5)); XCTAssertEqual(alert.cryStartedAt, s.origin)
        XCTAssertEqual(s.engine.detector.state, .quiet)
        XCTAssertEqual(s.engine.state, .crying)
        XCTAssertEqual(s.engine.lastAlertTrigger, .classifier)
        for end in 6...40 { s.score(0.99, end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 1, "The server, rather than either detector, owns reminders")
    }

    func testTwoSecondResultsCannotQualifyInAFourSecondCapture() {
        var s = Simulation()
        for end in 4...12 {
            let now = s.date(Double(end))
            let alerts = s.engine.consumeClassification(.result(.init(captureID: s.capture,
                windowStart: now.addingTimeInterval(-2), windowEnd: now,
                confidence: 1, observedAt: now, audioWindowEndAt: now)), at: now, listenerId: s.listener)
            XCTAssertTrue(alerts.isEmpty)
        }
        XCTAssertNil(s.engine.latestClassifierInputAt, "Invalid window lengths cannot prove microphone liveness")
        XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
    }

    func testScoresBelowSixtyPercentCannotTriggerClassifier() {
        var s = Simulation()
        for end in 4...30 { s.score(0.6.nextDown, end: Double(end)) }
        XCTAssertTrue(s.alerts.isEmpty)
        XCTAssertEqual(s.engine.state, .quiet)
    }

    func testClassifierUsesConfiguredDurationAndDoesNotDoubleCountOverlappingWindows() {
        var s = Simulation(duration: 30)
        for end in 4...29 { s.score(0.99, end: Double(end)) }
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(0.99, end: 30)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.durationSeconds, 30)
    }

    func testOneLowSecondUsesToleranceInsteadOfRestartingTheWindow() {
        var s = Simulation()
        s.score(end: 4); s.score(0.6.nextDown, end: 5)
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 6)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.origin)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(6))
    }

    func testTwoLowSecondsCannotQualifyAFiveSecondWindow() {
        var s = Simulation()
        s.score(end: 4); s.score(0.59, end: 5); s.score(0.59, end: 6); s.score(end: 7)
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 8); s.score(end: 9)
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 10)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(10))
    }

    func testOccasionalDipsDoNotPreventALongerClassifierAlert() {
        var s = Simulation(duration: 30)
        for end in 4...29 { s.score(end == 20 ? 0.59 : 0.95, end: Double(end)) }
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(0.95, end: 30)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(30))
    }

    func testOldClassifierBurstNeedsRecentSustainedActivityAndAPositiveLatestResult() {
        var s = Simulation(duration: 30)
        for end in 4...25 { s.score(end: Double(end)) }
        for end in 26...30 { s.score(0, end: Double(end)) }
        XCTAssertTrue(s.alerts.isEmpty, "80% historical coverage is insufficient while settled")
        s.score(end: 31)
        XCTAssertTrue(s.alerts.isEmpty, "One new high score cannot spend old evidence")
        for end in 32...34 { s.score(end: Double(end)) }
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(34))
    }

    func testSparseHighScoresCannotPreserveAnAlertedClassifierEpisode() {
        var s = Simulation()
        for end in 4...6 { s.score(end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 1)
        for end in 7...90 { s.score(end % 15 == 6 ? 0.95 : 0, end: Double(end)) }
        XCTAssertNil(s.engine.snapshot.current)
        XCTAssertEqual(s.engine.snapshot.history.count, 1)
        for end in 91...97 { s.score(end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 2)
    }

    func testMissingResultDoesNotCountAsContinuousHighConfidence() {
        var s = Simulation()
        s.score(end: 4)
        // Skip the result ending at 5; the first replacement window spans 2...6.
        s.score(end: 6); XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 7)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(2))
    }

    func testResultSilenceExpiresProgressWithoutAnotherCallback() {
        var s = Simulation()
        s.score(end: 4)
        s.levels(to: 10)
        XCTAssertEqual(s.engine.state, .quiet)
        s.score(end: 14); XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 15)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(10))
    }

    func testStaleFutureInvalidAndOldCaptureResultsCannotAlert() {
        for confidence in [Double.nan, .infinity, -0.1, 1.1] {
            var s = Simulation()
            for end in 4...8 { s.score(confidence, end: Double(end)) }
            XCTAssertTrue(s.alerts.isEmpty)
        }
        var stale = Simulation()
        for end in 4...8 { stale.score(1, end: Double(end), observed: Double(end + 10)) }
        XCTAssertTrue(stale.alerts.isEmpty)
        var future = Simulation()
        for end in 4...8 { future.score(1, end: Double(end + 10), observed: Double(end)) }
        XCTAssertTrue(future.alerts.isEmpty)
        var foreign = Simulation()
        for end in 4...8 { foreign.score(1, end: Double(end), captureID: UUID()) }
        XCTAssertTrue(foreign.alerts.isEmpty)
    }

    func testDuplicateAndOutOfOrderWindowsDoNotAccumulateTimeOrResetNewEvidence() {
        var s = Simulation()
        s.score(end: 4)
        for _ in 0..<10 { s.score(0, end: 4, observed: 4) }
        XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 5)
        XCTAssertEqual(s.alerts.count, 1)
    }

    func testLongCaptureAudioClockDriftDoesNotDisableFreshClassifierResults() {
        var s = Simulation()
        for second in 4...40 {
            let now = Double(second), audioEnd = now + Double(second - 2) * 0.05
            s.score(0.9, end: audioEnd, observed: now, captured: now)
        }
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.engine.state, .crying)
        XCTAssertEqual(s.engine.quietSince, nil)
        XCTAssertLessThanOrEqual(s.alerts[0].cryStartedAt, s.alerts[0].createdAt)
    }

    func testCallbackThatWaitedTooLongForHandlingCannotExtendAStreak() {
        var s = Simulation()
        s.score(end: 4)
        s.levels(to: 10)
        let delayed = SoundClassificationObservation(captureID: s.capture, windowStart: s.date(1),
            windowEnd: s.date(5), confidence: 1, observedAt: s.date(5))
        let events = s.engine.consumeClassification(.result(delayed), at: s.date(10), listenerId: s.listener)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
    }

    func testShortDisjointWindowsCannotClaimFiveSecondsOfCoveredAudio() {
        var s = Simulation()
        for second in 2...10 {
            s.levels(to: Double(second))
            let score = SoundClassificationObservation(captureID: s.capture,
                windowStart: s.date(Double(second) - 0.1), windowEnd: s.date(Double(second)), confidence: 1,
                observedAt: s.date(Double(second)))
            let events = s.engine.consumeClassification(.result(score), at: s.date(Double(second)), listenerId: s.listener)
            XCTAssertTrue(events.isEmpty)
        }
        XCTAssertEqual(s.engine.state, .quiet)
    }

    func testNewCaptureCannotCarryOverItsPredecessorsStreak() {
        var s = Simulation()
        s.score(end: 4)
        let old = s.capture
        s.capture = UUID(); s.startCapture(at: 4)
        s.score(1, end: 4, captureID: old)
        _ = s.engine.consumeClassification(.stopped(id: old, at: s.date(4)), at: s.date(4), listenerId: s.listener)
        s.score(end: 8); XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 9)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(4))
    }

    func testClassifierFailureAndDroppedEventsBreakOnlyClassifierProgress() {
        for event in [SoundClassificationEvent.unavailable(at: Date(timeIntervalSince1970: 1004)),
                      .droppedEvents(at: Date(timeIntervalSince1970: 1004)),
                      .droppedBuffers(count: 1, at: Date(timeIntervalSince1970: 1004))] {
            var s = Simulation()
            s.score(end: 4)
            _ = s.engine.consumeClassification(event, at: s.date(4), listenerId: s.listener)
            XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
            s.levels(to: 10, dbfs: -20)
            XCTAssertEqual(s.alerts.count, 1)
            XCTAssertEqual(s.engine.lastAlertTrigger, .volume)
        }
    }

    func testLowConfidenceCannotSuppressVolumeAlerts() {
        var s = Simulation()
        for end in 4...8 { s.score(0, end: Double(end), volume: -20) }
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(5.25))
        XCTAssertEqual(s.engine.lastAlertTrigger, .volume)
    }

    func testClassifierThenVolumeShareOneEpisodeAndOneInitialAlert() throws {
        var s = Simulation()
        for end in 4...6 { s.score(end: Double(end), volume: -20) }
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.engine.lastAlertTrigger, .classifier)
        s.levels(to: 15, dbfs: -20)
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertEqual(s.engine.snapshot.pending.count, 1)
        XCTAssertEqual(s.alerts.count, 1)
    }

    func testVolumeThenClassifierShareOneEpisodeAndOneInitialAlert() throws {
        var s = Simulation()
        s.levels(to: 6, dbfs: -20)
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        for end in 8...14 { s.score(end: Double(end)) }
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.engine.lastAlertTrigger, .volume)
    }

    func testDetectorsCannotCombinePartialTimersToCreateAnEarlyAlert() {
        var s = Simulation(duration: 10)
        s.levels(to: 6, dbfs: -20)
        for end in 10...15 { s.score(end: Double(end)); XCTAssertTrue(s.alerts.isEmpty) }
        s.score(end: 16)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(16))
    }

    func testLongClassifierTimerKeepsAnAlreadyAlertedVolumeEpisodeWithoutAlertingAgain() throws {
        var s = Simulation(duration: 60)
        s.levels(to: 61, dbfs: -20)
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        XCTAssertEqual(s.alerts.count, 1)
        // Volume quiet resets before this classifier's independent minute is
        // complete. Its positive evidence must keep the existing episode alive.
        for end in 63...125 { s.score(end: Double(end)) }
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertTrue(s.engine.snapshot.history.isEmpty)
        XCTAssertEqual(s.alerts.count, 1)
        for end in 126...146 { s.score(0, end: Double(end)) }
        XCTAssertNil(s.engine.snapshot.current)
        XCTAssertEqual(s.engine.snapshot.history.first?.id, id)
    }

    func testQuietVolumeCannotResolveAClassifierEpisodeAndBothMustSettle() throws {
        var s = Simulation()
        for end in 4...35 { s.score(end: Double(end)) }
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        XCTAssertEqual(s.engine.state, .crying)
        XCTAssertTrue(s.engine.snapshot.history.isEmpty)
        for end in 36...55 { s.score(0, end: Double(end)) }
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        s.score(0, end: 56)
        XCTAssertNil(s.engine.snapshot.current)
        XCTAssertEqual(s.engine.snapshot.history.first?.id, id)
        XCTAssertEqual(s.engine.snapshot.history.first?.quietConfirmed, true)
        for end in 57...60 { s.score(end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 2)
        XCTAssertNotEqual(s.engine.snapshot.current?.id, id)
    }

    func testMissingClassifierEventuallyReleasesItsEpisodeButLoudVolumeKeepsIt() {
        var s = Simulation()
        for end in 4...5 { s.score(end: Double(end)) }
        s.levels(to: 24.75)
        XCTAssertNotNil(s.engine.snapshot.current)
        s.levels(to: 25)
        XCTAssertNil(s.engine.snapshot.current)
        var loud = Simulation()
        for end in 4...5 { loud.score(end: Double(end), volume: -20) }
        loud.levels(to: 35, dbfs: -20)
        XCTAssertEqual(loud.engine.state, .crying)
        XCTAssertNotNil(loud.engine.snapshot.current)
        XCTAssertEqual(loud.alerts.count, 1)
    }

    func testSuspendAndRelaunchResetClassifierProgressAndPreserveOutbox() throws {
        var s = Simulation()
        for end in 4...5 { s.score(end: Double(end)) }
        let saved = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(s.engine.snapshot))
        var recovered = CrySessionManager(snapshot: saved)
        recovered.recoverAfterRelaunch()
        XCTAssertEqual(recovered.state, .quiet)
        XCTAssertEqual(recovered.snapshot.pending.map(\.alert.eventId), s.alerts.map(\.eventId))
        XCTAssertNil(recovered.confidenceDetector.captureID)
        s.engine.suspend()
        s.score(1, end: 6)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.engine.state, .quiet)
    }

    func testAudioLevelGapRetainsCaptureIdentityButRequiresNewClassifierAudio() {
        var s = Simulation()
        s.score(end: 4)
        s.elapsed = 10
        s.levels(to: 10.25)
        XCTAssertEqual(s.engine.confidenceDetector.captureID, s.capture)
        s.score(end: 14.25); XCTAssertTrue(s.alerts.isEmpty)
        s.score(end: 15.25)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(10.25))
    }

    func testLevelDeliveryGapCannotSplitAHealthyClassifierEpisodeOrDuplicateItsAlert() throws {
        var s = Simulation()
        s.score(end: 4)
        s.levels(to: 4.5)
        for end in [5.0, 6.0] {
            s.alerts += s.engine.consumeClassification(.result(.init(captureID: s.capture,
                windowStart: s.date(end - 4), windowEnd: s.date(end), confidence: 0.9, observedAt: s.date(end))),
                at: s.date(end), listenerId: s.listener)
        }
        let id = try XCTUnwrap(s.engine.snapshot.current?.id)
        XCTAssertEqual(s.alerts.count, 1)
        s.elapsed = 6.5; s.levels(to: 6.75)
        XCTAssertEqual(s.engine.state, .crying)
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
        XCTAssertTrue(s.engine.snapshot.history.isEmpty)
        for end in 7...14 { s.score(end: Double(end)) }
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.engine.snapshot.current?.id, id)
    }

    func testLevelGapPreservesAnUnfinishedClassifierTimer() {
        var s = Simulation()
        s.score(end: 4)
        s.elapsed = 5.0
        s.levels(to: 5.25)
        s.score(end: 5, observed: 5.25)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.origin)
    }

    func testDriftedCaptureCanQualifyAgainAfterBothStreamsHaveBeenQuietOrMissing() {
        var s = Simulation()
        for second in 4...20 {
            let now = Double(second)
            s.score(0, end: now + Double(second - 2) * 0.075, observed: now, captured: now)
        }
        s.elapsed = 25; s.levels(to: 25.25)
        for second in 29...30 {
            let now = Double(second)
            s.score(0.9, end: now + 1.35, observed: now, captured: now)
        }
        XCTAssertEqual(s.engine.confidenceDetector.captureID, s.capture)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(s.alerts.first?.createdAt, s.date(30))
        XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(25))
    }

    func testGrowingInferenceBacklogDoesNotReanchorOldAudioOrTriggerAnAlert() {
        for anchored in [false, true] {
            var s = Simulation()
            for (end, received, confidence) in [(4.0, 4.0, 0.0), (5, 6.5, 0.9), (6, 9, 0.9),
                                                (7, 11.5, 0.9), (8, 14, 0.9)] {
                s.score(confidence, end: end, observed: received, captured: anchored ? end : nil)
            }
            XCTAssertTrue(s.alerts.isEmpty)
            XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
            // A caught-up stream must recover on a new full streak, with the
            // original audio onset rather than an onset shifted by old latency.
            for end in 16...17 { s.score(end: Double(end), captured: anchored ? Double(end) : nil) }
            XCTAssertEqual(s.alerts.count, 1)
            XCTAssertEqual(s.alerts.first?.cryStartedAt, s.date(12))
        }
    }

    func testAudioAgeIncludesInferenceAndMainActorDelaysTogether() {
        var s = Simulation()
        s.score(end: 4)
        s.levels(to: 8.5)
        let result = SoundClassificationObservation(captureID: s.capture, windowStart: s.date(1), windowEnd: s.date(5),
            confidence: 0.9, observedAt: s.date(7), audioWindowEndAt: s.date(5))
        let events = s.engine.consumeClassification(.result(result), at: s.date(8.5), listenerId: s.listener)
        XCTAssertTrue(events.isEmpty, "Neither individual delay exceeds three seconds, but the audio is 3.5 seconds old")
        XCTAssertNil(s.engine.confidenceDetector.observationStartedAt)
    }

    func testAudioClockMapsOldInferenceToItsInputTimeWithoutReanchoring() throws {
        let origin = Date(timeIntervalSince1970: 1000)
        var clock = SoundClassificationAudioClock(sampleRate: 48_000)
        XCTAssertNil(clock.capturedWindowEnd(at: 2))
        clock.receive(through: 96_000, at: origin.addingTimeInterval(2))
        XCTAssertEqual(clock.capturedWindowEnd(at: 2), origin.addingTimeInterval(2))
        clock.receive(through: 480_000, at: origin.addingTimeInterval(10))
        XCTAssertEqual(clock.capturedWindowEnd(at: 2), origin.addingTimeInterval(2))
        XCTAssertEqual(clock.capturedWindowEnd(at: 10), origin.addingTimeInterval(10))
        XCTAssertNil(clock.capturedWindowEnd(at: 11))
        // A duplicate frame cannot pretend the same old audio arrived later.
        clock.receive(through: 480_000, at: origin.addingTimeInterval(100))
        XCTAssertEqual(clock.capturedWindowEnd(at: 10), origin.addingTimeInterval(10))
    }

    func testAudioClockUsesRecentInputEvenAfterLongCaptureDrift() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let seconds = 100_000.0
        var clock = SoundClassificationAudioClock(sampleRate: 48_000)
        clock.receive(through: Int64(seconds * 48_000), at: now)
        XCTAssertEqual(clock.capturedWindowEnd(at: seconds), now)
        XCTAssertEqual(clock.capturedWindowEnd(at: seconds - 6), now.addingTimeInterval(-6))
        XCTAssertNil(clock.capturedWindowEnd(at: .nan))
        XCTAssertNil(clock.capturedWindowEnd(at: .infinity))
        XCTAssertNil(clock.capturedWindowEnd(at: -1))
    }

    func testLaterInputJitterCannotMakeAnOlderWindowFreshAgain() {
        let origin = Date(timeIntervalSince1970: 1000)
        var clock = SoundClassificationAudioClock(sampleRate: 48_000)
        for second in [2, 4, 6, 8] {
            clock.receive(through: Int64(second * 48_000), at: origin.addingTimeInterval(Double(second)))
        }
        clock.receive(through: 480_000, at: origin.addingTimeInterval(14))
        XCTAssertEqual(clock.capturedWindowEnd(at: 8), origin.addingTimeInterval(8))
        XCTAssertEqual(clock.capturedWindowEnd(at: 10), origin.addingTimeInterval(14))
    }

    func testAudioTimestampHistoryIsBoundedAndEvictedWindowsAreUnknown() {
        let origin = Date(timeIntervalSince1970: 1000)
        var clock = SoundClassificationAudioClock(sampleRate: 1)
        for frame in 1...(SoundClassificationAudioClock.maximumAnchors + 10) {
            clock.receive(through: Int64(frame), at: origin.addingTimeInterval(Double(frame)))
        }
        XCTAssertNil(clock.capturedWindowEnd(at: 1))
        XCTAssertNil(clock.capturedWindowEnd(at: 10))
        XCTAssertEqual(clock.capturedWindowEnd(at: 11), origin.addingTimeInterval(11))
        let end = Double(SoundClassificationAudioClock.maximumAnchors + 10)
        XCTAssertEqual(clock.capturedWindowEnd(at: end), origin.addingTimeInterval(end))
    }
}
