import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SilentCryAlarmSnoozeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "SilentCryAlarmSnoozeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @MainActor func testDuplicateDoesNotExtendSnoozeOrEnqueueAnotherAcknowledgement() throws {
        try withDefaults { defaults in
            let snooze = SilentCryAlarmSnooze(defaults: defaults), id = UUID()
            XCTAssertTrue(snooze.apply(eventID: id, duration: 60, now: now))
            XCTAssertFalse(snooze.apply(eventID: id, duration: 900, now: now.addingTimeInterval(120)))
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, now)
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, now.addingTimeInterval(60))
            XCTAssertEqual(defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements"), [id.uuidString])
        }
    }

    @MainActor func testDelayedCopyAfterResumeAndRelaunchDoesNotRestoreSnooze() throws {
        try withDefaults { defaults in
            let id = UUID()
            SilentCryAlarmSnooze(defaults: defaults).apply(eventID: id, duration: 300, now: now)
            defaults.set([], forKey: "silentCryAlarmPendingAcknowledgements")
            defaults.removeObject(forKey: "silentCryAlarmMutedUntil")
            let relaunched = SilentCryAlarmSnooze(defaults: defaults)
            XCTAssertFalse(relaunched.apply(eventID: id, duration: 300, now: now.addingTimeInterval(30)))
            XCTAssertNil(defaults.object(forKey: "silentCryAlarmMutedUntil"))
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, now)
            XCTAssertEqual(defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements"), [])
        }
    }

    @MainActor func testOlderCopyPreservesNewerSnoozeAndItsPendingAcknowledgement() throws {
        try withDefaults { defaults in
            let snooze = SilentCryAlarmSnooze(defaults: defaults), first = UUID(), newer = UUID()
            snooze.apply(eventID: first, duration: 60, now: now)
            defaults.set([], forKey: "silentCryAlarmPendingAcknowledgements")
            let next = now.addingTimeInterval(120)
            XCTAssertTrue(snooze.apply(eventID: newer, duration: 60, now: next))
            XCTAssertFalse(snooze.apply(eventID: first, duration: 900, now: next.addingTimeInterval(30)))
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, next)
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, next.addingTimeInterval(60))
            XCTAssertEqual(defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements"), [newer.uuidString])
        }
    }

    @MainActor func testLegacyPendingCopyRemainsHandledAfterItsQueueDrains() throws {
        try withDefaults { defaults in
            let id = UUID(), deadline = now.addingTimeInterval(60)
            defaults.set([id.uuidString], forKey: "silentCryAlarmPendingAcknowledgements")
            defaults.set(now, forKey: "silentCryAlarmStoppedBefore")
            defaults.set(deadline, forKey: "silentCryAlarmMutedUntil")
            XCTAssertFalse(SilentCryAlarmSnooze(defaults: defaults).apply(eventID: id, duration: 900, now: now.addingTimeInterval(120)))
            defaults.set([], forKey: "silentCryAlarmPendingAcknowledgements")
            XCTAssertFalse(SilentCryAlarmSnooze(defaults: defaults).apply(eventID: id, duration: 900, now: now.addingTimeInterval(180)))
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, deadline)
            XCTAssertEqual(defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, now)
        }
    }

    @MainActor func testAlreadySyncedAcknowledgementCannotStartALocalSnoozeLater() throws {
        try withDefaults { defaults in
            let id = UUID()
            // The phone can confirm/discard an acknowledgement while AlarmKit is off.
            SilentCryAlarmSnooze(defaults: defaults).markHandled(id)
            XCTAssertFalse(SilentCryAlarmSnooze(defaults: defaults).apply(eventID: id, duration: 60, now: now))
            XCTAssertNil(defaults.object(forKey: "silentCryAlarmStoppedBefore"))
            XCTAssertNil(defaults.object(forKey: "silentCryAlarmMutedUntil"))
            XCTAssertNil(defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements"))
        }
    }
}

