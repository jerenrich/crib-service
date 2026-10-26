import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class NotificationCallbackJournalTests: XCTestCase {
    private func trace(phase: WatchAlertTrace.Phase = .controllerReceived) -> WatchAlertTrace {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let alert = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: date, createdAt: date, duration: 5, isTest: false)
        return WatchAlertTrace(alert: alert, phase: phase, deliveredAt: date.addingTimeInterval(1), observedAt: date.addingTimeInterval(15), callbackID: UUID())
    }
    func testEntryIsOnDiskBeforeReturningAndSurvivesRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = trace(), journal = NotificationCallbackJournal(directory: dir)
        journal.record(first)
        let file = dir.appendingPathComponent("watch-callbacks.log")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("watch_callback phase=controller_received"))
        XCTAssertTrue(saved.contains("callback_id=\(first.callbackID!.uuidString.lowercased())"))
        XCTAssertTrue(saved.contains("callback_lag_ms=14000"))
        XCTAssertTrue(saved.contains("callback_process_id="));XCTAssertTrue(saved.contains("process_elapsed_ms="))
        let restored = NotificationCallbackJournal(directory: dir)
        restored.record(trace())
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(saved))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 2)
    }
    func testPresentationProfileIsPersistedIndependentlyOfTheMainActorLogger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = NotificationCallbackJournal(directory: dir)
        journal.presentationProfile(.system)
        let entry = try String(contentsOf: dir.appendingPathComponent("watch-callbacks.log"), encoding: .utf8)
        XCTAssertTrue(entry.contains("watch_notification_presentation profile=system"))
        XCTAssertTrue(entry.contains("callback_process_id="))
        XCTAssertFalse(entry.contains("callback_id="), "A process profile marker must not look like a notification callback")
    }
    func testHistoryCannotCreateCallbackEntriesAndRepeatedInstancesAreRetained() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = NotificationCallbackJournal(directory: dir), value = trace()
        journal.record(trace(phase: .retained));journal.record(value);journal.record(value)
        let text = try String(contentsOf: dir.appendingPathComponent("watch-callbacks.log"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2);XCTAssertFalse(text.contains("phase=retained"))
    }
    func testRotationBoundsDiskAndRetainsRecentCompleteLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = NotificationCallbackJournal(directory: dir, segmentBytes: 1024)
        for _ in 0..<50 { journal.record(trace()) }
        journal.checkpoint(historyCount: 2)
        for name in ["watch-callbacks.log", "watch-callbacks.previous.log"] {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 1024);XCTAssertEqual(data.last, 10)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { XCTAssertTrue(line.contains("journal_sequence=")) }
        }
        let current = try String(contentsOf: dir.appendingPathComponent("watch-callbacks.log"), encoding: .utf8)
        XCTAssertTrue(current.contains("watch_callback_coverage"));XCTAssertTrue(current.contains("delivered_history_count=2"))
    }
    func testInterruptedTailIsRepairedWithoutDiscardingCompleteRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("watch-callbacks.log")
        try Data("complete record\npartial record".utf8).write(to: file)
        let journal = NotificationCallbackJournal(directory: dir)
        journal.record(trace());journal.checkpoint()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("complete record\n"));XCTAssertFalse(text.contains("partial record"))
        XCTAssertTrue(text.contains("repaired_tails=1"))
    }
    func testConcurrentAppendsStayWholeAndReportStorageFailureWithoutThrowing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = NotificationCallbackJournal(directory: dir), value = trace()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { journal.record(value) } }
        }
        let text = try String(contentsOf: dir.appendingPathComponent("watch-callbacks.log"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 30)
        for line in text.split(separator: "\n") { XCTAssertTrue(line.contains("callback_id="));XCTAssertTrue(line.contains("journal_sequence=")) }
        let blocked = dir.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failure = NotificationCallbackJournal(directory: blocked)
        failure.record(value) // No exception, model initialization, or retry loop.
    }
}
