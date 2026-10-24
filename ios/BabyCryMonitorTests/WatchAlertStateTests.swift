import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchAlertStateTests: XCTestCase {
    @MainActor final class Fixture {
        let suite = "WatchAlertStateTests.\(UUID())"
        let defaults: UserDefaults
        var activated = false
        var commands: [WatchCommand] = []

        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        func makeState() -> WatchAlertState {
            let state = WatchAlertState(defaults: defaults)
            state.sendAcknowledgement = { [weak self] command in
                guard let self, self.activated else { return }
                self.commands.append(command)
            }
            return state
        }

        func alert(episodeID: UUID = UUID()) -> WatchCryAlert {
            WatchCryAlert(eventId: UUID(), episodeId: episodeID, startedAt: Date().addingTimeInterval(-300),
                          createdAt: Date(), duration: 300, isTest: false)
        }
    }

    @MainActor func testAcknowledgingRetainedNotificationDoesNotDismissNewAlert() throws {
        let fixture = try Fixture()
        fixture.activated = true
        let state = fixture.makeState()
        let old = fixture.alert(), current = fixture.alert()
        state.receive(old)
        state.acknowledgeCurrent()
        state.confirmAcknowledgement(old.eventId)
        state.receive(current)

        // Notification Center can retain an episode already acknowledged in the app.
        state.handleNotification(old, acknowledging: true)

        XCTAssertEqual(state.alert, current)
        XCTAssertEqual(fixture.commands.map(\.eventId), [old.eventId])
        XCTAssertFalse(state.acknowledgementPending)
        state.acceptAlert(from: WatchSnapshot(alert: current))
        XCTAssertEqual(state.alert, current)
    }

    @MainActor func testAcknowledgingOlderUnseenNotificationTargetsOnlyItsEpisode() throws {
        let fixture = try Fixture()
        fixture.activated = true
        let state = fixture.makeState()
        let old = fixture.alert(), current = fixture.alert()
        state.receive(current)

        state.handleNotification(old, acknowledging: true)

        XCTAssertEqual(state.alert, current)
        XCTAssertEqual(fixture.commands.map(\.eventId), [old.eventId])
        state.receive(fixture.alert(episodeID: old.episodeId))
        XCTAssertEqual(state.alert, current)
    }

    @MainActor func testAcknowledgementBeforeActivationIsReplayedAndWaitsForConfirmation() throws {
        let fixture = try Fixture()
        let state = fixture.makeState()
        let alert = fixture.alert()
        state.handleNotification(alert, acknowledging: true)

        XCTAssertNil(state.alert)
        XCTAssertTrue(state.acknowledgementPending)
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "pendingAcknowledgements"), [alert.eventId.uuidString])

        fixture.activated = true
        state.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.map(\.eventId), [alert.eventId])
        XCTAssertEqual(fixture.commands.first?.kind, .acknowledge)
        XCTAssertTrue(state.acknowledgementPending)
        state.confirmAcknowledgement(UUID())
        XCTAssertTrue(state.acknowledgementPending)
        state.confirmAcknowledgement(alert.eventId)
        XCTAssertFalse(state.acknowledgementPending)
        state.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.count, 1)
    }

    @MainActor func testRelaunchRestoresUnsentAcknowledgementAndSilencedEpisode() throws {
        let fixture = try Fixture()
        let alert = fixture.alert()
        fixture.makeState().handleNotification(alert, acknowledging: true)

        let restored = fixture.makeState()
        XCTAssertTrue(restored.acknowledgementPending)
        restored.receive(alert)
        XCTAssertNil(restored.alert)
        fixture.activated = true
        restored.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.map(\.eventId), [alert.eventId])
        restored.confirmAcknowledgement(alert.eventId)
        XCTAssertFalse(fixture.makeState().acknowledgementPending)
    }

    @MainActor func testReconnectRetriesUnconfirmedAcknowledgementWithSameEventID() throws {
        let fixture = try Fixture()
        fixture.activated = true
        let state = fixture.makeState()
        let alert = fixture.alert()
        state.handleNotification(alert, acknowledging: true)
        fixture.activated = false
        state.retryPendingAcknowledgement()
        fixture.activated = true
        state.retryPendingAcknowledgement()

        XCTAssertEqual(fixture.commands.map(\.eventId), [alert.eventId, alert.eventId])
        XCTAssertTrue(state.acknowledgementPending)
    }

    @MainActor func testMultipleOfflineAcknowledgementsSurviveRelaunchAndConfirmInOrder() throws {
        let fixture = try Fixture()
        let state = fixture.makeState()
        let first = fixture.alert(), second = fixture.alert()
        state.handleNotification(first, acknowledging: true)
        state.handleNotification(second, acknowledging: true)

        let restored = fixture.makeState()
        fixture.activated = true
        restored.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.map(\.eventId), [first.eventId])
        restored.confirmAcknowledgement(first.eventId)
        XCTAssertTrue(restored.acknowledgementPending)
        XCTAssertEqual(fixture.commands.map(\.eventId), [first.eventId, second.eventId])
        restored.confirmAcknowledgement(first.eventId)
        XCTAssertEqual(fixture.commands.count, 2)
        restored.confirmAcknowledgement(second.eventId)
        XCTAssertFalse(restored.acknowledgementPending)
        XCTAssertFalse(fixture.makeState().acknowledgementPending)
    }

    @MainActor func testLegacyPendingAcknowledgementMigratesWithoutBeingLostOrResurrected() throws {
        let fixture = try Fixture()
        let eventID = UUID()
        fixture.defaults.set(eventID.uuidString, forKey: "pendingAcknowledgement")
        let state = fixture.makeState()
        XCTAssertTrue(state.acknowledgementPending)
        XCTAssertNil(fixture.defaults.string(forKey: "pendingAcknowledgement"))
        fixture.activated = true
        state.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.map(\.eventId), [eventID])
        state.confirmAcknowledgement(eventID)
        XCTAssertFalse(fixture.makeState().acknowledgementPending)
    }

    @MainActor func testOpeningNotificationStillShowsAlertAndCurrentAcknowledgementSilencesRepeats() throws {
        let fixture = try Fixture()
        fixture.activated = true
        let state = fixture.makeState()
        let alert = fixture.alert()
        state.handleNotification(alert, acknowledging: false)
        XCTAssertEqual(state.alert, alert)
        XCTAssertTrue(fixture.commands.isEmpty)

        state.acknowledgeCurrent()
        XCTAssertNil(state.alert)
        XCTAssertEqual(fixture.commands.map(\.eventId), [alert.eventId])
        state.receive(fixture.alert(episodeID: alert.episodeId))
        state.acceptAlert(from: WatchSnapshot(alert: alert))
        XCTAssertNil(state.alert)
    }
    @MainActor func testSameEpisodeCanAlertAgainAfterFiveMinuteMute() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 1000)
        let state = WatchAlertState(defaults: fixture.defaults, currentTime: { now })
        let initial = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: now,
                                    createdAt: now, duration: 5, isTest: false)
        state.acceptAlert(from: WatchSnapshot(snoozeDuration: 300))
        state.receive(initial); state.acknowledgeCurrent()
        state.confirmAcknowledgement(initial.eventId)
        let before = WatchCryAlert(eventId: UUID(), episodeId: initial.episodeId, startedAt: now,
                                   createdAt: now.addingTimeInterval(299), duration: 5, isTest: false)
        state.receive(before); XCTAssertNil(state.alert)
        let after = WatchCryAlert(eventId: UUID(), episodeId: initial.episodeId, startedAt: now,
                                  createdAt: now.addingTimeInterval(300), duration: 5, isTest: false)
        state.receive(after); XCTAssertEqual(state.alert, after)
        // Retained pre-mute notifications never restart the old alert.
        state.receive(initial); XCTAssertEqual(state.alert, after)
    }

    @MainActor func testDefaultSnoozeIsOneMinuteAndNewSettingsDoNotChangeExistingSnooze() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 1000)
        let state = WatchAlertState(defaults: fixture.defaults, currentTime: { now })
        let initial = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: now, createdAt: now, duration: 5, isTest: false)
        state.receive(initial); state.acknowledgeCurrent(); state.confirmAcknowledgement(initial.eventId)
        state.acceptAlert(from: WatchSnapshot(snoozeDuration: 300))
        let before = WatchCryAlert(eventId: UUID(), episodeId: initial.episodeId, startedAt: now,
                                   createdAt: now.addingTimeInterval(59), duration: 5, isTest: false)
        state.receive(before); XCTAssertNil(state.alert)
        let after = WatchCryAlert(eventId: UUID(), episodeId: initial.episodeId, startedAt: now,
                                  createdAt: now.addingTimeInterval(60), duration: 5, isTest: false)
        state.receive(after); XCTAssertEqual(state.alert, after)
    }

}
