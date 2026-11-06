import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchAlertStateTests: XCTestCase {
    private func notificationFixture() -> (WatchCryAlert, Date, WatchSnapshot) {
        let created = Date(timeIntervalSince1970: 1000)
        let alert = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: created,
                                  createdAt: created, duration: 5, isTest: false)
        let delivered = created.addingTimeInterval(1)
        let checked = created.addingTimeInterval(5)
        let snapshot = WatchSnapshot(updatedAt: checked, parentMode: true, paired: true, statusAvailable: true,
                                     notificationRelevance: NotificationRelevance(), notificationsCheckedAt: checked)
        return (alert, delivered, snapshot)
    }

    func testNotificationPresentationUpdatesOnlyFromAuthoritativeRelevance() {
        let (alert, delivered, resolved) = notificationFixture()
        var active = resolved
        active.notificationRelevance?.cryEpisodeIDs = [alert.episodeId]
        XCTAssertFalse(active.notificationIsInactive(alert, deliveredAt: delivered))
        XCTAssertTrue(resolved.notificationIsInactive(alert, deliveredAt: delivered))
        var unavailable = resolved; unavailable.statusAvailable = false
        XCTAssertFalse(unavailable.notificationIsInactive(alert, deliveredAt: delivered))
        var legacy = resolved; legacy.notificationRelevance = nil
        XCTAssertFalse(legacy.notificationIsInactive(alert, deliveredAt: delivered))
        var unchecked = resolved; unchecked.notificationsCheckedAt = nil
        XCTAssertFalse(unchecked.notificationIsInactive(alert, deliveredAt: delivered))
        var unpaired = resolved; unpaired.paired = false
        XCTAssertFalse(unpaired.notificationIsInactive(alert, deliveredAt: delivered))
        var wrongRole = resolved; wrongRole.parentMode = false
        XCTAssertFalse(wrongRole.notificationIsInactive(alert, deliveredAt: delivered))
    }

    func testStatusFetchCannotRetireAPushThatArrivesDuringTheFetch() {
        let (alert, delivered, snapshot) = notificationFixture()
        var beforeArrival = snapshot
        beforeArrival.notificationsCheckedAt = delivered.addingTimeInterval(-0.1)
        XCTAssertFalse(beforeArrival.notificationIsInactive(alert, deliveredAt: delivered))
        let newer = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: delivered,
                                  createdAt: snapshot.updatedAt.addingTimeInterval(1), duration: 5, isTest: false)
        XCTAssertFalse(snapshot.notificationIsInactive(newer, deliveredAt: delivered))
        XCTAssertFalse(snapshot.notificationIsInactive(alert, deliveredAt: nil))
        XCTAssertFalse(snapshot.notificationIsInactive(alert, deliveredAt: Date(timeIntervalSince1970: .nan)))
    }

    func testTestAlertsAreMatchedByEventAndRealRemindersByEpisode() {
        let (real, delivered, snapshot) = notificationFixture()
        let test = WatchCryAlert(eventId: UUID(), episodeId: real.episodeId, startedAt: real.startedAt,
                                 createdAt: real.createdAt, duration: 5, isTest: true)
        var relevant = snapshot
        relevant.notificationRelevance = NotificationRelevance(cryEpisodeIDs: [real.episodeId], testEventIDs: [test.eventId])
        XCTAssertFalse(relevant.notificationIsInactive(real, deliveredAt: delivered))
        XCTAssertFalse(relevant.notificationIsInactive(test, deliveredAt: delivered))
        relevant.notificationRelevance?.testEventIDs = []
        XCTAssertTrue(relevant.notificationIsInactive(test, deliveredAt: delivered))
        XCTAssertFalse(relevant.notificationIsInactive(real, deliveredAt: delivered))
    }

    @MainActor func testResolvedNotificationCannotResurrectAnAlertOrSnoozeANewerEpisode() throws {
        let fixture = try Fixture(); fixture.activated = true
        let state = fixture.makeState()
        let (old, delivered, resolved) = notificationFixture()
        let current = fixture.alert()
        state.receive(current)
        state.receive(old, snapshot: resolved, deliveredAt: delivered)
        XCTAssertEqual(state.alert, current)
        XCTAssertFalse(state.handleNotification(old, acknowledging: false, snapshot: resolved, deliveredAt: delivered))
        XCTAssertFalse(state.handleNotification(old, acknowledging: true, snapshot: resolved, deliveredAt: delivered))
        XCTAssertEqual(state.alert, current)
        XCTAssertFalse(state.acknowledgementPending)
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: "localCryAlertsMutedUntil"))
    }

    @MainActor func testOfflineUnknownNotificationStillAllowsAnAcknowledgement() throws {
        let fixture = try Fixture(); fixture.activated = true
        let state = fixture.makeState()
        let (alert, delivered, resolved) = notificationFixture()
        var unknown = resolved; unknown.statusAvailable = false
        state.receive(alert, snapshot: unknown, deliveredAt: delivered)
        XCTAssertEqual(state.alert, alert)
        XCTAssertTrue(state.handleNotification(alert, acknowledging: true, snapshot: unknown, deliveredAt: delivered))
        XCTAssertEqual(fixture.commands.last?.eventId, alert.eventId)
    }

    @MainActor func testDurableAcknowledgementsKeepRealAndTestClassification() throws {
        let fixture = try Fixture()
        var state = fixture.makeState()
        let real = fixture.alert()
        let test = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: Date(), createdAt: Date(), duration: 0, isTest: true)
        state.handleNotification(real, acknowledging: true)
        state.handleNotification(test, acknowledging: true)
        state = fixture.makeState()
        fixture.activated = true
        state.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.last?.isTest, false)
        state.confirmAcknowledgement(real.eventId)
        XCTAssertEqual(fixture.commands.last?.isTest, true)
        state.confirmAcknowledgement(test.eventId)
        XCTAssertTrue((fixture.defaults.dictionary(forKey: "pendingAcknowledgementTests") ?? [:]).isEmpty)
    }

    @MainActor func testQueuedSnoozeKeepsItsTapTimeAcrossRetriesAndRelaunch() throws {
        let fixture = try Fixture()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = fixture.makeState(currentTime: { now })
        let real = fixture.alert()
        state.handleNotification(real, acknowledging: true)
        now = now.addingTimeInterval(3600)
        state = fixture.makeState(currentTime: { now })
        fixture.activated = true
        state.retryPendingAcknowledgement()
        XCTAssertEqual(fixture.commands.last?.eventId, real.eventId)
        XCTAssertEqual(fixture.commands.last?.issuedAt, Date(timeIntervalSince1970: 1_800_000_000),
                       "The server snoozes from the tap, not from this late delivery")
        state.confirmAcknowledgement(real.eventId)
        XCTAssertTrue((fixture.defaults.dictionary(forKey: "pendingAcknowledgementTimes") ?? [:]).isEmpty)
    }

    @MainActor func testEarlyResumeAllowsNewRemindersButKeepsOldNotificationsDismissed() throws {
        let fixture = try Fixture()
        var now = Date()
        let state = WatchAlertState(defaults: fixture.defaults, currentTime: { now })
        let initial = fixture.alert()
        state.receive(initial); state.acknowledgeCurrent(); state.confirmAcknowledgement(initial.eventId)
        state.acceptAlert(from: WatchSnapshot(statusAvailable: true, alertsMutedUntil: now.addingTimeInterval(60)))
        now = now.addingTimeInterval(10)
        state.acceptAlert(from: WatchSnapshot(statusAvailable: true, alertsMutedUntil: now))
        state.receive(initial)
        XCTAssertNil(state.alert)
        let reminder = WatchCryAlert(eventId: UUID(), episodeId: initial.episodeId, startedAt: initial.startedAt,
                                     createdAt: now.addingTimeInterval(1), duration: 300, isTest: false)
        state.receive(reminder)
        XCTAssertEqual(state.alert?.eventId, reminder.eventId)
    }

    @MainActor func testDiscardedAcknowledgementAdvancesDurableQueueWithoutMutingNewAlerts() throws {
        let fixture = try Fixture()
        let deleted = fixture.alert(), current = fixture.alert()
        var state = fixture.makeState()
        state.handleNotification(deleted, acknowledging: true)
        state.handleNotification(current, acknowledging: true)
        state = fixture.makeState()
        fixture.activated = true
        let encoded = try JSONEncoder().encode(WatchSnapshot(discardedAcknowledgementEventId: deleted.eventId))
        state.resolveAcknowledgements(from: try JSONDecoder().decode(WatchSnapshot.self, from: encoded))
        XCTAssertTrue(state.acknowledgementPending)
        XCTAssertEqual(fixture.commands.last?.eventId, current.eventId)
        state.resolveAcknowledgements(from: WatchSnapshot(acknowledgedEventId: current.eventId))
        XCTAssertFalse(fixture.makeState().acknowledgementPending)
        state.acceptAlert(from: WatchSnapshot(statusAvailable: true))
        let next = fixture.alert()
        state.receive(next)
        XCTAssertEqual(state.alert, next)
    }
    @MainActor final class Fixture {
        let suite = "WatchAlertStateTests.\(UUID())"
        let defaults: UserDefaults
        var activated = false
        var commands: [WatchCommand] = []

        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        func makeState(currentTime: @escaping () -> Date = Date.init) -> WatchAlertState {
            let state = WatchAlertState(defaults: defaults, currentTime: currentTime)
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
        let old = fixture.alert()
        state.receive(old)
        state.acknowledgeCurrent()
        state.confirmAcknowledgement(old.eventId)
        state.acceptAlert(from: WatchSnapshot(statusAvailable: true, alertsMutedUntil: Date()))
        let current = fixture.alert()
        state.receive(current)

        // Notification Center can retain an episode already acknowledged in the app.
        state.handleNotification(old, acknowledging: true)

        XCTAssertEqual(state.alert, current)
        XCTAssertEqual(fixture.commands.map(\.eventId), [old.eventId])
        XCTAssertFalse(state.acknowledgementPending)
        state.acceptAlert(from: WatchSnapshot(alert: current))
        XCTAssertEqual(state.alert, current)
    }

    @MainActor func testSnoozingOlderNotificationClearsEveryCryingEpisode() throws {
        let fixture = try Fixture()
        fixture.activated = true
        let state = fixture.makeState()
        let old = fixture.alert(), current = fixture.alert()
        state.receive(current)

        state.handleNotification(old, acknowledging: true)

        XCTAssertNil(state.alert)
        XCTAssertEqual(fixture.commands.map(\.eventId), [old.eventId])
        state.receive(fixture.alert(episodeID: old.episodeId))
        XCTAssertNil(state.alert)
        let restored = fixture.makeState()
        restored.receive(current)
        XCTAssertNil(restored.alert)
        let test = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: Date(), createdAt: Date(), duration: 5, isTest: true)
        restored.receive(test)
        XCTAssertEqual(restored.alert, test)
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

    @MainActor func testTestAcknowledgementKeepsCurrentCryingAlert() throws {
        let fixture = try Fixture(), state = fixture.makeState()
        let current = fixture.alert()
        state.receive(current)
        let test = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: Date(), createdAt: Date(), duration: 5, isTest: true)
        state.handleNotification(test, acknowledging: true)
        XCTAssertEqual(state.alert, current)
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
