import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class LiveSoundTests: XCTestCase {
    private func frame(at time: TimeInterval = 100) -> SoundLevelFrame {
        SoundLevelFrame(sampledAt: time, levels: (0..<32).map { -80 + Double($0) },
                        threshold: -45, state: .crying, episodeStartedAt: 95, alertDuration: 30)
    }
    func testFramePreservesNurseryWindowAndAppliedThresholdThroughTransport() throws {
        let value = frame()
        let received = try JSONDecoder().decode(SoundLevelFrame.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(received, value)
        XCTAssertTrue(received.isValid)
        XCTAssertEqual(received.episodeDuration, 5)
        XCTAssertEqual(received.levels.count, 32)
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
