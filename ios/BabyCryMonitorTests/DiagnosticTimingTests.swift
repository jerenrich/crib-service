import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class DiagnosticTimingTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(elapsed: Int = 100, received: Int64 = 1_800_000_001_030, sent: Int64 = 1_800_000_001_050) -> DiagnosticClockSample? {
        DiagnosticClockSample.estimate(localStarted: start, localFinished: start.addingTimeInterval(Double(elapsed) / 1000),
            monotonicMS: elapsed, remoteReceivedMS: received, remoteSentMS: sent)
    }
    func testClockEstimateBoundsAsymmetricNetworkDelay() throws {
        let value = try XCTUnwrap(sample())
        XCTAssertEqual(value.offsetMS, 990); XCTAssertEqual(value.uncertaintyMS, 41)
        XCTAssertTrue(value.fields.contains("clock_source=http"))
        XCTAssertNil(value.ageMS(at: start.addingTimeInterval(1000)))
        XCTAssertNil(value.ageMS(at: start))
    }
    func testClockStepsAndMalformedOrImpossibleServerTimingsAreRejected() {
        XCTAssertNil(DiagnosticClockSample.estimate(localStarted: start, localFinished: start.addingTimeInterval(5), monotonicMS: 100,
            remoteReceivedMS: 1_800_000_001_030, remoteSentMS: 1_800_000_001_050))
        XCTAssertNil(sample(received: 200, sent: 100)); XCTAssertNil(sample(received: 0, sent: Int64.max))
        XCTAssertNil(sample(elapsed: 10)); XCTAssertNil(DiagnosticCorrelation.reference("private-token"))
        XCTAssertEqual(DiagnosticCorrelation.fields(reference: String(repeating: "a", count: 64), attempt: -1), "")
    }
    func testWatchBridgeComposesOffsetsAndUncertaintyAndRejectsStaleParentSamples() throws {
        let parent = try XCTUnwrap(sample()),watch = DiagnosticClockSample(offsetMS: 300, uncertaintyMS: 20, sampledAt: start.addingTimeInterval(1))
        let combined = try XCTUnwrap(parent.bridged(to: watch, phoneSentAt: parent.sampledAt.addingTimeInterval(1)))
        XCTAssertEqual(combined.offsetMS, 1290);XCTAssertGreaterThanOrEqual(combined.uncertaintyMS, 61)
        XCTAssertEqual(combined.source, .phoneBridge)
        XCTAssertNil(parent.bridged(to: watch, phoneSentAt: parent.sampledAt.addingTimeInterval(1000)))
    }
    func testNumericNetworkSummaryOmitsInvalidMetricsAndDoesNotInventReusedConnectionTimes() {
        let timing = DiagnosticNetworkTiming(transactions: 1, reusedConnections: 1, tlsMS: -1, serverWaitMS: 2500)
        XCTAssertTrue(timing.fields.contains("server_wait_ms=2500"));XCTAssertTrue(timing.fields.contains("reused_connections=1"))
        XCTAssertFalse(timing.fields.contains("tls_ms="));XCTAssertFalse(timing.fields.contains("dns_ms="))
    }
    func testCorrelationSurvivesCodingAndDistinctDeliveryAttemptsSurviveTraceDeduplication() throws {
        var alert = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: start, createdAt: start, duration: 5, isTest: false,
                                  diagnosticRef: String(repeating: "a", count: 64), deliveryAttempt: 1)
        XCTAssertEqual(try JSONDecoder().decode(WatchCryAlert.self, from: JSONEncoder().encode(alert)), alert)
        let first = WatchAlertTrace(alert: alert, phase: .retained)
        alert.deliveryAttempt = 2;let retry = WatchAlertTrace(alert: alert, phase: .retained)
        XCTAssertNotEqual(first.key, retry.key)
        XCTAssertEqual(WatchAlertTrace.key(in: "timestamp " + (try XCTUnwrap(retry.entry))), retry.key)
        alert.diagnosticRef = "private-header"
        let rejected = WatchAlertTrace(alert: alert, phase: .retained)
        XCTAssertFalse(try XCTUnwrap(rejected.entry).contains("private-header"))
        XCTAssertEqual(WatchAlertTrace.key(in: "timestamp " + (try XCTUnwrap(rejected.entry))), rejected.key)
    }
}
