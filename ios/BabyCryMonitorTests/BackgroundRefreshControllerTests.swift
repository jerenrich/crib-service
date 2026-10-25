#if !canImport(MonitorCore)
import XCTest
@testable import BabyCryMonitor

@MainActor private final class TestRefreshScheduler: RefreshScheduling {
    var date: Date?
    var submissions: [Date] = []
    var cancellations = 0
    var failure: Error?
    func pendingDate() async -> Date? { date }
    func submit(earliest: Date) async throws {
        submissions.append(earliest)
        if let failure { throw failure }
        date = earliest
    }
    func cancel() { cancellations += 1; date = nil }
}
final class BackgroundRefreshControllerTests: XCTestCase {
    @MainActor func testDoesNotReplaceAcceptedPendingRequestEveryMinute() async {
        let scheduler = TestRefreshScheduler()
        let log = RefreshExperimentLog(directory: nil)
        let controller = BackgroundRefreshController(log: log, scheduler: scheduler)
        await controller.setEnabled(true)
        let first = scheduler.submissions[0]
        await controller.reconcile(at: Date().addingTimeInterval(60))
        await controller.reconcile(at: Date().addingTimeInterval(600))
        XCTAssertEqual(scheduler.submissions, [first])
        XCTAssertEqual(log.pending?.earliestBeginAt, first)
    }
    @MainActor func testFailedSubmissionsRetryOnlyAfterSixtySeconds() async {
        let scheduler = TestRefreshScheduler(); scheduler.failure = NSError(domain: "BGTaskSchedulerErrorDomain", code: 1)
        let log = RefreshExperimentLog(directory: nil)
        let controller = BackgroundRefreshController(log: log, scheduler: scheduler)
        await controller.setEnabled(true)
        await controller.reconcile(at: Date().addingTimeInterval(59))
        XCTAssertEqual(scheduler.submissions.count, 1)
        await controller.reconcile(at: Date().addingTimeInterval(61))
        XCTAssertEqual(scheduler.submissions.count, 2)
        XCTAssertTrue(log.attempts.allSatisfy { $0.status == .submissionFailed })
    }
    @MainActor func testStopAndRoleChangeCancelOwnedTask() async {
        let scheduler = TestRefreshScheduler(); let log = RefreshExperimentLog(directory: nil)
        let controller = BackgroundRefreshController(log: log, scheduler: scheduler)
        await controller.setEnabled(true)
        controller.maintain(parent: false, foreground: false)
        XCTAssertFalse(log.enabled); XCTAssertNil(scheduler.date)
        XCTAssertEqual(log.attempts.last?.status, .cancelled)
        await controller.setEnabled(true)
        await controller.setEnabled(false)
        XCTAssertFalse(log.enabled); XCTAssertNil(scheduler.date)
    }
    @MainActor func testMissingQueueRequestIsPreservedAsNotObserved() async {
        let scheduler = TestRefreshScheduler(); let log = RefreshExperimentLog(directory: nil)
        let controller = BackgroundRefreshController(log: log, scheduler: scheduler)
        await controller.setEnabled(true)
        scheduler.date = nil
        await controller.reconcile(at: Date().addingTimeInterval(61))
        XCTAssertEqual(log.attempts[0].status, .notObserved)
        XCTAssertEqual(log.attempts[1].status, .pending)
    }
}
#endif
