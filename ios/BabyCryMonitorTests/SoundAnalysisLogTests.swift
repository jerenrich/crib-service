import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SoundAnalysisLogTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func rows(in urls: [URL]) throws -> [[String]] {
        try String(contentsOf: urls[0], encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.components(separatedBy: ",") }
    }
    @MainActor func testExportPreservesQuietScoresAndVolumeTriggersWithoutChangingAlerts() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        let now = Date(), capture = UUID()
        var config = MonitoringConfiguration(); config.absoluteThreshold = -35
        log.monitoring(true, at: now)
        log.classification(.started(id: capture, at: now, sampleRate: 48_000, voiceProcessing: false))
        log.level(.init(timestamp: now, dbFS: -35.01), configuration: config, state: .quiet,
                  alertQueued: false, episode: nil, nurserySound: nil, appActive: false)
        log.level(.init(timestamp: now.addingTimeInterval(0.25), dbFS: -35), configuration: config, state: .possibleCry,
                  alertQueued: false, episode: nil, nurserySound: .whiteNoise, appActive: true)
        let episode = CryEpisode(startedAt: now)
        log.level(.init(timestamp: now.addingTimeInterval(5), dbFS: -20), configuration: config, state: .crying,
                  alertQueued: true, episode: episode, nurserySound: nil, appActive: false)
        log.classification(.result(.init(captureID: capture, windowStart: now, windowEnd: now.addingTimeInterval(2),
                                        confidence: 0, observedAt: now.addingTimeInterval(3))))
        log.classification(.result(.init(captureID: capture, windowStart: now.addingTimeInterval(1),
            windowEnd: now.addingTimeInterval(3), confidence: 0.987654, observedAt: now.addingTimeInterval(4))))
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        let levels = data.filter { $0[2] == "level" }
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels.map { $0[9] }, ["0", "1", "1"])
        XCTAssertEqual(levels.map { $0[10] }, ["quiet", "possibleCry", "crying"])
        XCTAssertEqual(levels.map { $0[11] }, ["0", "0", "1"])
        XCTAssertEqual(levels[2][12], episode.id.uuidString.lowercased())
        XCTAssertEqual(levels[1][16], "whiteNoise")
        let scores = data.filter { $0[2] == "classification" }
        XCTAssertEqual(scores.map { $0[6] }, ["0.000000", "0.987654"])
        XCTAssertNotEqual(scores[0][0], scores[0][5], "Receipt time must remain distinct from audio time")
        XCTAssertEqual(scores[0][3], capture.uuidString.lowercased())
        XCTAssertEqual(log.latestConfidence, 0.987654)
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("Scores are diagnostic only"))
    }
    @MainActor func testSuccessiveBatchesContinueWritingAndExportSurvivesRelaunch() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        for index in 0..<100 {
            log.level(.init(timestamp: Date().addingTimeInterval(Double(index) / 4), dbFS: -50),
                      configuration: .init(), state: .quiet, alertQueued: false, episode: nil, nurserySound: nil, appActive: false)
            if index == 39 { await log.flush() }
        }
        await log.flush()
        let restored = SoundAnalysisLog(directory: directory)
        let export = try await restored.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertEqual(try rows(in: export).filter { $0[2] == "level" }.count, 100)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sound-analysis"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "coverage.json" })
        #if os(iOS)
        for file in files where file.pathExtension == "csv" {
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        #endif
    }
    func testAgeRetentionAndByteCapAreIndependentAndPersistEvictionCoverage() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), row = String(repeating: "x", count: 600) + "\n"
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 1500, segmentBytes: 1000)
        let first = await writer.append([row], droppedRows: 0, at: now.addingTimeInterval(-43 * 86400))
        XCTAssertTrue(first.available)
        let second = await writer.append([row], droppedRows: 0, at: now.addingTimeInterval(-86400))
        XCTAssertTrue(second.available)
        let third = await writer.append([row], droppedRows: 0, at: now)
        XCTAssertTrue(third.available)
        let restarted = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 1500)
        let export = try await restarted.prepareExport(droppedRows: 0, at: now)
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let report = try String(contentsOf: export[1], encoding: .utf8)
        XCTAssertTrue(report.contains("evicted_files=2"), report)
        XCTAssertEqual(try String(contentsOf: export[0], encoding: .utf8), SoundAnalysisLog.header + row)
    }
    @MainActor func testUnavailableAndDroppedEvidenceNeverInventsZeroConfidence() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), id = UUID()
        log.classification(.result(.init(captureID: id, windowStart: now, windowEnd: now, confidence: .nan, observedAt: now)))
        log.classification(.result(.init(captureID: id, windowStart: now, windowEnd: now, confidence: 0.7, observedAt: now)))
        log.classification(.unavailable(at: now))
        log.classification(.droppedBuffers(count: 5, at: now))
        log.classification(.droppedEvents(at: now))
        XCTAssertNil(log.latestConfidence)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        XCTAssertEqual(data.filter { $0[2] == "classification" }.count, 1)
        XCTAssertEqual(data.first { $0[2] == "classifier_unavailable" }?[6], "")
        XCTAssertEqual(data.first { $0[2] == "classifier_gap" }?[18], "dropped_buffers=5")
        XCTAssertNotNil(data.first { $0[2] == "classifier_event_gap" })
    }
    @MainActor func testBoundedMemoryDropsAreExplicitInNextFlushAndCoverage() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        // Deliberately do not yield, so disk work cannot drain the main actor buffer.
        for _ in 0..<800 { log.classification(.unavailable(at: Date())) }
        XCTAssertGreaterThan(log.droppedRows, 0)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertTrue(try rows(in: export).contains { $0[2] == "telemetry_gap" })
        let report = try String(contentsOf: export[1], encoding: .utf8)
        XCTAssertTrue(report.contains("memory_dropped_rows=\(log.droppedRows)"), report)
    }
    @MainActor func testStorageFailureIsVisibleAndDoesNotBlockDetection() async throws {
        let file = folder(); defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let log = SoundAnalysisLog(directory: file)
        log.classification(.unavailable(at: Date()))
        await log.flush()
        XCTAssertFalse(log.persistenceAvailable)
        XCTAssertTrue(log.status.contains("rows lost"))
        // Fixing the directory permits subsequent observations without a relaunch.
        try FileManager.default.removeItem(at: file)
        log.classification(.unavailable(at: Date()))
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertTrue(log.persistenceAvailable)
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("write_failures=1"))
    }
    func testExportStreamsSegmentsWithOneHeaderAndReplacesPreviousSnapshot() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000, segmentBytes: 600)
        let now = Date(), a = "a\n", b = "b\n"
        _ = await writer.append([a], droppedRows: 0, at: now)
        _ = await writer.append([b], droppedRows: 0, at: now.addingTimeInterval(86400))
        let first = try await writer.prepareExport(droppedRows: 0, at: now.addingTimeInterval(86400))
        let second = try await writer.prepareExport(droppedRows: 0, at: now.addingTimeInterval(86400))
        defer { try? FileManager.default.removeItem(at: second[0].deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first[0].path))
        XCTAssertEqual(try String(contentsOf: second[0], encoding: .utf8), SoundAnalysisLog.header + a + b)
    }
}