final class SilentCryAlarmRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let episode = UUID()
    private func payload(age: Double = 0) -> [AnyHashable: Any] {
        ["silentCryAlarm": true, "eventId": UUID().uuidString, "episodeId": episode.uuidString,
         "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))]
    }
    func testDisconnectedListenerUsesAlarmEligibilityAndClearsOnRecovery() throws {
        var value = payload(); value["type"] = "listener_disconnected"
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: value, now: now))
        XCTAssertTrue(request.isDisconnected)
        XCTAssertTrue(request.isEligible(enabled: true, serverEnabled: true, paired: true,
            relevance: NotificationRelevance(cryEpisodeIDs: [episode]), mutedUntil: nil,
            localMutedUntil: nil, stoppedBefore: nil, now: now))
        XCTAssertEqual(request.ineligibilityReason(enabled: true, serverEnabled: true, paired: true,
            relevance: NotificationRelevance(), mutedUntil: nil, localMutedUntil: nil,
            stoppedBefore: nil, now: now), .irrelevant)
        XCTAssertEqual(request.ineligibilityReason(enabled: true, serverEnabled: true, paired: true,
            relevance: NotificationRelevance(cryEpisodeIDs: [episode]), mutedUntil: now.addingTimeInterval(60),
            localMutedUntil: nil, stoppedBefore: nil, now: now), .serverMuted)
    }
    func testSchedulingCycleIsTypedAndLegacyRequestsRemainAccepted() throws {
        XCTAssertNil(try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now)).cycleID)
        let cycle = UUID(); var marked = payload(); marked["alarmCycleId"] = cycle.uuidString
        XCTAssertEqual(try XCTUnwrap(SilentCryAlarmRequest(payload: marked, now: now)).cycleID, cycle)
        marked["alarmCycleId"] = "invalid"
        XCTAssertNil(SilentCryAlarmRequest(payload: marked, now: now))
        XCTAssertEqual(SilentCryAlarmRequest.payloadRejection(marked, now: now), .malformed)
    }
    func testOnlyFreshRealCryPayloadsAreAccepted() throws {
        XCTAssertNotNil(SilentCryAlarmRequest(payload: payload(), now: now))
        XCTAssertNil(SilentCryAlarmRequest(payload: payload(age: 61), now: now))
        XCTAssertNil(SilentCryAlarmRequest(payload: payload(age: -6), now: now))
        var test = payload(); test["isTest"] = true
        XCTAssertNil(SilentCryAlarmRequest(payload: test, now: now))
        var ordinary = payload(); ordinary.removeValue(forKey: "silentCryAlarm")
        XCTAssertNil(SilentCryAlarmRequest(payload: ordinary, now: now))
        var invalid = payload(); invalid["episodeId"] = "invalid"
        XCTAssertNil(SilentCryAlarmRequest(payload: invalid, now: now))
    }
    func testBothOptInsCurrentEpisodeAndNoSnoozeAreRequired() throws {
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now))
        let relevant = NotificationRelevance(cryEpisodeIDs: [episode])
        func eligible(enabled: Bool = true, serverEnabled: Bool = true, paired: Bool = true,
                      relevance: NotificationRelevance? = relevant, muted: Date? = nil,
                      localMuted: Date? = nil, stopped: Date? = nil, at: Date? = nil) -> Bool {
            request.isEligible(enabled: enabled, serverEnabled: serverEnabled, paired: paired,
                relevance: relevance, mutedUntil: muted, localMutedUntil: localMuted, stoppedBefore: stopped, now: at ?? now)
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(enabled: false)); XCTAssertFalse(eligible(serverEnabled: false))
        XCTAssertFalse(eligible(paired: false)); XCTAssertFalse(eligible(relevance: nil))
        XCTAssertFalse(eligible(relevance: NotificationRelevance()))
        XCTAssertFalse(eligible(muted: now.addingTimeInterval(60)))
        XCTAssertFalse(eligible(localMuted: now.addingTimeInterval(60)))
        XCTAssertFalse(eligible(stopped: now)); XCTAssertFalse(eligible(at: now.addingTimeInterval(61)))
        XCTAssertTrue(eligible(muted: now.addingTimeInterval(-1), localMuted: now.addingTimeInterval(-1)))
    }
    func testRejectedPayloadDiagnosticsMatchAcceptanceIncludingExpiredCallbacks() {
        var test = payload(); test["isTest"] = true
        var ordinary = payload(); ordinary.removeValue(forKey: "silentCryAlarm")
        var malformed = payload(); malformed["episodeId"] = "private-payload"
        var badDate = payload(); badDate["createdAt"] = "private-payload"
        let cases: [([AnyHashable: Any], SilentCryAlarmRequest.Rejection?)] = [
            (payload(), nil), (payload(age: 60), nil), (payload(age: -5), nil),
            (payload(age: 61), .stale), (payload(age: -6), .stale),
            (test, .test), (ordinary, .notRequested), (malformed, .malformed), (badDate, .malformed)
        ]
        for (value, reason) in cases {
            XCTAssertEqual(SilentCryAlarmRequest.payloadRejection(value, now: now), reason)
            XCTAssertEqual(SilentCryAlarmRequest(payload: value, now: now) != nil, reason == nil)
        }
    }
    func testEligibilityDiagnosticsDistinguishUnknownRelevanceFromSnoozeAndStaleStatus() throws {
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(), now: now))
        func reason(relevance: NotificationRelevance? = NotificationRelevance(), muted: Date? = nil,
                    localMuted: Date? = nil, stopped: Date? = nil, at: Date? = nil) -> SilentCryAlarmRequest.Rejection? {
            request.ineligibilityReason(enabled: true, serverEnabled: true, paired: true, relevance: relevance,
                mutedUntil: muted, localMutedUntil: localMuted, stoppedBefore: stopped, now: at ?? now)
        }
        let relevant = NotificationRelevance(cryEpisodeIDs: [episode])
        XCTAssertEqual(reason(relevance: nil), .relevanceUnknown)
        XCTAssertEqual(reason(), .irrelevant)
        XCTAssertEqual(reason(relevance: relevant, muted: now.addingTimeInterval(1)), .serverMuted)
        XCTAssertEqual(reason(relevance: relevant, localMuted: now.addingTimeInterval(1)), .locallyMuted)
        XCTAssertEqual(reason(relevance: relevant, stopped: now), .stopped)
        XCTAssertEqual(reason(relevance: relevant, at: now.addingTimeInterval(61)), .stale)
        XCTAssertNil(reason(relevance: relevant, muted: now, localMuted: now))
    }
}

final class SilentCryAlarmStatusSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor func testSuspendedResponseExpiresWithoutARecoveryRequest() async {
        let started = ContinuousClock.now
        var clock = started, reads = 0
        do {
            _ = try await SilentCryAlarmStatusSnapshot.load(
                budget: .init(startedAt: started), clock: { clock }, date: { self.now }) {
                reads += 1
                clock = clock.advanced(by: .seconds(26))
                return NotificationRelevance(cryEpisodeIDs: [UUID()])
            }
            XCTFail("A resumed old response must not authorize an alarm or another read")
        } catch {
            XCTAssertEqual(error as? SilentCryAlarmRequest.Rejection, .budgetExpired)
        }
        XCTAssertEqual(reads, 1)
    }

    @MainActor func testExpiredCallbackDoesNotEvenStartTheStatusRequest() async {
        let started = ContinuousClock.now
        var reads = 0
        do {
            _ = try await SilentCryAlarmStatusSnapshot.load(
                budget: .init(startedAt: started), clock: { started.advanced(by: .seconds(26)) }) {
                reads += 1
                return NotificationRelevance()
            }
            XCTFail("An expired callback should finish without network work")
        } catch {
            XCTAssertEqual(error as? SilentCryAlarmRequest.Rejection, .budgetExpired)
        }
        XCTAssertEqual(reads, 0)
    }

    @MainActor func testPromptResponsePreservesCurrentStatusAndOriginalCheckTime() async throws {
        let started = ContinuousClock.now
        var clock = started, reads = 0
        let episode = UUID()
        let snapshot = try await SilentCryAlarmStatusSnapshot.load(
            budget: .init(startedAt: started), clock: { clock }, date: { self.now }) {
            reads += 1
            clock = clock.advanced(by: .milliseconds(300))
            return NotificationRelevance(cryEpisodeIDs: [episode])
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(snapshot.value.cryEpisodeIDs, [episode])
        XCTAssertEqual(snapshot.checkedAt, now)
        XCTAssertTrue(snapshot.isFresh(at: clock))
        XCTAssertFalse(snapshot.isFresh(at: started.advanced(by: .seconds(26))))
    }

    @MainActor func testNetworkFailureIsReturnedWithoutAnotherRequest() async {
        let started = ContinuousClock.now
        var clock = started, reads = 0
        do {
            let _: SilentCryAlarmStatusSnapshot<NotificationRelevance> = try await .load(
                budget: .init(startedAt: started), clock: { clock }) {
                reads += 1
                clock = clock.advanced(by: .seconds(2))
                throw URLError(.timedOut)
            }
            XCTFail("The caller must explicitly decide whether fallback is eligible")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertNoThrow(try SilentCryAlarmExecutionBudget(startedAt: started).requireTime(at: clock))
        }
        XCTAssertEqual(reads, 1)
    }

    func testSchedulingReserveAndRemainingBudgetIncludeElapsedSleep() {
        let started = ContinuousClock.now
        let budget = SilentCryAlarmExecutionBudget(startedAt: started)
        XCTAssertNoThrow(try budget.requireTime(at: started.advanced(by: .milliseconds(3_999))))
        XCTAssertThrowsError(try budget.requireTime(at: started.advanced(by: .seconds(4))))
        XCTAssertThrowsError(try budget.requireTime(at: started.advanced(by: .seconds(26))))
        XCTAssertEqual(budget.remainingMilliseconds(at: started), 5_000)
        XCTAssertEqual(budget.remainingMilliseconds(at: started.advanced(by: .seconds(2))), 3_000)
        XCTAssertEqual(budget.remainingMilliseconds(at: started.advanced(by: .seconds(26))), 0)
    }
}

