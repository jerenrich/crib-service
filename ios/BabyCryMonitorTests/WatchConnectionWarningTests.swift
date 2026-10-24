import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchConnectionWarningTests: XCTestCase {
    func testFailedParentRefreshPreservesAbsoluteDeadlineDespiteNewSnapshotTime() {
        var snapshot = WatchSnapshot()
        snapshot.parentMode = true; snapshot.paired = true
        snapshot.connectionWarningSupported = true
        snapshot.connectionWarningDeadline = Date(timeIntervalSince1970: 1_180)
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_000)
        snapshot.statusAvailable = true; snapshot.monitoring = true
        let deadline = snapshot.localConnectionDeadline
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_170)
        snapshot.statusAvailable = false; snapshot.monitoring = false
        XCTAssertEqual(snapshot.localConnectionDeadline, deadline)
        snapshot.paired = false
        XCTAssertNil(snapshot.localConnectionDeadline)
        snapshot.paired = true; snapshot.parentMode = false
        XCTAssertNil(snapshot.localConnectionDeadline)
    }

    func testSnapshotRoundTripsDeadlineAndSupportsOldPhoneMessages() throws {
        var snapshot = WatchSnapshot()
        snapshot.parentMode = true; snapshot.paired = true
        snapshot.connectionWarningSupported = true
        snapshot.connectionWarningDeadline = Date(timeIntervalSince1970: 1_180)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WatchSnapshot.self, from: data).localConnectionDeadline,
                       snapshot.connectionWarningDeadline)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "connectionWarningSupported")
        old.removeValue(forKey: "connectionWarningDeadline")
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.localConnectionDeadline)
    }
}
