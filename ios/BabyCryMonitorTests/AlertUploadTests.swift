import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class AlertUploadTests: XCTestCase {
    private func alert() -> CryAlert {
        let created = Date(timeIntervalSince1970: 1_800_000_000.569)
        return CryAlert(episodeId: UUID(), listenerId: UUID(), cryStartedAt: created.addingTimeInterval(-5),
                        durationSeconds: 5, createdAt: created, isRepeat: false)
    }
    private func wire(_ alert: CryAlert) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AlertUpload(alert: alert))) as? [String: Any])
    }
    func testNewAlertKeepsMillisecondsAcrossPersistenceAndWireRetries() throws {
        let original = alert()
        let restored = try JSONDecoder().decode(CryAlert.self, from: JSONEncoder().encode(original))
        let first = try wire(original), retry = try wire(restored)
        XCTAssertEqual(first["createdAt"] as? String, "2027-01-15T08:00:00.569Z")
        XCTAssertEqual(first["cryStartedAt"] as? String, "2027-01-15T07:59:55.569Z")
        XCTAssertEqual(first["createdAt"] as? String, retry["createdAt"] as? String)
        XCTAssertNil(first["wireTimestampVersion"])
        XCTAssertEqual(first.count, 8)
    }
    func testLegacyQueuedAlertRetainsSecondRoundedWireIdentityAfterUpgrade() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(alert())) as? [String: Any])
        saved.removeValue(forKey: "wireTimestampVersion")
        let legacy = try JSONDecoder().decode(CryAlert.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(legacy.wireTimestampVersion)
        XCTAssertEqual(try wire(legacy)["createdAt"] as? String, "2027-01-15T08:00:00Z")
        let restored = try JSONDecoder().decode(CryAlert.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(try wire(restored)["createdAt"] as? String, "2027-01-15T08:00:00Z")
    }
}
