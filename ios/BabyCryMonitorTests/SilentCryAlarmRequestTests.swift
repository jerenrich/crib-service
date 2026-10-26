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
    func testSchedulingCycleIsTypedAndLegacyRequestsRemainAccepted() throws {
        XCTAssertNil(try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now)).cycleID)
        let cycle = UUID(); var marked = payload(); marked["alarmCycleId"] = cycle.uuidString
        XCTAssertEqual(try XCTUnwrap(SilentCryAlarmRequest(payload: marked, now: now)).cycleID, cycle)
        marked["alarmCycleId"] = "invalid"
        XCTAssertNil(SilentCryAlarmRequest(payload: marked, now: now))
        XCTAssertEqual(SilentCryAlarmRequest.payloadRejection(marked, now: now), .malformed)
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
    func testRejectedPayloadDiagnosticsMatchAcceptanceIncludingExpiredCallbacks() {
        var test = payload(); test["isTest"] = true
        var ordinary = payload(); ordinary.removeValue(forKey: "silentCryAlarm")
        var malformed = payload(); malformed["episodeId"] = "private-payload"
        var badDate = payload(); badDate["createdAt"] = "private-payload"
        let cases: [([AnyHashable: Any], SilentCryAlarmRequest.Rejection?)] = [
            (payload(), nil), (payload(age: 60), nil), (payload(age: -5), nil),
            (payload(age: 61), .stale), (payload(age: -6), .stale),
            (test, .test), (ordinary, .notRequested), (malformed, .malformed), (badDate, .malformed)
        ]
        for (value, reason) in cases {
            XCTAssertEqual(SilentCryAlarmRequest.payloadRejection(value, now: now), reason)
            XCTAssertEqual(SilentCryAlarmRequest(payload: value, now: now) != nil, reason == nil)
        }
    }
    func testEligibilityDiagnosticsDistinguishUnknownRelevanceFromSnoozeAndStaleStatus() throws {
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now))
        func reason(relevance: NotificationRelevance? = NotificationRelevance(), muted: Date? = nil,
                    localMuted: Date? = nil, stopped: Date? = nil, at: Date? = nil) -> SilentCryAlarmRequest.Rejection? {
            request.ineligibilityReason(enabled: true, serverEnabled: true, paired: true, relevance: relevance,
                mutedUntil: muted, localMutedUntil: localMuted, stoppedBefore: stopped, now: at ?? now)
        }
        let relevant = NotificationRelevance(cryEpisodeIDs: [episode])
        XCTAssertEqual(reason(relevance: nil), .relevanceUnknown)
        XCTAssertEqual(reason(), .irrelevant)
        XCTAssertEqual(reason(relevance: relevant, muted: now.addingTimeInterval(1)), .serverMuted)
        XCTAssertEqual(reason(relevance: relevant, localMuted: now.addingTimeInterval(1)), .locallyMuted)
        XCTAssertEqual(reason(relevance: relevant, stopped: now), .stopped)
        XCTAssertEqual(reason(relevance: relevant, at: now.addingTimeInterval(61)), .stale)
        XCTAssertNil(reason(relevance: relevant, muted: now, localMuted: now))
    }
}
