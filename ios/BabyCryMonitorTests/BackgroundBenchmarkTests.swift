import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class BackgroundBenchmarkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var context: BackgroundBenchmark.Context { .init(active: true, powered: true, lowPower: false, networkAvailable: true, battery: 0.8) }
    @MainActor func testDisabledRecorderDoesNothingAndSamplingUsesUptime() {
        let recorder = BackgroundBenchmark(directory: nil, now: start, uptime: 100)
        recorder.observe(context, at: start, uptime: 100)
        XCTAssertNil(recorder.requestStarted(at: start, uptime: 100))
        XCTAssertEqual(recorder.entryCount, 0)
        recorder.start(at: start, uptime: 100)
        recorder.observe(context, at: start, uptime: 100)
        recorder.observe(context, at: start.addingTimeInterval(4), uptime: 104)
        recorder.observe(context, at: start.addingTimeInterval(5), uptime: 105)
        XCTAssertEqual(recorder.entries.filter { $0.kind == .sample }.count, 2)
        var background = context; background.active = false
        recorder.observe(background, at: start.addingTimeInterval(6), uptime: 106)
        XCTAssertEqual(recorder.entries.filter { $0.kind == .context }.count, 2)
    }
    @MainActor func testRelaunchKeepsSessionButChangesProcessAndStopPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BackgroundBenchmark(directory: directory, now: start, uptime: 100)
        first.start(at: start, uptime: 100); first.mark(.podcastVisible, at: start, uptime: 100)
        let second = BackgroundBenchmark(directory: directory, now: start.addingTimeInterval(60), uptime: 160)
        XCTAssertTrue(second.enabled); XCTAssertEqual(second.scenario, .podcastVisible)
        XCTAssertNotEqual(first.runID, second.runID)
        XCTAssertEqual(second.entries.first?.sessionID, second.entries.last?.sessionID)
        XCTAssertEqual(second.entries.last?.kind, .launch)
        second.stop(at: start.addingTimeInterval(61), uptime: 161)
        let third = BackgroundBenchmark(directory: directory, now: start.addingTimeInterval(62), uptime: 162)
        XCTAssertFalse(third.enabled)
        XCTAssertTrue(third.report.contains("process_runs=2"))
    }
    @MainActor func testAutoExpiryAndClockRollbackStopRecording() {
        for seconds in [BackgroundBenchmark.maximumDuration, -1] {
            let recorder = BackgroundBenchmark(directory: nil, now: start, uptime: 100)
            recorder.start(at: start, uptime: 100)
            recorder.observe(context, at: start.addingTimeInterval(seconds), uptime: 200)
            XCTAssertFalse(recorder.enabled)
            XCTAssertEqual(recorder.entries.last?.kind, .stop)
        }
    }
    @MainActor func testEveryStatusAttemptIsRecordedWithServerCorrelationWithoutRoutineSampling() {
        let recorder = BackgroundBenchmark(directory: nil, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        let serverID = UUID()
        for second in 0..<3 {
            let at = start.addingTimeInterval(Double(second))
            let attempt = recorder.requestStarted(at: at, uptime: 100 + Double(second))
            recorder.requestFinished(attempt, outcome: "ok", requestID: serverID, status: 200, elapsedMS: 10, at: at, uptime: 100 + Double(second))
        }
        XCTAssertEqual(recorder.entries.filter { $0.kind == .requestEnd }.count, 3)
        XCTAssertTrue(recorder.report.contains(serverID.uuidString))
        XCTAssertTrue(recorder.report.contains("unfinished_status_requests=0"))
        let previous = recorder.requestStarted(at: start, uptime: 100)
        recorder.stop(at: start, uptime: 100); recorder.start(at: start, uptime: 100)
        recorder.requestFinished(previous, outcome: "ok", requestID: nil, status: 200, elapsedMS: 0, at: start, uptime: 100)
        XCTAssertEqual(recorder.entries.filter { $0.kind == .requestEnd }.count, 3)
    }
    @MainActor func testExecutionGapsAndSimulatedDeadlinesIncludeOnlyObservedTime() {
        let recorder = BackgroundBenchmark(directory: nil, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        recorder.mark(.podcastVisible, at: start, uptime: 100)
        recorder.observe(context, at: start, uptime: 100)
        recorder.verifiedQuiet(at: start, uptime: 100)
        recorder.observe(context, at: start.addingTimeInterval(65), uptime: 165)
        let report = recorder.report
        XCTAssertTrue(report.contains("largest_observed_execution_sample_gap_seconds=65"))
        XCTAssertTrue(report.contains("scenario=podcastVisible samples=2 largest_observed_sample_gap_seconds=65"))
        XCTAssertTrue(report.contains("simulated_30s_deadline_crossings=1"))
        XCTAssertTrue(report.contains("simulated_60s_deadline_crossings=1"))
        XCTAssertTrue(report.contains("simulated_120s_deadline_crossings=0"))
        XCTAssertTrue(report.contains("unfinished_status_requests=0"))
    }
    @MainActor func testJournalCompactsInBatchesAndRetainsActiveSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let row = BackgroundBenchmark.Entry(at: start, uptime: 100, runID: UUID(), sessionID: UUID(), scenario: .foreground, kind: .sample)
        var line = try JSONEncoder().encode(row); line.append(10)
        var data = Data()
        for _ in 0..<BackgroundBenchmark.maximumEntries { data.append(line) }
        let url = directory.appendingPathComponent("background-benchmark.jsonl")
        try data.write(to: url)
        let recorder = BackgroundBenchmark(directory: directory, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        XCTAssertEqual(recorder.entryCount, BackgroundBenchmark.maximumEntries - 5000)
        XCTAssertEqual(recorder.entries.last?.kind, .start)
        XCTAssertEqual(try Data(contentsOf: url).split(separator: 10).count, recorder.entryCount)
        let restored = BackgroundBenchmark(directory: directory, now: start.addingTimeInterval(1), uptime: 101)
        XCTAssertTrue(restored.enabled)
        XCTAssertLessThan(restored.entryCount, BackgroundBenchmark.maximumEntries)
    }
    @MainActor func testExpiredRecordingDoesNotRestartOnRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BackgroundBenchmark(directory: directory, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        let restored = BackgroundBenchmark(directory: directory, now: start.addingTimeInterval(BackgroundBenchmark.maximumDuration), uptime: 200)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.entries.last?.kind, .stop)
    }
    @MainActor func testClockChangeDoesNotHideDeadlineCrossingsWithinOneProcess() {
        let recorder = BackgroundBenchmark(directory: nil, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        recorder.verifiedQuiet(at: start, uptime: 100)
        recorder.observe(context, at: start.addingTimeInterval(1), uptime: 165)
        XCTAssertTrue(recorder.report.contains("simulated_60s_deadline_crossings=1"))
    }
    @MainActor func testStorageFailureLeavesExportAvailable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let recorder = BackgroundBenchmark(directory: file, now: start, uptime: 100)
        recorder.start(at: start, uptime: 100)
        XCTAssertFalse(recorder.persistenceAvailable)
        XCTAssertEqual(recorder.entryCount, 1)
        XCTAssertTrue(recorder.report.contains("persistence=unavailable"))
    }
}
