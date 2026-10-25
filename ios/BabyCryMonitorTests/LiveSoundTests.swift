import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class LiveSoundTests: XCTestCase {
    private func frame(at time: TimeInterval = 100) -> SoundLevelFrame {
        SoundLevelFrame(sampledAt: time, levels: (0..<120).map { -80 + Double($0 % 20) },
                        threshold: -45, state: .crying, episodeStartedAt: 95, alertDuration: 30)
    }
    func testFramePreservesNurseryWindowAndAppliedThresholdThroughTransport() throws {
        let value = frame()
        let received = try JSONDecoder().decode(SoundLevelFrame.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(received, value)
        XCTAssertTrue(received.isValid)
        XCTAssertEqual(received.episodeDuration, 5)
        XCTAssertEqual(received.levels.count, 120)
    }
    func testInvalidLevelsThresholdsAndEpisodeDatesAreRejected() {
        var value = frame(); value.levels[0] = .nan; XCTAssertFalse(value.isValid)
        value = frame(); value.levels[0] = 1; XCTAssertFalse(value.isValid)
        value = frame(); value.levels.removeLast(); XCTAssertFalse(value.isValid)
        value = frame(); value.threshold = -100; XCTAssertFalse(value.isValid)
        value = frame(); value.episodeStartedAt = 101; XCTAssertFalse(value.isValid)
        value = frame(); value.alertDuration = .infinity; XCTAssertFalse(value.isValid)
    }
    func testFrozenReplayedAndDisconnectedReadingsCannotRemainLive() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = RemoteSoundState()
        XCTAssertFalse(state.isLive(at: now))
        state.receive(frame(), at: now)
        XCTAssertTrue(state.isLive(at: now.addingTimeInterval(2.9)))
        XCTAssertFalse(state.isLive(at: now.addingTimeInterval(3)))
        XCTAssertFalse(state.isLive(at: now.addingTimeInterval(-1)))
        state.receive(frame(), at: now.addingTimeInterval(10))
        state.receive(frame(at: 99), at: now.addingTimeInterval(10))
        XCTAssertEqual(state.receivedAt, now)
        state.receive(frame(at: 101), at: now.addingTimeInterval(11))
        XCTAssertTrue(state.isLive(at: now.addingTimeInterval(11)))
        state.disconnected()
        XCTAssertFalse(state.isLive(at: now.addingTimeInterval(11)))
        XCTAssertEqual(state.frame?.sampledAt, 101)
    }
    func testDelayedPacketsCannotBecomeLiveEvenWithDifferentDeviceClocks() {
        var requests = LiveSoundRequests()
        let now = Date(timeIntervalSince1970: 10_000)
        var value = frame(at: 100)
        XCTAssertFalse(requests.accepts(value, at: now))
        value.requestID = requests.issue(at: now)
        XCTAssertTrue(requests.accepts(value, at: now.addingTimeInterval(2.9)))
        XCTAssertFalse(requests.accepts(value, at: now.addingTimeInterval(3)))
        XCTAssertFalse(requests.accepts(value, at: now.addingTimeInterval(-1)))
        value.requestID = UUID().uuidString
        XCTAssertFalse(requests.accepts(value, at: now))
    }
}

final class ParentMonitoringEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveStartSupersedesCachedStandbyWithoutFlickerAndEventuallyExpires() {
        var evidence = ParentMonitoringEvidence()
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now)
        evidence.receiveLive(at: now.addingTimeInterval(1))
        // Re-fetching the same cached heartbeat is not a new pause.
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now)
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(5), statusAvailable: true), .monitoring)
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(50), statusAvailable: true), .monitoring)
        XCTAssertFalse(evidence.canResume(at: now.addingTimeInterval(5), statusAvailable: true))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(152), statusAvailable: true), .connectionLost)
    }
    func testNewerStopSupersedesLiveAfterInFlightWindowAndOlderResponsesCannotUndoIt() {
        var evidence = ParentMonitoringEvidence()
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now)
        evidence.receiveLive(at: now.addingTimeInterval(1))
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: false,
            version: now.addingTimeInterval(2), observedAt: now.addingTimeInterval(2))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(2), statusAvailable: true), .monitoring)
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(4), statusAvailable: true), .stopped)
        evidence.receiveHeartbeat(monitoring: true, microphoneActive: true, version: now, observedAt: now)
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(5), statusAvailable: true), .stopped)
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(6), statusAvailable: false), .unavailable)
    }
    func testContinuingLiveReadingsSupersedeAnOlderStopAndNewStandbyAllowsResume() {
        var evidence = ParentMonitoringEvidence()
        evidence.receiveLive(at: now)
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true,
            version: now.addingTimeInterval(1), observedAt: now.addingTimeInterval(1))
        evidence.receiveLive(at: now.addingTimeInterval(2))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(6), statusAvailable: true), .monitoring)
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true,
            version: now.addingTimeInterval(7), observedAt: now.addingTimeInterval(7))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(7), statusAvailable: true), .standby)
        XCTAssertTrue(evidence.canResume(at: now.addingTimeInterval(7), statusAvailable: true))
        XCTAssertFalse(evidence.canResume(at: now.addingTimeInterval(38), statusAvailable: true))
    }
    func testRepeatedCachedHeartbeatNeverRenewsFreshness() {
        var evidence = ParentMonitoringEvidence()
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now)
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now.addingTimeInterval(120))
        XCTAssertFalse(evidence.canResume(at: now.addingTimeInterval(120), statusAvailable: true))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(151), statusAvailable: true), .connectionLost)
    }
    func testPauseBlocksAlreadyIssuedLiveChallengesButAllowsGenuineLaterResume() {
        var evidence = ParentMonitoringEvidence()
        evidence.receiveLive(at: now)
        evidence.receiveHeartbeat(monitoring: false, microphoneActive: true, version: now, observedAt: now)
        evidence.pause(at: now)
        evidence.receiveLive(at: now.addingTimeInterval(2.99))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(2.99), statusAvailable: true), .standby)
        XCTAssertFalse(evidence.acceptsLive(at: now.addingTimeInterval(2.99)))
        evidence.receiveLive(at: now.addingTimeInterval(3))
        XCTAssertEqual(evidence.state(at: now.addingTimeInterval(3), statusAvailable: true), .monitoring)
    }
}
