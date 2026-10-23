import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchAlertSetupTests: XCTestCase {
    @MainActor func testAlreadyGrantedPermissionStillShowsRegistrationProgress() async throws {
        let setup = WatchAlertSetup()
        let allowed = try await setup.requestPermission { true }
        XCTAssertTrue(allowed)
        XCTAssertEqual(setup.phase, .registeringPush)
        XCTAssertTrue(setup.inProgress)
        // A cached registration on the iPhone is not proof this attempt finished.
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .registeringPush)
        setup.sendRegistration = { _ in true }
        setup.receivedToken("abc")
        XCTAssertEqual(setup.phase, .syncing)
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .registered)
        XCTAssertFalse(setup.inProgress)
    }

    @MainActor func testTokenBeforeSessionActivationIsRetriedWithOriginalCommand() async throws {
        let setup = WatchAlertSetup()
        var activated = false
        var commands: [WatchCommand] = []
        setup.sendRegistration = { command in
            guard activated else { return false }
            commands.append(command)
            return true
        }
        _ = try await setup.requestPermission { true }
        setup.receivedToken("abc")
        let issuedAt = try XCTUnwrap(setup.registrationCommand?.issuedAt)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(setup.awaitingConnection)
        XCTAssertEqual(setup.title, "Waiting for your iPhone…")
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .syncing)

        activated = true
        setup.retryRegistration()
        XCTAssertEqual(commands.map(\.token), ["abc"])
        XCTAssertEqual(commands.first?.issuedAt, issuedAt)
        XCTAssertFalse(setup.awaitingConnection)
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .registered)
    }

    @MainActor func testDeniedPermissionGuidanceSurvivesStatusRefresh() async throws {
        let setup = WatchAlertSetup()
        let allowed = try await setup.requestPermission { false }
        XCTAssertFalse(allowed)
        let detail = setup.detail
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .blocked)
        XCTAssertEqual(setup.detail, detail)
        XCTAssertTrue(detail.contains("Watch → Notifications → Crib Service"))
        XCTAssertFalse(setup.notificationsAllowed)
        setup.receivedToken("late-callback")
        XCTAssertNil(setup.registrationCommand)
    }

    @MainActor func testRevocationBeforeActivationRetainsRemovalForRetry() async throws {
        let setup = WatchAlertSetup()
        var commands: [WatchCommand] = []
        setup.sendRegistration = { _ in false }
        setup.updateAuthorization(false, registeredOnPhone: true)
        let removal = try XCTUnwrap(setup.registrationCommand)
        XCTAssertNil(removal.token)
        XCTAssertTrue(setup.awaitingConnection)
        setup.sendRegistration = { commands.append($0); return true }
        setup.retryRegistration()
        XCTAssertEqual(commands.count, 1)
        XCTAssertNil(commands.first?.token)
        XCTAssertEqual(commands.first?.issuedAt, removal.issuedAt)
        XCTAssertEqual(setup.phase, .blocked)
    }

    @MainActor func testAppleRegistrationFailureCannotBeErasedByOldBackendSuccess() async throws {
        let setup = WatchAlertSetup()
        setup.sendRegistration = { _ in true }
        _ = try await setup.requestPermission { true }
        setup.receivedToken("old-token")
        _ = try await setup.requestPermission { true }
        setup.fail("Apple registration failed. Retry setup.")
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .blocked)
        XCTAssertEqual(setup.detail, "Apple registration failed. Retry setup.")
    }

    @MainActor func testBackendFailureStaysVisibleUntilRegistrationRecovers() async throws {
        let setup = WatchAlertSetup()
        setup.sendRegistration = { _ in true }
        _ = try await setup.requestPermission { true }
        setup.receivedToken("abc")
        setup.accept(WatchSnapshot(parentMode: true, message: "Watch sync pending. Check backend setup."))
        setup.accept(WatchSnapshot(parentMode: true))
        XCTAssertEqual(setup.phase, .blocked)
        XCTAssertEqual(setup.detail, "Watch sync pending. Check backend setup.")
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .registered)
    }

    @MainActor func testWrongPhoneRoleHasActionableFeedbackAndCanRecover() async throws {
        let setup = WatchAlertSetup()
        setup.sendRegistration = { _ in true }
        _ = try await setup.requestPermission { true }
        setup.receivedToken("abc")
        setup.accept(WatchSnapshot())
        XCTAssertEqual(setup.phase, .blocked)
        XCTAssertTrue(setup.detail.contains("Choose Parent Alerts"))
        setup.retryRegistration()
        setup.accept(WatchSnapshot(parentMode: true, watchPushRegistered: true))
        XCTAssertEqual(setup.phase, .registered)
    }

    @MainActor func testPermissionErrorIsVisibleAndRetryCanSucceed() async throws {
        let setup = WatchAlertSetup()
        do {
            _ = try await setup.requestPermission { throw URLError(.unknown) }
            XCTFail("Expected permission request failure")
        } catch {}
        XCTAssertEqual(setup.phase, .blocked)
        XCTAssertTrue(setup.detail.contains("Retry setup"))
        _ = try await setup.requestPermission { true }
        XCTAssertEqual(setup.phase, .registeringPush)
    }
}
