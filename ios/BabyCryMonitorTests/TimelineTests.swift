import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class TimelineTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Double) -> Date { zero.addingTimeInterval(seconds) }
    func testStandbyCoverageSeparatesDiscardedCaptureFromMonitoringAndOff() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                      TimelineEvent(kind: "standby_observed", occurredAt: at(110)),
                      TimelineEvent(kind: "monitoring_started", occurredAt: at(200)),
                      TimelineEvent(kind: "monitoring_stopped", occurredAt: at(300))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(400), availableSince: at(0))
        XCTAssertEqual(segments.map(\.state), [.monitoring, .standby, .monitoring, .stopped])
        XCTAssertEqual(segments[1].start, at(100)); XCTAssertEqual(segments[1].end, at(200))
        XCTAssertTrue(TimelineEvent(kind: "coverage_standby", occurredAt: at(110)).isObservation)
    }
    func testMissingHeartbeatBackdatesMissingUpdatesAndFreshObservationEndsIt() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(kind: "heartbeat_missing", occurredAt: at(480), endAt: at(300)),
                      TimelineEvent(kind: "monitoring_observed", occurredAt: at(700)),
                      TimelineEvent(kind: "monitoring_stopped", occurredAt: at(900))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(1000), availableSince: at(0))
        XCTAssertEqual(segments.map(\.state), [.monitoring, .updatesMissing, .monitoring, .stopped])
        XCTAssertEqual(segments.map(\.start), [at(0), at(300), at(700), at(900)])
        XCTAssertEqual(segments.last?.end, at(1000))
    }
    func testMissingHistoryAndNetworkRecoveryNeverImplyMonitoring() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(-300)),
                      TimelineEvent(kind: "network_restored", occurredAt: at(200)),
                      TimelineEvent(kind: "connection_restored", occurredAt: at(250)),
                      TimelineEvent(kind: "monitoring_observed", occurredAt: at(400))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(500), availableSince: at(100))
        XCTAssertEqual(segments.map(\.state), [.noHistory, .monitoring])
        XCTAssertEqual(segments.first?.end, at(400))
    }
    func testCoverageUsesBoundaryEventBeforeWindowAndClipsFutureEvents() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(-500)),
                      TimelineEvent(kind: "monitoring_stopped", occurredAt: at(2000))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(1000), availableSince: at(-1000))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.state, .monitoring)
        XCTAssertEqual(segments.first?.end, at(1000))
    }
    func testHistoryBeforeLoggingIsSeparateFromMissingUpdates() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(100)),
                      TimelineEvent(kind: "heartbeat_missing", occurredAt: at(480), endAt: at(300)),
                      TimelineEvent(kind: "monitoring_observed", occurredAt: at(700))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(800), availableSince: at(100))
        XCTAssertEqual(segments.map(\.state), [.noHistory, .monitoring, .updatesMissing, .monitoring])
        XCTAssertEqual(segments.map(\.start), [at(0), at(100), at(300), at(700)])
    }
    func testUnavailableRefreshPreservesFetchedHistoryAndDoesNotClaimDisconnection() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(kind: "heartbeat_missing", occurredAt: at(480), endAt: at(300))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(1000), availableSince: at(0),
                                                statusUnavailableSince: at(600))
        XCTAssertEqual(segments.map(\.state), [.monitoring, .updatesMissing, .unavailable])
        XCTAssertEqual(segments.map(\.start), [at(0), at(300), at(600)])
        XCTAssertEqual(segments.last?.end, at(1000))
        let refreshed = TimelineCoverage.segments(events: events + [TimelineEvent(kind: "monitoring_observed", occurredAt: at(900))],
                                                 from: at(0), to: at(1000), availableSince: at(0))
        XCTAssertEqual(refreshed.map(\.state), [.monitoring, .updatesMissing, .monitoring])
    }
    func testNoFetchedHistoryIsUnavailableAndTruncatedHistoryIsMissing() {
        let unavailable = TimelineCoverage.segments(events: [], from: at(0), to: at(1000), availableSince: at(1000),
                                                   statusUnavailableSince: at(0))
        XCTAssertEqual(unavailable.map(\.state), [.unavailable])
        let truncated = TimelineCoverage.segments(events: [TimelineEvent(kind: "monitoring_started", occurredAt: at(300))],
                                                 from: at(0), to: at(1000), availableSince: at(100), historyTruncated: true)
        XCTAssertEqual(truncated.map(\.state), [.noHistory])
    }
    func testRelaunchIsUnverifiedRatherThanAConnectionGap() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(kind: "monitoring_unverified", occurredAt: at(300)),
                      TimelineEvent(kind: "monitoring_started", occurredAt: at(600))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(1000), availableSince: at(0))
        XCTAssertEqual(segments.map(\.state), [.monitoring, .unverified, .monitoring])
    }
    func testOfflineJournalRoundTripsAndAcknowledgesOnlyUploadedBatch() throws {
        var engine = CrySessionManager()
        engine.recordTimeline("monitoring_started", at: at(0))
        let first = try XCTUnwrap(engine.snapshot.timelineEvents.first?.id)
        engine.recordTimeline("monitoring_stopped", at: at(10))
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(engine.snapshot))
        engine = CrySessionManager(snapshot: restored)
        engine.uploadedTimeline([first])
        XCTAssertEqual(engine.snapshot.timelineEvents.count, 2)
        XCTAssertEqual(engine.snapshot.pendingTimelineIDs.count, 1)
        XCTAssertNotEqual(engine.snapshot.pendingTimelineIDs.first, first)
    }
    func testOldSnapshotsDefaultToEmptyTimeline() throws {
        let encoded = try JSONEncoder().encode(SessionSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "timelineEvents"); object.removeValue(forKey: "pendingTimelineIDs")
        let old = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.timelineEvents.isEmpty); XCTAssertTrue(old.pendingTimelineIDs.isEmpty)
    }
    func testJournalBoundsRetentionAndDropsExpiredPendingIDs() {
        var engine = CrySessionManager()
        for second in 0..<1100 { engine.recordTimeline("network_lost", at: at(Double(second))) }
        XCTAssertEqual(engine.snapshot.timelineEvents.count, 1000)
        XCTAssertEqual(engine.snapshot.pendingTimelineIDs.count, 1000)
        engine.recordTimeline("network_restored", at: at(100_000))
        XCTAssertEqual(engine.snapshot.timelineEvents.count, 1)
        XCTAssertEqual(engine.snapshot.pendingTimelineIDs.count, 1)
    }
    func testChangingBackendOrDeviceClearsLocalTimelineAndPendingUploads() {
        var engine = CrySessionManager()
        engine.scopeTimeline(to: "backend-a|listener-a")
        engine.recordTimeline("monitoring_started", at: at(0))
        engine.scopeTimeline(to: "backend-a|listener-a")
        XCTAssertEqual(engine.snapshot.timelineEvents.count, 1)
        engine.scopeTimeline(to: "backend-b|listener-a")
        XCTAssertTrue(engine.snapshot.timelineEvents.isEmpty)
        XCTAssertTrue(engine.snapshot.pendingTimelineIDs.isEmpty)
    }
    func testBackdatedOutageWinsOverObservationAtSameTimestamp() {
        let events = [TimelineEvent(id: "state:0", kind: "monitoring_observed", occurredAt: at(0)),
                      TimelineEvent(id: "missing:0", kind: "heartbeat_missing", occurredAt: at(180), endAt: at(0))]
        let segments = TimelineCoverage.segments(events: events, from: at(0), to: at(300), availableSince: at(0))
        XCTAssertEqual(segments.map(\.state), [.updatesMissing])
    }
    func testCryTransitionsAreRetainedAndQueuedSeparatelyFromBoundedEpisodeHistory() throws {
        var engine = CrySessionManager()
        let listener = UUID()
        for tick in 0..<32 { _ = engine.consume(AudioLevelSample(timestamp: at(Double(tick) / 4), dbFS: -15), listenerId: listener) }
        let episode = try XCTUnwrap(engine.snapshot.current)
        engine.suspend()
        let journal = engine.snapshot.timelineEvents
        XCTAssertEqual(journal.map(\.kind), ["cry_started", "cry_ended"])
        XCTAssertEqual(journal.first?.id, "cry:\(episode.id.uuidString.lowercased())")
        XCTAssertEqual(journal.last?.endAt, episode.startedAt)
        XCTAssertEqual(engine.snapshot.pendingTimelineIDs.count, 2)
    }

    private func page(_ events: [TimelineEvent], now: Double, truncated: Bool = false, availableSince: Double = -100_000) -> TimelineResponse {
        TimelineResponse(paired: true, serverTime: at(now), availableSince: at(availableSince), events: events, truncated: truncated)
    }
    func testStandbyStartIsTheOldestStandbyEventSinceTheLastOtherState() {
        let events = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(kind: "cry_started", occurredAt: at(50)),
                      TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                      TimelineEvent(kind: "standby_observed", occurredAt: at(118)),
                      TimelineEvent(kind: "coverage_standby", occurredAt: at(3600))]
        XCTAssertEqual(page(events, now: 4000).standbyStart(), .at(at(100)))
    }
    func testStandbyStartIsUnknownUnlessTheNewestStateIsStandby() {
        let events = [TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                      TimelineEvent(kind: "monitoring_started", occurredAt: at(200))]
        XCTAssertNil(page(events, now: 300).standbyStart(), "Monitoring resumed; the old pause is not current")
        XCTAssertNil(page([], now: 300).standbyStart())
    }
    func testStandbyOlderThanTheFetchedHistoryIsDatedFromItsOldestState() {
        // The server adds the last state event before its window; hourly Standby
        // observations make that boundary a Standby event too. The window length
        // itself is the server's choice and is not assumed here.
        let hour = 3600.0
        let events = [TimelineEvent(kind: "coverage_standby", occurredAt: at(-hour)),
                      TimelineEvent(kind: "coverage_standby", occurredAt: at(0)),
                      TimelineEvent(kind: "coverage_standby", occurredAt: at(11 * hour))]
        XCTAssertEqual(page(events, now: 11.5 * hour).standbyStart(), .before(at(-hour)))
        XCTAssertNil(page(events, now: 11.5 * hour, truncated: true).standbyStart(), "Truncated history cannot place the start")
    }
    func testConnectionGapOrRelaunchInsideAPauseKeepsItsStart() {
        let gap = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                   TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                   TimelineEvent(kind: "heartbeat_missing", occurredAt: at(500), endAt: at(400)),
                   TimelineEvent(kind: "standby_observed", occurredAt: at(600))]
        XCTAssertEqual(page(gap, now: 700).standbyStart(), .at(at(100)), "A dropped connection is not a new pause")
        let relaunch = [TimelineEvent(kind: "monitoring_started", occurredAt: at(0)),
                        TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                        TimelineEvent(kind: "monitoring_unverified", occurredAt: at(500)),
                        TimelineEvent(kind: "standby_observed", occurredAt: at(510))]
        XCTAssertEqual(page(relaunch, now: 600).standbyStart(), .at(at(100)))
    }
    func testMonitoringAfterAGapStartsANewPause() {
        let events = [TimelineEvent(kind: "monitoring_paused", occurredAt: at(100)),
                      TimelineEvent(kind: "heartbeat_missing", occurredAt: at(500), endAt: at(400)),
                      TimelineEvent(kind: "monitoring_observed", occurredAt: at(600)),
                      TimelineEvent(kind: "monitoring_paused", occurredAt: at(700))]
        XCTAssertEqual(page(events, now: 800).standbyStart(), .at(at(700)))
    }
    func testSameTimestampTieIsDeterministicAndMatchesCoverage() {
        let events = [TimelineEvent(id: "a", kind: "monitoring_started", occurredAt: at(0)),
                      TimelineEvent(id: "b", kind: "monitoring_observed", occurredAt: at(100)),
                      TimelineEvent(id: "c", kind: "monitoring_paused", occurredAt: at(100))]
        XCTAssertEqual(page(events, now: 200).standbyStart(), .at(at(100)))
        XCTAssertEqual(page(events.reversed(), now: 200).standbyStart(), .at(at(100)), "Event order must not change the answer")
    }
    func testHistoryThatBeginsMidPauseOnlyBoundsTheStart() {
        let events = [TimelineEvent(kind: "monitoring_paused", occurredAt: at(20)),
                      TimelineEvent(kind: "standby_observed", occurredAt: at(100))]
        XCTAssertEqual(page(events, now: 200, availableSince: 50).standbyStart(), .before(at(100)),
                       "Events before logging began cannot date the pause; it was already paused at the first known state")
    }
}
