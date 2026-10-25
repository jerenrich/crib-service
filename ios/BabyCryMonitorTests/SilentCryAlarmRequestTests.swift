import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SilentCryAlarmRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let episode = UUID()
    private func payload(age: Double = 0) -> [AnyHashable: Any] {
        ["silentCryAlarm": true, "eventId": UUID().uuidString, "episodeId": episode.uuidString,
         "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))]
    }
    func testOnlyFreshRealCryPayloadsAreAccepted() throws {
        XCTAssertNotNil(SilentCryAlarmRequest(payload: payload(), now: now))
        XCTAssertNil(SilentCryAlarmRequest(payload: payload(age: 61), now: now))
        XCTAssertNil(SilentCryAlarmRequest(payload: payload(age: -6), now: now))
        var test = payload(); test["isTest"] = true
        XCTAssertNil(SilentCryAlarmRequest(payload: test, now: now))
        var ordinary = payload(); ordinary.removeValue(forKey: "silentCryAlarm")
        XCTAssertNil(SilentCryAlarmRequest(payload: ordinary, now: now))
        var invalid = payload(); invalid["episodeId"] = "invalid"
        XCTAssertNil(SilentCryAlarmRequest(payload: invalid, now: now))
    }
    func testBothOptInsCurrentEpisodeAndNoSnoozeAreRequired() throws {
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now))
        let relevant = NotificationRelevance(cryEpisodeIDs: [episode])
        func eligible(enabled: Bool = true, serverEnabled: Bool = true, paired: Bool = true,
                      relevance: NotificationRelevance? = relevant, muted: Date? = nil,
                      localMuted: Date? = nil, stopped: Date? = nil, at: Date? = nil) -> Bool {
            request.isEligible(enabled: enabled, serverEnabled: serverEnabled, paired: paired,
                relevance: relevance, mutedUntil: muted, localMutedUntil: localMuted, stoppedBefore: stopped, now: at ?? now)
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(enabled: false)); XCTAssertFalse(eligible(serverEnabled: false))
        XCTAssertFalse(eligible(paired: false)); XCTAssertFalse(eligible(relevance: nil))
        XCTAssertFalse(eligible(relevance: NotificationRelevance()))
        XCTAssertFalse(eligible(muted: now.addingTimeInterval(60)))
        XCTAssertFalse(eligible(localMuted: now.addingTimeInterval(60)))
        XCTAssertFalse(eligible(stopped: now)); XCTAssertFalse(eligible(at: now.addingTimeInterval(61)))
        XCTAssertTrue(eligible(muted: now.addingTimeInterval(-1), localMuted: now.addingTimeInterval(-1)))
    }
}
