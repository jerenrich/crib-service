#if !canImport(MonitorCore)
import Foundation
import XCTest
@testable import BabyCryMonitor

final class WatchIntegrationTests: XCTestCase {
    actor Backend: BackendServing {
        nonisolated let credential: DeviceCredential
        private(set) var tokens: [String?] = []
        private(set) var acknowledgements: [UUID] = []
        private var failing = false
        private(set) var resumedDeadlines: [Date] = []
        var muteUntil: Date?
        func setMute(_ until: Date) { muteUntil = until }
        func resumeAlerts(until: Date) async throws {
            if failing { throw URLError(.notConnectedToInternet) }
            resumedDeadlines.append(until)
            if until == muteUntil { muteUntil = Date().addingTimeInterval(-1) }
        }
        private var acknowledgementFailures: [UUID: Int] = [:]
        private(set) var acknowledgementAttempts: [UUID] = []
        init(_ credential: DeviceCredential) { self.credential = credential }
        func fail(_ value: Bool) { failing = value }
        func failAcknowledgement(_ id: UUID, status: Int?) { acknowledgementFailures[id] = status }
        func register() async throws {}
        func createPairing() async throws -> PairingCode { PairingCode(code: "123456", expiresAt: .distantFuture) }
        func claim(_ code: String) async throws {}
        func status() async throws -> ParentStatus {
            if failing { throw URLError(.notConnectedToInternet) }
            return ParentStatus(paired: true, watchPushRegistered: tokens.last.flatMap { $0 } != nil, alertsMutedUntil: muteUntil, configuration: MonitoringConfiguration())
        }
        func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration { MonitoringConfiguration() }
        func settings(_ configuration: MonitoringConfiguration) async throws {}
        func send(_ alert: CryAlert) async throws -> AlertReceipt { AlertReceipt(status: "sent") }
        func acknowledge(_ id: UUID) async throws {
            acknowledgementAttempts.append(id)
            if failing { throw URLError(.notConnectedToInternet) }
            if let status = acknowledgementFailures[id] { throw BackendError.response(status, "Test failure") }
            acknowledgements.append(id)
        }
        func pushToken(_ token: String) async throws {}
        func watchPushToken(_ token: String?) async throws {
            if failing { throw URLError(.notConnectedToInternet) }
            tokens.append(token)
        }
    }

    @MainActor final class Fixture {
        let model: AppModel
        let backend: Backend
        let defaults: UserDefaults
        let suite = "WatchIntegrationTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("parent", forKey: "role")
            defaults.set("https://monitor.test", forKey: "backendURL")
            let parent = DeviceCredential(deviceId: UUID(), secret: "parent", role: .parent, registered: true)
            let listener = DeviceCredential(deviceId: UUID(), secret: "listener", role: .listener, registered: true)
            let backend = Backend(parent); self.backend = backend
            model = AppModel(defaults: defaults, metadataStore: try MetadataStore(directory: directory),
                             log: DiagnosticLog(directory: directory),
                             audio: AppModelTests.Audio(), connectivity: AppModelTests.Connectivity(),
                             notifications: AppModelTests.Notifications(),
                             keychain: AppModelTests.Credentials(listener: listener, parent: parent),
                             makeClient: { _, _ in backend }, automaticallyStart: false)
        }
        deinit {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func command(_ command: WatchCommand) async throws -> WatchSnapshot {
            let handler = try XCTUnwrap(model.watch.onCommand)
            return await handler(command)
        }
    }

    @MainActor func testWatchResumeCarriesObservedDeadlineAndPreservesNewerSnooze() async throws {
        let fixture = try Fixture()
        let original = Date().addingTimeInterval(60), newer = Date().addingTimeInterval(120)
        await fixture.backend.setMute(newer)
        let unchanged = try await fixture.command(WatchCommand(kind: .resumeAlerts, snoozeDeadline: original))
        XCTAssertEqual(unchanged.alertsMutedUntil, newer)
        XCTAssertTrue(unchanged.message?.contains("not confirmed") == true)
        let resumed = try await fixture.command(WatchCommand(kind: .resumeAlerts, snoozeDeadline: newer))
        XCTAssertLessThan(try XCTUnwrap(resumed.alertsMutedUntil), Date())
        XCTAssertEqual(resumed.message, "Alerts resumed.")
        let sent = await fixture.backend.resumedDeadlines
        XCTAssertEqual(sent, [original, newer])
    }

