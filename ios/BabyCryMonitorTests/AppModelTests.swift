#if !canImport(MonitorCore)
import Foundation
import XCTest
import UserNotifications
@testable import BabyCryMonitor

actor RequestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

final class AppModelTests: XCTestCase {
    @MainActor func testGeneratedAlertUploadsWithoutNetworkTickAfterDurableSave() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(sendGate: gate)
        await fixture.model.start()
        let start = fixture.time.now
        // automaticallyStart is false: no networking tick runs in this test.
        for index in 0...44 {
            fixture.time.now = start.addingTimeInterval(Double(index) / 4)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        }
        let started = await eventually { await fixture.backend.sent.count == 1 }
        XCTAssertTrue(started)
        let sent = await fixture.backend.sent
        let event = try XCTUnwrap(sent.first)
        XCTAssertEqual(event.cryStartedAt, start)
        XCTAssertEqual(event.createdAt.timeIntervalSince(start), 5)
        let saved = try MetadataStore(directory: fixture.directory).load()
        XCTAssertTrue(saved.pending.contains { $0.alert.eventId == event.eventId })
        XCTAssertTrue(fixture.model.log.export.contains("alert_outbox phase=persisted event_id=\(event.eventId.uuidString.lowercased())"))
        XCTAssertTrue(fixture.model.log.export.contains("alert_outbox phase=upload_started event_id=\(event.eventId.uuidString.lowercased())"))
        let tick = Task { await fixture.model.tick() }
        await gate.open(); await tick.value
        let finished = await eventually { fixture.model.snapshot.pending.isEmpty }
        XCTAssertTrue(finished)
        let requests = await fixture.backend.sent
        XCTAssertEqual(requests.map(\.eventId), [event.eventId])
        fixture.model.stop()
    }

    @MainActor func testAlertWaitsForUnsentLocalStartSoAnOlderStopCannotSilenceIt() async throws {
        let fixture = try Fixture()
        await fixture.backend.setMonitoringFailure(true)
        await fixture.model.start()
        let start = fixture.time.now
        for index in 0...44 {
            fixture.time.now = start.addingTimeInterval(Double(index) / 4)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        }
        let held = await eventually { fixture.model.log.export.contains("alert_held_for_monitoring_report") }
        XCTAssertTrue(held)
        var sent = await fixture.backend.sent
        XCTAssertTrue(sent.isEmpty, "The server would judge this upload against the earlier Stop and retire it")
        XCTAssertEqual(fixture.model.snapshot.pending.count, 1)
        await fixture.backend.setMonitoringFailure(false)
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        await fixture.model.tick()
        let delivered = await eventually { fixture.model.snapshot.pending.isEmpty }
        XCTAssertTrue(delivered)
        sent = await fixture.backend.sent
        XCTAssertEqual(sent.count, 1)
        let requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.last?.0, true)
        XCTAssertTrue(fixture.model.log.export.contains("alert_outbox phase=receipt event_id=\(sent[0].eventId.uuidString.lowercased())"))
        XCTAssertTrue(fixture.model.log.export.contains("status=sent"))
        fixture.model.stop()
    }

    @MainActor func testFailedDurableSavePreventsImmediateAlertUpload() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        let start = fixture.time.now
        // Confirmation is included: the alert is due at 5 seconds, not 9.75.
        for index in 0..<20 {
            fixture.time.now = start.addingTimeInterval(Double(index) / 4)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        }
        let observed = await eventually { fixture.model.snapshot.lastObservedAt == fixture.time.now }
        XCTAssertTrue(observed)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        let before = await fixture.backend.sent
        XCTAssertTrue(before.isEmpty)
        // A file in place of the parent directory cannot be replaced by an
        // atomic metadata write (an empty target directory can be replaced).
        try FileManager.default.removeItem(at: fixture.directory)
        try Data("blocked directory".utf8).write(to: fixture.directory)
        fixture.time.now = start.addingTimeInterval(5)
        fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        let failed = await eventually { fixture.model.log.export.contains("metadata_write_failed") }
        XCTAssertTrue(failed)
        await fixture.model.tick()
        let requests = await fixture.backend.sent
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(fixture.model.log.export.contains("alert_outbox phase=upload_started"))
        await gate.open()
        fixture.model.stop()
    }

    @MainActor func testCleanupUsesSuccessfulCompleteStatusAndFailureLeavesNotificationsAlone() async throws {
        let fixture = try Fixture()
        fixture.model.role = .parent; fixture.model.paired = true
        let relevance = NotificationRelevance(cryEpisodeIDs: [UUID()], testEventIDs: [UUID()])
        await fixture.backend.setStatus(ParentStatus(paired: true, configuration: MonitoringConfiguration(), notificationRelevance: relevance))
        let began = fixture.time.now
        await fixture.model.refreshParent()
        XCTAssertEqual(fixture.notifications.cleanupCalls.count, 1)
        XCTAssertEqual(fixture.notifications.cleanupCalls.first?.0, relevance)
        XCTAssertEqual(fixture.notifications.cleanupCalls.first?.1, began)
        await fixture.backend.setStatusFailure(true)
        await fixture.model.refreshParent()
        XCTAssertEqual(fixture.notifications.cleanupCalls.count, 1)
    }

    @MainActor func testTestAlertsNeverTakeOverMonitorButStillReachWatch() async throws {
        let fixture = try Fixture()
        fixture.model.role = .parent; fixture.model.paired = true
        let now = fixture.time.now; fixture.model.now = now
        func test(_ age: TimeInterval) -> RemoteAlert {
            RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now.addingTimeInterval(-age), durationSeconds: 5,
                        createdAt: now.addingTimeInterval(-age), status: "sent", acknowledgedAt: nil, isTest: true)
        }
        let stale = test(1860)
        let recent = [test(2), test(4)]
        let status = ParentStatus(paired: true, alerts: recent + [stale], configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status)
        await fixture.model.refreshParent()
        XCTAssertNil(fixture.model.activeAlert, "Fresh and restored tests must not replace nursery status")
        let handler = try XCTUnwrap(fixture.model.watch.onCommand)
        let watch = await handler(WatchCommand(kind: .refresh))
        XCTAssertEqual(watch.alert?.eventId, recent[0].eventId)
        XCTAssertEqual(watch.alert?.isTest, true)
        let acknowledged = await fixture.backend.acknowledgements
        XCTAssertTrue(acknowledged.isEmpty, "Opening Monitor must not report an unobserved receipt")
        XCTAssertTrue(fixture.notifications.dismissals.isEmpty)

        var oldStatus = status; oldStatus.alerts = [stale]
        await fixture.backend.setStatus(oldStatus)
        let oldWatch = await handler(WatchCommand(kind: .refresh))
        XCTAssertNil(oldWatch.alert, "Old tests must not resurface on Watch either")
        XCTAssertNil(fixture.model.activeAlert)
    }

    @MainActor func testSnoozeClearsRealNotificationsAndTestAcknowledgementOnlyClearsItsTest() async throws {
        let fixture = try Fixture()
        fixture.model.role = .parent; fixture.model.paired = true
        let now = fixture.time.now
        let real = RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now, durationSeconds: 5, createdAt: now, status: "sent", acknowledgedAt: nil, isTest: false)
        let test = RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now, durationSeconds: 5, createdAt: now, status: "sent", acknowledgedAt: nil, isTest: true)
        let status = ParentStatus(paired: true, alerts: [test,real], configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); fixture.model.parentStatus = status
        XCTAssertEqual(fixture.model.activeAlert?.id, real.eventId)
        _ = await fixture.model.acknowledge(real.eventId)
        _ = await fixture.model.acknowledge(test.eventId)
        XCTAssertEqual(fixture.notifications.dismissals.count, 2)
        XCTAssertNil(fixture.notifications.dismissals[0])
        XCTAssertEqual(fixture.notifications.dismissals[1], test.eventId)
        var resolved = real; resolved.resolvedAt = now
        fixture.model.parentStatus?.alerts = [resolved,test]
        XCTAssertNil(fixture.model.activeAlert)
    }

    @MainActor func testResumeAlertsRefreshesConfirmedDeadlineAndKeepsMonitoringActive() async throws {
        let fixture = try Fixture()
        fixture.model.role = .parent; fixture.model.paired = true
        let until = fixture.time.now.addingTimeInterval(60)
        let status = ParentStatus(paired: true, alertsMutedUntil: until, lastHeartbeat: fixture.time.now, monitoring: true,
                                  configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); fixture.model.parentStatus = status
        await fixture.model.resumeAlerts()
        let deadlines = await fixture.backend.resumedDeadlines
        XCTAssertEqual(deadlines, [until])
        XCTAssertTrue(fixture.model.parentOnline)
        XCTAssertLessThan(try XCTUnwrap(fixture.model.parentStatus?.alertsMutedUntil), fixture.time.now)
        XCTAssertFalse(fixture.model.resumingAlerts)
    }

    @MainActor func testFailedResumeDoesNotPretendSnoozeEnded() async throws {
        let fixture = try Fixture()
        fixture.model.role = .parent; fixture.model.paired = true
        let until = fixture.time.now.addingTimeInterval(60)
        fixture.model.parentStatus = ParentStatus(paired: true, alertsMutedUntil: until, configuration: MonitoringConfiguration())
        await fixture.backend.setResumeFailure(true)
        await fixture.model.resumeAlerts()
        XCTAssertEqual(fixture.model.parentStatus?.alertsMutedUntil, until)
        XCTAssertTrue(fixture.model.error?.contains("Could not confirm") == true)
        XCTAssertFalse(fixture.model.resumingAlerts)
    }

    @MainActor func testNurserySnoozeAndResumeUseSharedStateWithoutStoppingTheMicrophone() async throws {
        let fixture = try Fixture()
        let now = fixture.time.now
        let alert = RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now, durationSeconds: 5,
                                createdAt: now, status: "sent", acknowledgedAt: nil, isTest: false)
        await fixture.backend.setStatus(ParentStatus(paired: true, lastHeartbeat: now, monitoring: true, alerts: [alert],
                                                   configuration: MonitoringConfiguration()))
        await fixture.model.start()
        XCTAssertEqual(fixture.model.activeAlert?.eventId, alert.eventId)
        let stops = fixture.audio.stops
        await fixture.backend.setSnoozeResult(until: now.addingTimeInterval(60))
        let snoozed = await fixture.model.acknowledge(alert.eventId)
        XCTAssertTrue(snoozed)
        XCTAssertNil(fixture.model.activeAlert)
        XCTAssertEqual(fixture.model.listenerPairStatus?.alertsMutedUntil, now.addingTimeInterval(60))
        XCTAssertTrue(fixture.model.monitoring); XCTAssertTrue(fixture.model.microphoneActive)
        XCTAssertEqual(fixture.audio.stops, stops)
        let resumed = await fixture.model.resumeAlerts()
        XCTAssertTrue(resumed)
        XCTAssertLessThan(try XCTUnwrap(fixture.model.listenerPairStatus?.alertsMutedUntil), now)
        XCTAssertTrue(fixture.model.monitoring); XCTAssertTrue(fixture.model.microphoneActive)
        XCTAssertEqual(fixture.audio.stops, stops)
        fixture.model.stop()
    }

    @MainActor func testSlowNurseryPollCannotDelayOrUndoConfirmedSnooze() async throws {
        let fixture = try Fixture(), now = Date(), gate = RequestGate()
        let alert = RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now, durationSeconds: 5,
                                createdAt: now, status: "sent", acknowledgedAt: nil, isTest: false)
        await fixture.backend.setStatus(ParentStatus(paired: true, alerts: [alert], configuration: MonitoringConfiguration()))
        await fixture.model.start()
        await fixture.backend.holdNextStatus(gate)
        await fixture.model.tick()
        let polling = await eventually { await fixture.backend.statusCalls >= 2 }
        XCTAssertTrue(polling)
        let until = fixture.time.now.addingTimeInterval(60)
        await fixture.backend.setSnoozeResult(until: until)
        let action = Task { await fixture.model.acknowledge(alert.eventId) }
        let confirmed = await eventually { fixture.model.listenerPairStatus?.alertsMutedUntil == until && !fixture.model.acknowledgingAlert }
        await gate.open()
        let succeeded = await action.value
        XCTAssertTrue(confirmed, "Snooze must not wait for a slow poll begun before the tap")
        XCTAssertTrue(succeeded)
        // Give the stale response a chance to finish and attempt its assignment.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.model.listenerPairStatus?.alertsMutedUntil, until)
        XCTAssertNil(fixture.model.activeAlert)
        XCTAssertTrue(fixture.model.monitoring)
        fixture.model.stop()
    }

    @MainActor func testFailedNurserySnoozeOrResumeDoesNotShowAConfirmedChange() async throws {
        let fixture = try Fixture(), now = Date()
        let alert = RemoteAlert(eventId: UUID(), episodeId: UUID(), cryStartedAt: now, durationSeconds: 5,
                                createdAt: now, status: "sent", acknowledgedAt: nil, isTest: false)
        await fixture.backend.setStatus(ParentStatus(paired: true, alerts: [alert], configuration: MonitoringConfiguration()))
        await fixture.model.start()
        await fixture.backend.setSnoozeFailure(true)
        let result = await fixture.model.acknowledge(alert.eventId)
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.model.activeAlert?.eventId, alert.eventId)
        XCTAssertNil(fixture.model.listenerPairStatus?.alertsMutedUntil)
        XCTAssertTrue(fixture.model.monitoring)
        let until = fixture.time.now.addingTimeInterval(60)
        await fixture.backend.setStatus(ParentStatus(paired: true, alertsMutedUntil: until, configuration: MonitoringConfiguration()))
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        await fixture.model.tick()
        let received = await eventually { fixture.model.listenerPairStatus?.alertsMutedUntil == until }
        XCTAssertTrue(received)
        await fixture.backend.setResumeFailure(true)
        let resumed = await fixture.model.resumeAlerts()
        XCTAssertFalse(resumed)
        XCTAssertEqual(fixture.model.listenerPairStatus?.alertsMutedUntil, until)
        XCTAssertTrue(fixture.model.monitoring)
        fixture.model.stop()
    }

    @MainActor final class Audio: AudioLevelProviding {
        let levels: AsyncStream<AudioLevelSample>
        private let continuation: AsyncStream<AudioLevelSample>.Continuation
        var onStatus: ((AudioCaptureStatus) -> Void)?
        var permissionGranted = true
        var recoveryGate: RequestGate?
        var startFailure: Error?
        var recoveringOnStartFailure = false
        private(set) var starts = 0
        private(set) var stops = 0
        init() {
            let stream = AsyncStream<AudioLevelSample>.makeStream()
            levels = stream.stream; continuation = stream.continuation
        }
        func emit(_ sample: AudioLevelSample) { continuation.yield(sample) }
        func requestPermission() async -> Bool { permissionGranted }
        func start() async throws {
            starts += 1
            if let recoveryGate {
                onStatus?(.recovering("Audio route changed. Recovering microphone…"))
                await recoveryGate.wait()
            }
            if let startFailure {
                if recoveringOnStartFailure { onStatus?(.recovering("Audio route changed. Recovering microphone…")) }
                throw startFailure
            }
            onStatus?(.active)
        }
        func stop() { stops += 1; onStatus?(.stopped) }
    }
    @MainActor final class Connectivity: ConnectivityProviding {
        var available = true
        var checked = true
    }
    @MainActor final class LiveSound: LiveSoundStreaming {
        var onFrame: ((SoundLevelFrame) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var connectedDevice: UUID?
        var frames: [SoundLevelFrame] = []
        func connect(baseURL: URL, credential: DeviceCredential) { connectedDevice = credential.deviceId }
        func disconnect() { connectedDevice = nil; onConnectionChange?(false) }
        func publish(_ frame: SoundLevelFrame) { frames.append(frame) }
    }
    @MainActor final class Notifications: NotificationProviding {
        var cleanupCalls: [(NotificationRelevance, Date)] = []
        var dismissals: [UUID?] = []
        func cleanUpAlerts(using relevance: NotificationRelevance, deliveredBefore: Date) async { cleanupCalls.append((relevance, deliveredBefore)) }
        func dismissCryingAlerts(testEventID: UUID?) async { dismissals.append(testEventID) }
        var status = "Test notifications"
        var onToken: ((String) -> Void)?
        var onAlert: (() -> Void)?
        var connectionDeadlines: [Date?] = []
        var scheduledConnectionDeadline: Date?
        var connectionWarningFails = false
        var connectionWarningGate: RequestGate?
        func register() async {}
        func registered(_ token: Data) {}
        func failed() {}
        func simulate(_ alert: CryAlert) async throws {}
        func setParentConnectionDeadline(_ deadline: Date?) async throws {
            connectionDeadlines.append(deadline)
            await connectionWarningGate?.wait()
            if deadline != nil, connectionWarningFails { throw URLError(.notConnectedToInternet) }
            scheduledConnectionDeadline = deadline
        }
    }
    struct Credentials: CredentialStoring {
        let listener: DeviceCredential
        let parent: DeviceCredential
        func load(role: DeviceRole, environment: String) throws -> DeviceCredential? {
            role == .listener ? listener : parent
        }
        func save(_ credential: DeviceCredential, environment: String) throws {}
        func create(role: DeviceRole) throws -> DeviceCredential { role == .listener ? listener : parent }
    }
    actor Backend: BackendServing {
        nonisolated let credential: DeviceCredential
        private(set) var beats: [Heartbeat] = []
        private(set) var sent: [CryAlert] = []
        private(set) var settingsCalls = 0
        private(set) var heartbeatCompletions = 0
        var settingsFail = false
        var settingsGate: RequestGate?
        var heartbeatGate: RequestGate?
        var sendGate: RequestGate?
        var heartbeatFail = false
        var sendFail = false
        var receipt = "sent"
        private(set) var removedPair = false
        private(set) var deletedDevice = false
        private(set) var requestedTest = false
        private(set) var connectionAlertPreferences: [Bool] = []
        var testRequestFails = false
        var statusValue: ParentStatus?
        var statusGate: RequestGate?
        private(set) var statusCalls = 0
        var statusFails = false
        var monitoringFails = false
        private(set) var monitoringRequests: [(Bool, UUID)] = []
        private(set) var monitoringResults: [(UUID, Bool)] = []
        func setMonitoringFailure(_ value: Bool) { monitoringFails = value }
        func setMonitoring(_ enabled: Bool, id: UUID) async throws -> MonitoringCommand {
            monitoringRequests.append((enabled, id))
            if monitoringFails { throw URLError(.notConnectedToInternet) }
            return MonitoringCommand(id: id, enabled: enabled, status: "pending", createdAt: Date(), expiresAt: Date().addingTimeInterval(30))
        }
        func completeMonitoring(_ id: UUID, succeeded: Bool) async throws { monitoringResults.append((id, succeeded)) }
        init(credential: DeviceCredential) { self.credential = credential }
        func configure(settingsFail: Bool = false, settingsGate: RequestGate? = nil,
                       heartbeatGate: RequestGate? = nil, sendGate: RequestGate? = nil,
                       heartbeatFail: Bool = false, sendFail: Bool = false, receipt: String = "sent") {
            self.settingsFail = settingsFail; self.settingsGate = settingsGate
            self.heartbeatGate = heartbeatGate; self.receipt = receipt
            self.sendGate = sendGate; self.heartbeatFail = heartbeatFail; self.sendFail = sendFail
        }
        func register() async throws {}
        func createPairing() async throws -> PairingCode { PairingCode(code: "123456", expiresAt: .distantFuture) }
        func claim(_ code: String) async throws {}
        private var nextStatusGate: RequestGate?
        func holdNextStatus(_ gate: RequestGate) { nextStatusGate = gate }
        func status() async throws -> ParentStatus {
            statusCalls += 1
            if let gate = nextStatusGate {
                nextStatusGate = nil
                let captured = statusValue ?? ParentStatus(paired: true, configuration: MonitoringConfiguration())
                await gate.wait()
                return captured
            }
            await statusGate?.wait()
            if statusFails { throw URLError(.timedOut) }
            return statusValue ?? ParentStatus(paired: true, configuration: MonitoringConfiguration())
        }
        func setStatusFailure(_ fails: Bool) { statusFails = fails }
        func setStatusGate(_ gate: RequestGate?) { statusGate = gate }
        func setStatus(_ value: ParentStatus) { statusValue = value }
        func unpair() async throws { removedPair = true }
        func deleteDevice() async throws { deletedDevice = true }
        func setTestRequestFailure(_ fails: Bool) { testRequestFails = fails }
        func requestTestPush() async throws {
            if testRequestFails { throw URLError(.notConnectedToInternet) }
            requestedTest = true
        }
        private(set) var watchTestRequests = 0
        var watchTestGate: RequestGate?
        func setWatchTestGate(_ gate: RequestGate?) { watchTestGate = gate }
        func sendWatchTest() async throws {
            watchTestRequests += 1
            await watchTestGate?.wait()
            if testRequestFails { throw URLError(.notConnectedToInternet) }
        }
        func connectionAlerts(_ enabled: Bool) async throws {
            connectionAlertPreferences.append(enabled)
            statusValue?.connectionAlertsEnabled = enabled
        }
        func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration {
            beats.append(value)
            await heartbeatGate?.wait()
            heartbeatCompletions += 1
            if heartbeatFail { throw URLError(.timedOut) }
            return MonitoringConfiguration()
        }
        func settings(_ configuration: MonitoringConfiguration) async throws {
            settingsCalls += 1
            await settingsGate?.wait()
            if settingsFail { throw URLError(.badServerResponse) }
        }
        func send(_ alert: CryAlert) async throws -> AlertReceipt {
            sent.append(alert)
            await sendGate?.wait()
            if sendFail { throw URLError(.notConnectedToInternet) }
            return AlertReceipt(status: receipt)
        }
        private(set) var resumedDeadlines: [Date] = []
        var resumeFails = false
        func setResumeFailure(_ value: Bool) { resumeFails = value }
        func resumeAlerts(until: Date) async throws {
            resumedDeadlines.append(until)
            if resumeFails { throw URLError(.notConnectedToInternet) }
            statusValue?.alertsMutedUntil = Date().addingTimeInterval(-1)
        }
        private(set) var acknowledgements: [UUID] = []
        var snoozeFails = false
        var snoozeUntil: Date?
        func setSnoozeFailure(_ value: Bool) { snoozeFails = value }
        func setSnoozeResult(until: Date) { snoozeUntil = until }
        func acknowledge(_ id: UUID, actedAt: Date?) async throws {
            if snoozeFails { throw URLError(.notConnectedToInternet) }
            acknowledgements.append(id)
            if let snoozeUntil {
                statusValue?.alertsMutedUntil = snoozeUntil
                if let index = statusValue?.alerts?.firstIndex(where: { $0.eventId == id }), let old = statusValue?.alerts?[index] {
                    statusValue?.alerts?[index] = RemoteAlert(eventId: old.eventId, episodeId: old.episodeId, cryStartedAt: old.cryStartedAt,
                        durationSeconds: old.durationSeconds, createdAt: old.createdAt, status: old.status, acknowledgedAt: Date(), isTest: old.isTest)
                }
            }
        }
        func pushToken(_ token: String) async throws {}
        func watchPushToken(_ token: String?) async throws {}
    }
    @MainActor final class Fixture {
        let model: AppModel
        let audio = Audio()
        let liveSound = LiveSound()
        let connectivity = Connectivity()
        let notifications = Notifications()
        let backend: Backend
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let listener: DeviceCredential
        let parent: DeviceCredential
        final class Time { var now = Date() }
        let time: Time
        init(pending: Bool = false, automaticallyStart: Bool = false, logEvents: [String] = [], snapshotData: Data? = nil, heartbeatJitter: @escaping () -> Double = { 1 }, localWarnings: Bool = false, configureDefaults: (UserDefaults, DeviceCredential) -> Void = { _, _ in }) throws {
            suite = "AppModelTests.\(UUID())"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            listener = DeviceCredential(deviceId: UUID(), secret: "test-listener", role: .listener, registered: true)
            parent = DeviceCredential(deviceId: UUID(), secret: "test-parent", role: .parent, registered: true)
            defaults.set("listener", forKey: "role")
            defaults.set(true, forKey: "safetyAccepted")
            defaults.set("https://monitor.test", forKey: "backendURL")
            defaults.set(true, forKey: "paired|https://monitor.test|listener")
            if localWarnings { defaults.set(true, forKey: "localConnectionWarningEnabled") }
            configureDefaults(defaults, parent)
            let store = try MetadataStore(directory: directory)
            var snapshot = SessionSnapshot()
            if pending {
                snapshot.pending = [PendingAlert(alert: CryAlert(episodeId: UUID(), listenerId: listener.deviceId,
                    cryStartedAt: Date().addingTimeInterval(-301), durationSeconds: 300,
                    createdAt: Date().addingTimeInterval(-1), isRepeat: false))]
            }
            try store.save(snapshot)
            if let snapshotData { try snapshotData.write(to: directory.appendingPathComponent("listener-metadata.json")) }
            let backend = Backend(credential: listener); self.backend = backend
            let time = Time(); self.time = time
            let log = DiagnosticLog(directory: directory)
            for event in logEvents { log.record(event) }
            model = AppModel(defaults: defaults, metadataStore: store, log: log, audio: audio, liveSound: liveSound, connectivity: connectivity,
                             notifications: notifications, keychain: Credentials(listener: listener, parent: parent),
                             makeClient: { _, _ in backend }, currentTime: { time.now }, heartbeatJitter: heartbeatJitter, automaticallyStart: automaticallyStart)
        }
        deinit {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    @MainActor func testLiveSoundPublishesExactNurseryWindowAndStopsWithMicrophone() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        XCTAssertEqual(fixture.liveSound.connectedDevice, fixture.listener.deviceId)
        for i in 0..<40 {
            fixture.time.now = fixture.time.now.addingTimeInterval(0.25)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -80 + Double(i)))
        }
        for _ in 0..<100 { await Task.yield() }
        let frame = try XCTUnwrap(fixture.liveSound.frames.last)
        XCTAssertEqual(frame.levels, fixture.model.meter)
        XCTAssertEqual(frame.levels, Array(repeating: -100.0, count: SoundLevelFrame.barCount - 40) + (0..<40).map { -80 + Double($0) })
        XCTAssertEqual(frame.threshold, fixture.model.threshold)
        XCTAssertEqual(frame.state, fixture.model.state)
        XCTAssertTrue(frame.isValid)
        fixture.model.stop()
        XCTAssertNil(fixture.liveSound.connectedDevice)
    }
    @MainActor func testParentSoundStaysCurrentWithoutMonitorVisibilityAndClearsOnUnpairing() async throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        XCTAssertEqual(fixture.liveSound.connectedDevice, fixture.parent.deviceId)
        let frame = SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
                                   threshold: -45, state: .quiet, alertDuration: 30)
        fixture.liveSound.onFrame?(frame)
        XCTAssertTrue(fixture.model.remoteSound.isLive(at: fixture.time.now))
        // Time spent in Activity must still replace the chart with current data.
        fixture.time.now = fixture.time.now.addingTimeInterval(10)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        var latest = frame
        latest.sampledAt += 10; latest.levels = Array(repeating: -30, count: 120)
        fixture.liveSound.onFrame?(latest)
        XCTAssertEqual(fixture.model.remoteSound.frame, latest)
        XCTAssertTrue(fixture.model.remoteSound.isLive(at: fixture.time.now))
        fixture.model.setAppActive(false)
        XCTAssertNil(fixture.liveSound.connectedDevice)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        latest.sampledAt += 1
        fixture.liveSound.onFrame?(latest)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        fixture.model.setAppActive(true)
        XCTAssertEqual(fixture.liveSound.connectedDevice, fixture.parent.deviceId)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        fixture.liveSound.onFrame?(latest)
        XCTAssertEqual(fixture.model.remoteSound.frame, latest)
        XCTAssertTrue(fixture.model.remoteSound.isLive(at: fixture.time.now))
        await fixture.model.removePairing(deleteDevice: false)
        XCTAssertNil(fixture.liveSound.connectedDevice)
        XCTAssertNil(fixture.model.remoteSound.frame)
    }
    @MainActor func testLiveSoundImmediatelyOffersPauseBeforeStoppedHeartbeatRefreshes() async throws {
        let fixture = try Fixture(localWarnings: true)
        fixture.model.selectRole(.parent)
        fixture.model.paired = true
        fixture.model.parentStatus = ParentStatus(paired: true, lastHeartbeat: fixture.time.now,
            monitoring: false, configuration: MonitoringConfiguration(), microphoneActive: true)
        XCTAssertTrue(fixture.model.canStartMonitoringRemotely)
        XCTAssertFalse(fixture.model.parentDisplaysMonitoring)
        let frame = SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
            threshold: -45, state: .quiet, alertDuration: 30)
        fixture.liveSound.onFrame?(frame)
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring)
        XCTAssertTrue(fixture.model.parentHasLiveMonitoring)
        XCTAssertFalse(fixture.model.parentOnline, "Live readings must not confirm a server heartbeat")
        XCTAssertNil(fixture.model.parentConnectionDeadline)
        XCTAssertEqual(fixture.model.parentStatus?.monitoring, false)
        fixture.model.now = fixture.time.now.addingTimeInterval(3)
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring, "A short stream gap must not restore an older stopped heartbeat")
        fixture.model.now = fixture.time.now
        fixture.liveSound.onConnectionChange?(false)
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring)
    }

    @MainActor func testAllParentSurfacesShareLiveLatchAndNewerStandbyEvidence() throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.parent); fixture.model.paired = true
        var status = ParentStatus(paired: true, lastHeartbeat: fixture.time.now,
            monitoring: false, configuration: MonitoringConfiguration(), microphoneActive: true)
        fixture.model.parentStatus = status
        fixture.liveSound.onFrame?(SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
            threshold: -45, state: .quiet, alertDuration: 30))
        fixture.time.now = fixture.time.now.addingTimeInterval(5); fixture.model.now = fixture.time.now
        fixture.liveSound.onConnectionChange?(false)
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring)
        XCTAssertTrue(fixture.model.parentDisplaysActiveMicrophone)
        XCTAssertEqual(fixture.model.nurseryConnection, "Monitoring")
        XCTAssertEqual(fixture.model.nightstandDevices.first?.status, "Monitoring")
        XCTAssertFalse(fixture.model.canStartMonitoringRemotely)
        status.lastHeartbeat = fixture.time.now
        fixture.model.parentStatus = status
        XCTAssertEqual(fixture.model.parentMonitoringDisplayState, .standby)
        XCTAssertFalse(fixture.model.parentDisplaysMonitoring)
        XCTAssertTrue(fixture.model.parentDisplaysActiveMicrophone)
        XCTAssertEqual(fixture.model.nightstandDevices.first?.status, "Standby")
        XCTAssertTrue(fixture.model.canStartMonitoringRemotely)
    }

    @MainActor func testRepairedListenerCannotInheritLivePresentationAfterStatusFailure() throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.parent); fixture.model.paired = true
        fixture.model.parentStatus = ParentStatus(paired: true, pairingID: "first", lastHeartbeat: fixture.time.now,
            monitoring: false, configuration: MonitoringConfiguration(), microphoneActive: true)
        fixture.liveSound.onFrame?(SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
            threshold: -45, state: .quiet, alertDuration: 30))
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring)
        fixture.model.parentStatus = nil
        XCTAssertTrue(fixture.model.parentDisplaysMonitoring)
        fixture.model.parentStatus = ParentStatus(paired: true, pairingID: "second", lastHeartbeat: fixture.time.now,
            monitoring: false, configuration: MonitoringConfiguration(), microphoneActive: false)
        XCTAssertEqual(fixture.model.parentMonitoringDisplayState, .stopped)
        XCTAssertFalse(fixture.model.parentHasLiveMonitoring)
    }

    @MainActor func testPauseDiscardsLiveEvidenceAndIgnoresFramesAlreadyInFlight() async throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        var frame = SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
            threshold: -45, state: .quiet, alertDuration: 30)
        fixture.liveSound.onFrame?(frame)
        XCTAssertTrue(fixture.model.parentHasLiveMonitoring)
        await fixture.model.requestMonitoring(false)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        frame.sampledAt += 1
        fixture.liveSound.onFrame?(frame)
        XCTAssertFalse(fixture.model.remoteSound.isLive(at: fixture.time.now))
        XCTAssertFalse(fixture.model.parentHasLiveMonitoring)
    }

    @MainActor func testLiveSoundCannotConfirmMonitoringOrArmConnectionWarnings() async throws {
        let fixture = try Fixture(localWarnings: true)
        fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        await fixture.model.requestMonitoring(true)
        let pending = try XCTUnwrap(fixture.model.pendingMonitoringCommand)
        fixture.liveSound.onFrame?(SoundLevelFrame(sampledAt: 100, levels: Array(repeating: -40, count: 120),
            threshold: -45, state: .crying, episodeStartedAt: 95, alertDuration: 30))
        XCTAssertTrue(fixture.model.remoteSound.isLive(at: fixture.time.now))
        XCTAssertFalse(fixture.model.parentHasLiveMonitoring)
        XCTAssertFalse(fixture.model.parentDisplaysMonitoring)
        XCTAssertEqual(fixture.model.pendingMonitoringCommand?.id, pending.id)
        XCTAssertFalse(fixture.model.parentOnline)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
        fixture.liveSound.onConnectionChange?(false)
        XCTAssertEqual(fixture.model.pendingMonitoringCommand?.id, pending.id)
        XCTAssertNil(fixture.model.monitoringControlError)
    }
    @MainActor func testParentRequestRequiresMicrophoneConfirmationAndTimesOutProminently() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        await fixture.model.requestMonitoring(true)
        XCTAssertNotNil(fixture.model.pendingMonitoringCommand)
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertNil(fixture.model.monitoringControlError)
        fixture.time.now = fixture.time.now.addingTimeInterval(31)
        await fixture.model.tick()
        XCTAssertNil(fixture.model.pendingMonitoringCommand)
        XCTAssertTrue(fixture.model.monitoringControlError?.contains("could not be started or verified") == true)
    }
    @MainActor func testParentRequiresFreshMatchingMicrophoneHeartbeat() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent(); await fixture.model.requestMonitoring(true)
        let pending = try XCTUnwrap(fixture.model.pendingMonitoringCommand)
        let command = MonitoringCommand(id: pending.id, enabled: true, status: "applied", createdAt: fixture.time.now.addingTimeInterval(-1), expiresAt: fixture.time.now.addingTimeInterval(30))
        var status = ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, monitoring: false, configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.pendingMonitoringCommand)
        status.monitoring = true; status.lastHeartbeat = fixture.time.now.addingTimeInterval(-45)
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.pendingMonitoringCommand)
        status.lastHeartbeat = fixture.time.now
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertNil(fixture.model.pendingMonitoringCommand)
        XCTAssertEqual(fixture.model.monitoringControlMessage, "Monitoring confirmed on nursery phone")
        XCTAssertNil(fixture.model.monitoringControlError)
    }
    @MainActor func testParentReportsFailureOnlyIfMicrophoneRemainsUnverifiedAtDeadline() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent(); await fixture.model.requestMonitoring(true)
        var command = try XCTUnwrap(fixture.model.pendingMonitoringCommand); command.status = "failed"
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.refreshParent()
        XCTAssertNil(fixture.model.monitoringControlError, "A startup callback can fail while route recovery is still running")
        XCTAssertNotNil(fixture.model.pendingMonitoringCommand)
        fixture.time.now = fixture.time.now.addingTimeInterval(31); await fixture.model.tick()
        XCTAssertNotNil(fixture.model.monitoringControlError)
        XCTAssertNil(fixture.model.pendingMonitoringCommand)
        await fixture.backend.setMonitoringFailure(true)
        await fixture.model.requestMonitoring(false)
        XCTAssertNil(fixture.model.monitoringControlError, "A lost POST response does not prove the request failed")
        fixture.time.now = fixture.time.now.addingTimeInterval(31); await fixture.model.tick()
        XCTAssertTrue(fixture.model.monitoringControlError?.contains("Monitoring pause could not be verified") == true)
    }
    @MainActor func testFreshMicrophoneHeartbeatOverridesFailedOrPendingStartupReceipt() async throws {
        for receipt in ["failed", "pending", "expired"] {
            let fixture = try Fixture(); fixture.model.selectRole(.parent)
            await fixture.model.refreshParent(); await fixture.model.requestMonitoring(true)
            let pending = try XCTUnwrap(fixture.model.pendingMonitoringCommand)
            let command = MonitoringCommand(id: pending.id, enabled: true, status: receipt,
                createdAt: fixture.time.now.addingTimeInterval(-1), expiresAt: fixture.time.now.addingTimeInterval(30))
            await fixture.backend.setStatus(ParentStatus(paired: true, lastHeartbeat: fixture.time.now,
                serverTime: fixture.time.now, monitoringCommand: command, monitoring: true, configuration: MonitoringConfiguration()))
            await fixture.model.refreshParent()
            XCTAssertNil(fixture.model.pendingMonitoringCommand, receipt)
            XCTAssertNil(fixture.model.monitoringControlError, receipt)
            XCTAssertEqual(fixture.model.monitoringControlMessage, "Monitoring confirmed on nursery phone", receipt)
        }
    }
    @MainActor func testLateMicrophoneConfirmationClearsPersistedFailure() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent(); await fixture.model.requestMonitoring(true)
        let pending = try XCTUnwrap(fixture.model.pendingMonitoringCommand)
        fixture.time.now = fixture.time.now.addingTimeInterval(31); await fixture.model.tick()
        XCTAssertNotNil(fixture.model.monitoringControlError)
        let command = MonitoringCommand(id: pending.id, enabled: true, status: "failed",
            createdAt: fixture.time.now.addingTimeInterval(-32), expiresAt: fixture.time.now.addingTimeInterval(-2))
        await fixture.backend.setStatus(ParentStatus(paired: true, lastHeartbeat: fixture.time.now,
            serverTime: fixture.time.now, monitoringCommand: command, monitoring: true, configuration: MonitoringConfiguration()))
        await fixture.model.refreshParent()
        XCTAssertNil(fixture.model.monitoringControlError)
        XCTAssertNil(fixture.defaults.string(forKey: "paired|https://monitor.test|parent|pendingMonitoringCommand|error"))
        XCTAssertEqual(fixture.model.monitoringControlMessage, "Monitoring confirmed on nursery phone")
    }
    @MainActor func testTransientStatusFailureDoesNotPresentMonitoringFailureBeforeDeadline() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent(); await fixture.model.requestMonitoring(true)
        await fixture.backend.setStatusFailure(true); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.pendingMonitoringCommand)
        XCTAssertNil(fixture.model.monitoringControlError)
        fixture.time.now = fixture.time.now.addingTimeInterval(31); await fixture.model.tick()
        XCTAssertNotNil(fixture.model.monitoringControlError)
    }
    @MainActor func testRemoteStartWaitsForAudioRouteRecoveryInsteadOfReportingFalseFailure() async throws {
        let fixture = try Fixture()
        fixture.audio.startFailure = CancellationError(); fixture.audio.recoveringOnStartFailure = true
        let command = MonitoringCommand(id: UUID(), enabled: true, status: "pending", createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let recovering = await eventually { fixture.model.recoveringAudio && !fixture.model.starting }
        XCTAssertTrue(recovering)
        let beforeRecovery = await fixture.backend.monitoringResults
        XCTAssertTrue(beforeRecovery.isEmpty, "Do not turn a cancelled start callback into a terminal failure while audio recovers")
        fixture.audio.onStatus?(.active)
        fixture.time.now = fixture.time.now.addingTimeInterval(3); await fixture.model.tick()
        let confirmed = await eventually { (await fixture.backend.monitoringResults).contains { $0.0 == command.id && $0.1 } }
        XCTAssertTrue(confirmed); XCTAssertEqual(fixture.audio.starts, 1)
        fixture.model.stop()
    }
    @MainActor func testListenerPauseReportsStandbyAndAllowsRemoteResumeWithoutRestartingMicrophone() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        await fixture.model.tick()
        fixture.model.pauseMonitoring()
        XCTAssertTrue(fixture.model.standby)
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.microphoneActive)
        XCTAssertEqual(fixture.audio.stops, 0)
        XCTAssertNil(fixture.model.snapshot.current)
        XCTAssertEqual(fixture.model.currentDBFS, -100)
        fixture.time.now = fixture.time.now.addingTimeInterval(3)
        await fixture.model.tick()
        let requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.map(\.0), [true, false], "Local pause must also cancel server alert reminders")
        let reported = await eventually {
            let beat = await fixture.backend.beats.last
            return beat?.monitoring == false && beat?.microphoneActive == true
        }
        XCTAssertTrue(reported)
        fixture.model.setAppActive(false)
        try await remoteCommand(true, fixture: fixture)
        XCTAssertTrue(fixture.model.monitoring)
        XCTAssertFalse(fixture.model.standby)
        XCTAssertEqual(fixture.audio.starts, 1, "Parent resume must reuse the microphone while Listener is in the background")
        fixture.model.stop()
        XCTAssertFalse(fixture.model.microphoneActive)
        XCTAssertEqual(fixture.audio.stops, 1)
    }

    @MainActor func testRemotePauseKeepsAudioAndPublishesStandbyHeartbeat() async throws {
        let fixture = try Fixture(); await fixture.model.start()
        let command = MonitoringCommand(id: UUID(), enabled: false, status: "pending", createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let stopped = await eventually {
            let results = await fixture.backend.monitoringResults
            return !fixture.model.monitoring && results.contains { $0.0 == command.id && $0.1 }
        }
        XCTAssertTrue(stopped)
        let reported = await eventually { await fixture.backend.beats.last?.monitoring == false }
        XCTAssertTrue(reported)
    }
    @MainActor private func remoteCommand(_ enabled: Bool, fixture: Fixture) async throws {
        fixture.time.now = fixture.time.now.addingTimeInterval(3)
        let command = MonitoringCommand(id: UUID(), enabled: enabled, status: "pending",
            createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now,
            monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let applied = await eventually { (await fixture.backend.monitoringResults).contains { $0.0 == command.id && $0.1 } }
        XCTAssertTrue(applied)
    }
    @MainActor func testStandbyDiscardsSoundAndRemoteResumeReusesCaptureWithFreshDetection() async throws {
        let fixture = try Fixture(); await fixture.model.start()
        for _ in 0..<24 {
            fixture.time.now = fixture.time.now.addingTimeInterval(0.25)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        }
        let crying = await eventually { fixture.model.snapshot.current != nil }
        XCTAssertTrue(crying)
        try await remoteCommand(false, fixture: fixture)
        XCTAssertTrue(fixture.model.standby); XCTAssertFalse(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.microphoneActive); XCTAssertEqual(fixture.audio.stops, 0)
        XCTAssertEqual(fixture.model.state, .quiet); XCTAssertNil(fixture.model.snapshot.current)
        XCTAssertNil(fixture.liveSound.connectedDevice)
        let history = fixture.model.snapshot.history.count
        let frames = fixture.liveSound.frames.count
        let pending = fixture.model.snapshot.pending.count
        for _ in 0..<160 {
            fixture.time.now = fixture.time.now.addingTimeInterval(0.25)
            fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.model.snapshot.history.count, history)
        XCTAssertEqual(fixture.model.snapshot.pending.count, pending)
        XCTAssertNil(fixture.model.snapshot.current)
        XCTAssertEqual(fixture.liveSound.frames.count, frames)
        XCTAssertEqual(fixture.model.currentDBFS, -100)
        let pausedSampleTime = fixture.time.now
        fixture.model.setAppActive(false)
        try await remoteCommand(true, fixture: fixture)
        XCTAssertTrue(fixture.model.monitoring); XCTAssertFalse(fixture.model.standby)
        XCTAssertEqual(fixture.audio.starts, 1, "Resume must not reactivate a background audio session")
        XCTAssertEqual(fixture.model.state, .quiet)
        fixture.audio.emit(AudioLevelSample(timestamp: pausedSampleTime, dbFS: -10))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.model.currentDBFS, -100, "Queued standby audio must be discarded after resume")
        fixture.time.now = fixture.time.now.addingTimeInterval(0.25)
        fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -10))
        let live = await eventually { fixture.liveSound.frames.count > frames }
        XCTAssertTrue(live)
        XCTAssertNil(fixture.model.snapshot.current, "Resume starts a fresh confirmation window")
        fixture.model.stop()
        XCTAssertFalse(fixture.model.microphoneActive); XCTAssertEqual(fixture.audio.stops, 1)
    }
    @MainActor func testStandbyKeepsSendingHeartbeatsAndLocalStopReleasesMicrophone() async throws {
        let fixture = try Fixture(); await fixture.model.start()
        try await remoteCommand(false, fixture: fixture)
        let settled = await eventually { await fixture.backend.beats.last?.microphoneActive == true && fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(settled)
        await fixture.backend.setStatus(ParentStatus(paired: true, configuration: MonitoringConfiguration()))
        let count = await fixture.backend.beats.count
        fixture.time.now = fixture.time.now.addingTimeInterval(16)
        await fixture.model.tick()
        let periodic = await eventually { await fixture.backend.beats.count > count }
        XCTAssertTrue(periodic)
        let beats = await fixture.backend.beats
        let beat = try XCTUnwrap(beats.last)
        XCTAssertFalse(beat.monitoring); XCTAssertEqual(beat.microphoneActive, true)
        fixture.model.stop()
        XCTAssertFalse(fixture.model.standby); XCTAssertFalse(fixture.model.microphoneActive)
        let off = await eventually { await fixture.backend.beats.last?.microphoneActive == false }
        XCTAssertTrue(off)
    }
    @MainActor func testStandbyRecoveryNeverEnablesDetectionAndCalibrationCannotTakeCapture() async throws {
        let fixture = try Fixture(); await fixture.model.start()
        try await remoteCommand(false, fixture: fixture)
        await fixture.model.beginCalibration()
        XCTAssertEqual(fixture.model.calibrationPhase, "idle")
        XCTAssertEqual(fixture.audio.starts, 1)
        fixture.audio.onStatus?(.recovering("Audio interrupted"))
        XCTAssertFalse(fixture.model.microphoneActive); XCTAssertTrue(fixture.model.recoveringAudio)
        fixture.audio.onStatus?(.active)
        XCTAssertTrue(fixture.model.standby); XCTAssertFalse(fixture.model.monitoring)
        fixture.audio.onStatus?(.failed("Microphone unavailable"))
        XCTAssertFalse(fixture.model.standby); XCTAssertFalse(fixture.model.microphoneActive)
        XCTAssertTrue(fixture.model.needsRestart)
        fixture.model.stop()
    }
    @MainActor func testPausingAnOffListenerDoesNotStartItsMicrophone() async throws {
        let fixture = try Fixture()
        try await remoteCommand(false, fixture: fixture)
        XCTAssertFalse(fixture.model.microphoneActive); XCTAssertFalse(fixture.model.standby)
        XCTAssertEqual(fixture.audio.starts, 0)
    }
    @MainActor func testParentRemoteStartRequiresRecentStandbyAndConnectivity() throws {
        @MainActor func ready(age: TimeInterval? = 0, microphone: Bool? = true,
                              monitoring: Bool = false, network: Bool = true, paired: Bool = true) throws -> Bool {
            let fixture = try Fixture()
            fixture.model.selectRole(.parent); fixture.model.paired = paired
            fixture.connectivity.available = network
            fixture.model.parentStatus = ParentStatus(paired: paired,
                lastHeartbeat: age.map { fixture.time.now.addingTimeInterval(-$0) },
                monitoring: monitoring, configuration: MonitoringConfiguration(), microphoneActive: microphone)
            return fixture.model.canStartMonitoringRemotely
        }
        XCTAssertTrue(try ready())
        XCTAssertFalse(try ready(microphone: false))
        XCTAssertFalse(try ready(microphone: nil))
        for age in [31.0, 180, -6] { XCTAssertFalse(try ready(age: age)) }
        XCTAssertFalse(try ready(age: nil))
        XCTAssertFalse(try ready(network: false))
        XCTAssertFalse(try ready(monitoring: true))
        XCTAssertFalse(try ready(paired: false))
    }

    @MainActor func testParentDistinguishesStandbyOffAndStaleListener() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        var status = ParentStatus(paired: true, lastHeartbeat: fixture.time.now,
            serverTime: fixture.time.now, monitoring: false, configuration: MonitoringConfiguration(), microphoneActive: true)
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Standby")
        XCTAssertEqual(fixture.model.nightstandDevices.first?.status, "Standby")
        status.microphoneActive = false
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Stopped")
        fixture.time.now = fixture.time.now.addingTimeInterval(180); fixture.model.now = fixture.time.now
        status.microphoneActive = true; status.serverTime = fixture.time.now
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Connection lost")
    }
    @MainActor func testRemoteStartActivatesMicrophoneAndReportsSuccess() async throws {
        let fixture = try Fixture()
        let command = MonitoringCommand(id: UUID(), enabled: true, status: "pending", createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let started = await eventually { (await fixture.backend.monitoringResults).contains { $0.0 == command.id && $0.1 } }
        XCTAssertTrue(started); XCTAssertTrue(fixture.model.monitoring); XCTAssertEqual(fixture.audio.starts, 1)
        fixture.model.stop()
    }
    @MainActor func testRemoteStartFailureIsReportedAndNotReplayed() async throws {
        let fixture = try Fixture(); fixture.audio.startFailure = URLError(.cannotOpenFile)
        let command = MonitoringCommand(id: UUID(), enabled: true, status: "pending", createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let failed = await eventually { (await fixture.backend.monitoringResults).contains { $0.0 == command.id && !$0.1 } }
        XCTAssertTrue(failed); XCTAssertFalse(fixture.model.monitoring)
        fixture.time.now = fixture.time.now.addingTimeInterval(4); await fixture.model.tick()
        let retried = await eventually { await fixture.backend.monitoringResults.count == 2 }
        XCTAssertTrue(retried); XCTAssertEqual(fixture.audio.starts, 1)
    }
    @MainActor func testLocalStopInvalidatesSuspendedRemoteStartRead() async throws {
        let fixture = try Fixture(); let gate = RequestGate()
        let command = MonitoringCommand(id: UUID(), enabled: true, status: "pending", createdAt: fixture.time.now, expiresAt: fixture.time.now.addingTimeInterval(30))
        await fixture.backend.setStatus(ParentStatus(paired: true, serverTime: fixture.time.now, monitoringCommand: command, configuration: MonitoringConfiguration()))
        await fixture.backend.setStatusGate(gate); await fixture.model.tick()
        let reading = await eventually { await fixture.backend.statusCalls > 0 }; XCTAssertTrue(reading)
        fixture.model.stop(); await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(fixture.model.monitoring); XCTAssertEqual(fixture.audio.starts, 0)
    }

    @MainActor func testPhoneWatchTestIntervalChangesAndOfflineStop() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        fixture.model.startWatchTest(interval: 1)
        await fixture.model.tick()
        var requests = await fixture.backend.watchTestRequests
        XCTAssertEqual(requests, 0)
        fixture.time.now = fixture.time.now.addingTimeInterval(1)
        await fixture.model.tick()
        let first = await eventually { await fixture.backend.watchTestRequests == 1 }
        XCTAssertTrue(first)
        // Allow the completed request to install its next deadline.
        for _ in 0..<10 { await Task.yield() }
        fixture.model.setWatchTestInterval(10)
        fixture.time.now = fixture.time.now.addingTimeInterval(9)
        await fixture.model.tick()
        requests = await fixture.backend.watchTestRequests; XCTAssertEqual(requests, 1)
        fixture.time.now = fixture.time.now.addingTimeInterval(1)
        await fixture.model.tick()
        let second = await eventually { await fixture.backend.watchTestRequests == 2 }
        XCTAssertTrue(second)
        fixture.connectivity.available = false
        fixture.model.stopWatchTest()
        XCTAssertFalse(fixture.model.watchTestRunning)
        fixture.time.now = fixture.time.now.addingTimeInterval(60)
        await fixture.model.tick()
        requests = await fixture.backend.watchTestRequests; XCTAssertEqual(requests, 2)
    }
    /// iOS freezes requests when it suspends the app; the Parent must not start polls it cannot finish.
    @MainActor func testParentDoesNotPollInTheBackgroundAndResumesInTheForeground() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        let before = await fixture.backend.statusCalls
        fixture.model.setAppActive(false)
        fixture.time.now = fixture.time.now.addingTimeInterval(60)
        await fixture.model.tick()
        let background = await fixture.backend.statusCalls
        XCTAssertEqual(background, before)
        fixture.model.setAppActive(true)
        await fixture.model.tick()
        let foreground = await fixture.backend.statusCalls
        XCTAssertEqual(foreground, before + 1)
    }
    /// The app can be back in the background before `foreground()` reaches its refresh,
    /// or be launched in the background for a push: neither starts a poll or logs a foreground.
    @MainActor func testForegroundWorkThatFinishesInTheBackgroundDoesNotPoll() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        let before = await fixture.backend.statusCalls
        let foregrounds = fixture.model.log.lines.filter { $0.hasSuffix(" foreground") }.count
        fixture.model.setAppActive(false)
        await fixture.model.foreground()
        let background = await fixture.backend.statusCalls
        XCTAssertEqual(background, before)
        XCTAssertEqual(fixture.model.log.lines.filter { $0.hasSuffix(" foreground") }.count, foregrounds)
        fixture.model.setAppActive(true)
        await fixture.model.foreground()
        let foreground = await fixture.backend.statusCalls
        XCTAssertEqual(foreground, before + 1)
        XCTAssertEqual(fixture.model.log.lines.filter { $0.hasSuffix(" foreground") }.count, foregrounds + 1)
    }
    @MainActor func testPhoneWatchTestStopsOnBackgroundAndNeverAutomaticallyResumes() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        fixture.model.startWatchTest(interval: 5)
        fixture.model.setAppActive(false)
        XCTAssertFalse(fixture.model.watchTestRunning)
        fixture.time.now = fixture.time.now.addingTimeInterval(60)
        fixture.model.setAppActive(true)
        await fixture.model.tick()
        let requests = await fixture.backend.watchTestRequests
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(fixture.model.watchTestRunning)
    }
    @MainActor func testPhoneWatchTestNeverOverlapsOrContinuesAfterFailure() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        let gate = RequestGate(); await fixture.backend.setWatchTestGate(gate)
        fixture.model.startWatchTest(interval: 1)
        fixture.time.now = fixture.time.now.addingTimeInterval(1)
        await fixture.model.tick()
        let sending = await eventually { await fixture.backend.watchTestRequests == 1 }
        XCTAssertTrue(sending)
        fixture.time.now = fixture.time.now.addingTimeInterval(60)
        for _ in 0..<5 { await fixture.model.tick() }
        var requests = await fixture.backend.watchTestRequests; XCTAssertEqual(requests, 1)
        await fixture.backend.setTestRequestFailure(true)
        await gate.open()
        let stopped = await eventually { !fixture.model.watchTestRunning }
        XCTAssertTrue(stopped); XCTAssertNotNil(fixture.model.watchTestError)
        fixture.time.now = fixture.time.now.addingTimeInterval(60)
        await fixture.model.tick()
        requests = await fixture.backend.watchTestRequests; XCTAssertEqual(requests, 1)
    }
    @MainActor func testPhoneWatchTestStopIgnoresLateFailureAndDoesNotPersistRunningState() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        let gate = RequestGate(); await fixture.backend.setWatchTestGate(gate)
        fixture.model.startWatchTest(interval: 1)
        fixture.time.now = fixture.time.now.addingTimeInterval(1)
        await fixture.model.tick()
        let sending = await eventually { await fixture.backend.watchTestRequests == 1 }
        XCTAssertTrue(sending)
        fixture.model.stopWatchTest()
        await fixture.backend.setTestRequestFailure(true); await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(fixture.model.watchTestRunning); XCTAssertNil(fixture.model.watchTestError)
        let reloaded = AppModel(defaults: fixture.defaults, metadataStore: try MetadataStore(directory: fixture.directory),
                                audio: fixture.audio, notifications: fixture.notifications,
                                keychain: Credentials(listener: fixture.listener, parent: fixture.parent), automaticallyStart: false)
        XCTAssertFalse(reloaded.watchTestRunning)
    }
    @MainActor func testPhoneWatchTestStopsOnRoleChangeAndClampsInterval() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        fixture.model.startWatchTest(interval: 0)
        XCTAssertEqual(fixture.model.watchTestInterval, 1)
        fixture.model.setWatchTestInterval(99)
        XCTAssertEqual(fixture.model.watchTestInterval, 10)
        fixture.model.selectRole(.listener)
        XCTAssertFalse(fixture.model.watchTestRunning)
    }

    @MainActor func testWatchTestRequiresFreshWatchRegistration() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.backend.setStatus(ParentStatus(paired: true, watchPushRegistered: true, configuration: MonitoringConfiguration()))
        await fixture.model.refreshParent()
        XCTAssertTrue(fixture.model.canTestWatchAlert)
        // A token can be removed after the guide was opened. Recheck before sending.
        await fixture.backend.setStatus(ParentStatus(paired: true, watchPushRegistered: false, configuration: MonitoringConfiguration()))
        let sent = await fixture.model.requestParentTest(requiresWatch: true)
        XCTAssertFalse(sent)
        let requested = await fixture.backend.requestedTest
        XCTAssertFalse(requested)
        XCTAssertFalse(fixture.model.canTestWatchAlert)
        XCTAssertFalse(fixture.model.sendingTestPush)
    }

    @MainActor func testWatchTestUsesRealBackendRequest() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.backend.setStatus(ParentStatus(paired: true, watchPushRegistered: true, configuration: MonitoringConfiguration()))
        await fixture.model.refreshParent()
        let sent = await fixture.model.requestParentTest(requiresWatch: true)
        XCTAssertTrue(sent)
        let requested = await fixture.backend.requestedTest
        XCTAssertTrue(requested)
        XCTAssertTrue(fixture.model.testPushStatus?.contains("Test requested") == true)
        XCTAssertFalse(fixture.model.sendingTestPush)
        XCTAssertNil(fixture.model.recentConfirmedTest)
    }

    @MainActor func testFailedWatchTestDoesNotEnableConfirmation() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        await fixture.backend.setStatus(ParentStatus(paired: true, watchPushRegistered: true, configuration: MonitoringConfiguration()))
        await fixture.model.refreshParent()
        await fixture.backend.setTestRequestFailure(true)
        let sent = await fixture.model.requestParentTest(requiresWatch: true)
        XCTAssertFalse(sent)
        XCTAssertTrue(fixture.model.testPushStatus?.contains("could not be sent") == true)
        XCTAssertFalse(fixture.model.sendingTestPush)
    }

    @MainActor private func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor func testMetadataDecodeFailureAndBlockedStartRetainTheException() async throws {
        let fixture = try Fixture(snapshotData: Data("{}".utf8))
        let model = fixture.model
        XCTAssertTrue(model.log.export.contains("metadata_load_failed operation=metadata_decode"))
        XCTAssertTrue(model.log.export.contains("error=decoding_key_not_found path=$.configuration"))
        model.error = nil
        await model.start()
        XCTAssertFalse(model.monitoring)
        XCTAssertTrue(model.log.export.contains("monitoring_start_blocked_storage operation=metadata_decode"))
        XCTAssertTrue(model.error?.contains("Local monitoring data is unavailable") == true)
        // Preserve the original file for investigation; logging must not reset local history or alerts.
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("listener-metadata.json")), Data("{}".utf8))
    }
    @MainActor func testMetadataWriteFailureIsRetainedForLaterStartAttempts() async throws {
        let fixture = try Fixture()
        let file = fixture.directory.appendingPathComponent("listener-metadata.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        fixture.model.saveSettings(MonitoringConfiguration())
        XCTAssertTrue(fixture.model.log.export.contains("metadata_write_failed operation=metadata_write"))
        await fixture.model.start()
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.log.export.contains("monitoring_start_blocked_storage operation=metadata_write"))
    }
    @MainActor func testMissingSafetyAcceptanceHasItsOwnStartDiagnostic() async throws {
        let fixture = try Fixture()
        fixture.model.safetyAccepted = false
        await fixture.model.start()
        XCTAssertTrue(fixture.model.log.export.contains("monitoring_start_blocked_safety"))
        XCTAssertFalse(fixture.model.log.export.contains("monitoring_start_blocked_storage"))
    }
    @MainActor func testCalibrationCannotCreateLiveEpisodesOrAlerts() async throws {
        let fixture = try Fixture()
        await fixture.model.beginCalibration()
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertEqual(fixture.model.calibrationPhase, "background")
        for i in 0..<24 { fixture.audio.emit(AudioLevelSample(timestamp: Date().addingTimeInterval(Double(i) / 4), dbFS: -55)) }
        let measured = await eventually { fixture.model.calibration.background.count == 24 }
        XCTAssertTrue(measured)
        fixture.model.finishCalibrationBackground(); fixture.model.beginCalibrationSample()
        for i in 0..<20 { fixture.audio.emit(AudioLevelSample(timestamp: Date().addingTimeInterval(Double(i) / 4 + 10), dbFS: -10)) }
        let sampled = await eventually { fixture.model.calibration.sample.count == 20 }
        XCTAssertTrue(sampled); fixture.model.finishCalibrationSample()
        XCTAssertNil(fixture.model.snapshot.current); XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertFalse(fixture.model.monitoring); XCTAssertEqual(fixture.model.calibrationPhase, "complete")
        XCTAssertEqual(fixture.model.calibration.recommendedThreshold, -15)
        var config = fixture.model.configuration
        config.absoluteThreshold = try XCTUnwrap(fixture.model.calibration.recommendedThreshold)
        fixture.model.saveSettings(config)
        XCTAssertEqual(fixture.model.threshold, -15)
        XCTAssertEqual(fixture.model.snapshot.configuration.absoluteThreshold, -15)
        XCTAssertNil(fixture.model.snapshot.current); XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
    }
    @MainActor func testUnpairClearsLocalOutboxAndStopsMonitoring() async throws {
        let fixture = try Fixture(pending: true)
        await fixture.model.start(); await fixture.model.removePairing(deleteDevice: false)
        let removed = await fixture.backend.removedPair
        XCTAssertTrue(removed); XCTAssertFalse(fixture.model.paired); XCTAssertFalse(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty); XCTAssertTrue(fixture.model.snapshot.history.isEmpty)
        XCTAssertEqual(fixture.model.role, .listener)
    }
    @MainActor func testDeletionReturnsToRoleSelection() async throws {
        let fixture = try Fixture(pending: true)
        await fixture.model.removePairing(deleteDevice: true)
        let deleted = await fixture.backend.deletedDevice
        XCTAssertTrue(deleted); XCTAssertNil(fixture.model.role); XCTAssertFalse(fixture.model.paired)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
    }
    @MainActor func testRevokedPairingStopsListenerAndClearsQueuedHistory() async throws {
        let fixture = try Fixture(pending: true)
        await fixture.model.start()
        await fixture.backend.setStatus(ParentStatus(paired: false, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let revoked = await eventually { !fixture.model.paired }
        XCTAssertTrue(revoked)
        XCTAssertFalse(fixture.model.monitoring); XCTAssertFalse(fixture.model.paired)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        var config = fixture.model.configuration; config.alertDuration = 30
        fixture.model.saveSettings(config)
        fixture.time.now = fixture.time.now.addingTimeInterval(20)
        await fixture.model.tick()
        XCTAssertEqual(fixture.model.configuration.alertDuration, 30)
    }
    @MainActor func testSuspendedPairingRefreshDoesNotDelayQueuedAlert() async throws {
        let fixture = try Fixture(pending: true)
        let gate = RequestGate(); await fixture.backend.setStatusGate(gate)
        await fixture.model.tick()
        let sent = await fixture.backend.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        await gate.open()
    }
    @MainActor func testParentDistinguishesConnectionStatesAndSettingsAcknowledgement() async throws {
        let fixture = try Fixture(); fixture.model.selectRole(.parent)
        var status = ParentStatus(paired: true, lastHeartbeat: fixture.time.now, monitoring: false, configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Stopped")
        status.monitoring = true; status.listenerConfiguration = MonitoringConfiguration()
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Monitoring"); XCTAssertEqual(fixture.model.settingsSyncStatus, "Applied on Listener")
        fixture.time.now = fixture.time.now.addingTimeInterval(151); fixture.model.now = fixture.time.now
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Connection lost"); XCTAssertFalse(fixture.model.parentOnline)
        XCTAssertEqual(fixture.model.settingsSyncStatus, "Waiting for Listener")
    }

    @MainActor func testLocalWarningDefaultsOffWhileServerAlertsRemainEnabled() async throws {
        let fixture = try Fixture()
        await fixture.backend.setStatus(ParentStatus(paired: true, connectionAlertsEnabled: true,
            monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        XCTAssertFalse(fixture.model.localConnectionWarningEnabled)
        XCTAssertEqual(fixture.model.parentStatus?.connectionAlertsEnabled, true)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
        XCTAssertFalse(fixture.notifications.connectionDeadlines.contains { $0 != nil })
        let handler = try XCTUnwrap(fixture.model.watch.onCommand)
        let snapshot = await handler(WatchCommand(kind: .refresh))
        XCTAssertEqual(snapshot.localConnectionWarningEnabled, false)
        XCTAssertNil(snapshot.localConnectionDeadline)
        await fixture.model.setConnectionAlerts(false)
        await fixture.model.setConnectionAlerts(true)
        XCTAssertFalse(fixture.model.localConnectionWarningEnabled)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
    }

    @MainActor func testUpgradeClearsLegacyLocalWarningWithoutOptIn() async throws {
        let deadline = Date().addingTimeInterval(180)
        let fixture = try Fixture(configureDefaults: { defaults, parent in
            defaults.set("parent", forKey: "role")
            defaults.set(true, forKey: "paired|https://monitor.test|parent")
            defaults.set(deadline, forKey: "parentConnectionWarningDeadline")
            defaults.set(deadline, forKey: "parentConnectionWarningScheduledDeadline")
            defaults.set("https://monitor.test|\(parent.deviceId.uuidString)", forKey: "parentConnectionWarningScope")
        })
        XCTAssertFalse(fixture.model.localConnectionWarningEnabled)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
        let cancelled = await eventually { !fixture.notifications.connectionDeadlines.isEmpty }
        XCTAssertTrue(cancelled)
        XCTAssertNil(fixture.notifications.scheduledConnectionDeadline)
        XCTAssertNil(fixture.defaults.object(forKey: "parentConnectionWarningDeadline"))
        XCTAssertNil(fixture.defaults.object(forKey: "parentConnectionWarningScheduledDeadline"))
        let handler = try XCTUnwrap(fixture.model.watch.onCommand)
        let snapshot = await handler(WatchCommand(kind: .refresh))
        XCTAssertNil(snapshot.localConnectionDeadline)
    }

    @MainActor func testLocalOptInRequiresSuccessfulCheckAndOptOutCancelsOfflineOnPhoneAndWatch() async throws {
        let fixture = try Fixture()
        await fixture.backend.setStatus(ParentStatus(paired: true, connectionAlertsEnabled: true,
            monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        await fixture.backend.setStatusFailure(true)
        fixture.model.setLocalConnectionWarning(true)
        await fixture.model.refreshParent()
        XCTAssertTrue(fixture.defaults.bool(forKey: "localConnectionWarningEnabled"))
        XCTAssertNil(fixture.model.parentConnectionDeadline, "Cached healthy status cannot arm the warning")
        await fixture.backend.setStatusFailure(false); await fixture.model.refreshParent()
        let armed = await eventually { fixture.notifications.scheduledConnectionDeadline != nil }
        XCTAssertTrue(armed)
        let handler = try XCTUnwrap(fixture.model.watch.onCommand)
        let enabled = await handler(WatchCommand(kind: .refresh))
        XCTAssertNotNil(enabled.localConnectionDeadline)
        fixture.connectivity.available = false
        await fixture.backend.setStatusFailure(true)
        fixture.model.setLocalConnectionWarning(false)
        let cancelled = await eventually { fixture.notifications.scheduledConnectionDeadline == nil }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "localConnectionWarningEnabled"))
        let disabled = await handler(WatchCommand(kind: .refresh))
        XCTAssertEqual(disabled.localConnectionWarningEnabled, false)
        XCTAssertNil(disabled.localConnectionDeadline)
        let serverChanges = await fixture.backend.connectionAlertPreferences
        XCTAssertTrue(serverChanges.isEmpty, "Local preferences must not change server alerts")
    }

    @MainActor func testLocalOptOutWinsOverPendingSchedulingAndStatusResponse() async throws {
        let fixture = try Fixture(localWarnings: true)
        XCTAssertTrue(fixture.notifications.connectionDeadlines.isEmpty, "A fresh Listener has no OS warning to cancel")
        let scheduleGate = RequestGate(); fixture.notifications.connectionWarningGate = scheduleGate
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let scheduling = await eventually { fixture.notifications.connectionDeadlines.contains { $0 != nil } }
        XCTAssertTrue(scheduling)
        let statusGate = RequestGate(); await fixture.backend.setStatusGate(statusGate)
        let calls = await fixture.backend.statusCalls
        let refresh = Task { await fixture.model.refreshParent() }
        let waiting = await eventually { await fixture.backend.statusCalls > calls }
        XCTAssertTrue(waiting)
        fixture.model.setLocalConnectionWarning(false)
        await statusGate.open(); await refresh.value
        await scheduleGate.open()
        let cancelled = await eventually {
            fixture.notifications.connectionDeadlines.last == .some(nil) && fixture.notifications.scheduledConnectionDeadline == nil
        }
        XCTAssertTrue(cancelled)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
    }

    @MainActor func testKeepScreenAwakeDefaultsOffAndPersistsOnlyForParentMode() async throws {
        let fixture = try Fixture()
        XCTAssertFalse(fixture.model.keepScreenAwake)
        XCTAssertFalse(fixture.model.shouldKeepScreenAwake)
        fixture.model.setKeepScreenAwake(true)
        XCTAssertTrue(fixture.defaults.bool(forKey: "keepScreenAwake"))
        XCTAssertFalse(fixture.model.shouldKeepScreenAwake, "Listener retains normal screen locking")
        fixture.model.selectRole(.parent)
        XCTAssertTrue(fixture.model.shouldKeepScreenAwake)
        let restored = AppModel(defaults: fixture.defaults, metadataStore: try MetadataStore(directory: fixture.directory),
            log: DiagnosticLog(directory: fixture.directory), audio: Audio(), connectivity: fixture.connectivity,
            notifications: Notifications(), keychain: Credentials(listener: fixture.listener, parent: fixture.parent),
            makeClient: { _, _ in fixture.backend }, automaticallyStart: false)
        XCTAssertTrue(restored.keepScreenAwake)
        XCTAssertTrue(restored.shouldKeepScreenAwake)
        restored.setKeepScreenAwake(false)
        XCTAssertFalse(restored.shouldKeepScreenAwake)
        XCTAssertFalse(fixture.defaults.bool(forKey: "keepScreenAwake"))
        fixture.model.selectRole(.listener)
        XCTAssertFalse(fixture.model.shouldKeepScreenAwake)
    }

    @MainActor func testLocalConnectionWarningSurvivesBothDevicesLosingInternetAndOnlySuccessRenewsIt() async throws {
        let fixture = try Fixture(localWarnings: true)
        let status = ParentStatus(paired: true, connectionAlertsEnabled: true, lastHeartbeat: fixture.time.now,
                                  monitoring: true, configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); fixture.model.selectRole(.parent)
        await fixture.model.refreshParent()
        let deadline = fixture.time.now.addingTimeInterval(180)
        let armed = await eventually { fixture.notifications.scheduledConnectionDeadline == deadline }
        XCTAssertTrue(armed)
        fixture.connectivity.available = false
        fixture.time.now = fixture.time.now.addingTimeInterval(181)
        await fixture.model.tick()
        XCTAssertEqual(fixture.notifications.scheduledConnectionDeadline, deadline)
        fixture.connectivity.available = true
        await fixture.backend.setStatusFailure(true); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.parentConnectionDeadline, deadline)
        XCTAssertEqual(fixture.notifications.scheduledConnectionDeadline, deadline)
        await fixture.backend.setStatusFailure(false); await fixture.model.refreshParent()
        let renewed = fixture.time.now.addingTimeInterval(180)
        let recovered = await eventually { fixture.notifications.scheduledConnectionDeadline == renewed }
        XCTAssertTrue(recovered)
    }

    @MainActor func testSuspendedStatusRequestDoesNotDelayLocalConnectionWarning() async throws {
        let fixture = try Fixture(localWarnings: true)
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let deadline = try XCTUnwrap(fixture.model.parentConnectionDeadline)
        let gate = RequestGate(); await fixture.backend.setStatusGate(gate)
        let calls = await fixture.backend.statusCalls
        let refresh = Task { await fixture.model.refreshParent() }
        let waiting = await eventually { await fixture.backend.statusCalls > calls }
        XCTAssertTrue(waiting)
        fixture.time.now = deadline.addingTimeInterval(1)
        XCTAssertEqual(fixture.model.parentConnectionDeadline, deadline)
        await fixture.backend.setStatusFailure(true); await gate.open(); await refresh.value
        XCTAssertEqual(fixture.model.parentConnectionDeadline, deadline)
    }

    @MainActor func testLocalWarningIsIndependentOfServerAlertsAndCrySnoozeAndCancelsForStopAndUnpair() async throws {
        let fixture = try Fixture(localWarnings: true)
        var status = ParentStatus(paired: true, connectionAlertsEnabled: true,
                                  alertsMutedUntil: fixture.time.now.addingTimeInterval(900),
                                  monitoring: true, configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status); fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.parentConnectionDeadline)
        status.monitoring = false
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        let stopped = await eventually { fixture.notifications.scheduledConnectionDeadline == nil }
        XCTAssertTrue(stopped); XCTAssertNil(fixture.model.parentConnectionDeadline)
        status.monitoring = true; status.connectionAlertsEnabled = false
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.parentConnectionDeadline)
        await fixture.model.setConnectionAlerts(true)
        await fixture.model.setConnectionAlerts(false)
        XCTAssertNotNil(fixture.model.parentConnectionDeadline)
        fixture.model.setLocalConnectionWarning(false)
        let disabled = await eventually { fixture.notifications.scheduledConnectionDeadline == nil }
        XCTAssertTrue(disabled); XCTAssertNil(fixture.model.parentConnectionDeadline)
        fixture.model.setLocalConnectionWarning(true)
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertNotNil(fixture.model.parentConnectionDeadline)
        await fixture.model.removePairing(deleteDevice: false)
        let unpaired = await eventually { fixture.notifications.scheduledConnectionDeadline == nil }
        XCTAssertTrue(unpaired); XCTAssertNil(fixture.model.parentConnectionDeadline)
    }

    @MainActor func testLateLocalWarningScheduleCannotUndoRoleChangeCancellation() async throws {
        let fixture = try Fixture(localWarnings: true)
        XCTAssertTrue(fixture.notifications.connectionDeadlines.isEmpty, "A fresh Listener has no OS warning to cancel")
        let gate = RequestGate(); fixture.notifications.connectionWarningGate = gate
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let requested = await eventually { fixture.notifications.connectionDeadlines.contains { $0 != nil } }
        XCTAssertTrue(requested)
        fixture.model.selectRole(.listener)
        await gate.open()
        let cancelled = await eventually { fixture.notifications.connectionDeadlines.count >= 2 && fixture.notifications.scheduledConnectionDeadline == nil }
        XCTAssertTrue(cancelled)
        XCTAssertNil(fixture.model.parentConnectionDeadline)
    }

    @MainActor func testLocalWarningSchedulingFailureIsVisibleAndCanRecover() async throws {
        let fixture = try Fixture(localWarnings: true); fixture.notifications.connectionWarningFails = true
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let failed = await eventually { fixture.model.parentConnectionWarningError != nil }
        XCTAssertTrue(failed)
        fixture.notifications.connectionWarningFails = false
        fixture.time.now = fixture.time.now.addingTimeInterval(15)
        await fixture.model.refreshParent()
        let recovered = await eventually { fixture.model.parentConnectionWarningError == nil && fixture.notifications.scheduledConnectionDeadline != nil }
        XCTAssertTrue(recovered)
    }

    @MainActor func testRelaunchRetainsWarningDeadlineWithoutRenewingIt() async throws {
        let fixture = try Fixture(localWarnings: true)
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let deadline = try XCTUnwrap(fixture.model.parentConnectionDeadline)
        let scheduled = await eventually { fixture.notifications.scheduledConnectionDeadline == deadline }
        XCTAssertTrue(scheduled)
        fixture.time.now = deadline.addingTimeInterval(1)
        let restoredNotifications = Notifications()
        let restored = AppModel(defaults: fixture.defaults, metadataStore: try MetadataStore(directory: fixture.directory),
            log: DiagnosticLog(directory: fixture.directory), audio: Audio(), connectivity: fixture.connectivity,
            notifications: restoredNotifications, keychain: Credentials(listener: fixture.listener, parent: fixture.parent),
            makeClient: { _, _ in fixture.backend }, currentTime: { fixture.time.now }, automaticallyStart: false)
        XCTAssertEqual(restored.parentConnectionDeadline, deadline)
        await fixture.backend.setStatusFailure(true); await restored.refreshParent()
        XCTAssertEqual(restored.parentConnectionDeadline, deadline)
        XCTAssertTrue(restoredNotifications.connectionDeadlines.isEmpty, "Do not replay an already delivered deadline on relaunch")
    }

    @MainActor func testWatchReceivesOriginalDeadlineWhenParentServerChecksFail() async throws {
        let fixture = try Fixture(localWarnings: true)
        await fixture.backend.setStatus(ParentStatus(paired: true, monitoring: true, configuration: MonitoringConfiguration()))
        fixture.model.selectRole(.parent); await fixture.model.refreshParent()
        let deadline = try XCTUnwrap(fixture.model.parentConnectionDeadline)
        let handler = try XCTUnwrap(fixture.model.watch.onCommand)
        fixture.time.now = fixture.time.now.addingTimeInterval(120)
        await fixture.backend.setStatusFailure(true)
        let failed = await handler(WatchCommand(kind: .refresh))
        XCTAssertFalse(failed.statusAvailable)
        XCTAssertEqual(failed.localConnectionDeadline, deadline, "A new Bluetooth snapshot must not renew an unverified server check")
        fixture.model.selectRole(.listener)
        let changed = await handler(WatchCommand(kind: .refresh))
        XCTAssertNil(changed.localConnectionDeadline)
    }

    @MainActor func testLocalWarningNotificationIsTimeSensitiveOnPhoneAndWatchWithoutCryActions() throws {
        let now = Date()
        for watch in [false, true] {
            let request = ConnectionWarningNotification.request(deadline: now.addingTimeInterval(180), now: now, watch: watch)
            XCTAssertEqual(request.identifier, ConnectionWarningNotification.identifier)
            XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 180)
            XCTAssertFalse(try XCTUnwrap(request.trigger).repeats)
            XCTAssertNotNil(request.content.sound)
            XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
            XCTAssertEqual(request.content.categoryIdentifier, "")
            XCTAssertNil(request.content.userInfo["eventId"])
            XCTAssertEqual(request.content.userInfo["localConnectionWarning"] as? Bool, true)
        }
        let expired = ConnectionWarningNotification.request(deadline: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual((expired.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
    }

    func testParentPollTimingUsesServerClockAndBoundsLateRetries() {
        let server = Date(timeIntervalSince1970: 1_000)
        var status = ParentStatus(paired: true, lastHeartbeat: server, serverTime: server.addingTimeInterval(11),
                                  nextHeartbeatExpectedAt: server.addingTimeInterval(15), monitoring: true,
                                  configuration: MonitoringConfiguration())
        XCTAssertEqual(status.refreshDelay(), 4)
        status.serverTime = server.addingTimeInterval(15)
        XCTAssertEqual(status.refreshDelay(), 1)
        status.serverTime = server.addingTimeInterval(29)
        XCTAssertEqual(status.refreshDelay(), 1)
        status.serverTime = server.addingTimeInterval(31)
        XCTAssertEqual(status.refreshDelay(), 15)
        status.serverTime = server.addingTimeInterval(-300)
        XCTAssertEqual(status.refreshDelay(), 15, "Never sleep longer than the normal interval")
        status.serverTime = server; status.monitoring = false
        XCTAssertEqual(status.refreshDelay(), 15)
        status.monitoring = true; status.nextHeartbeatExpectedAt = nil
        XCTAssertEqual(status.refreshDelay(), 15, "Older servers retain the original cadence")
        status.nextHeartbeatExpectedAt = server.addingTimeInterval(15); status.serverTime = nil
        XCTAssertEqual(status.refreshDelay(), 15)
    }

    @MainActor func testParentWaitsUntilExpectedHeartbeatThenPollsEachSecond() async throws {
        let fixture = try Fixture(), start = Date(timeIntervalSince1970: 1_000)
        fixture.time.now = start
        var status = ParentStatus(paired: true, lastHeartbeat: start, serverTime: start,
                                  nextHeartbeatExpectedAt: start.addingTimeInterval(15), monitoring: true,
                                  configuration: MonitoringConfiguration())
        await fixture.backend.setStatus(status)
        fixture.model.selectRole(.parent)
        let ready = await eventually { fixture.model.parentStatus != nil }
        XCTAssertTrue(ready)
        let initialCalls = await fixture.backend.statusCalls
        fixture.time.now = start.addingTimeInterval(14)
        await fixture.model.tick()
        let beforeDue = await fixture.backend.statusCalls
        XCTAssertEqual(beforeDue, initialCalls)
        fixture.time.now = start.addingTimeInterval(15); status.serverTime = fixture.time.now
        await fixture.backend.setStatus(status); await fixture.model.tick()
        let due = await fixture.backend.statusCalls
        XCTAssertEqual(due, initialCalls + 1)
        // At the next one-second check a new heartbeat arrives. Resume waiting.
        fixture.time.now = start.addingTimeInterval(16)
        status.lastHeartbeat = start.addingTimeInterval(15); status.serverTime = fixture.time.now
        status.nextHeartbeatExpectedAt = start.addingTimeInterval(30)
        await fixture.backend.setStatus(status); await fixture.model.tick()
        let newBeat = await fixture.backend.statusCalls
        XCTAssertEqual(newBeat, due + 1)
        fixture.time.now = start.addingTimeInterval(29); await fixture.model.tick()
        let waiting = await fixture.backend.statusCalls
        XCTAssertEqual(waiting, newBeat)
        // Explicit refreshes still bypass the predicted due time.
        await fixture.model.refreshParent()
        let explicit = await fixture.backend.statusCalls
        XCTAssertEqual(explicit, waiting + 1)
    }

    @MainActor func testParentStatusFailureBacksOffAndConcurrentRefreshDoesNotOverlap() async throws {
        let fixture = try Fixture()
        fixture.model.selectRole(.parent)
        let ready = await eventually { fixture.model.parentStatus != nil }
        XCTAssertTrue(ready)
        let gate = RequestGate(); await fixture.backend.setStatusGate(gate)
        let initialCalls = await fixture.backend.statusCalls
        let refresh = Task { await fixture.model.refreshParent() }
        let started = await eventually { await fixture.backend.statusCalls > initialCalls }
        XCTAssertTrue(started)
        let overlappingRefresh = Task { await fixture.model.refreshParent() }
        await Task.yield()
        let overlapping = await fixture.backend.statusCalls
        XCTAssertEqual(overlapping, initialCalls + 1)
        await fixture.backend.setStatusFailure(true); await gate.open(); await refresh.value; await overlappingRefresh.value
        XCTAssertNil(fixture.model.parentStatus)
        let failedCalls = await fixture.backend.statusCalls
        fixture.time.now = fixture.time.now.addingTimeInterval(1); await fixture.model.tick()
        let immediate = await fixture.backend.statusCalls
        XCTAssertEqual(immediate, failedCalls)
        fixture.time.now = fixture.time.now.addingTimeInterval(14); await fixture.model.tick()
        let retried = await fixture.backend.statusCalls
        XCTAssertEqual(retried, failedCalls + 1)
    }

    @MainActor func testStartupRouteRecoveryDoesNotPresentAnError() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        fixture.audio.recoveryGate = gate
        let start = Task { await fixture.model.start() }
        let recovering = await eventually { fixture.model.recoveringAudio }
        XCTAssertTrue(recovering)
        XCTAssertTrue(fixture.model.starting)
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertFalse(fixture.model.snapshot.wasMonitoring)
        XCTAssertNil(fixture.model.error)
        XCTAssertFalse(fixture.model.needsRestart)
        await fixture.model.foreground()
        XCTAssertNil(fixture.model.error)
        await gate.open()
        await start.value
        XCTAssertTrue(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.snapshot.wasMonitoring)
        XCTAssertFalse(fixture.model.recoveringAudio)
        XCTAssertNil(fixture.model.error)
    }
    @MainActor func testInterruptionRecoveryStaysInlineAndCanBeStopped() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        fixture.audio.onStatus?(.recovering("Audio interrupted. Waiting for microphone…"))
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertTrue(fixture.model.recoveringAudio)
        XCTAssertFalse(fixture.model.snapshot.wasMonitoring)
        XCTAssertNil(fixture.model.error)
        await fixture.model.foreground()
        await fixture.model.start()
        XCTAssertNil(fixture.model.error)
        XCTAssertEqual(fixture.audio.starts, 1)
        fixture.model.stop()
        XCTAssertFalse(fixture.model.recoveringAudio)
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertEqual(fixture.model.audioStatus, "Stopped")
    }
    @MainActor func testFailedRecoveryStillRequiresAttention() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        fixture.audio.onStatus?(.recovering("Recovering microphone…"))
        let message = "Microphone unavailable. Open the app to restart monitoring."
        fixture.audio.onStatus?(.failed(message))
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertFalse(fixture.model.recoveringAudio)
        XCTAssertFalse(fixture.model.snapshot.wasMonitoring)
        XCTAssertTrue(fixture.model.needsRestart)
        XCTAssertEqual(fixture.model.error, message)
        // An explicit retry still recovers from the failure.
        await fixture.model.start()
        XCTAssertTrue(fixture.model.monitoring)
        XCTAssertFalse(fixture.model.needsRestart)
        XCTAssertNil(fixture.model.error)
    }
    @MainActor func testDeniedPermissionAndStartupFailureStillPresentErrors() async throws {
        let fixture = try Fixture()
        fixture.audio.permissionGranted = false
        await fixture.model.start()
        XCTAssertTrue(fixture.model.error?.contains("Microphone permission denied") == true)
        XCTAssertFalse(fixture.model.monitoring)
        XCTAssertEqual(fixture.audio.starts, 0)
        fixture.audio.permissionGranted = true
        fixture.audio.startFailure = URLError(.unknown)
        await fixture.model.start()
        XCTAssertEqual(fixture.model.error, URLError(.unknown).localizedDescription)
        XCTAssertFalse(fixture.model.monitoring)
    }

    @MainActor func testWatchdogStopsCaptureWhileNetworkRequestIsSuspended() async throws {
        let fixture = try Fixture(automaticallyStart: true)
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        XCTAssertTrue(fixture.model.monitoring)
        let started = await eventually { await fixture.backend.beats.count == 1 }
        XCTAssertTrue(started)
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        let stopped = await eventually { !fixture.model.monitoring }
        // The request remains blocked until after these watchdog assertions.
        XCTAssertTrue(stopped)
        XCTAssertTrue(fixture.model.needsRestart)
        XCTAssertTrue(fixture.model.error?.contains("samples stopped arriving") == true)
        XCTAssertEqual(fixture.model.now, fixture.time.now)
        await gate.open()
    }
    @MainActor func testMicrophoneStallDoesNotReportAStopThatWouldRetireAlerts() async throws {
        let fixture = try Fixture(automaticallyStart: true)
        await fixture.model.start()
        let reported = await eventually { await fixture.backend.monitoringRequests.count == 1 }
        XCTAssertTrue(reported)
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        let stopped = await eventually { !fixture.model.monitoring }
        XCTAssertTrue(stopped)
        XCTAssertTrue(fixture.model.needsRestart)
        try await Task.sleep(for: .seconds(2))
        let requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.map(\.0), [true], "Only the person's Start is reported; the stall is not a Stop")
    }
    @MainActor func testUnexpectedMicrophoneFailureSendsOnePersistentStopAlertUntilRestart() async throws {
        let fixture = try Fixture()
        await fixture.model.start(); await fixture.model.tick()
        fixture.audio.onStatus?(.recovering("Recovering microphone…"))
        fixture.audio.onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring."))
        let sent = await eventually { await fixture.backend.sent.contains { $0.isMonitoringFailure } }
        XCTAssertTrue(sent)
        let uploads = await fixture.backend.sent
        let alert = try XCTUnwrap(uploads.first { $0.isMonitoringFailure })
        XCTAssertEqual(alert.type, "monitoring_failed"); XCTAssertFalse(alert.isRepeat); XCTAssertNil(alert.isTest)
        XCTAssertEqual(alert.cryStartedAt, alert.createdAt); XCTAssertEqual(alert.durationSeconds, 0)
        fixture.audio.onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring."))
        await fixture.model.tick()
        var failures = await fixture.backend.sent.filter(\.isMonitoringFailure)
        XCTAssertEqual(failures.count, 1, "One episode per unexpected stop")
        XCTAssertTrue(fixture.model.log.export.contains("monitoring_failure_alert_queued"))
        // Restarting ends the episode (the server resolves it from the monitoring heartbeat).
        await fixture.model.start()
        XCTAssertTrue(fixture.model.monitoring)
        fixture.audio.onStatus?(.failed("Microphone unavailable. Open the app to restart monitoring."))
        let again = await eventually { await fixture.backend.sent.filter(\.isMonitoringFailure).count == 2 }
        XCTAssertTrue(again, "A new stop after a restart is a new episode")
        failures = await fixture.backend.sent.filter(\.isMonitoringFailure)
        XCTAssertNotEqual(failures[0].episodeId, failures[1].episodeId)
        fixture.model.stop()
    }
    @MainActor func testPersonStopPauseAndStandbyFailureSendNoStopAlert() async throws {
        let fixture = try Fixture()
        await fixture.model.start(); await fixture.model.tick()
        fixture.model.stop(); await fixture.model.tick()
        await fixture.model.start(); await fixture.model.tick()
        fixture.model.pauseMonitoring()
        fixture.audio.onStatus?(.recovering("Audio interrupted"))
        fixture.audio.onStatus?(.failed("Microphone unavailable"))
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        await fixture.model.tick()
        try await Task.sleep(for: .milliseconds(300))
        let failures = await fixture.backend.sent.filter(\.isMonitoringFailure)
        XCTAssertTrue(failures.isEmpty)
        fixture.model.stop()
    }
    @MainActor func testMicrophoneStallSendsStopAlertWithoutReportingAStop() async throws {
        let fixture = try Fixture(automaticallyStart: true)
        await fixture.model.start()
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        let sent = await eventually(timeout: .seconds(5)) { await fixture.backend.sent.contains { $0.isMonitoringFailure } }
        XCTAssertTrue(sent)
        let requests = await fixture.backend.monitoringRequests
        XCTAssertFalse(requests.contains { !$0.0 }, "The stall must not report a Stop that would retire alerts")
    }
    @MainActor func testRelaunchAfterTerminationDoesNotReportAStopButResendsAnUnsentLocalAction() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        await fixture.model.tick()
        var requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.map(\.0), [true])
        func relaunch() throws -> AppModel {
            AppModel(defaults: fixture.defaults, metadataStore: try MetadataStore(directory: fixture.directory),
                     log: DiagnosticLog(directory: fixture.directory), audio: Audio(), liveSound: LiveSound(), connectivity: fixture.connectivity,
                     notifications: Notifications(), keychain: Credentials(listener: fixture.listener, parent: fixture.parent),
                     makeClient: { _, _ in fixture.backend }, currentTime: { fixture.time.now }, automaticallyStart: false)
        }
        // Terminated while monitoring: the relaunch must leave outstanding alerts and reminders alone.
        let restored = try relaunch()
        XCTAssertTrue(restored.needsRestart)
        await restored.tick()
        requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.map(\.0), [true])
        // A person's Stop that was never sent is replayed with its original identity.
        await fixture.backend.setMonitoringFailure(true)
        restored.stop()
        await restored.tick()
        requests = await fixture.backend.monitoringRequests
        let stop = try XCTUnwrap(requests.last)
        XCTAssertFalse(stop.0)
        await fixture.backend.setMonitoringFailure(false)
        let again = try relaunch()
        await again.tick()
        requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.last?.0, false)
        XCTAssertEqual(requests.last?.1, stop.1, "Retry the same request so the server stays idempotent")
        let before = requests.count
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        await again.tick()
        requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.count, before, "A delivered report is not resent")
    }
    @MainActor func testFailedLocalStartDoesNotReportAStop() async throws {
        let fixture = try Fixture()
        fixture.audio.startFailure = URLError(.unknown)
        await fixture.model.start()
        XCTAssertFalse(fixture.model.monitoring)
        await fixture.model.tick()
        let reported = await eventually(timeout: .milliseconds(500)) { await !fixture.backend.monitoringRequests.isEmpty }
        XCTAssertFalse(reported, "A Stop here would retire alerts the Listener never stopped watching")
    }
    @MainActor func testEndedPairingDiscardsUnsentMonitoringReport() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        await fixture.backend.setMonitoringFailure(true)
        await fixture.backend.setStatus(ParentStatus(paired: false, configuration: MonitoringConfiguration()))
        await fixture.model.tick()
        let unpaired = await eventually { !fixture.model.paired }
        XCTAssertTrue(unpaired)
        XCTAssertFalse(fixture.model.monitoring)
        await fixture.backend.setMonitoringFailure(false)
        let attempts = await fixture.backend.monitoringRequests.count
        fixture.time.now = fixture.time.now.addingTimeInterval(4)
        await fixture.model.tick()
        let requests = await fixture.backend.monitoringRequests
        XCTAssertEqual(requests.count, attempts, "Never retry the old pairing's report")
        XCTAssertNil(fixture.defaults.string(forKey: "paired|https://monitor.test|listener|localMonitoringReport"))
    }
    @MainActor func testClippedMicrophoneLevelsCountAsLoudestSoundInsteadOfBeingDropped() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        fixture.time.now = fixture.time.now.addingTimeInterval(0.25)
        fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: 3))
        let received = await eventually { fixture.model.currentDBFS == 0 }
        XCTAssertTrue(received)
        XCTAssertEqual(fixture.model.meter.last, 0)
    }
    @MainActor func testSettingsFailureDoesNotPreventPendingAlertDeliveryAndRemainsDirty() async throws {
        let fixture = try Fixture(pending: true)
        await fixture.backend.configure(settingsFail: true)
        fixture.model.saveSettings(MonitoringConfiguration())
        await fixture.model.tick()
        let attempted = await eventually { await fixture.backend.settingsCalls == 1 }
        XCTAssertTrue(attempted)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertTrue(fixture.defaults.bool(forKey: "settingsDirty"))
        let sent = await fixture.backend.sent
        XCTAssertEqual(sent.count, 1)
        // The failed configuration is retried and cleared only after success.
        await fixture.backend.configure()
        let synced = await eventually {
            await fixture.model.tick()
            return !fixture.defaults.bool(forKey: "settingsDirty")
        }
        XCTAssertTrue(synced)
    }
    @MainActor func testSuspendedSettingsUploadDoesNotDelayAlertDelivery() async throws {
        let fixture = try Fixture(pending: true)
        let gate = RequestGate()
        await fixture.backend.configure(settingsGate: gate)
        fixture.model.saveSettings(MonitoringConfiguration())
        await fixture.model.tick()
        let attempted = await eventually { await fixture.backend.settingsCalls == 1 }
        XCTAssertTrue(attempted)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertTrue(fixture.defaults.bool(forKey: "settingsDirty"))
        await gate.open()
        let synced = await eventually { !fixture.defaults.bool(forKey: "settingsDirty") }
        XCTAssertTrue(synced)
    }
    @MainActor func testRoleChangeSendsStoppedListenerHeartbeatAfterInFlightActiveHeartbeat() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        let request = Task { await fixture.model.tick() }
        let started = await eventually { await fixture.backend.beats.count == 1 }
        XCTAssertTrue(started)
        fixture.model.selectRole(.parent)
        XCTAssertEqual(fixture.model.role, .parent)
        XCTAssertFalse(fixture.model.monitoring)
        await gate.open()
        await request.value
        let stopped = await eventually { await fixture.backend.beats.count == 2 }
        XCTAssertTrue(stopped)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false])
        XCTAssertEqual(beats.map(\.listenerId), [fixture.listener.deviceId, fixture.listener.deviceId])
        XCTAssertEqual(beats.last?.state, .quiet)
    }
    @MainActor func testOlderHeartbeatResponseDoesNotUndoSuccessfulSettingsUpload() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        var config = MonitoringConfiguration(); config.alertDuration = 5
        fixture.model.saveSettings(config)
        let request = Task { await fixture.model.tick() }
        let uploaded = await eventually {
            let beats = await fixture.backend.beats
            return beats.count == 1 && !fixture.defaults.bool(forKey: "settingsDirty")
        }
        XCTAssertTrue(uploaded)
        await gate.open()
        await request.value
        let completed = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.model.configuration, config)
        fixture.model.stop()
    }
    @MainActor func testAcknowledgedServerReceiptRemovesAlertWithoutClaimingAPNsDelivery() async throws {
        let fixture = try Fixture(pending: true, logEvents: ["alert_apns_accepted"])
        let priorAccepted = fixture.model.log.lines.filter { $0.contains("alert_apns_accepted") }
        XCTAssertEqual(priorAccepted.count, 1)
        await fixture.backend.configure(receipt: "acknowledged")
        await fixture.model.tick()
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertEqual(fixture.model.deliveryStatus, "Alert acknowledged on Parent")
        XCTAssertEqual(fixture.model.log.lines.filter { $0.contains("alert_apns_accepted") }, priorAccepted)
    }
    @MainActor func testPendingAlertDoesNotWaitForHungHeartbeatOrQueueDuplicateHeartbeats() async throws {
        let fixture = try Fixture(pending: true)
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        await fixture.model.tick()
        let started = await eventually { await fixture.backend.beats.count == 1 }
        XCTAssertTrue(started)
        let sent = await fixture.backend.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        // Repeated pulses during the same suspended request must not build a backlog.
        for _ in 0..<3 { await fixture.model.tick() }
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.count, 1)
        await gate.open()
        let completed = await eventually { await fixture.backend.heartbeatCompletions == 1 }
        XCTAssertTrue(completed)
        fixture.model.stop()
    }
    @MainActor func testHeartbeatsContinueWhileAlertDeliveryIsSuspended() async throws {
        let fixture = try Fixture(pending: true, automaticallyStart: true)
        let gate = RequestGate()
        await fixture.backend.configure(sendGate: gate)
        await fixture.model.start()
        let sending = await eventually { await fixture.backend.sent.count == 1 }
        XCTAssertTrue(sending)
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        fixture.time.now = fixture.time.now.addingTimeInterval(16)
        fixture.audio.emit(AudioLevelSample(timestamp: fixture.time.now, dbFS: -65))
        let observed = await eventually { fixture.model.snapshot.lastObservedAt == fixture.time.now }
        XCTAssertTrue(observed)
        let refreshed = await eventually { await fixture.backend.beats.count == 2 }
        XCTAssertTrue(refreshed)
        // The second heartbeat was sent before allowing the alert request to finish.
        XCTAssertEqual(fixture.model.snapshot.pending.count, 1)
        await gate.open()
        let delivered = await eventually { fixture.model.snapshot.pending.isEmpty }
        XCTAssertTrue(delivered)
        fixture.model.stop()
    }
    @MainActor func testStoppedHeartbeatCompletionCannotSuppressHeartbeatAfterRestart() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        fixture.model.stop()
        let started = await eventually { await fixture.backend.beats.count == 1 }
        XCTAssertTrue(started)
        await fixture.model.start()
        await gate.open()
        let completed = await eventually { await fixture.backend.heartbeatCompletions >= 1 }
        XCTAssertTrue(completed)
        await fixture.model.tick()
        let refreshed = await eventually { await fixture.backend.beats.count == 2 }
        XCTAssertTrue(refreshed)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [false, true])
        fixture.model.stop()
    }
    @MainActor func testFailedHeartbeatDoesNotPreventAlertDeliveryAndCanRetry() async throws {
        let fixture = try Fixture(pending: true)
        await fixture.backend.configure(heartbeatFail: true)
        await fixture.model.start()
        await fixture.model.tick()
        let failed = await eventually { fixture.model.log.lines.contains { $0.contains("heartbeat_retry_scheduled") } }
        XCTAssertTrue(failed)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        await fixture.backend.configure()
        fixture.time.now = fixture.time.now.addingTimeInterval(2)
        await fixture.model.tick()
        let reconnected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(reconnected)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.count, 2)
        fixture.model.stop()
    }
    @MainActor func testTerminalFailureIsPersistedAndNeverRetried() async throws {
        let fixture = try Fixture(pending: true)
        let original = try XCTUnwrap(fixture.model.snapshot.pending.first?.alert)
        await fixture.backend.configure(receipt: "failed")
        await fixture.model.tick()
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertEqual(fixture.model.snapshot.failedAlerts.map(\.alert), [original])
        XCTAssertEqual(fixture.model.snapshot.failedAlerts.first?.failedAt, fixture.time.now)
        let restored = try MetadataStore(directory: fixture.directory).load()
        XCTAssertTrue(restored.pending.isEmpty)
        XCTAssertEqual(restored.failedAlerts.map(\.alert), [original])
        fixture.time.now = fixture.time.now.addingTimeInterval(301)
        await fixture.model.tick()
        let requests = await fixture.backend.sent
        XCTAssertEqual(requests.count, 1)
        // A new alert can still be delivered without replaying the retired event.
        await fixture.backend.configure()
        await fixture.model.sendTestPush()
        let delivered = await fixture.backend.sent
        XCTAssertEqual(delivered.count, 2)
        XCTAssertNotEqual(delivered.last?.eventId, original.eventId)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        XCTAssertEqual(fixture.model.snapshot.failedAlerts.count, 1)
    }
    @MainActor func testRetryableReceiptsAndTransportFailuresRemainQueued() async throws {
        for status in ["pending", "blocked", "uncertain"] {
            let fixture = try Fixture(pending: true)
            await fixture.backend.configure(receipt: status)
            await fixture.model.tick()
            XCTAssertEqual(fixture.model.snapshot.pending.count, 1, status)
            XCTAssertTrue(fixture.model.snapshot.failedAlerts.isEmpty, status)
        }
        let fixture = try Fixture(pending: true)
        await fixture.backend.configure(sendFail: true)
        await fixture.model.tick()
        XCTAssertEqual(fixture.model.snapshot.pending.first?.attempts, 1)
        XCTAssertTrue(fixture.model.snapshot.failedAlerts.isEmpty)
    }
    @MainActor func testFixtureLogsAreIsolatedAndExistingHistoryStillLoads() async throws {
        let first = try Fixture(logEvents: ["alert_apns_accepted"])
        let second = try Fixture()
        XCTAssertTrue(second.model.log.lines.isEmpty)
        second.model.log.record("monitoring_started")
        XCTAssertFalse(first.model.log.export.contains("monitoring_started"))
        let restored = DiagnosticLog(directory: first.directory)
        XCTAssertEqual(restored.lines, first.model.log.lines)
    }

    @MainActor func testHeartbeatRetryBackoffAndSuccessReset() async throws {
        let fixture = try Fixture()
        await fixture.backend.configure(heartbeatFail: true)
        await fixture.model.start()
        let first = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(first)
        var count = 1
        for delay in [2.0, 4, 8, 16, 30, 30] {
            // Give each response a distinct status to wait on, ensuring its deadline is installed.
            fixture.model.deliveryStatus = "Waiting for retry"
            fixture.time.now = fixture.time.now.addingTimeInterval(delay - 0.01)
            for _ in 0..<5 { await fixture.model.tick() }
            let before = await fixture.backend.beats.count
            XCTAssertEqual(before, count)
            fixture.time.now = fixture.time.now.addingTimeInterval(0.01)
            await fixture.model.tick()
            let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
            XCTAssertTrue(failed)
            count += 1
            let after = await fixture.backend.beats.count
            XCTAssertEqual(after, count)
        }
        await fixture.backend.configure()
        fixture.time.now = fixture.time.now.addingTimeInterval(30)
        await fixture.model.tick()
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        count += 1
        fixture.time.now = fixture.time.now.addingTimeInterval(14.99)
        await fixture.model.tick()
        let beforeInterval = await fixture.backend.beats.count
        XCTAssertEqual(beforeInterval, count)
        await fixture.backend.configure(heartbeatFail: true)
        fixture.time.now = fixture.time.now.addingTimeInterval(0.01)
        await fixture.model.tick()
        let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(failed)
        await fixture.backend.configure()
        fixture.time.now = fixture.time.now.addingTimeInterval(2)
        await fixture.model.tick()
        let reset = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(reset)
        let afterReset = await fixture.backend.beats.count
        XCTAssertEqual(afterReset, count + 2)
        fixture.model.stop()
    }

    @MainActor func testStoppedHeartbeatRetriesAndDoesNotBecomePeriodic() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        await fixture.backend.configure(heartbeatFail: true)
        fixture.model.stop()
        let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(failed)
        await fixture.backend.configure()
        fixture.time.now = fixture.time.now.addingTimeInterval(2)
        await fixture.model.tick()
        let recovered = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(recovered)
        fixture.time.now = fixture.time.now.addingTimeInterval(600)
        await fixture.model.tick()
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false, false])
    }

    @MainActor func testConnectivityRecoveryRetriesStoppedHeartbeatImmediately() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        await fixture.backend.configure(heartbeatFail: true)
        fixture.model.stop()
        let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(failed)
        fixture.connectivity.available = false
        await fixture.model.tick()
        await fixture.backend.configure()
        fixture.connectivity.available = true
        await fixture.model.tick() // No clock advance: bypass the existing deadline once.
        let recovered = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(recovered)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false, false])
    }

    @MainActor func testQueuedHeartbeatUsesLatestStateAndNeverOverlaps() async throws {
        let fixture = try Fixture()
        let gate = RequestGate()
        await fixture.backend.configure(heartbeatGate: gate)
        await fixture.model.start()
        let sending = await eventually { await fixture.backend.beats.count == 1 }
        XCTAssertTrue(sending)
        fixture.model.stop()
        await fixture.model.start()
        fixture.model.stop()
        for _ in 0..<3 { await fixture.model.tick() }
        let inFlight = await fixture.backend.beats
        XCTAssertEqual(inFlight.map(\.monitoring), [true])
        await gate.open()
        let finished = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(finished)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false])
    }

    @MainActor func testStopAndRestartBypassOldHeartbeatBackoff() async throws {
        let fixture = try Fixture()
        await fixture.backend.configure(heartbeatFail: true)
        await fixture.model.start()
        let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(failed)
        fixture.model.deliveryStatus = "Stopping"
        fixture.model.stop()
        let stopped = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(stopped)
        await fixture.backend.configure()
        await fixture.model.start()
        let restarted = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(restarted)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false, true])
        fixture.model.stop()
    }

    @MainActor func testStoppedHeartbeatSurvivesRoleChangeAndOfflinePeriod() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        fixture.connectivity.available = false
        fixture.model.selectRole(.parent)
        await fixture.model.tick()
        let offline = await fixture.backend.beats
        XCTAssertEqual(offline.map(\.monitoring), [true])
        fixture.connectivity.available = true
        await fixture.model.tick()
        let sent = await eventually { await fixture.backend.beats.count == 2 }
        XCTAssertTrue(sent)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false])
        XCTAssertEqual(beats.last?.listenerId, fixture.listener.deviceId)
    }

    @MainActor func testAlertsSendDuringHeartbeatBackoff() async throws {
        let fixture = try Fixture()
        await fixture.backend.configure(heartbeatFail: true)
        await fixture.model.start()
        let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
        XCTAssertTrue(failed)
        // Advance only enough to make the new test alert due, not the heartbeat.
        fixture.time.now = fixture.time.now.addingTimeInterval(1)
        await fixture.model.sendTestPush()
        let sent = await fixture.backend.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(fixture.model.snapshot.pending.isEmpty)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.count, 1)
        fixture.model.stop()
    }

    @MainActor func testHeartbeatJitterStaysBounded() async throws {
        for factor in [0.9, 1.1] {
            let fixture = try Fixture(heartbeatJitter: { factor })
            await fixture.backend.configure(heartbeatFail: true)
            await fixture.model.start()
            let failed = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
            XCTAssertTrue(failed)
            var count = 1
            for base in [2.0, 4, 8, 16, 30, 30] {
                fixture.model.deliveryStatus = "Waiting"
                let due = fixture.time.now.addingTimeInterval(min(30, base * factor))
                fixture.time.now = due.addingTimeInterval(-0.01)
                await fixture.model.tick()
                let before = await fixture.backend.beats.count
                XCTAssertEqual(before, count)
                fixture.time.now = due
                await fixture.model.tick()
                let retried = await eventually { fixture.model.deliveryStatus.contains("status update pending") }
                XCTAssertTrue(retried)
                count += 1
                let after = await fixture.backend.beats
                XCTAssertEqual(after.count, count)
                XCTAssertEqual(after.last?.timestamp, due)
            }
            fixture.model.stop()
        }
    }

    @MainActor func testFailedEpisodeMessageUsesTerminalOutcome() throws {
        var simulation = CrySessionTests.Simulation(); simulation.run(306)
        let alert = try XCTUnwrap(simulation.emitted.first)
        let episode = try XCTUnwrap(simulation.engine.snapshot.current)
        XCTAssertTrue(ListenerView.alertMessage(for: episode, snapshot: simulation.engine.snapshot, now: simulation.time).contains("Waiting for delivery"))
        simulation.engine.permanentlyFailed(alert.eventId, at: simulation.time)
        let message = ListenerView.alertMessage(for: episode, snapshot: simulation.engine.snapshot, now: simulation.time)
        XCTAssertTrue(message.contains("Alert delivery failed"))
        XCTAssertTrue(message.contains("will not be retried"))
        XCTAssertFalse(message.contains("Waiting"))
        // Never clear the queue marker: doing so would create another initial event.
        simulation.run(60)
        XCTAssertEqual(simulation.emitted.count, 1)
    }

    @MainActor func testFailedStoppedHeartbeatRetriesWithListenerIdentityAfterRoleChange() async throws {
        let fixture = try Fixture()
        await fixture.model.start()
        let connected = await eventually { fixture.model.deliveryStatus == "Connected" }
        XCTAssertTrue(connected)
        await fixture.backend.configure(heartbeatFail: true)
        fixture.model.selectRole(.parent)
        let failed = await eventually { fixture.model.log.lines.contains { $0.contains("heartbeat_retry_scheduled") } }
        XCTAssertTrue(failed)
        await fixture.backend.configure()
        fixture.time.now = fixture.time.now.addingTimeInterval(2)
        await fixture.model.tick()
        let retried = await eventually { await fixture.backend.heartbeatCompletions == 3 }
        XCTAssertTrue(retried)
        let beats = await fixture.backend.beats
        XCTAssertEqual(beats.map(\.monitoring), [true, false, false])
        XCTAssertTrue(beats.allSatisfy { $0.listenerId == fixture.listener.deviceId })
    }
}
#endif
