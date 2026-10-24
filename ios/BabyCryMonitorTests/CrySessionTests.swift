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
        var engine: CrySessionManager = {
            var snapshot = SessionSnapshot()
            snapshot.configuration.alertDuration = 300
            return CrySessionManager(snapshot: snapshot, clock: FixedClock(now: Date(timeIntervalSince1970: 1000)))
        }()
        var time = Date(timeIntervalSince1970: 1000)
        let listener = UUID()
        var emitted: [CryAlert] = []
        mutating func run(_ seconds: Double, loud: Bool = true, level: Double? = nil) {
            for _ in 0..<Int(seconds * 4) {
                time = time.addingTimeInterval(0.25)
                emitted += engine.consume(AudioLevelSample(timestamp: time, dbFS: level ?? (loud ? -20 : -65)), listenerId: listener)
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
    func testListenerQueuesOnlyInitialAlertsAndServerOwnsRepeats() {
        var s = Simulation(); var config = MonitoringConfiguration(); config.alertDuration = 30
        s.engine.configure(config); s.run(280)
        XCTAssertEqual(s.emitted.count, 1); XCTAssertFalse(s.emitted[0].isRepeat)
        s.run(30, loud: false); s.run(40)
        XCTAssertEqual(s.emitted.count, 2); XCTAssertFalse(s.emitted[1].isRepeat)
    }
    func testNewInstallDefaultsAndLegacyReminderMigration() throws {
        let fresh = MonitoringConfiguration()
        XCTAssertEqual(fresh.alertDuration, 5)
        XCTAssertEqual(fresh.repeatInterval, 5)
        XCTAssertEqual(fresh.snoozeDuration, 60)
        for legacy in ["null", "15", "120", "300"] {
            let data = Data("{\"alertDuration\":300,\"quietResetDuration\":20,\"repeatInterval\":\(legacy),\"absoluteThreshold\":-35}".utf8)
            let restored = try JSONDecoder().decode(MonitoringConfiguration.self, from: data)
            XCTAssertEqual(restored.alertDuration, 300)
            XCTAssertEqual(restored.repeatInterval, 5)
            XCTAssertEqual(restored.snoozeDuration, 60)
            XCTAssertTrue(restored.isValid)
        }
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
        XCTAssertEqual(detector.state, .quiet)
    }
    func testAbsoluteThresholdIsIndependentOfPreviousRoomNoise() {
        for background in [-80.0, -36] {
            var s = Simulation(); var config = MonitoringConfiguration(); config.alertDuration = 5
            s.engine.configure(config)
            s.run(180, level: background)
            XCTAssertNil(s.engine.snapshot.current)
            XCTAssertTrue(s.emitted.isEmpty)
            s.run(10, level: -35)
            XCTAssertEqual(s.engine.detector.state, .crying)
            XCTAssertEqual(s.emitted.count, 1, "Expected an alert after background at \(background) dBFS")
        }
    }
    func testSelectedAbsoluteThresholdControlsDetectionAndAlertDelivery() {
        for threshold in [-60.0, -50, -35, -20, -10] {
            var s = Simulation(); var config = MonitoringConfiguration()
            config.absoluteThreshold = threshold; config.alertDuration = 5
            s.engine.configure(config)
            s.run(30, level: threshold - 0.01)
            XCTAssertNil(s.engine.snapshot.current)
            XCTAssertTrue(s.emitted.isEmpty)
            s.run(10, level: threshold)
            XCTAssertEqual(s.emitted.count, 1, "Expected detection at \(threshold) dBFS")
            XCTAssertEqual(s.emitted.first?.durationSeconds, 5)
            // Continued sound never creates a competing Listener reminder.
            s.engine.configure(config)
            s.run(119 - s.time.timeIntervalSince(s.emitted[0].createdAt), level: threshold)
            s.run(2, level: threshold - 0.01)
            XCTAssertEqual(s.emitted.count, 1)
            s.run(0.25, level: threshold)
            XCTAssertEqual(s.emitted.count, 1)
        }
    }
    func testAbsoluteThresholdValidationAndPersistence() throws {
        var config = MonitoringConfiguration()
        for threshold in [-60.0, -47.5, -35, -10] {
            config.absoluteThreshold = threshold
            XCTAssertTrue(config.isValid)
            XCTAssertEqual(try JSONDecoder().decode(MonitoringConfiguration.self, from: JSONEncoder().encode(config)), config)
        }
        for threshold in [-60.01, -9.99, .infinity, -.infinity, .nan] {
            config.absoluteThreshold = threshold
            XCTAssertFalse(config.isValid)
            var engine = CrySessionManager(); engine.configure(config)
            XCTAssertEqual(engine.snapshot.configuration.absoluteThreshold, -35)
        }
    }
    func testLegacySensitivityIsIgnoredWhenRestoringSavedSessions() throws {
        var s = Simulation(); s.run(306)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s.engine.snapshot)) as? [String: Any])
        var config = try XCTUnwrap(saved["configuration"] as? [String: Any])
        config["sensitivity"] = "high"; saved["configuration"] = config
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(restored.configuration.absoluteThreshold, -35)
        XCTAssertEqual(restored.pending.map(\.alert), s.engine.snapshot.pending.map(\.alert))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains("sensitivity"))
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
        XCTAssertEqual(first.durationSeconds, 5)
        XCTAssertEqual(first.createdAt.timeIntervalSince(first.cryStartedAt), 5)
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
    func testPermanentFailureRetiresOnlyMatchingAlertAndSurvivesRelaunch() throws {
        var s = Simulation(); s.run(306)
        let alert = try XCTUnwrap(s.emitted.first)
        let other = s.engine.queueTestAlert(listenerId: s.listener)
        s.engine.suspend()
        s.engine.permanentlyFailed(alert.eventId, at: s.time)
        s.engine.permanentlyFailed(alert.eventId, at: s.time)
        s.engine.permanentlyFailed(UUID(), at: s.time)
        XCTAssertEqual(s.engine.snapshot.pending.map { $0.alert.eventId }, [other.eventId])
        XCTAssertEqual(s.engine.snapshot.failedAlerts.map(\.alert), [alert])
        XCTAssertNil(s.engine.snapshot.history.first?.alertSentAt)
        let data = try JSONEncoder().encode(s.engine.snapshot)
        var restored = CrySessionManager(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
        restored.recoverAfterRelaunch()
        XCTAssertEqual(restored.snapshot.failedAlerts.first?.failedAt, s.time)
        XCTAssertEqual(restored.snapshot.failedAlerts.map(\.alert), [alert])
        XCTAssertEqual(restored.snapshot.pending.map { $0.alert.eventId }, [other.eventId])
    }
    func testPermanentFailureHistoryIsBoundedAndKeepsNewestFailures() {
        var engine = CrySessionManager()
        let listener = UUID()
        var newest: UUID?
        for index in 0..<105 {
            let alert = engine.queueTestAlert(listenerId: listener)
            engine.permanentlyFailed(alert.eventId, at: Date(timeIntervalSince1970: Double(index)))
            newest = alert.eventId
        }
        XCTAssertTrue(engine.snapshot.pending.isEmpty)
        XCTAssertEqual(engine.snapshot.failedAlerts.count, 100)
        XCTAssertEqual(engine.snapshot.failedAlerts.first?.id, newest)
        XCTAssertEqual(engine.snapshot.failedAlerts.last?.failedAt, Date(timeIntervalSince1970: 5))
    }
    func testLegacySnapshotsWithoutFailureHistoryPreservePendingAlerts() throws {
        var s = Simulation(); s.run(306)
        let data = try JSONEncoder().encode(s.engine.snapshot)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "failedAlerts")
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.failedAlerts.isEmpty)
        XCTAssertEqual(restored.pending.map(\.alert), s.engine.snapshot.pending.map(\.alert))
        XCTAssertEqual(restored.current?.id, s.engine.snapshot.current?.id)
        XCTAssertEqual(restored.configuration, s.engine.snapshot.configuration)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionSnapshot.self, from: Data("{}".utf8)))
    }

    func testEpisodeAlertStatusTracksTerminalFailureAcrossPersistence() throws {
        var s = Simulation(); s.run(306)
        let episode = try XCTUnwrap(s.engine.snapshot.current)
        let alert = try XCTUnwrap(s.emitted.first)
        XCTAssertEqual(s.engine.snapshot.alertStatus(for: episode), .pending)
        s.engine.permanentlyFailed(alert.eventId, at: s.time)
        XCTAssertEqual(s.engine.snapshot.alertStatus(for: episode), .failed)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(s.engine.snapshot))
        XCTAssertEqual(restored.alertStatus(for: episode), .failed)
        var other = CryEpisode(startedAt: s.time)
        XCTAssertEqual(restored.alertStatus(for: other), .notQueued)
        other.alertQueuedAt = s.time
        XCTAssertEqual(restored.alertStatus(for: other), .acknowledged)
        other.alertSentAt = s.time
        XCTAssertEqual(restored.alertStatus(for: other), .sent)
    }
    func testDeliveryDoesNotCreateListenerRepeats() throws {
        var s = Simulation(); s.run(306)
        s.engine.delivered(try XCTUnwrap(s.emitted.first?.eventId), at: s.time)
        s.run(600)
        XCTAssertEqual(s.emitted.count, 1)
        XCTAssertTrue(s.engine.snapshot.pending.isEmpty)
        XCTAssertEqual(s.engine.snapshot.alertStatus(for: try XCTUnwrap(s.engine.snapshot.current)), .sent)
    }
    func testSnoozeSelectionValidationAndPersistence() throws {
        for duration in MonitoringConfiguration.snoozeDurations {
            var config = MonitoringConfiguration(); config.snoozeDuration = duration
            XCTAssertTrue(config.isValid)
            XCTAssertEqual(try JSONDecoder().decode(MonitoringConfiguration.self, from: JSONEncoder().encode(config)).snoozeDuration, duration)
        }
        for duration in [0.0, 30, 61, .infinity, .nan] {
            var config = MonitoringConfiguration(); config.snoozeDuration = duration
            XCTAssertFalse(config.isValid)
        }
    }

}