    @MainActor func testEarlyResumeClearsSilentAlarmSnoozeAndKeepsOldPushCutoff() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Silent crying alarms require iOS 26.") }
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: "silentWatchAlarmsEnabled")
        let service = SilentCryAlarmService(defaults: fixture.defaults)
        let until = Date().addingTimeInterval(300)
        await fixture.backend.setMute(until)
        service.snoozeLocally(eventID: UUID(), duration: 300)
        let cutoff = try XCTUnwrap(fixture.defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date)
        // Sync the original acknowledgement before requesting an early Resume.
        await service.synchronize(using: fixture.backend, status: try await fixture.backend.status(), checkedAt: Date())
        await fixture.model.refreshParent()
        let resumed = await fixture.model.resumeAlerts(until: until)
        XCTAssertTrue(resumed)
        let checkedAt = Date(), status = try await fixture.backend.status()
        await service.synchronize(using: fixture.backend, status: status, checkedAt: checkedAt)
        XCTAssertNil(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil"))
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, cutoff)

        let now = max(Date(), cutoff.addingTimeInterval(1)), episode = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: [
            "silentCryAlarm": true, "eventId": UUID().uuidString, "episodeId": episode.uuidString,
            "createdAt": formatter.string(from: now)
        ], now: now))
        XCTAssertNil(request.ineligibilityReason(enabled: true, serverEnabled: true, paired: true,
            relevance: NotificationRelevance(cryEpisodeIDs: [episode]), mutedUntil: status.alertsMutedUntil,
            localMutedUntil: fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date,
            stoppedBefore: cutoff, now: now))
    }

    @MainActor func testSilentAlarmResumePreservesNewerLocalAndServerSnoozes() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Silent crying alarms require iOS 26.") }
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: "silentWatchAlarmsEnabled")
        let service = SilentCryAlarmService(defaults: fixture.defaults)
        let beforeSnooze = Date().addingTimeInterval(-1), until = Date().addingTimeInterval(300)
        fixture.defaults.set(Date(), forKey: "silentCryAlarmStoppedBefore")
        fixture.defaults.set(until, forKey: "silentCryAlarmMutedUntil")
        let unmuted = ParentStatus(paired: true, configuration: MonitoringConfiguration())
        await service.synchronize(using: fixture.backend, status: unmuted, checkedAt: beforeSnooze)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, until)
        let muted = ParentStatus(paired: true, alertsMutedUntil: until, configuration: MonitoringConfiguration())
        await service.synchronize(using: fixture.backend, status: muted, checkedAt: Date())
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, until)
    }

    @MainActor func testSilentAlarmResumeRequiresStatusFetchedAfterAcknowledgementSync() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Silent crying alarms require iOS 26.") }
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: "silentWatchAlarmsEnabled")
        let service = SilentCryAlarmService(defaults: fixture.defaults)
        service.snoozeLocally(eventID: UUID(), duration: 300)
        let until = fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date
        let checkedAt = Date(), unmuted = ParentStatus(paired: true, configuration: MonitoringConfiguration())
        await fixture.backend.fail(true)
        await service.synchronize(using: fixture.backend, status: unmuted, checkedAt: checkedAt)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, until)
        await fixture.backend.fail(false)
        await service.synchronize(using: fixture.backend, status: unmuted, checkedAt: checkedAt)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, until)
        XCTAssertTrue((fixture.defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements") ?? []).isEmpty)
        // Reusing that old read must still preserve the mute after the queue drains.
        await service.synchronize(using: fixture.backend, status: unmuted, checkedAt: checkedAt)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, until)
        await service.synchronize(using: fixture.backend, status: unmuted, checkedAt: Date())
        XCTAssertNil(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil"))
    }

    @MainActor func testDuplicateWatchSnoozePreservesNewAlarmWorkAcrossRelaunch() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Silent crying alarms require iOS 26.") }
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: "silentWatchAlarmsEnabled")
        let service = SilentCryAlarmService(defaults: fixture.defaults), first = UUID(), newer = UUID()
        service.snoozeLocally(eventID: first, duration: 60)
        await service.synchronize(using: fixture.backend,
            status: ParentStatus(paired: true, configuration: MonitoringConfiguration()), checkedAt: Date())
        service.snoozeLocally(eventID: newer, duration: 60)
        let cutoff = fixture.defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date
        let deadline = fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date
        // cancelAll() clears these receipts even when no system alarm is present.
        // A late duplicate must never reach that cancellation path.
        let receipt = try JSONSerialization.data(withJSONObject: [[
            "episodeID": UUID().uuidString, "eventID": UUID().uuidString, "cycleID": UUID().uuidString
        ]])
        fixture.defaults.set(receipt, forKey: "silentCryAlarmSchedulingReceipts")
        service.snoozeLocally(eventID: first, duration: 900)
        let relaunched = SilentCryAlarmService(defaults: fixture.defaults)
        relaunched.snoozeLocally(eventID: first, duration: 900)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, cutoff)
        XCTAssertEqual(fixture.defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date, deadline)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "silentCryAlarmPendingAcknowledgements"), [newer.uuidString])
        XCTAssertEqual(fixture.defaults.data(forKey: "silentCryAlarmSchedulingReceipts"), receipt)
    }

    @MainActor func testOldQueuedTokenCannotUndoNewerRemoval() async throws {
        let fixture = try Fixture()
        let date = Date()
        _ = try await fixture.command(WatchCommand(kind: .registerToken, issuedAt: date, token: "abc"))
        _ = try await fixture.command(WatchCommand(kind: .registerToken, issuedAt: date.addingTimeInterval(2)))
        _ = try await fixture.command(WatchCommand(kind: .registerToken, issuedAt: date.addingTimeInterval(1), token: "abc"))
        let tokens = await fixture.backend.tokens
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens.first!, "abc")
        XCTAssertNil(tokens.last!)
    }
    @MainActor func testFailedAcknowledgementRetriesAndConfirmsOnlyAfterSuccess() async throws {
        let fixture = try Fixture()
        let id = UUID()
        await fixture.backend.fail(true)
        let queued = try await fixture.command(WatchCommand(kind: .acknowledge, eventId: id))
        XCTAssertNil(queued.acknowledgedEventId)
        XCTAssertNotNil(queued.message)
        await fixture.backend.fail(false)
        let confirmed = try await fixture.command(WatchCommand(kind: .refresh))
        XCTAssertEqual(confirmed.acknowledgedEventId, id)
        let acknowledgements = await fixture.backend.acknowledgements
        XCTAssertEqual(acknowledgements, [id])
    }
    @MainActor func testListenerModeDoesNotRegisterWatchOrExposeParentStatus() async throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.listener)
        let result = try await fixture.command(WatchCommand(kind: .registerToken, token: "abc"))
        XCTAssertFalse(result.parentMode)
        XCTAssertNil(result.alert)
        let tokens = await fixture.backend.tokens
        XCTAssertTrue(tokens.isEmpty)
    }
    @MainActor func testDeletedAlertIsDiscardedAndDoesNotBlockNewWatchAcknowledgements() async throws {
        let fixture = try Fixture()
        let deleted = UUID(), current = UUID()
        await fixture.backend.failAcknowledgement(deleted, status: 404)
        let resolved = try await fixture.command(WatchCommand(kind: .acknowledge, eventId: deleted))
        XCTAssertEqual(resolved.discardedAcknowledgementEventId, deleted)
        XCTAssertNil(resolved.acknowledgedEventId)
        XCTAssertNil(resolved.message)
        let next = try await fixture.command(WatchCommand(kind: .acknowledge, eventId: current))
        XCTAssertEqual(next.acknowledgedEventId, current)
        _ = try await fixture.command(WatchCommand(kind: .refresh))
        let attempts = await fixture.backend.acknowledgementAttempts
        let acknowledgements = await fixture.backend.acknowledgements
        XCTAssertEqual(attempts, [deleted, current])
        XCTAssertEqual(acknowledgements, [current])
    }

    @MainActor func testRetryableWatchAcknowledgementFailuresRemainQueued() async throws {
        for status in [401, 409, 429, 503] {
            let fixture = try Fixture()
            let first = UUID(), second = UUID()
            await fixture.backend.failAcknowledgement(first, status: status)
            _ = try await fixture.command(WatchCommand(kind: .acknowledge, eventId: first))
            let failed = try await fixture.command(WatchCommand(kind: .acknowledge, eventId: second))
            XCTAssertNil(failed.discardedAcknowledgementEventId)
            XCTAssertNil(failed.acknowledgedEventId)
            XCTAssertNotNil(failed.message)
            await fixture.backend.failAcknowledgement(first, status: nil)
            let recovered = try await fixture.command(WatchCommand(kind: .refresh))
            XCTAssertEqual(recovered.acknowledgedEventId, second)
            let acknowledgements = await fixture.backend.acknowledgements
            XCTAssertEqual(acknowledgements, [first, second])
        }
    }
    @MainActor func testWatchRegistrationFailureRemainsPendingUntilBackendRecovers() async throws {
        let fixture = try Fixture()
        await fixture.backend.fail(true)
        let failed = try await fixture.command(WatchCommand(kind: .registerToken, token: "abc"))
        XCTAssertFalse(failed.watchPushRegistered)
        XCTAssertNotNil(failed.message)
        await fixture.backend.fail(false)
        let recovered = try await fixture.command(WatchCommand(kind: .refresh))
        XCTAssertTrue(recovered.watchPushRegistered)
        let tokens = await fixture.backend.tokens
        XCTAssertEqual(tokens.count, 1)
    }
}
#endif
