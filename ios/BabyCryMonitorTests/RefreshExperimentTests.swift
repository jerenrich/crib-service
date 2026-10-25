import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class RefreshExperimentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    @MainActor func testKeepsOnePendingRequestWithoutPostponingItsDeadline() {
        let log = RefreshExperimentLog(directory: nil, now: now)
        XCTAssertNil(log.beginRequest(availability: "available", at: now))
        log.start(at: now)
        let request = log.beginRequest(availability: "available", at: now)!
        XCTAssertEqual(request.earliestBeginAt, now.addingTimeInterval(60))
        log.submission(request.id, errorCode: nil, at: now)
        XCTAssertNil(log.beginRequest(availability: "available", at: now.addingTimeInterval(60)))
        XCTAssertEqual(log.pending?.id, request.id)
        XCTAssertEqual(log.pending?.earliestBeginAt, request.earliestBeginAt)
        let report = log.report(at: now.addingTimeInterval(180))
        XCTAssertTrue(report.contains("status=pending")); XCTAssertTrue(report.contains("observed_wait_seconds=180"))
        XCTAssertTrue(report.contains("overdue_seconds=120"))
        XCTAssertFalse(report.contains("executed="))
    }
    @MainActor func testDeliveryLatencyCompletionAndNextRequest() {
        let log = RefreshExperimentLog(directory: nil, now: now); log.start(at: now)
        let first = log.beginRequest(availability: "available", at: now)!
        log.submission(first.id, errorCode: nil, at: now)
        let id = log.delivered(at: now.addingTimeInterval(95))
        XCTAssertEqual(id, first.id)
        log.finished(id, expired: false, at: now.addingTimeInterval(96))
        log.finished(id, expired: true, at: now.addingTimeInterval(97))
        XCTAssertEqual(log.attempts[0].status, .completed, "A late expiration must not overwrite completion")
        let next = log.beginRequest(availability: "available", at: now.addingTimeInterval(95))!
        XCTAssertEqual(next.earliestBeginAt, now.addingTimeInterval(155))
        let report = log.report(at: now.addingTimeInterval(100))
        XCTAssertTrue(report.contains("request_to_execution_seconds=95")); XCTAssertTrue(report.contains("lateness_seconds=35"))
    }
    @MainActor func testFailureCancellationAndMissingQueueAreDistinct() {
        let log = RefreshExperimentLog(directory: nil, now: now); log.start(at: now)
        let failed = log.beginRequest(availability: "denied", at: now)!
        log.submission(failed.id, errorCode: 1, at: now)
        XCTAssertEqual(log.attempts[0].status, .submissionFailed)
        let missing = log.beginRequest(availability: "available", at: now.addingTimeInterval(60))!
        log.submission(missing.id, errorCode: nil, at: now.addingTimeInterval(60))
        log.reconcile(earliestBeginAt: nil, at: now.addingTimeInterval(120))
        XCTAssertEqual(log.attempts[1].status, .notObserved)
        let cancelled = log.beginRequest(availability: "available", at: now.addingTimeInterval(120))!
        log.stop(at: now.addingTimeInterval(121))
        log.submission(cancelled.id, errorCode: nil, at: now.addingTimeInterval(122))
        XCTAssertEqual(log.attempts[2].status, .cancelled)
        XCTAssertFalse(log.enabled)
    }
    @MainActor func testRestorePendingAcrossProcessRelaunchAndExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = RefreshExperimentLog(directory: directory, now: now); first.start(at: now)
        let request = first.beginRequest(availability: "available", at: now)!
        first.submission(request.id, errorCode: nil, at: now)
        let second = RefreshExperimentLog(directory: directory, now: now.addingTimeInterval(120))
        XCTAssertTrue(second.enabled); XCTAssertEqual(second.pending?.id, request.id)
        XCTAssertNotEqual(first.runID, second.runID)
        _ = second.delivered(at: now.addingTimeInterval(130))
        XCTAssertEqual(second.attempts[0].deliveryRunID, second.runID)
        let third = RefreshExperimentLog(directory: directory, now: now.addingTimeInterval(86400))
        XCTAssertFalse(third.enabled)
        XCTAssertEqual(third.attempts[0].status, .delivered, "An unfinished delivered task must not be called completed or never executed")
    }
    @MainActor func testAdoptedQueueAndUnmatchedDeliveryNeverInventSubmissionTime() {
        let log = RefreshExperimentLog(directory: nil, now: now); log.start(at: now)
        log.reconcile(earliestBeginAt: now.addingTimeInterval(60), at: now)
        XCTAssertNil(log.pending?.submittedAt)
        let id = log.delivered(at: now.addingTimeInterval(100))
        log.finished(id, expired: true, at: now.addingTimeInterval(101))
        XCTAssertEqual(log.attempts[0].status, .expired)
        XCTAssertFalse(log.report(at: now).contains("request_to_execution_seconds="))
        _ = log.delivered(at: now.addingTimeInterval(102))
        XCTAssertNil(log.attempts.last?.submittedAt)
    }
    @MainActor func testStorageFailureLeavesResultsExportableAndNormalizesAvailability() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let log = RefreshExperimentLog(directory: file, now: now); log.start(at: now)
        _ = log.beginRequest(availability: "private-token", at: now)
        XCTAssertFalse(log.persistenceAvailable)
        XCTAssertFalse(log.report(at: now).contains("private-token"))
        XCTAssertEqual(log.pending?.refreshAvailability, "unknown")
    }
}