final class SilentCryAlarmFallbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(age: TimeInterval = 0) throws -> SilentCryAlarmRequest {
        try XCTUnwrap(SilentCryAlarmRequest(payload: [
            "silentCryAlarm": true, "eventId": UUID().uuidString, "episodeId": UUID().uuidString,
            "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        ], now: now))
    }

    func testRecentPushCanSurviveTimeoutButNeverOverridesLocalSnoozeOrDisabledSetting() throws {
        let request = try request(age: 2)
        func reason(enabled: Bool = true, pending: Bool = false, muted: Date? = nil, stopped: Date? = nil) -> SilentCryAlarmRequest.Rejection? {
            request.fallbackIneligibilityReason(enabled: enabled, acknowledgementPending: pending,
                localMutedUntil: muted, stoppedBefore: stopped, evidence: nil, now: now)
        }
        XCTAssertNil(reason())
        XCTAssertEqual(reason(enabled: false), .disabled)
        XCTAssertEqual(reason(pending: true), .acknowledgementPending)
        XCTAssertEqual(reason(muted: now.addingTimeInterval(60)), .locallyMuted)
        XCTAssertEqual(reason(stopped: now), .stopped)
    }

    func testFallbackRejectsOlderPushesEvenThoughNormalStatusValidationCanStillAcceptThem() throws {
        for age in [10.0, 11.0, 42.0] {
            let request = try request(age: age)
            let rejection = request.fallbackIneligibilityReason(enabled: true, acknowledgementPending: false,
                localMutedUntil: nil, stoppedBefore: nil, evidence: nil, now: now)
            XCTAssertEqual(rejection, age <= 10 ? nil : .stale)
        }
    }

    func testKnownResolutionUnpairDisableOrServerSnoozeBlocksFallbackAfterRelaunch() throws {
        let request = try request(age: 2)
        let relevant = NotificationRelevance(cryEpisodeIDs: [request.episodeID])
        let cases: [(Bool, Bool, NotificationRelevance, Date?, SilentCryAlarmRequest.Rejection)] = [
            (true, true, NotificationRelevance(), nil, .irrelevant),
            (false, true, relevant, nil, .unpaired),
            (true, false, relevant, nil, .serverDisabled),
            (true, true, relevant, now.addingTimeInterval(60), .serverMuted)
        ]
        for (paired, enabled, relevance, muted, reason) in cases {
            let evidence = SilentCryAlarmRequest.ServerEvidence(observedAt: now,
                paired: paired, enabled: enabled, relevance: relevance, mutedUntil: muted)
            // The same serialized evidence the service restores after relaunch.
            let restored = try JSONDecoder().decode(SilentCryAlarmRequest.ServerEvidence.self,
                from: JSONEncoder().encode(evidence))
            XCTAssertEqual(request.fallbackIneligibilityReason(enabled: true, acknowledgementPending: false,
                localMutedUntil: nil, stoppedBefore: nil, evidence: restored, now: now), reason)
        }
    }

    func testOldQuietSnapshotDoesNotOverrideANewerCryPush() throws {
        let request = try request()
        let old = SilentCryAlarmRequest.ServerEvidence(observedAt: now.addingTimeInterval(-30),
            paired: true, enabled: true, relevance: NotificationRelevance(), mutedUntil: nil)
        XCTAssertNil(request.fallbackIneligibilityReason(enabled: true, acknowledgementPending: false,
            localMutedUntil: nil, stoppedBefore: nil, evidence: old, now: now))
    }

    func testOnlyUnavailableNetworkErrorsPermitFallback() {
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .networkConnectionLost,
                                   .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertTrue(SilentCryAlarmRequest.allowsStatusFallback(for: URLError(code)))
        }
        for code: URLError.Code in [.cancelled, .secureConnectionFailed, .serverCertificateUntrusted,
                                   .userAuthenticationRequired, .badServerResponse] {
            XCTAssertFalse(SilentCryAlarmRequest.allowsStatusFallback(for: URLError(code)))
        }
        XCTAssertFalse(SilentCryAlarmRequest.allowsStatusFallback(for: CancellationError()))
        XCTAssertFalse(SilentCryAlarmRequest.allowsStatusFallback(for: SilentCryAlarmRequest.Rejection.staleStatus))
        XCTAssertFalse(SilentCryAlarmRequest.allowsStatusFallback(for: SilentCryAlarmRequest.Rejection.budgetExpired))
    }
}
