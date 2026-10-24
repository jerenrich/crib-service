import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class BatteryDrainLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    @MainActor private func record(_ log: BatteryDrainLog, seconds: Double = 0, level: Double? = 0.9,
                                  powered: Bool? = false, monitoring: Bool = true, audio: Bool = true,
                                  lowPower: Bool = false, active: Bool = false) {
        log.record(batteryLevel: level, powerConnected: powered, monitoring: monitoring, audioActive: audio,
                   lowPowerMode: lowPower, appActive: active, at: start.addingTimeInterval(seconds))
    }
    @MainActor func testFiveMinuteSamplingAndImmediateContextTransitions() {
        let log = BatteryDrainLog(directory: nil, now: start)
        record(log)
        record(log, seconds: 299, level: 0.89)
        XCTAssertEqual(log.samples.count, 1)
        record(log, seconds: 300, level: 0.88)
        record(log, seconds: 301, powered: true)
        record(log, seconds: 302, powered: true, monitoring: false, audio: false)
        record(log, seconds: 303, powered: true, monitoring: false, audio: false, lowPower: true)
        record(log, seconds: 304, powered: true, monitoring: false, audio: false, lowPower: true, active: true)
        XCTAssertEqual(log.samples.count, 6)
    }
    @MainActor func testRelaunchRetainsSamplesButStartsNewRunImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatteryDrainLog(directory: directory, now: start)
        record(log)
        XCTAssertTrue(log.persistenceAvailable)
        let restored = BatteryDrainLog(directory: directory, now: start.addingTimeInterval(1))
        record(restored, seconds: 1)
        XCTAssertEqual(restored.samples.count, 2)
        XCTAssertNotEqual(restored.samples[0].runID, restored.samples[1].runID)
        XCTAssertTrue(restored.export.contains("battery_percent,power_connected,monitoring,audio_active,low_power_mode,app_active"))
        XCTAssertTrue(restored.export.contains(",90.00,0,1,1,0,0"))
    }
    @MainActor func testRetainsThirtyDaysAndCapsTenThousandSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runID = UUID()
        let rows = (0..<10_001).map { index in
            BatteryDrainLog.Sample(timestamp: start.addingTimeInterval(Double(index)), runID: runID,
                                   batteryLevel: 0.9, powerConnected: false, monitoring: true, audioActive: true,
                                   lowPowerMode: false, appActive: false)
        }
        try JSONEncoder().encode(rows).write(to: directory.appendingPathComponent("battery-drain.json"))
        let log = BatteryDrainLog(directory: directory, now: start.addingTimeInterval(10_000))
        XCTAssertEqual(log.samples.count, 10_000)
        XCTAssertEqual(log.samples.first?.timestamp, start.addingTimeInterval(1))
        record(log, seconds: BatteryDrainLog.retention + 10_001)
        XCTAssertEqual(log.samples.count, 1)
        let restored = BatteryDrainLog(directory: directory, now: start.addingTimeInterval(2 * BatteryDrainLog.retention + 10_002))
        XCTAssertTrue(restored.samples.isEmpty)
    }
    @MainActor func testUnknownAndInvalidReadingsRemainExplicitGaps() {
        let log = BatteryDrainLog(directory: nil, now: start)
        record(log)
        record(log, seconds: 1, level: nil, powered: nil)
        XCTAssertEqual(log.samples.count, 2)
        XCTAssertNil(log.samples.last?.batteryLevel)
        XCTAssertNil(log.samples.last?.powerConnected)
        record(log, seconds: 301, level: .nan)
        XCTAssertNil(log.samples.last?.batteryLevel)
        XCTAssertFalse(log.export.contains("nan"))
        record(log, seconds: 302, level: 0.8)
        XCTAssertEqual(log.samples.last?.batteryLevel, 0.8)
    }
    @MainActor func testClockRollbackDoesNotSuppressNewSamples() {
        let log = BatteryDrainLog(directory: nil, now: start)
        record(log)
        record(log, seconds: -10)
        XCTAssertEqual(log.samples.count, 2)
    }
    @MainActor func testStorageFailureKeepsExportableInMemoryEvidence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let log = BatteryDrainLog(directory: file, now: start)
        record(log)
        XCTAssertFalse(log.persistenceAvailable)
        XCTAssertEqual(log.samples.count, 1)
        XCTAssertTrue(log.export.contains("persistence=unavailable"))
    }
}
