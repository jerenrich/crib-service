import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class AlertTestConfigurationTests: XCTestCase {
    func testRequiresDeliveryAndBoundsRepeats() {
        var configuration = AlertTestConfiguration()
        XCTAssertTrue(configuration.isValid)
        configuration.phone = false; configuration.watch = false
        XCTAssertFalse(configuration.isValid)
        configuration.alarmKit = true
        XCTAssertTrue(configuration.isValid)
        configuration.count = 21
        XCTAssertFalse(configuration.isValid)
        configuration.count = 20; configuration.repeatInterval = 30
        XCTAssertTrue(configuration.isValid)
        configuration.repeatInterval = 0
        XCTAssertFalse(configuration.isValid)
    }

    func testHeadStartRequiresBothNotificationRoutes() {
        var configuration = AlertTestConfiguration()
        configuration.phoneHeadStartMS = 500
        XCTAssertTrue(configuration.isValid)
        configuration.watch = false
        XCTAssertFalse(configuration.isValid)
        configuration.watch = true; configuration.phoneHeadStartMS = 501
        XCTAssertFalse(configuration.isValid)
    }

    func testDecodesServerSessionAndDetectsActiveStates() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = Data("""
        {"session":{"id":"3B1550D8-D918-4B64-9BE6-A8A28B31ACD1","configuration":{
          "alarmKit":false,"phone":true,"watch":false,"repeatInterval":5,"count":2,
          "sharedCollapseIDs":true,"distinctRequestIDs":false,"coalesceRepeats":true,
          "groupNotifications":true,"phoneHeadStartMS":0},
          "startsAt":"2026-10-27T10:00:10Z","nextAt":"2026-10-27T10:00:15Z",
          "completedCount":1,"state":"running","message":null}}
        """.utf8)
        let session = try XCTUnwrap(decoder.decode(AlertTestResponse.self, from: data).session)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.completedCount, 1)
        XCTAssertEqual(session.nextAt?.timeIntervalSince(session.startsAt), 5)
        XCTAssertTrue(session.configuration.coalesceRepeats)
    }
}
