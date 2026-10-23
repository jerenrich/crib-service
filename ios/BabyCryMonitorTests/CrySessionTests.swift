import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class CrySessionTests: XCTestCase {
    struct FixedClock: ClockProviding { let now: Date }
    struct Simulation {
        var engine = CrySessionManager(clock: FixedClock(now: Date(timeIntervalSince1970: 1000)))
        var time = Date(timeIntervalSince1970: 1000)
        let listener = UUID()
        var emitted: [CryAlert] = []
        mutating func run(_ seconds: Double, loud: Bool = true) {
            for _ in 0..<Int(seconds * 4) {
                time = time.addingTimeInterval(0.25)
                emitted += engine.consume(AudioLevelSample(timestamp: time, dbFS: loud ? -20 : -65), listenerId: listener)
            }
        }
    }
    func testBriefNoiseDoesNotCreateEpisode() {
        var s = Simulation(); s.run(2); s.run(30, loud: false)
        XCTAssertNil(s.engine.snapshot.current); XCTAssertTrue(s.engine.snapshot.history.isEmpty); XCTAssertTrue(s.emitted.isEmpty)
    }
    func testCryShorterThanThreshold() {
        var s = Simulation(); s.run(180); s.run(25, loud: false)
        XCTAssertEqual(s.engine.snapshot.history.count, 1); XCTAssertTrue(s.emitted.isEmpty)
        XCTAssertLessThan(s.engine.snapshot.history[0].duration(at: s.time), 180)
    }
    func testExactlyOneInitialAlertAndTimerStartsAtConfirmation() {
        var s = Simulation(); s.run(304); XCTAssertTrue(s.emitted.isEmpty)
        s.run(2); XCTAssertEqual(s.emitted.count, 1)
        XCTAssertEqual(s.emitted[0].durationSeconds, 300, accuracy: 0.25)
        s.run(600); XCTAssertEqual(s.emitted.count, 1)
    }
    func testFiveSecondAlertStartsAtConfirmationAndDoesNotRepeat() throws {
        var s = Simulation(); var config = MonitoringConfiguration(); config.alertDuration = 5
        s.engine.configure(config)
        s.run(5)
        let episode = try XCTUnwrap(s.engine.snapshot.current)
        XCTAssertTrue(s.emitted.isEmpty)
        s.run(4.75)
        XCTAssertTrue(s.emitted.isEmpty)
        s.run(0.25)
        let alert = try XCTUnwrap(s.emitted.first)
        XCTAssertEqual(alert.cryStartedAt, episode.startedAt)
        XCTAssertEqual(alert.durationSeconds, 5, accuracy: 0.001)
        s.run(30)
        XCTAssertEqual(s.emitted.count, 1)
    }
    func testAlertDurationBounds() {
        var config = MonitoringConfiguration()
        for duration in [5.0, 15, 30, 3600] {
            config.alertDuration = duration
            XCTAssertTrue(config.isValid, "Expected \(duration) seconds to be accepted")
        }
        for duration in [0.0, 4.99, 3600.01, .infinity, .nan] {
            config.alertDuration = duration
            XCTAssertFalse(config.isValid, "Expected \(duration) seconds to be rejected")
        }
    }
    func testBriefPausesPreserveEpisode() {
        var s = Simulation(); s.run(120); let id = s.engine.snapshot.current?.id
        s.run(10, loud: false); s.run(180)
        XCTAssertEqual(s.engine.snapshot.current?.id, id); XCTAssertEqual(s.emitted.count, 1)
        XCTAssertTrue(s.engine.snapshot.history.isEmpty)
    }
    func testSettlesJustBeforeThresholdDoesNotAlertDuringTrailingGap() {
        var s = Simulation(); s.run(303); s.run(30, loud: false)
        XCTAssertTrue(s.emitted.isEmpty); XCTAssertEqual(s.engine.snapshot.history.count, 1)
    }
    func testQuietGapCrossesThresholdAndAlertsOnResumption() {
        var s = Simulation(); s.run(300); s.run(10, loud: false)
        XCTAssertTrue(s.emitted.isEmpty); s.run(1)
        XCTAssertEqual(s.emitted.count, 1); XCTAssertGreaterThan(s.emitted[0].durationSeconds, 300)
    }
    func testLongPauseEndsEpisode() {
        var s = Simulation(); s.run(120); let id = s.engine.snapshot.current?.id
        s.run(30, loud: false); s.run(180)
        XCTAssertEqual(s.engine.snapshot.history.count, 1); XCTAssertNotEqual(s.engine.snapshot.current?.id, id); XCTAssertTrue(s.emitted.isEmpty)
    }
    func testQuietResetBoundary() {
        var s = Simulation(); s.run(10); s.run(20, loud: false)
        XCTAssertNotNil(s.engine.snapshot.current)
        s.run(0.25, loud: false); XCTAssertNil(s.engine.snapshot.current)
    }
    func testOutagePersistsStableUUIDAndBackoff() throws {
        var s = Simulation(); s.run(306)
        let id = try XCTUnwrap(s.emitted.first?.eventId)
        s.engine.failed(id, at: s.time)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(s.engine.snapshot))
        var recovered = CrySessionManager(snapshot: restored); recovered.recoverAfterRelaunch()
        XCTAssertEqual(recovered.snapshot.pending[0].alert.eventId, id)
        XCTAssertEqual(recovered.snapshot.pending[0].attempts, 1)
        XCTAssertEqual(recovered.snapshot.pending[0].nextAttemptAt.timeIntervalSince(s.time), 2)
        recovered.delivered(id, at: s.time); recovered.delivered(id, at: s.time)
        XCTAssertTrue(recovered.snapshot.pending.isEmpty); XCTAssertNotNil(recovered.snapshot.history[0].alertSentAt)
    }
    func testRepeatsAndReset() {
        var s = Simulation(); var config = MonitoringConfiguration(); config.alertDuration = 30; config.repeatInterval = 120
        s.engine.configure(config); s.run(280)
        XCTAssertEqual(s.emitted.count, 3); XCTAssertFalse(s.emitted[0].isRepeat); XCTAssertTrue(s.emitted[1].isRepeat)
        s.run(30, loud: false); s.run(40); XCTAssertEqual(s.emitted.count, 4); XCTAssertFalse(s.emitted[3].isRepeat)
    }
    func testMissingSamplesDoNotCountAsCrying() {
        var s = Simulation(); s.run(60); s.time = s.time.addingTimeInterval(300); s.run(1)
        XCTAssertTrue(s.emitted.isEmpty); XCTAssertNil(s.engine.snapshot.current); XCTAssertEqual(s.engine.snapshot.history.count, 1)
    }
    func testSilenceNaNAndOutOfOrderSamples() {
        var detector = CryDetector(); let config = MonitoringConfiguration(); let start = Date(timeIntervalSince1970: 100)
        for i in 0..<1000 { _ = detector.consume(.init(timestamp: start.addingTimeInterval(Double(i) / 4), dbFS: -100), configuration: config) }
        _ = detector.consume(.init(timestamp: start, dbFS: -10), configuration: config)
        _ = detector.consume(.init(timestamp: start.addingTimeInterval(1000), dbFS: .nan), configuration: config)
        XCTAssertEqual(detector.state, .quiet); XCTAssertTrue(detector.ambientDBFS.isFinite)
    }
    func testAmbientFrozenDuringCryAndSensitivity() {
        var s = Simulation(); s.run(30, loud: false); let baseline = s.engine.detector.ambientDBFS; s.run(120)
        XCTAssertEqual(s.engine.detector.ambientDBFS, baseline, accuracy: 0.01)
        XCTAssertLessThan(Sensitivity.high.margin, Sensitivity.medium.margin)
        XCTAssertLessThan(Sensitivity.medium.margin, Sensitivity.low.margin)
    }
    func testHistoryBoundAndConfigValidation() {
        var s = Simulation()
        for _ in 0..<105 { s.run(6); s.run(25, loud: false) }
        XCTAssertEqual(s.engine.snapshot.history.count, 100)
        var config = MonitoringConfiguration(); config.alertDuration = -1; s.engine.configure(config)
        XCTAssertEqual(s.engine.snapshot.configuration.alertDuration, 300)
    }
    func testStopUsesInjectableClock() {
        var s = Simulation(); s.run(10); s.engine.end()
        XCTAssertEqual(s.engine.snapshot.history[0].endedAt, s.engine.snapshot.history[0].startedAt)
    }
    func testAcknowledgmentRemovesOnlyMatchingEventWithoutMarkingItSent() throws {
        var s = Simulation(); s.run(306)
        let first = try XCTUnwrap(s.emitted.first)
        s.engine.suspend(); s.run(306)
        let second = try XCTUnwrap(s.emitted.last)
        XCTAssertNotEqual(first.eventId, second.eventId)
        s.engine.acknowledged(first.eventId)
        s.engine.acknowledged(first.eventId)
        XCTAssertEqual(s.engine.snapshot.pending.map { $0.alert.eventId }, [second.eventId])
        XCTAssertNil(s.engine.snapshot.history.first?.alertSentAt)
        XCTAssertNil(s.engine.snapshot.current?.alertSentAt)
    }
    func testRemoteTestQueuesWithoutStartingMonitoring() throws {
        var engine = CrySessionManager(clock: FixedClock(now: Date(timeIntervalSince1970: 1000)))
        let listener = UUID()
        let first = engine.queueTestAlert(listenerId: listener)
        let second = engine.queueTestAlert(listenerId: listener)
        XCTAssertEqual(first.isTest, true)
        XCTAssertEqual(first.listenerId, listener)
        XCTAssertEqual(first.durationSeconds, 300)
        XCTAssertEqual(first.createdAt.timeIntervalSince(first.cryStartedAt), 300)
        XCTAssertNotEqual(first.eventId, second.eventId)
        XCTAssertNotEqual(first.episodeId, second.episodeId)
        XCTAssertFalse(engine.snapshot.wasMonitoring)
        XCTAssertNil(engine.snapshot.current)
        XCTAssertTrue(engine.snapshot.history.isEmpty)
        XCTAssertEqual(engine.detector.state, .quiet)
        let saved = try JSONEncoder().encode(engine.snapshot)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: saved)
        XCTAssertEqual(restored.pending.map(\.alert), [first, second])
    }
    func testRemoteTestDoesNotChangeActiveEpisodeOrDelayRealAlert() throws {
        var s = Simulation(); s.run(60)
        let episode = try XCTUnwrap(s.engine.snapshot.current)
        let test = s.engine.queueTestAlert(listenerId: s.listener)
        XCTAssertEqual(s.engine.snapshot.current?.id, episode.id)
        XCTAssertEqual(s.engine.snapshot.current?.startedAt, episode.startedAt)
        XCTAssertNil(s.engine.snapshot.current?.alertQueuedAt)
        XCTAssertEqual(s.engine.detector.state, .crying)
        s.engine.delivered(test.eventId, at: s.time)
        XCTAssertNil(s.engine.snapshot.current?.alertSentAt)
        s.run(246)
        XCTAssertEqual(s.emitted.count, 1)
        XCTAssertEqual(s.emitted.first?.episodeId, episode.id)
        XCTAssertNil(s.emitted.first?.isTest)
    }
    func testOldAlertsDecodeWithoutTestFlag() throws {
        var s = Simulation(); s.run(306)
        let encoded = try JSONEncoder().encode(s.engine.snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("isTest"))
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: encoded)
        XCTAssertNil(restored.pending.first?.alert.isTest)
    }
}
