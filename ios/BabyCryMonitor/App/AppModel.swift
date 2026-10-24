import Foundation
import Observation
import UIKit

@MainActor @Observable final class AppModel {
    var role: DeviceRole?
    var safetyAccepted: Bool
    var configuration = MonitoringConfiguration()
    var backendURL: String
    var monitoring = false
    var starting = false
    var recoveringAudio = false
    var paired = false
    var error: String?
    var audioStatus = "Stopped"
    var deliveryStatus = "Not connected"
    var sendingTestPush = false
    var testPushStatus: String?
    var pairingCode: PairingCode?
    var parentStatus: ParentStatus?
    var timeline: TimelineResponse?
    var timelineClockOffset: TimeInterval = 0
    var timelineError: String?
    var loadingTimeline = false
    var currentDBFS: Double = -100
    var meter: [Double] = Array(repeating: -100, count: 32)
    var batteryLevel: Double?
    var powerConnected = false
    var now = Date()
    var needsRestart = false
    var requestingMonitoring = false
    var monitoringControlError: String?
    var monitoringControlMessage: String?
    private(set) var pendingMonitoringCommand: MonitoringCommand?
    @ObservationIgnored private var monitoringControlDeadline: Date?
    @ObservationIgnored private var controlGeneration = 0
    @ObservationIgnored private var localMonitoringReport: (id: UUID, enabled: Bool)?
    var managingDevice = false
    var changingConnectionAlerts = false
    private(set) var localConnectionWarningEnabled: Bool
    private(set) var keepScreenAwake: Bool
    private(set) var parentConnectionDeadline: Date?
    private(set) var parentConnectionWarningError: String?
    var calibration = SoundCalibration()
    var calibrationPhase = "idle"
    var calibrationMessage: String?
    private var calibrationActive: Bool { ["background", "sample", "waiting"].contains(calibrationPhase) }
    let connectivity: any ConnectivityProviding
    let notifications: any NotificationProviding
    let watch: PhoneWatchBridge
    let log: DiagnosticLog
    private var engine = CrySessionManager()
    @ObservationIgnored private var store: MetadataStore?
    @ObservationIgnored private let audio: any AudioLevelProviding
    @ObservationIgnored private let alerts = AlertCoordinator()
    @ObservationIgnored private var credential: DeviceCredential?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var listenerStatusTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any CredentialStoring
    @ObservationIgnored private let makeClient: (URL, DeviceCredential) -> any BackendServing
    @ObservationIgnored private let currentTime: () -> Date
    @ObservationIgnored private var settingsGeneration = 0
    @ObservationIgnored private var monitoringGeneration = 0
    @ObservationIgnored private let heartbeatJitter: () -> Double
    @ObservationIgnored private var lastConnectivityAvailable: Bool
    private struct HeartbeatRequest {
        let id = UUID()
        let client: any BackendServing
        var value: Heartbeat
        let revision: Int
        var settingsGeneration: Int
        let observation: Int
        var failures = 0
        var nextAttemptAt = Date.distantPast
    }
    @ObservationIgnored private var pendingHeartbeats: [String: HeartbeatRequest] = [:]
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var lastHeartbeatAt = Date.distantPast
    @ObservationIgnored private var lastRefreshAt = Date.distantPast
    @ObservationIgnored private var nextParentRefreshAt = Date.distantPast
    @ObservationIgnored private var parentRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var uploadedToken: String?
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var pendingWatchToken: String?
    @ObservationIgnored private var hasPendingWatchToken = false
    @ObservationIgnored private var lastWatchRetryAt = Date.distantPast
    @ObservationIgnored private var watchSyncInFlight = false
    @ObservationIgnored private var storageHealthy = true
    @ObservationIgnored private var storageFailure: (any Error)?
    @ObservationIgnored private var settingsDirty = false
    @ObservationIgnored private var environmentRevision = 0
    @ObservationIgnored private var latestTestEventID: UUID?
    @ObservationIgnored private var parentWarningTask: Task<Void, Never>?
    @ObservationIgnored private var parentWarningUpdatePending = false
    @ObservationIgnored private var parentWarningRetryAt: Date?
    private static let parentWarningDeadlineKey = "parentConnectionWarningDeadline"
    private static let parentWarningScopeKey = "parentConnectionWarningScope"
    private static let parentWarningScheduledKey = "parentConnectionWarningScheduledDeadline"

