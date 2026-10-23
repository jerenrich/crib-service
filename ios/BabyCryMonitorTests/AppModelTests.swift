#if !canImport(MonitorCore)
import Foundation
import XCTest
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
    @MainActor final class Audio: AudioLevelProviding {
        let levels: AsyncStream<AudioLevelSample>
        private let continuation: AsyncStream<AudioLevelSample>.Continuation
        var onStatus: ((AudioCaptureStatus) -> Void)?
        var permissionGranted = true
        var recoveryGate: RequestGate?
        var startFailure: Error?
        private(set) var starts = 0
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
            if let startFailure { throw startFailure }
            onStatus?(.active)
        }
        func stop() { onStatus?(.stopped) }
    }
    @MainActor final class Connectivity: ConnectivityProviding {
        var available = true
        var checked = true
    }
    @MainActor final class Notifications: NotificationProviding {
        var status = "Test notifications"
        var onToken: ((String) -> Void)?
        var onAlert: (() -> Void)?
        func register() async {}
        func registered(_ token: Data) {}
        func failed() {}
        func simulate(_ alert: CryAlert) async throws {}
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
        var statusValue: ParentStatus?
        var statusGate: RequestGate?
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
        func status() async throws -> ParentStatus { await statusGate?.wait(); return statusValue ?? ParentStatus(paired: true, configuration: MonitoringConfiguration()) }
        func setStatusGate(_ gate: RequestGate?) { statusGate = gate }
        func setStatus(_ value: ParentStatus) { statusValue = value }
        func unpair() async throws { removedPair = true }
        func deleteDevice() async throws { deletedDevice = true }
        func requestTestPush() async throws { requestedTest = true }
        func connectionAlerts(_ enabled: Bool) async throws {}
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
        func acknowledge(_ id: UUID) async throws {}
        func pushToken(_ token: String) async throws {}
        func watchPushToken(_ token: String?) async throws {}
    }
    @MainActor final class Fixture {
        let model: AppModel
        let audio = Audio()
        let connectivity = Connectivity()
        let backend: Backend
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let listener: DeviceCredential
        final class Time { var now = Date() }
        let time: Time
        init(pending: Bool = false, automaticallyStart: Bool = false, logEvents: [String] = [], heartbeatJitter: @escaping () -> Double = { 1 }) throws {
            suite = "AppModelTests.\(UUID())"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            listener = DeviceCredential(deviceId: UUID(), secret: "test-listener", role: .listener, registered: true)
            let parent = DeviceCredential(deviceId: UUID(), secret: "test-parent", role: .parent, registered: true)
            defaults.set("listener", forKey: "role")
            defaults.set(true, forKey: "safetyAccepted")
            defaults.set("https://monitor.test", forKey: "backendURL")
            defaults.set(true, forKey: "paired|https://monitor.test|listener")
            let store = try MetadataStore(directory: directory)
            var snapshot = SessionSnapshot()
            if pending {
                snapshot.pending = [PendingAlert(alert: CryAlert(episodeId: UUID(), listenerId: listener.deviceId,
                    cryStartedAt: Date().addingTimeInterval(-301), durationSeconds: 300,
                    createdAt: Date().addingTimeInterval(-1), isRepeat: false))]
            }
            try store.save(snapshot)
            let backend = Backend(credential: listener); self.backend = backend
            let time = Time(); self.time = time
            let log = DiagnosticLog(directory: directory)
            for event in logEvents { log.record(event) }
            model = AppModel(defaults: defaults, metadataStore: store, log: log, audio: audio, connectivity: connectivity,
                             notifications: Notifications(), keychain: Credentials(listener: listener, parent: parent),
                             makeClient: { _, _ in backend }, currentTime: { time.now }, heartbeatJitter: heartbeatJitter, automaticallyStart: automaticallyStart)
        }
        deinit {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    @MainActor private func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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
        status.lastHeartbeat = fixture.time.now.addingTimeInterval(-151)
        await fixture.backend.setStatus(status); await fixture.model.refreshParent()
        XCTAssertEqual(fixture.model.nurseryConnection, "Connection lost"); XCTAssertFalse(fixture.model.parentOnline)
        XCTAssertEqual(fixture.model.settingsSyncStatus, "Waiting for Listener")
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
