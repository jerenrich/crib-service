#if !canImport(MonitorCore)
import Foundation
import XCTest
@testable import BabyCryMonitor

final class NightstandDeviceTests: XCTestCase {
    @MainActor private func parentFixture() throws -> AppModelTests.Fixture {
        try AppModelTests.Fixture(configureDefaults: { defaults, _ in
            defaults.set("parent", forKey: "role")
            defaults.set(true, forKey: "paired|https://monitor.test|parent")
        })
    }
    @MainActor func testUnpairedModeShowsOnlyThisIPhone() throws {
        let fixture = try AppModelTests.Fixture()
        fixture.model.paired = false
        XCTAssertEqual(fixture.model.nightstandDevices.map(\.id), ["listener"])
        fixture.model.selectRole(.parent)
        XCTAssertEqual(fixture.model.nightstandDevices.map(\.id), ["parent"])
    }

    @MainActor func testStaleListenerStatusNeverLooksLiveOrShowsCurrentPower() throws {
        let fixture = try parentFixture()
        fixture.model.paired = true
        fixture.model.parentStatus = ParentStatus(paired: true,
            lastHeartbeat: fixture.model.now.addingTimeInterval(-151), monitoring: true,
            batteryLevel: 0.82, powerConnected: true, configuration: MonitoringConfiguration())
        let nursery = try XCTUnwrap(fixture.model.nightstandDevices.first { $0.id == "listener" })
        XCTAssertEqual(nursery.status, "Connection lost")
        XCTAssertEqual(nursery.tone, .warning)
        XCTAssertTrue(nursery.detail.contains("Last known"))
        XCTAssertTrue(nursery.detail.contains("82%"))
    }

    @MainActor func testMissingHeartbeatDoesNotInventPowerInformation() throws {
        let fixture = try parentFixture()
        fixture.model.paired = true
        fixture.model.parentStatus = ParentStatus(paired: true, monitoring: false,
            powerConnected: false, configuration: MonitoringConfiguration())
        let nursery = try XCTUnwrap(fixture.model.nightstandDevices.first { $0.id == "listener" })
        XCTAssertEqual(nursery.status, "Status unavailable")
        XCTAssertTrue(nursery.detail.contains("Battery unavailable"))
        XCTAssertFalse(nursery.detail.contains("On battery"))
        XCTAssertFalse(nursery.detail.contains("Last known"))
    }

    @MainActor func testRegisteredWatchIsNotReportedAsReachable() throws {
        let fixture = try parentFixture()
        fixture.model.paired = true
        fixture.model.parentStatus = ParentStatus(paired: true, watchPushRegistered: true,
            configuration: MonitoringConfiguration())
        let watch = try XCTUnwrap(fixture.model.nightstandDevices.first { $0.id == "watch" })
        XCTAssertEqual(watch.status, "Alerts registered")
        XCTAssertTrue(watch.detail.contains("Live Watch status unavailable"))
        fixture.connectivity.available = false
        XCTAssertEqual(fixture.model.nightstandDevices.first { $0.id == "watch" }?.status, "Status unavailable")
    }

    @MainActor func testListenerReceivesRemoteDestinationsWithoutInventingOnlineState() async throws {
        let fixture = try AppModelTests.Fixture()
        fixture.model.paired = true
        await fixture.backend.setStatus(ParentStatus(paired: true, watchPushRegistered: true,
            phonePushRegistered: true, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        for _ in 0..<200 {
            if fixture.model.listenerPairStatus != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(fixture.model.nightstandDevices.map(\.id), ["listener", "parent", "watch"])
        let parent = try XCTUnwrap(fixture.model.nightstandDevices.first { $0.id == "parent" })
        XCTAssertEqual(parent.status, "Alerts registered")
        XCTAssertTrue(parent.detail.contains("Live device status unavailable"))
        fixture.model.now = fixture.model.now.addingTimeInterval(31)
        XCTAssertEqual(fixture.model.nightstandDevices.first { $0.id == "parent" }?.status, "Paired")
        XCTAssertEqual(fixture.model.nightstandDevices.first { $0.id == "watch" }?.status, "Status unavailable")
    }
}
#endif
