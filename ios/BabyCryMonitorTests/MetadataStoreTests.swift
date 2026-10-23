#if !canImport(MonitorCore)
import Foundation
import XCTest
@testable import BabyCryMonitor
final class MetadataStoreTests: XCTestCase {
    @MainActor func testOutboxIsDurableAndExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MetadataStore(directory: directory)
        var simulation = CrySessionTests.Simulation(); simulation.run(306)
        try store.save(simulation.engine.snapshot)
        let restored = try MetadataStore(directory: directory).load()
        XCTAssertEqual(restored.pending.count, 1)
        XCTAssertEqual(restored.pending[0].alert.eventId, simulation.emitted[0].eventId)
        XCTAssertNotNil(restored.current)
        let file = directory.appendingPathComponent("listener-metadata.json")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if !targetEnvironment(simulator)
        // Simulator storage is macOS and does not report iOS Data Protection classes.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
    }
    @MainActor func testCorruptionIsReportedInsteadOfDiscardingPendingEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MetadataStore(directory: directory)
        let missing = try store.load(); XCTAssertTrue(missing.pending.isEmpty)
        try Data("invalid metadata".utf8).write(to: directory.appendingPathComponent("listener-metadata.json"))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual((error as? MetadataStoreError)?.operation, .decode)
            XCTAssertTrue((error as? MetadataStoreError)?.underlyingError is DecodingError)
        }
    }
}
#endif
