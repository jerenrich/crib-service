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
}