    init(defaults: UserDefaults = .standard, metadataStore: MetadataStore? = nil,
         log: DiagnosticLog = DiagnosticLog(),
         audio: any AudioLevelProviding = AudioLevelMonitor(),
         connectivity: any ConnectivityProviding = ConnectivityMonitor(),
         notifications: any NotificationProviding = NotificationService(),
         keychain: any CredentialStoring = KeychainStore(),
         makeClient: @escaping (URL, DeviceCredential) -> any BackendServing = { BackendClient(baseURL: $0, credential: $1) },
         currentTime: @escaping () -> Date = Date.init,
          heartbeatJitter: @escaping () -> Double = { Double.random(in: 0.9...1.1) }, automaticallyStart: Bool = true) {
        self.defaults = defaults; self.audio = audio; self.connectivity = connectivity; self.log = log
        self.notifications = notifications; self.keychain = keychain; self.makeClient = makeClient
        self.watch = PhoneWatchBridge(enabled: automaticallyStart)
        self.currentTime = currentTime; self.heartbeatJitter = heartbeatJitter
        self.lastConnectivityAvailable = connectivity.available
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset"), let bundle = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundle)
        }
        #endif
        role = defaults.string(forKey: "role").flatMap(DeviceRole.init)
        safetyAccepted = defaults.bool(forKey: "safetyAccepted")
        localConnectionWarningEnabled = defaults.bool(forKey: "localConnectionWarningEnabled")
        keepScreenAwake = defaults.bool(forKey: "keepScreenAwake")
        backendURL = defaults.string(forKey: "backendURL") ?? (Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String ?? "")
        var interruptedMonitoringAt: Date?
        do {
            let store = try metadataStore ?? MetadataStore(); self.store = store
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting-reset"),
               ProcessInfo.processInfo.arguments.contains("--uitesting-offline") {
                try store.save(SessionSnapshot())
            }
            #endif
            let saved = try store.load(); needsRestart = saved.wasMonitoring
            if saved.wasMonitoring { interruptedMonitoringAt = saved.lastObservedAt }
            engine = CrySessionManager(snapshot: saved); engine.recoverAfterRelaunch()
            configuration = engine.snapshot.configuration
            try store.save(engine.snapshot)
        } catch { storageHealthy = false; storageFailure = error; self.error = "Local metadata storage failed: \(error.localizedDescription)"; log.record("metadata_load_failed", error: error) }
        settingsDirty = defaults.bool(forKey: "settingsDirty")
        UIDevice.current.isBatteryMonitoringEnabled = true
        audio.onStatus = { [weak self] status in self?.audioChanged(status) }
        (notifications as? NotificationService)?.log = log
        watch.log = log
        (audio as? AudioLevelMonitor)?.log = log
        notifications.onToken = { [weak self] token in self?.pushToken = token; self?.uploadedToken = nil; self?.log.record("push_token_received") }
        notifications.onAlert = { [weak self] in self?.log.record("push_received"); Task { await self?.refreshParent() } }
        notifications.onAcknowledge = { [weak self] id in await self?.acknowledge(id) }
        watch.onCommand = { [weak self] command in
            guard let self else { return WatchSnapshot() }
            return await self.handleWatch(command)
        }
        audioTask = Task { [weak self, levels = audio.levels] in
            for await sample in levels {
                guard !Task.isCancelled else { break }; self?.consume(sample)
            }
        }
        if automaticallyStart {
            log.record("app_launched")
            if needsRestart { log.record("monitoring_recovered_after_relaunch") }
            // Local health and freshness must advance even while a request is suspended.
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateLocalState()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            networkTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
        }
        loadCredential()
        if role == .listener, paired, needsRestart || defaults.string(forKey: localMonitoringReportKey) != nil {
            queueLocalMonitoringReport(false)
        }
        if role == .parent { monitoringControlError = defaults.string(forKey: monitoringControlPendingKey + "|error") }
        if role == .parent, let data = defaults.data(forKey: monitoringControlPendingKey),
           let command = try? JSONDecoder().decode(MonitoringCommand.self, from: data) {
            pendingMonitoringCommand = command
            monitoringControlDeadline = defaults.object(forKey: monitoringControlPendingKey + "|deadline") as? Date ?? .distantPast
            monitoringControlMessage = "Waiting for nursery monitoring confirmation…"
            checkMonitoringControlDeadline()
        }
        if needsRestart, role == .listener {
            engine.recordTimeline("monitoring_unverified", at: interruptedMonitoringAt ?? currentTime()); persist()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-timeline") { seedTimelineForUITest() }
        #endif
        // Restore a warning only after explicit opt-in; clear legacy deadlines on
        // upgrade. Relaunch/network availability must never postpone a deadline.
        if localConnectionWarningEnabled, role == .parent, paired,
           defaults.string(forKey: Self.parentWarningScopeKey) == parentWarningScope,
           let deadline = defaults.object(forKey: Self.parentWarningDeadlineKey) as? Date {
            parentConnectionDeadline = deadline
            if deadline > currentTime() || defaults.object(forKey: Self.parentWarningScheduledKey) as? Date != deadline {
                setParentConnectionDeadline(deadline, force: true)
            }
        } else if defaults.object(forKey: Self.parentWarningDeadlineKey) != nil || defaults.object(forKey: Self.parentWarningScheduledKey) != nil {
            setParentConnectionDeadline(nil, force: true)
        }
        publishWatch()
    }
    deinit {
        loopTask?.cancel(); networkTask?.cancel(); audioTask?.cancel()
        settingsTask?.cancel(); heartbeatTask?.cancel()
        listenerStatusTask?.cancel(); parentRefreshTask?.cancel()
    }
    var snapshot: SessionSnapshot { engine.snapshot }
    var state: CryState { engine.detector.state }
    var threshold: Double { configuration.absoluteThreshold }
    var listenerID: String { credential?.deviceId.uuidString ?? "Not registered" }
    var shouldKeepScreenAwake: Bool { safetyAccepted && role == .parent && keepScreenAwake }
    var parentOnline: Bool {
        guard pendingMonitoringCommand == nil, monitoringControlError == nil else { return false }
        guard let status = parentStatus, status.monitoring == true, let last = status.lastHeartbeat else { return false }
        return (-5...150).contains(now.timeIntervalSince(last))
    }
    var nurseryConnection: String {
        guard paired else { return "Not paired" }
        if let command = pendingMonitoringCommand { return command.enabled ? "Starting…" : "Stopping…" }
        if monitoringControlError != nil { return "Monitoring unverified" }
        guard let status = parentStatus, let last = status.lastHeartbeat else { return "Status unavailable" }
        guard (-5...150).contains(now.timeIntervalSince(last)) else { return "Connection lost" }
        return status.monitoring == true ? "Monitoring" : "Stopped"
    }
    var settingsSyncStatus: String {
        if !paired { return "Saved on this iPhone · Pair to sync" }
        if settingsDirty { return "Saving settings…" }
        if role == .listener { return "Applied on this Listener" }
        guard let applied = parentStatus?.listenerConfiguration else { return "Waiting for Listener confirmation" }
        return applied == configuration && parentOnline ? "Applied on Listener" : "Waiting for Listener"
    }
    var listenerPowerReadiness: ListenerPowerReadiness {
        ListenerPowerReadiness(batteryLevel: parentStatus?.batteryLevel, powerConnected: parentStatus?.powerConnected,
                               fresh: parentOnline, now: now)
    }
    var recentConfirmedTest: RemoteAlert? {
        parentStatus?.alerts?.first {
            $0.isTest == true && $0.acknowledgedAt != nil && (-5...1800).contains(now.timeIntervalSince($0.createdAt))
        }
    }
    var activeAlert: RemoteAlert? {
        let alerts = parentStatus?.alerts?.filter { $0.acknowledgedAt == nil }
        return alerts?.first { $0.isTest != true } ?? alerts?.first
    }
    func acceptSafety() { safetyAccepted = true; defaults.set(true, forKey: "safetyAccepted") }
    func selectRole(_ value: DeviceRole) {
        guard !managingDevice else { return }
        setParentConnectionDeadline(nil)
        cancelCalibration()
        stop(); environmentRevision += 1; role = value; defaults.set(value.rawValue, forKey: "role")
        resetMonitoringControl()
        timeline = nil; timelineError = nil
        parentStatus = nil; pairingCode = nil; credential = nil; uploadedToken = nil; loadCredential()
        nextParentRefreshAt = .distantPast
        testPushStatus = nil; latestTestEventID = nil
        hasPendingWatchToken = false; pendingWatchToken = nil
        publishWatch()
        if value == .parent { Task { await notifications.register(); await refreshParent() } }
    }
    func setBackend(_ value: String) {
        guard !monitoring, !starting, !recoveringAudio, snapshot.pending.isEmpty else { error = "Stop monitoring and deliver pending alerts before changing the backend."; return }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { error = "Enter the HTTPS origin of your deployed Worker."; return }
        setParentConnectionDeadline(nil)
        resetMonitoringControl()
        environmentRevision += 1; backendURL = url.absoluteString
        defaults.set(backendURL, forKey: "backendURL")
        timeline = nil; timelineError = nil
        credential = nil; parentStatus = nil; pairingCode = nil; uploadedToken = nil
        nextParentRefreshAt = .distantPast
        testPushStatus = nil; latestTestEventID = nil
        hasPendingWatchToken = false; pendingWatchToken = nil
        loadCredential()
        publishWatch()
    }
    private var pairingKey: String { "paired|\(backendURL)|\(role?.rawValue ?? "")" }
    private func loadCredential() {
        paired = defaults.bool(forKey: pairingKey)
        guard let role else { return }
        do {
            credential = try keychain.load(role: role, environment: backendURL)
            if credential == nil {
                let created = try keychain.create(role: role)
                try keychain.save(created, environment: backendURL); credential = created
            }
            if let credential { engine.scopeTimeline(to: "\(backendURL)|\(credential.deviceId)"); persist() }
        } catch { self.error = error.localizedDescription; log.record("credential_failed", error: error) }
    }
    private func client() throws -> any BackendServing {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-monitoring-rejected") {
            throw BackendError.response(409, "Monitoring request rejected by the test service.")
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-offline") { throw URLError(.notConnectedToInternet) }
        #endif
        guard let credential, let url = URL(string: backendURL), !backendURL.isEmpty else {
            throw BackendError.message("The connection service is not configured. Contact the app provider for a configured build.")
        }
        let value = makeClient(url, credential)
        if var backend = value as? BackendClient { backend.log = log; return backend }
        return value
    }
    private func registeredClient() async throws -> any BackendServing {
        let client = try client()
        if credential?.registered != true {
            let revision = environmentRevision
            try await client.register()
            guard revision == environmentRevision, credential?.deviceId == client.credential.deviceId else { throw CancellationError() }
            var saved = client.credential; saved.registered = true
            try keychain.save(saved, environment: backendURL); credential = saved
        }
        return client
    }
    func createPairing() async {
        let revision = environmentRevision
        do {
            let client = try await registeredClient(); let created = try await client.createPairing()
            guard revision == environmentRevision else { return }; pairingCode = created; error = nil; log.record("pairing_created")
        }
        catch { self.error = error.localizedDescription; log.record("pairing_failed", error: error) }
    }
    func claimPairing(_ code: String) async {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { error = "Enter the six-digit code shown on the Parent iPhone."; return }
        let revision = environmentRevision
        do {
            let client = try await registeredClient(); try await client.claim(code)
            guard revision == environmentRevision else { return }
            environmentRevision += 1
            paired = true; defaults.set(true, forKey: pairingKey)
            log.record("paired_successfully"); error = nil
        } catch { self.error = error.localizedDescription; log.record("pairing_failed", error: error) }
    }
    func start(remote: Bool = false, deadline: Date? = nil, commandID: UUID? = nil) async {
        guard !starting, !monitoring, !recoveringAudio, !calibrationActive, !managingDevice, role == .listener else { return }
        if !remote { controlGeneration += 1 }
        let control = controlGeneration
        let revision = environmentRevision, generation = settingsGeneration
        starting = true
        defer {
            starting = false
            if !remote, revision == environmentRevision, control == controlGeneration { queueLocalMonitoringReport(monitoring) }
        }
        guard safetyAccepted else {
            log.record("monitoring_start_blocked_safety")
            error = "Review and accept the safety information before monitoring."; return
        }
        guard storageHealthy else {
            log.record("monitoring_start_blocked_storage", error: storageFailure)
            error = "Local monitoring data is unavailable. Close and reopen the app, then check Diagnostics if the problem continues."; return
        }
        guard paired else { error = "Pair this Listener with a Parent before monitoring."; return }
        guard await audio.requestPermission() else { error = "Microphone permission denied. Enable Microphone in iPhone Settings → Crib Service."; log.record("microphone_permission_denied"); return }
        guard revision == environmentRevision, control == controlGeneration, role == .listener else { return }
        do {
            if connectivity.available {
                do {
                    let client = try await registeredClient(); let status = try await client.status()
                    guard revision == environmentRevision, control == controlGeneration else { return }
                    observePairing(status)
                    guard status.paired else {
                        throw BackendError.message("Pairing no longer exists. Pair again before monitoring.")
                    }
                    if let commandID, status.monitoringCommand?.id != commandID { return }
                    if !settingsDirty, generation == settingsGeneration { applyRemote(status.configuration) }
                } catch let failure as BackendError {
                    if case .response(let status, _) = failure, status >= 500 {
                        deliveryStatus = "Monitoring locally. Backend unavailable; alerts will retry."
                    } else { throw failure }
                } catch let failure as URLError {
                    deliveryStatus = "Monitoring locally. Internet unavailable (\(failure.code.rawValue)); alerts will retry."
                }
            }
            guard revision == environmentRevision, control == controlGeneration, role == .listener, storageHealthy else { return }
            guard deadline.map({ currentTime() < $0 }) ?? true else { return }
            try await audio.start()
            guard revision == environmentRevision, control == controlGeneration,
                  deadline.map({ currentTime() < $0 }) ?? true else { audio.stop(); return }
            engine.markMonitoring(true); persist()
            guard storageHealthy else { return }
            lastSampleAt = currentTime(); needsRestart = false; error = nil
            log.record("monitoring_started")
            recordBatterySample()
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription; log.record("monitoring_start_failed", error: error) }
    }
    func stop(remote: Bool = false) {
        if !remote { controlGeneration += 1 }
        if !remote, role == .listener, paired { queueLocalMonitoringReport(false) }
        let wasActive = monitoring || recoveringAudio
        audio.stop(); engine.suspend(); persist()
        if wasActive { log.record("monitoring_stopped") }
        recordBatterySample()
    }
    private var localMonitoringReportKey: String { pairingKey + "|localMonitoringReport" }
    private var monitoringControlPendingKey: String { pairingKey + "|pendingMonitoringCommand" }
    private func persistMonitoringControl() {
        defaults.set(pendingMonitoringCommand.flatMap { try? JSONEncoder().encode($0) }, forKey: monitoringControlPendingKey)
        defaults.set(monitoringControlDeadline, forKey: monitoringControlPendingKey + "|deadline")
        defaults.set(monitoringControlError, forKey: monitoringControlPendingKey + "|error")
    }
    private func queueLocalMonitoringReport(_ enabled: Bool) {
        localMonitoringReport = (UUID(), enabled)
        defaults.set(localMonitoringReport?.id.uuidString, forKey: localMonitoringReportKey)
        lastRefreshAt = .distantPast
    }
    private func resetMonitoringControl() {
        controlGeneration += 1
        localMonitoringReport = nil; pendingMonitoringCommand = nil
        monitoringControlDeadline = nil; monitoringControlError = nil; monitoringControlMessage = nil
    }
    func requestMonitoring(_ enabled: Bool) async {
        guard role == .parent, paired, !requestingMonitoring, !managingDevice else { return }
        requestingMonitoring = true; defer { requestingMonitoring = false }
        let revision = environmentRevision, id = UUID()
        pendingMonitoringCommand = MonitoringCommand(id: id, enabled: enabled, status: "pending",
            createdAt: currentTime(), expiresAt: currentTime().addingTimeInterval(30))
        monitoringControlDeadline = currentTime().addingTimeInterval(30)
        monitoringControlError = nil
        persistMonitoringControl()
        monitoringControlMessage = enabled ? "Start requested · Waiting for the nursery microphone…" : "Stop requested · Waiting for nursery confirmation…"
        do {
            let client = try await registeredClient()
            let command = try await client.setMonitoring(enabled, id: id)
            guard revision == environmentRevision, pendingMonitoringCommand?.id == id else { return }
            pendingMonitoringCommand = command
            persistMonitoringControl()
            nextParentRefreshAt = .distantPast
            Task { await refreshParent() }
        } catch {
            guard revision == environmentRevision else { return }
            // A lost response can follow a successful request. Keep checking the
            // microphone until the deadline instead of presenting a false failure.
            monitoringControlMessage = "Connection interrupted · Checking nursery monitoring…"
            if case BackendError.response(let code, _) = error, (400..<500).contains(code) {
                monitoringControlDeadline = .distantPast
            }
            log.record("monitoring_control_failed", error: error)
            persistMonitoringControl()
        }
        checkMonitoringControlDeadline()
    }
    private func checkMonitoringControlDeadline() {
        guard let command = pendingMonitoringCommand, let deadline = monitoringControlDeadline, currentTime() >= deadline else { return }
        monitoringControlError = command.enabled
            ? "Monitoring could not be started or verified. Open Crib Service on the nursery phone, check microphone permission and internet access, then try again. Do not rely on alerts until Monitoring is confirmed."
            : "Monitoring stop could not be verified. Check the nursery phone. It may still be listening; repeating crying alerts were cancelled if the service received your request."
        monitoringControlMessage = nil; pendingMonitoringCommand = nil; monitoringControlDeadline = nil
        persistMonitoringControl()
    }
    private func reconcileMonitoringControl(_ status: ParentStatus) {
        guard let pending = pendingMonitoringCommand else {
            // A heartbeat may arrive after an earlier timeout or startup failure.
            // Recover persisted warnings as soon as the actual state is verified.
            if monitoringControlError != nil, let command = status.monitoringCommand {
                _ = confirmMonitoringControl(command, status: status)
            }
            return
        }
        guard status.paired else {
            monitoringControlError = "Monitoring could not be changed because the phones are no longer paired."
            pendingMonitoringCommand = nil; monitoringControlDeadline = nil; monitoringControlMessage = nil
            persistMonitoringControl()
            return
        }
        guard let command = status.monitoringCommand, command.id == pending.id else {
            checkMonitoringControlDeadline(); return
        }
        // Audio-route recovery can outlive the initial command callback. A fresh
        // post-request heartbeat proves the requested state even if that callback
        // reported failure or its acknowledgement was lost.
        if !confirmMonitoringControl(command, status: status) { checkMonitoringControlDeadline() }
    }
    @discardableResult private func confirmMonitoringControl(_ command: MonitoringCommand, status: ParentStatus) -> Bool {
        guard status.paired, status.monitoring == command.enabled,
              let heartbeat = status.lastHeartbeat, let serverTime = status.serverTime,
              heartbeat >= command.createdAt, (0...30).contains(serverTime.timeIntervalSince(heartbeat)) else { return false }
        monitoringControlMessage = command.enabled ? "Monitoring confirmed on nursery phone" : "Monitoring stopped on nursery phone"
        monitoringControlError = nil; pendingMonitoringCommand = nil; monitoringControlDeadline = nil
        persistMonitoringControl()
        return true
    }
    private func applyMonitoringCommand(_ command: MonitoringCommand?, serverTime: Date?, fetchedAt: Date, using client: any BackendServing) async {
        guard let command, command.status == "pending", !starting, !managingDevice, localMonitoringReport == nil else { return }
        let remaining = command.expiresAt.timeIntervalSince(serverTime ?? command.expiresAt)
        let deadline = fetchedAt.addingTimeInterval(remaining)
        guard currentTime() < deadline else { return }
        let revision = environmentRevision, control = controlGeneration
        let handledKey = pairingKey + "|handledMonitoringCommand"
        // Persist before execution so a lost acknowledgement never replays a Start.
        if defaults.string(forKey: handledKey) != command.id.uuidString {
            defaults.set(command.id.uuidString, forKey: handledKey)
            if command.enabled { await start(remote: true, deadline: deadline, commandID: command.id) }
            else { stop(remote: true) }
        }
        guard revision == environmentRevision, control == controlGeneration, role == .listener else { return }
        // A route change can cancel the original audio.start() while recovery
        // continues. Leave this command pending and confirm on the next poll.
        guard !recoveringAudio else { return }
        let succeeded = command.enabled ? monitoring : !monitoring && !recoveringAudio
        do {
            try await client.completeMonitoring(command.id, succeeded: succeeded)
            guard revision == environmentRevision, control == controlGeneration else { return }
            queueHeartbeat()
        } catch { log.record("monitoring_control_failed", error: error) }
    }
    func sendTestPush() async {
        guard !sendingTestPush, role == .listener, paired else { return }
        guard safetyAccepted, storageHealthy, let credential else {
            error = "Resolve local storage and device registration before sending a test push."; return
        }
        sendingTestPush = true; defer { sendingTestPush = false }
        let alert = engine.queueTestAlert(listenerId: credential.deviceId)
        persist()
        guard storageHealthy else { return }
        latestTestEventID = alert.eventId
        let queuedStatus = connectivity.available ? "Test push queued. Contacting the Parent…" : "Test push queued. It will send when internet returns."
        testPushStatus = queuedStatus
        log.record("test_push_queued")
        await tick()
        if latestTestEventID == alert.eventId, testPushStatus == queuedStatus,
           engine.snapshot.pending.contains(where: { $0.alert.eventId == alert.eventId }) {
            testPushStatus = "Test push queued for retry. \(deliveryStatus)"
        }
    }
    private func audioChanged(_ status: AudioCaptureStatus) {
        if calibrationActive {
            switch status {
            case .active: audioStatus = "Checking sound · Monitoring paused"
            case .stopped: break
            case .recovering, .failed:
                calibrationMessage = "Sound check interrupted. Start again when the microphone is available."
                calibrationPhase = "idle"; audio.stop()
            }
            return
        }
        let wasActive = monitoring || recoveringAudio
        let wasRecovering = recoveringAudio
        monitoringGeneration += 1; lastHeartbeatAt = .distantPast
        monitoring = false; recoveringAudio = false
        switch status {
        case .active:
            log.record("audio_active")
            monitoring = true; audioStatus = "Microphone active"
            engine.markMonitoring(true); lastSampleAt = currentTime(); lastHeartbeatAt = .distantPast
            needsRestart = false; error = nil
            if !wasActive || wasRecovering { engine.recordTimeline(wasRecovering ? "audio_resumed" : "monitoring_started", at: currentTime()); persist() }
            queueHeartbeat()
        case .stopped:
            audioStatus = "Stopped"
            if wasActive { engine.recordTimeline("monitoring_stopped", at: currentTime()) }
            engine.suspend(); persist()
            if wasActive { queueHeartbeat() }
        case .recovering(let message):
            // Route changes and resumable interruptions need no user action.
            // Suspend detection so the missing audio never extends an episode.
            recoveringAudio = true; audioStatus = message; needsRestart = false
            if wasActive && !wasRecovering { engine.recordTimeline("audio_interrupted", at: currentTime()) }
            engine.suspend(); persist()
            log.record("audio_recovering"); queueHeartbeat()
        case .failed(let message):
            audioStatus = message
            if wasActive { engine.recordTimeline("audio_interrupted", at: currentTime()) }
            engine.suspend(); persist()
            error = message; needsRestart = true
            log.record("audio_interrupted"); queueHeartbeat()
        }
    }
    private func consume(_ sample: AudioLevelSample) {
        if calibrationActive {
            guard sample.dbFS.isFinite else { return }
            currentDBFS = sample.dbFS
            if calibrationPhase != "waiting" { calibration.record(sample.dbFS, background: calibrationPhase == "background") }
            return
        }
        guard monitoring, let credential, storageHealthy else { return }
        lastSampleAt = sample.timestamp; currentDBFS = sample.dbFS
        meter.append(sample.dbFS); meter = Array(meter.suffix(32))
        let before = state; let quietBefore = engine.detector.quietSince
        let events = engine.consume(sample, listenerId: credential.deviceId)
        if state != before {
            log.record(state == .crying ? "crying_started" : state == .possibleCry ? "possible_cry" : "crying_ended")
        }
        if state == .crying, engine.detector.quietSince != quietBefore {
            log.record(engine.detector.quietSince == nil ? "crying_resumed" : "quiet_gap_started")
        }
        if !events.isEmpty { log.record("alert_threshold_reached") }
        if !events.isEmpty || before != state || sample.timestamp.timeIntervalSince(lastSavedAt) >= 5 { persist(); lastSavedAt = sample.timestamp }
    }
    private func persist() {
        guard let store, storageHealthy else { return }
        if let credential { engine.scopeTimeline(to: "\(backendURL)|\(credential.deviceId)") }
        do { try store.save(engine.snapshot) }
        catch {
            storageHealthy = false; storageFailure = error; monitoring = false; audio.stop()
            self.error = "Monitoring stopped: metadata could not be saved. \(error.localizedDescription)"
            log.record("metadata_write_failed", error: error)
        }
    }
    func saveSettings(_ config: MonitoringConfiguration) {
        guard config.isValid else { error = "Check alert timing, quiet reset, repeat interval, and sound threshold (−60 to −10 dBFS)."; return }
        configuration = config; engine.configure(config); persist()
        settingsGeneration += 1
        settingsDirty = true; defaults.set(true, forKey: "settingsDirty")
    }
    private func applyRemote(_ config: MonitoringConfiguration) {
        guard config.isValid else { return }
        configuration = config; engine.configure(config); persist()
    }
    private func updateLocalState() {
        now = currentTime(); let device = UIDevice.current
        batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let powered = device.batteryState == .charging || device.batteryState == .full
        if powerConnected != powered, role == .listener, paired {
            engine.recordTimeline(powered ? "power_connected" : "power_disconnected", at: now); persist()
        }
        powerConnected = powered
        if monitoring, let lastSampleAt, now.timeIntervalSince(lastSampleAt) > 3 {
            stop(); error = "Monitoring stopped: microphone samples stopped arriving."; needsRestart = true; log.record("audio_stalled")
        }
        recordBatterySample()
        scheduleHeartbeatIfDue()
        checkMonitoringControlDeadline()
        if let retry = parentWarningRetryAt, now >= retry, parentWarningTask == nil {
            parentWarningUpdatePending = true
            dispatchParentConnectionWarning()
        }
    }
    private func recordBatterySample() {
        guard role == .listener else { return }
        let device = UIDevice.current
        log.battery(batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                    powerConnected: device.batteryState == .unknown ? nil : device.batteryState == .charging || device.batteryState == .full,
                    monitoring: monitoring || recoveringAudio, audioActive: monitoring && !recoveringAudio,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    appActive: UIApplication.shared.applicationState == .active, at: currentTime())
    }
    private var parentWarningScope: String { "\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private func setParentConnectionDeadline(_ deadline: Date?, force: Bool = false) {
        guard force || deadline != parentConnectionDeadline else { return }
        parentConnectionDeadline = deadline
        if let deadline {
            defaults.set(deadline, forKey: Self.parentWarningDeadlineKey)
            defaults.set(parentWarningScope, forKey: Self.parentWarningScopeKey)
        } else {
            defaults.removeObject(forKey: Self.parentWarningDeadlineKey)
            defaults.removeObject(forKey: Self.parentWarningScopeKey)
        }
        parentWarningUpdatePending = true
        parentWarningRetryAt = nil
        dispatchParentConnectionWarning()
    }
    private func dispatchParentConnectionWarning() {
        guard parentWarningTask == nil else { return }
        parentWarningTask = Task { [weak self] in
            guard let self else { return }
            while self.parentWarningUpdatePending {
                let deadline = self.parentConnectionDeadline
                self.parentWarningUpdatePending = false
                do {
                    try await self.notifications.setParentConnectionDeadline(deadline)
                    if let deadline { self.defaults.set(deadline, forKey: Self.parentWarningScheduledKey) }
                    else { self.defaults.removeObject(forKey: Self.parentWarningScheduledKey) }
                    if !self.parentWarningUpdatePending {
                        self.parentConnectionWarningError = nil; self.parentWarningRetryAt = nil
                    }
                    self.log.record(deadline == nil ? "parent_connection_warning_cancelled" : "parent_connection_warning_armed")
                } catch {
                    if !self.parentWarningUpdatePending {
                        self.parentConnectionWarningError = error.localizedDescription
                        self.parentWarningRetryAt = self.currentTime().addingTimeInterval(15)
                    }
                    self.log.record("parent_connection_warning_failed", error: error)
                }
            }
            self.parentWarningTask = nil
        }
    }
    func tick() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-offline") { return }
        #endif
        guard !managingDevice else { return }
        checkMonitoringControlDeadline()
        scheduleHeartbeatIfDue()
        guard connectivity.available else {
            deliveryStatus = connectivity.checked ? "Internet unavailable. Alerts cannot currently be delivered." : "Checking connectivity…"
            return
        }
        guard !backendURL.isEmpty, role != nil else { return }
        do {
            let revision = environmentRevision
            let client = try await registeredClient()
            guard revision == environmentRevision else { return }
            synchronizeSettings(using: client)
            guard revision == environmentRevision else { return }
            if role == .parent {
                if let pushToken, pushToken != uploadedToken { try await client.pushToken(pushToken); uploadedToken = pushToken; log.record("push_token_uploaded") }
                if now.timeIntervalSince(lastWatchRetryAt) >= 15 {
                    lastWatchRetryAt = now
                    if watch.activated, !watch.installed, parentStatus?.watchPushRegistered == true {
                        pendingWatchToken = nil; hasPendingWatchToken = true
                    }
                    await syncWatchCommands()
                }
                if currentTime() >= nextParentRefreshAt { await refreshParent() }
            } else if role == .listener {
                refreshListenerPairing(using: client)
                guard paired else { return }
                scheduleHeartbeatIfDue()
                guard revision == environmentRevision, role == .listener, storageHealthy else { return }
                await alerts.deliverReady(snapshot.pending, listenerId: client.credential.deviceId, now: currentTime(), sender: client) { alert, result in
                    guard revision == environmentRevision else { return }
                    switch result {
                    case .success(let receipt) where receipt.status == "sent":
                        engine.delivered(alert.eventId, at: Date()); log.record("alert_apns_accepted")
                        deliveryStatus = "Connected · APNs accepted alert"
                    case .success(let receipt) where receipt.status == "acknowledged":
                        engine.acknowledged(alert.eventId)
                        log.record("alert_acknowledged")
                        deliveryStatus = "Alert acknowledged on Parent"
                    case .success(let receipt) where receipt.status == "failed":
                        engine.permanentlyFailed(alert.eventId, at: currentTime())
                        deliveryStatus = "Alert delivery failed. Check Worker/APNs diagnostics."
                        log.record("alert_delivery_failed")
                    case .success(let receipt):
                        engine.failed(alert.eventId, at: Date())
                        switch receipt.status {
                        case "uncertain": deliveryStatus = "Alert delivery uncertain. Check the Parent iPhone."; log.record("alert_uncertain")
                        case "blocked": deliveryStatus = "Alert blocked. Open Parent Mode and enable notifications."; log.record("alert_blocked")
                        default: deliveryStatus = "Alert queued on server (\(receipt.status))."; log.record("alert_server_pending")
                        }
                    case .failure(let failure):
                        engine.failed(alert.eventId, at: Date()); deliveryStatus = "Alert pending: \(failure.localizedDescription)"
                        log.record("alert_retry_scheduled", error: failure)
                    }
                    if alert.eventId == latestTestEventID {
                        if case .success(let receipt) = result, receipt.status == "sent" {
                            testPushStatus = "APNs accepted the test push. Check your registered Apple Watch, or the Parent iPhone if Watch alerts are not set up."
                            log.record("test_push_apns_accepted")
                        } else { testPushStatus = "Test push: \(deliveryStatus)" }
                    }
                    persist()
                }
            }
        } catch { deliveryStatus = "Backend unavailable: \(error.localizedDescription)"; log.record("backend_unavailable", error: error) }
    }
    private func synchronizeSettings(using client: any BackendServing) {
        guard settingsDirty, paired, settingsTask == nil else { return }
        let revision = environmentRevision, generation = settingsGeneration
        let config = configuration
        settingsTask = Task { [weak self] in
            defer { self?.settingsTask = nil }
            do {
                try await client.settings(config)
                guard let self, revision == self.environmentRevision,
                      generation == self.settingsGeneration else { return }
                self.settingsDirty = false; self.defaults.set(false, forKey: "settingsDirty")
                self.log.record("settings_synced")
                // Invalidate remote reads begun before this upload finished.
                self.settingsGeneration += 1
            } catch {
                guard let self, revision == self.environmentRevision else { return }
                self.deliveryStatus = "Settings sync pending: \(error.localizedDescription)"
                self.log.record("settings_sync_failed", error: error)
            }
        }
    }
    private var heartbeatKey: String? {
        guard role == .listener, let credential else { return nil }
        return "\(backendURL)|\(credential.deviceId)"
    }
    private func heartbeatValue(listenerID: UUID) -> Heartbeat {
        func remote(_ episode: CryEpisode) -> RemoteEpisode {
            RemoteEpisode(id: episode.id, startedAt: episode.startedAt, endedAt: episode.endedAt, alertSentAt: episode.alertSentAt)
        }
        return Heartbeat(listenerId: listenerID, timestamp: currentTime(), monitoring: monitoring,
                         batteryLevel: batteryLevel, powerConnected: powerConnected, state: state,
                         currentEpisode: snapshot.current.map(remote), episodes: Array(snapshot.history.prefix(100)).map(remote), appliedConfiguration: configuration,
                         timelineEvents: Array(snapshot.timelineEvents.filter { snapshot.pendingTimelineIDs.contains($0.id) }.prefix(100)))
    }
    private func scheduleHeartbeatIfDue() {
        guard !managingDevice else { return }
        let available = connectivity.available
        if available != lastConnectivityAvailable {
            log.record(available ? "network_available" : "network_unavailable")
            if role == .listener, paired {
                engine.recordTimeline(available ? "network_restored" : "network_lost", at: currentTime()); persist()
            }
        }
        if available && !lastConnectivityAvailable {
            // A recovered path gets one immediate attempt, then normal backoff.
            for key in Array(pendingHeartbeats.keys) { pendingHeartbeats[key]?.nextAttemptAt = currentTime() }
        }
        lastConnectivityAvailable = available
        if (monitoring || !snapshot.pendingTimelineIDs.isEmpty), let key = heartbeatKey, pendingHeartbeats[key] == nil,
           currentTime().timeIntervalSince(lastHeartbeatAt) >= 15 {
            queueHeartbeat()
        }
        dispatchHeartbeatIfReady()
    }
    /// Capture the Listener identity before a role change. A new state replaces
    /// obsolete queued work, while an in-flight request finishes before the next.
    private func queueHeartbeat() {
        guard paired, let key = heartbeatKey, let client = try? client() else { return }
        pendingHeartbeats[key] = HeartbeatRequest(client: client, value: heartbeatValue(listenerID: client.credential.deviceId),
                                                  revision: environmentRevision, settingsGeneration: settingsGeneration,
                                                  observation: monitoringGeneration)
        dispatchHeartbeatIfReady()
    }
    private func dispatchHeartbeatIfReady() {
        guard connectivity.available, heartbeatTask == nil,
              let entry = pendingHeartbeats.filter({ $0.value.nextAttemptAt <= currentTime() })
                .min(by: { $0.value.nextAttemptAt < $1.value.nextAttemptAt }) else { return }
        let key = entry.key
        var request = entry.value
        if request.revision == environmentRevision, request.observation == monitoringGeneration {
            // Refresh metadata at dispatch, without resetting a retry's backoff.
            request.value = heartbeatValue(listenerID: request.client.credential.deviceId)
            request.settingsGeneration = settingsGeneration
        }
        let attempt = request
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            // A stop/restart may have superseded this task before it even ran.
            guard self.pendingHeartbeats[key]?.id == attempt.id else {
                self.heartbeatTask = nil; self.scheduleHeartbeatIfDue(); return
            }
            do {
                let config = try await attempt.client.heartbeat(attempt.value)
                if attempt.revision == self.environmentRevision {
                    self.engine.uploadedTimeline(Set((attempt.value.timelineEvents ?? []).map(\.id))); self.persist()
                }
                if attempt.failures > 0 { self.log.record("heartbeat_recovered") }
                if self.pendingHeartbeats[key]?.id == attempt.id { self.pendingHeartbeats.removeValue(forKey: key) }
                if attempt.revision == self.environmentRevision, attempt.observation == self.monitoringGeneration {
                    self.lastHeartbeatAt = self.currentTime(); self.deliveryStatus = "Connected"
                    if !self.settingsDirty, attempt.settingsGeneration == self.settingsGeneration {
                        self.applyRemote(config)
                        if attempt.value.appliedConfiguration != config { self.queueHeartbeat() }
                    }
                }
            } catch {
                if var pending = self.pendingHeartbeats[key], pending.id == attempt.id {
                    pending.failures += 1
                    let base = min(30.0, pow(2, Double(min(pending.failures, 5))))
                    let delay = min(30, base * min(1.1, max(0.9, self.heartbeatJitter())))
                    pending.nextAttemptAt = self.currentTime().addingTimeInterval(delay)
                    self.pendingHeartbeats[key] = pending
                    self.log.record("heartbeat_retry_scheduled", error: error)
                }
                if attempt.revision == self.environmentRevision, attempt.observation == self.monitoringGeneration {
                    self.deliveryStatus = "Monitoring status update pending: \(error.localizedDescription)"
                }
            }
            self.heartbeatTask = nil
            self.scheduleHeartbeatIfDue()
        }
    }
    func refreshParent() async {
        guard role == .parent else { return }
        if let task = parentRefreshTask { await task.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchParentStatus()
        }
        parentRefreshTask = task
        await task.value
        parentRefreshTask = nil
    }
    private func fetchParentStatus() async {
        let revision = environmentRevision, generation = settingsGeneration
        do {
            let client = try await registeredClient(); let status = try await client.status()
            guard revision == environmentRevision, role == .parent else { return }
            if !status.paired || (parentStatus?.pairingID != nil && parentStatus?.pairingID != status.pairingID) { timeline = nil; timelineError = nil }
            parentStatus = status; paired = status.paired; defaults.set(paired, forKey: pairingKey)
            reconcileMonitoringControl(status)
            // Only a successful server response renews the local warning. A failed
            // or suspended request leaves the previous OS notification untouched.
            let warn = localConnectionWarningEnabled && status.paired && status.monitoring == true
            setParentConnectionDeadline(warn ? currentTime().addingTimeInterval(ConnectionWarningNotification.timeout) : nil)
            if !settingsDirty, generation == settingsGeneration { applyRemote(status.configuration) }
            nextParentRefreshAt = currentTime().addingTimeInterval(pendingMonitoringCommand != nil ? 1 : status.refreshDelay())
            deliveryStatus = "Connected"; error = nil
            publishWatch()
        } catch {
            guard revision == environmentRevision, role == .parent else { return }
            deliveryStatus = "Status unavailable: \(error.localizedDescription)"; parentStatus = nil
            nextParentRefreshAt = currentTime().addingTimeInterval(pendingMonitoringCommand == nil ? 15 : 1)
            checkMonitoringControlDeadline()
            log.record("parent_status_failed", error: error)
            publishWatch()
        }
    }
    private func observePairing(_ status: ParentStatus) {
        let identityKey = pairingKey + "|identity"
        let previous = defaults.string(forKey: identityKey)
        if (!status.paired && paired) || (previous != nil && status.pairingID != nil && previous != status.pairingID) {
            stop(); pendingHeartbeats.removeAll(); timeline = nil; timelineError = nil
            engine = CrySessionManager(); configuration = engine.snapshot.configuration; persist()
            settingsDirty = false; defaults.set(false, forKey: "settingsDirty")
            needsRestart = false
        }
        paired = status.paired; defaults.set(paired, forKey: pairingKey)
        if let identity = status.pairingID { defaults.set(identity, forKey: identityKey) }
        else { defaults.removeObject(forKey: identityKey) }
    }
    private func refreshListenerPairing(using client: any BackendServing) {
        guard listenerStatusTask == nil, currentTime().timeIntervalSince(lastRefreshAt) >= 3 else { return }
        lastRefreshAt = currentTime()
        let revision = environmentRevision, control = controlGeneration
        listenerStatusTask = Task { [weak self] in
            defer { self?.listenerStatusTask = nil }
            do {
                guard let self else { return }
                if let report = self.localMonitoringReport {
                    do {
                        _ = try await client.setMonitoring(report.enabled, id: report.id)
                        guard revision == self.environmentRevision, control == self.controlGeneration else { return }
                        if self.localMonitoringReport?.id == report.id {
                            self.localMonitoringReport = nil; self.defaults.removeObject(forKey: self.localMonitoringReportKey)
                        }
                    } catch { self.log.record("monitoring_control_failed", error: error) }
                }
                let fetchedAt = self.currentTime()
                let status = try await client.status()
                guard revision == self.environmentRevision, control == self.controlGeneration, self.role == .listener else { return }
                self.observePairing(status)
                if status.paired { await self.applyMonitoringCommand(status.monitoringCommand, serverTime: status.serverTime, fetchedAt: fetchedAt, using: client) }
            } catch {
                guard let self, revision == self.environmentRevision else { return }
                self.log.record("listener_status_failed", error: error)
            }
        }
    }
    func refreshTimeline() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-timeline") { return }
        #endif
        guard !loadingTimeline, paired else { return }
        loadingTimeline = true; defer { loadingTimeline = false }
        let revision = environmentRevision
        do {
            let client = try await registeredClient()
            let page = try await client.timeline()
            guard revision == environmentRevision, paired else { return }
            timeline = page; timelineClockOffset = page.serverTime.timeIntervalSince(currentTime()); timelineError = nil
        } catch {
            guard revision == environmentRevision else { return }
            timelineError = "Could not refresh timeline. \(error.localizedDescription)"
            log.record("timeline_failed", error: error)
        }
    }
    #if DEBUG
    private func seedTimelineForUITest() {
        role = .parent; safetyAccepted = true; paired = true
        let now = currentTime(), episode = UUID().uuidString
        func time(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }
        parentStatus = ParentStatus(paired: true, lastHeartbeat: now, monitoring: true, state: .quiet, configuration: configuration)
        timeline = TimelineResponse(paired: true, serverTime: now, availableSince: time(-13 * 3600), events: [
            TimelineEvent(kind: "monitoring_started", occurredAt: time(-48 * 60)),
            TimelineEvent(kind: "monitoring_stopped", occurredAt: time(-50 * 60)),
            TimelineEvent(kind: "cry_ended", occurredAt: time(-4 * 3600 + 78), endAt: time(-4 * 3600), episodeID: episode),
            TimelineEvent(kind: "alert_acknowledged", occurredAt: time(-4 * 3600 + 38), endAt: time(-4 * 3600 + 98), episodeID: episode),
            TimelineEvent(kind: "alert", occurredAt: time(-4 * 3600 + 5), endAt: time(-4 * 3600 + 35), episodeID: episode, target: "watch", count: 7, status: "sent"),
            TimelineEvent(kind: "cry_started", occurredAt: time(-4 * 3600), episodeID: episode),
            TimelineEvent(kind: "connection_restored", occurredAt: time(-5 * 3600), endAt: time(-5 * 3600 - 444)),
            TimelineEvent(kind: "monitoring_observed", occurredAt: time(-5 * 3600)),
            TimelineEvent(kind: "heartbeat_missing", occurredAt: time(-5 * 3600 - 264), endAt: time(-5 * 3600 - 444)),
            TimelineEvent(kind: "monitoring_started", occurredAt: time(-11 * 3600))
        ], truncated: false)
    }
    #endif
    func acknowledge(_ id: UUID) async {
        do { let client = try await registeredClient(); try await client.acknowledge(id); await refreshParent() }
        catch { self.error = error.localizedDescription; log.record("acknowledgement_failed", error: error) }
    }
    var canTestWatchAlert: Bool {
        role == .parent && paired && parentStatus?.watchPushRegistered == true && !sendingTestPush && !managingDevice
    }
    @discardableResult func requestParentTest(requiresWatch: Bool = false) async -> Bool {
        guard role == .parent, paired, !sendingTestPush, !managingDevice else { return false }
        sendingTestPush = true; defer { sendingTestPush = false }
        let revision = environmentRevision
        if requiresWatch {
            await refreshParent()
            guard revision == environmentRevision, role == .parent, paired else { return false }
            guard parentStatus?.watchPushRegistered == true else {
                testPushStatus = "Open Crib Service on your Watch and enable alerts, then refresh Watch registration here."
                return false
            }
        }
        testPushStatus = "Sending a real test notification…"
        do {
            let client = try await registeredClient()
            guard revision == environmentRevision else { return false }
            try await client.requestTestPush()
            guard revision == environmentRevision else { return false }
            testPushStatus = requiresWatch
                ? "Test requested. Lock this iPhone and wait for a test notification and wrist tap on your Watch. Confirm only if you feel it."
                : "Test requested. Lock this iPhone and check your receiving phone or Watch, then confirm receipt below."
            await refreshParent()
            return revision == environmentRevision && role == .parent && paired
        } catch {
            guard revision == environmentRevision else { return false }
            testPushStatus = "Test could not be sent: \(error.localizedDescription)"; log.record("test_push_failed", error: error)
            return false
        }
    }
    func setLocalConnectionWarning(_ enabled: Bool) {
        guard enabled != localConnectionWarningEnabled else { return }
        localConnectionWarningEnabled = enabled
        defaults.set(enabled, forKey: "localConnectionWarningEnabled")
        if !enabled { setParentConnectionDeadline(nil, force: true) }
        publishWatch()
        // Enabling requires a fresh successful check before either device arms.
        if enabled, role == .parent { Task { await refreshParent() } }
    }
    func setKeepScreenAwake(_ enabled: Bool) {
        keepScreenAwake = enabled
        defaults.set(enabled, forKey: "keepScreenAwake")
    }
    func setConnectionAlerts(_ enabled: Bool) async {
        guard role == .parent, !changingConnectionAlerts else { return }
        changingConnectionAlerts = true; defer { changingConnectionAlerts = false }
        let revision = environmentRevision
        do {
            let client = try await registeredClient(); try await client.connectionAlerts(enabled)
            guard revision == environmentRevision, role == .parent else { return }
            await refreshParent()
        }
        catch { self.error = error.localizedDescription; log.record("connection_preferences_failed", error: error) }
    }
    func removePairing(deleteDevice: Bool) async {
        guard !managingDevice else { return }
        managingDevice = true
        defer { managingDevice = false }
        cancelCalibration(); stop()
        environmentRevision += 1
        pendingHeartbeats.removeAll(); heartbeatTask?.cancel(); settingsTask?.cancel(); listenerStatusTask?.cancel()
        let old = credential
        let watchKeys = [watchAcknowledgementsKey, watchConfirmedKey, watchDiscardedKey, watchRegistrationKey, watchRegistrationDateKey]
        do {
            let client = try await registeredClient()
            if deleteDevice { try await client.deleteDevice() } else { try await client.unpair() }
            if deleteDevice, let old {
                let replacement = try keychain.create(role: old.role)
                try keychain.save(replacement, environment: backendURL)
                credential = replacement
            }
            for key in watchKeys { defaults.removeObject(forKey: key) }
            defaults.removeObject(forKey: localMonitoringReportKey)
            defaults.removeObject(forKey: monitoringControlPendingKey)
            defaults.removeObject(forKey: monitoringControlPendingKey + "|deadline")
            defaults.removeObject(forKey: monitoringControlPendingKey + "|error")
            defaults.removeObject(forKey: pairingKey + "|handledMonitoringCommand")
            resetMonitoringControl()
            defaults.removeObject(forKey: pairingKey + "|identity")
            paired = false; defaults.set(false, forKey: pairingKey)
            setParentConnectionDeadline(nil)
            timeline = nil; timelineError = nil
            parentStatus = nil; pairingCode = nil; needsRestart = false
            settingsDirty = false; defaults.set(false, forKey: "settingsDirty")
            engine = CrySessionManager(); configuration = engine.snapshot.configuration; persist()
            calibration = SoundCalibration(); testPushStatus = nil; latestTestEventID = nil
            hasPendingWatchToken = false; pendingWatchToken = nil
            if deleteDevice { role = nil; defaults.removeObject(forKey: "role"); uploadedToken = nil }
            deliveryStatus = "Pair a device to reconnect"; error = nil
            publishWatch()
        } catch { self.error = "Could not finish: \(error.localizedDescription). Monitoring is stopped. Try again."; log.record("device_removal_failed", error: error) }
    }
    func beginCalibration() async {
        guard role == .listener, !monitoring, !starting, !recoveringAudio, !calibrationActive else { return }
        calibration = SoundCalibration(); calibrationMessage = nil; calibrationPhase = "background"
        let revision = environmentRevision
        guard await audio.requestPermission() else {
            calibrationPhase = "idle"; calibrationMessage = "Enable Microphone in iPhone Settings to check sound."; return
        }
        guard calibrationActive, revision == environmentRevision else { return }
        do { try await audio.start() }
        catch { calibrationPhase = "idle"; audio.stop(); calibrationMessage = error.localizedDescription; log.record("calibration_failed", error: error) }
    }
    func finishCalibrationBackground() {
        guard calibrationPhase == "background" else { return }
        guard calibration.background.count >= 20 else {
            cancelCalibration(); calibrationMessage = "Too few microphone samples. Keep this screen open and try again."; return
        }
        calibrationPhase = "waiting"
    }
    func beginCalibrationSample() { if calibrationPhase == "waiting" { calibrationPhase = "sample" } }
    func finishCalibrationSample() {
        guard calibrationPhase == "sample" else { return }
        calibrationPhase = "complete"; audio.stop()
        calibrationMessage = calibration.recommendedThreshold == nil
            ? "No available threshold safely separates this sample from room noise. Reduce nearby fan or white-noise volume, or move the Listener closer to the sound source, then repeat the check."
            : "A threshold can separate this sample from background noise. This check does not prove cry detection or notification delivery."
    }
    func cancelCalibration() {
        guard calibrationActive else { return }
        calibrationPhase = "idle"; audio.stop()
    }
    func foreground() async {
        log.record("foreground")
        #if DEBUG
        // This offline UI fixture supplies a complete paired snapshot. Loading
        // real credentials here would replace it with the empty test defaults.
        if ProcessInfo.processInfo.arguments.contains("--uitesting-timeline") { return }
        #endif
        if credential == nil { loadCredential() }
        if role == .parent { await notifications.register(); await refreshParent() }
        if role == .listener && needsRestart && !monitoring && !starting && !recoveringAudio { error = "Monitoring needs to be restarted. Check the microphone and tap Start Monitoring." }
    }

    private var watchAcknowledgementsKey: String { "watchAcknowledgements|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private var watchConfirmedKey: String { "watchConfirmed|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private var watchDiscardedKey: String { "watchDiscarded|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private var watchRegistrationKey: String { "watchRegistration|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private var watchRegistrationDateKey: String { watchRegistrationKey + "|date" }

    private func watchSnapshot(message: String? = nil) -> WatchSnapshot {
        var value = WatchSnapshot()
        value.updatedAt = currentTime()
        value.parentMode = role == .parent
        value.paired = value.parentMode && paired
        value.statusAvailable = value.parentMode && parentStatus != nil
        value.lastHeartbeat = value.parentMode ? parentStatus?.lastHeartbeat : nil
        value.monitoring = value.parentMode && parentStatus?.monitoring == true
        value.connectionWarningSupported = true
        value.localConnectionWarningEnabled = localConnectionWarningEnabled
        value.connectionWarningDeadline = value.parentMode && paired ? parentConnectionDeadline : nil
        value.state = value.parentMode ? parentStatus?.state : nil
        value.alertDuration = configuration.alertDuration
        value.snoozeDuration = configuration.snoozeDuration
        value.watchPushRegistered = value.parentMode && parentStatus?.watchPushRegistered == true
        value.alertsMutedUntil = value.parentMode ? parentStatus?.alertsMutedUntil : nil
        value.acknowledgedEventId = defaults.string(forKey: watchConfirmedKey).flatMap(UUID.init(uuidString:))
        value.discardedAcknowledgementEventId = defaults.string(forKey: watchDiscardedKey).flatMap(UUID.init(uuidString:))
        if value.parentMode, let alert = activeAlert {
            value.alert = WatchCryAlert(eventId: alert.eventId, episodeId: alert.episodeId, startedAt: alert.cryStartedAt,
                                        createdAt: alert.createdAt, duration: alert.durationSeconds, isTest: alert.isTest == true)
        }
        value.message = message
        return value
    }
    private func publishWatch() { watch.publish(watchSnapshot()) }

    private func handleWatch(_ command: WatchCommand) async -> WatchSnapshot {
        guard role == .parent else { return watchSnapshot(message: "Choose Parent Mode on your paired iPhone.") }
        switch command.kind {
        case .refresh: break
        case .registerToken:
            let latest = defaults.object(forKey: watchRegistrationDateKey) as? Date ?? .distantPast
            if command.issuedAt >= latest {
                pendingWatchToken = command.token
                hasPendingWatchToken = true
                defaults.set(command.issuedAt, forKey: watchRegistrationDateKey)
                defaults.set(try? JSONEncoder().encode(command), forKey: watchRegistrationKey)
            }
        case .acknowledge:
            if let id = command.eventId {
                var queue = defaults.stringArray(forKey: watchAcknowledgementsKey) ?? []
                if !queue.contains(id.uuidString) { queue.append(id.uuidString) }
                defaults.set(queue, forKey: watchAcknowledgementsKey)
            }
        }
        let failure = await syncWatchCommands()
        await refreshParent()
        return watchSnapshot(message: failure)
    }

    @discardableResult private func syncWatchCommands() async -> String? {
        guard role == .parent, !watchSyncInFlight else { return nil }
        watchSyncInFlight = true
        defer { watchSyncInFlight = false }
        let revision = environmentRevision
        let queueKey = watchAcknowledgementsKey
        let confirmedKey = watchConfirmedKey
        let discardedKey = watchDiscardedKey
        let registrationKey = watchRegistrationKey
        do {
            let client = try await registeredClient()
            guard revision == environmentRevision else { return nil }
            if !hasPendingWatchToken, let data = defaults.data(forKey: registrationKey),
               let command = try? JSONDecoder().decode(WatchCommand.self, from: data) {
                pendingWatchToken = command.token; hasPendingWatchToken = true
            }
            if hasPendingWatchToken {
                let token = pendingWatchToken
                try await client.watchPushToken(token)
                log.record("watch_token_synced")
                guard revision == environmentRevision else { return nil }
                if pendingWatchToken == token {
                    hasPendingWatchToken = false
                    defaults.removeObject(forKey: registrationKey)
                }
            }
            let queue = defaults.stringArray(forKey: queueKey) ?? []
            for rawID in queue {
                guard let id = UUID(uuidString: rawID), revision == environmentRevision else { continue }
                let discarded: Bool
                do {
                    try await client.acknowledge(id)
                    discarded = false
                } catch BackendError.response(404, _) {
                    // Deleted/old-pair alerts cannot be acknowledged. Resolve the
                    // Watch's durable item too, or it will enqueue this ID forever.
                    discarded = true
                }
                guard revision == environmentRevision else { return nil }
                log.record(discarded ? "watch_acknowledgement_discarded" : "watch_acknowledged")
                var remaining = defaults.stringArray(forKey: queueKey) ?? []
                remaining.removeAll { $0 == rawID }
                defaults.set(remaining, forKey: queueKey)
                defaults.set(rawID, forKey: discarded ? discardedKey : confirmedKey)
            }
            return nil
        } catch { log.record("watch_sync_failed", error: error); return "Watch sync pending. Check the Parent iPhone connection and backend setup." }
    }
}
