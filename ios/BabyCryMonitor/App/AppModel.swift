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
    var currentDBFS: Double = -100
    var meter: [Double] = Array(repeating: -100, count: 32)
    var batteryLevel: Double?
    var powerConnected = false
    var now = Date()
    var needsRestart = false
    let connectivity: any ConnectivityProviding
    let notifications: any NotificationProviding
    let watch: PhoneWatchBridge
    let log = DiagnosticLog()
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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any CredentialStoring
    @ObservationIgnored private let makeClient: (URL, DeviceCredential) -> any BackendServing
    @ObservationIgnored private let currentTime: () -> Date
    @ObservationIgnored private var settingsGeneration = 0
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var lastHeartbeatAt = Date.distantPast
    @ObservationIgnored private var lastRefreshAt = Date.distantPast
    @ObservationIgnored private var uploadedToken: String?
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var pendingWatchToken: String?
    @ObservationIgnored private var hasPendingWatchToken = false
    @ObservationIgnored private var lastWatchRetryAt = Date.distantPast
    @ObservationIgnored private var watchSyncInFlight = false
    @ObservationIgnored private var storageHealthy = true
    @ObservationIgnored private var settingsDirty = false
    @ObservationIgnored private var environmentRevision = 0
    @ObservationIgnored private var latestTestEventID: UUID?

    init(defaults: UserDefaults = .standard, metadataStore: MetadataStore? = nil,
         audio: any AudioLevelProviding = AudioLevelMonitor(),
         connectivity: any ConnectivityProviding = ConnectivityMonitor(),
         notifications: any NotificationProviding = NotificationService(),
         keychain: any CredentialStoring = KeychainStore(),
         makeClient: @escaping (URL, DeviceCredential) -> any BackendServing = { BackendClient(baseURL: $0, credential: $1) },
         currentTime: @escaping () -> Date = Date.init, automaticallyStart: Bool = true) {
        self.defaults = defaults; self.audio = audio; self.connectivity = connectivity
        self.notifications = notifications; self.keychain = keychain; self.makeClient = makeClient
        self.watch = PhoneWatchBridge(enabled: automaticallyStart)
        self.currentTime = currentTime
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset"), let bundle = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundle)
        }
        #endif
        role = defaults.string(forKey: "role").flatMap(DeviceRole.init)
        safetyAccepted = defaults.bool(forKey: "safetyAccepted")
        backendURL = defaults.string(forKey: "backendURL") ?? (Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String ?? "")
        do {
            let store = try metadataStore ?? MetadataStore(); self.store = store
            let saved = try store.load(); needsRestart = saved.wasMonitoring
            engine = CrySessionManager(snapshot: saved); engine.recoverAfterRelaunch()
            configuration = engine.snapshot.configuration
            try store.save(engine.snapshot)
        } catch { storageHealthy = false; self.error = "Local metadata storage failed: \(error.localizedDescription)" }
        settingsDirty = defaults.bool(forKey: "settingsDirty")
        UIDevice.current.isBatteryMonitoringEnabled = true
        audio.onStatus = { [weak self] status in self?.audioChanged(status) }
        notifications.onToken = { [weak self] token in self?.pushToken = token; self?.uploadedToken = nil }
        notifications.onAlert = { [weak self] in Task { await self?.refreshParent() } }
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
    }
    deinit {
        loopTask?.cancel(); networkTask?.cancel(); audioTask?.cancel()
        settingsTask?.cancel(); heartbeatTask?.cancel()
    }
    var snapshot: SessionSnapshot { engine.snapshot }
    var state: CryState { engine.detector.state }
    var ambient: Double { engine.detector.ambientDBFS }
    var threshold: Double { engine.detector.effectiveThreshold }
    var listenerID: String { credential?.deviceId.uuidString ?? "Not registered" }
    var parentOnline: Bool {
        guard let status = parentStatus, status.monitoring == true, let last = status.lastHeartbeat else { return false }
        return now.timeIntervalSince(last) < 150
    }
    var activeAlert: RemoteAlert? {
        let alerts = parentStatus?.alerts?.filter { $0.acknowledgedAt == nil }
        return alerts?.first { $0.isTest != true } ?? alerts?.first
    }
    func acceptSafety() { safetyAccepted = true; defaults.set(true, forKey: "safetyAccepted") }
    func selectRole(_ value: DeviceRole) {
        stop(); environmentRevision += 1; role = value; defaults.set(value.rawValue, forKey: "role")
        parentStatus = nil; pairingCode = nil; credential = nil; uploadedToken = nil; loadCredential()
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
        environmentRevision += 1; backendURL = url.absoluteString
        defaults.set(backendURL, forKey: "backendURL")
        credential = nil; parentStatus = nil; pairingCode = nil; uploadedToken = nil
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
        } catch { self.error = error.localizedDescription }
    }
    private func client() throws -> any BackendServing {
        guard let credential, let url = URL(string: backendURL), !backendURL.isEmpty else {
            throw BackendError.message("The connection service is not configured. Contact the app provider for a configured build.")
        }
        return makeClient(url, credential)
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
            guard revision == environmentRevision else { return }; pairingCode = created; error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    func claimPairing(_ code: String) async {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { error = "Enter the six-digit code shown on the Parent iPhone."; return }
        let revision = environmentRevision
        do {
            let client = try await registeredClient(); try await client.claim(code)
            guard revision == environmentRevision else { return }
            paired = true; defaults.set(true, forKey: pairingKey)
            log.record("paired_successfully"); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func start() async {
        guard !starting, !monitoring, !recoveringAudio, role == .listener else { return }
        let revision = environmentRevision, generation = settingsGeneration
        starting = true; defer { starting = false }
        guard safetyAccepted, storageHealthy else { error = "Review onboarding and resolve local storage before monitoring."; return }
        guard paired else { error = "Pair this Listener with a Parent before monitoring."; return }
        guard await audio.requestPermission() else { error = "Microphone permission denied. Enable Microphone in iPhone Settings → Crib Service."; return }
        guard revision == environmentRevision, role == .listener else { return }
        do {
            if connectivity.available {
                do {
                    let client = try await registeredClient(); let status = try await client.status()
                    guard revision == environmentRevision else { return }
                    guard status.paired else {
                        paired = false; defaults.set(false, forKey: pairingKey)
                        throw BackendError.message("Pairing no longer exists. Pair again before monitoring.")
                    }
                    if !settingsDirty, generation == settingsGeneration { applyRemote(status.configuration) }
                } catch let failure as BackendError {
                    if case .response(let status, _) = failure, status >= 500 {
                        deliveryStatus = "Monitoring locally. Backend unavailable; alerts will retry."
                    } else { throw failure }
                } catch let failure as URLError {
                    deliveryStatus = "Monitoring locally. Internet unavailable (\(failure.code.rawValue)); alerts will retry."
                }
            }
            guard revision == environmentRevision, role == .listener, storageHealthy else { return }
            try await audio.start(); engine.markMonitoring(true); persist()
            guard storageHealthy else { return }
            lastSampleAt = currentTime(); lastHeartbeatAt = .distantPast; needsRestart = false; error = nil
            log.record("monitoring_started")
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
    func stop() {
        let wasActive = monitoring || recoveringAudio
        audio.stop(); engine.suspend(); persist()
        if wasActive { log.record("monitoring_stopped"); queueHeartbeat() }
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
        monitoring = false; recoveringAudio = false
        switch status {
        case .active:
            monitoring = true; audioStatus = "Microphone active"
            engine.markMonitoring(true); lastSampleAt = currentTime(); lastHeartbeatAt = .distantPast
            needsRestart = false; error = nil
        case .stopped:
            audioStatus = "Stopped"
            engine.suspend(); persist()
        case .recovering(let message):
            // Route changes and resumable interruptions need no user action.
            // Suspend detection so the missing audio never extends an episode.
            recoveringAudio = true; audioStatus = message; needsRestart = false
            engine.suspend(); persist()
            log.record("audio_recovering"); queueHeartbeat()
        case .failed(let message):
            audioStatus = message
            engine.suspend(); persist()
            error = message; needsRestart = true
            log.record("audio_interrupted"); queueHeartbeat()
        }
    }
    private func consume(_ sample: AudioLevelSample) {
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
        do { try store.save(engine.snapshot) }
        catch {
            storageHealthy = false; monitoring = false; audio.stop()
            self.error = "Monitoring stopped: metadata could not be saved. \(error.localizedDescription)"
            log.record("metadata_write_failed")
        }
    }
    func saveSettings(_ config: MonitoringConfiguration) {
        guard config.isValid else { error = "Alert duration must be between 5 seconds and 60 minutes."; return }
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
        powerConnected = device.batteryState == .charging || device.batteryState == .full
        if monitoring, let lastSampleAt, now.timeIntervalSince(lastSampleAt) > 3 {
            stop(); error = "Monitoring stopped: microphone samples stopped arriving."; needsRestart = true; log.record("audio_stalled")
        }
    }
    func tick() async {
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
                if let pushToken, pushToken != uploadedToken { try await client.pushToken(pushToken); uploadedToken = pushToken }
                if now.timeIntervalSince(lastWatchRetryAt) >= 15 {
                    lastWatchRetryAt = now
                    if watch.activated, !watch.installed, parentStatus?.watchPushRegistered == true {
                        pendingWatchToken = nil; hasPendingWatchToken = true
                    }
                    await syncWatchCommands()
                }
                if now.timeIntervalSince(lastRefreshAt) >= 15 { await refreshParent() }
            } else if role == .listener {
                if monitoring && currentTime().timeIntervalSince(lastHeartbeatAt) >= 60 { await queueHeartbeat()?.value }
                guard revision == environmentRevision, role == .listener, storageHealthy else { return }
                await alerts.deliverReady(snapshot.pending, listenerId: client.credential.deviceId, now: currentTime(), sender: client) { alert, result in
                    switch result {
                    case .success(let receipt) where receipt.status == "sent":
                        engine.delivered(alert.eventId, at: Date()); log.record("alert_apns_accepted")
                        deliveryStatus = "Connected · APNs accepted alert"
                    case .success(let receipt) where receipt.status == "acknowledged":
                        engine.acknowledged(alert.eventId)
                        deliveryStatus = "Alert acknowledged on Parent"
                    case .success(let receipt):
                        engine.failed(alert.eventId, at: Date())
                        switch receipt.status {
                        case "uncertain": deliveryStatus = "Alert delivery uncertain. Check the Parent iPhone."
                        case "failed": deliveryStatus = "Alert delivery failed. Check Worker/APNs diagnostics."
                        case "blocked": deliveryStatus = "Alert blocked. Open Parent Mode and enable notifications."
                        default: deliveryStatus = "Alert queued on server (\(receipt.status))."
                        }
                    case .failure(let failure):
                        engine.failed(alert.eventId, at: Date()); deliveryStatus = "Alert pending: \(failure.localizedDescription)"
                        log.record("alert_retry_scheduled")
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
        } catch { deliveryStatus = "Backend unavailable: \(error.localizedDescription)" }
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
                // Invalidate remote reads begun before this upload finished.
                self.settingsGeneration += 1
            } catch {
                guard let self, revision == self.environmentRevision else { return }
                self.deliveryStatus = "Settings sync pending: \(error.localizedDescription)"
            }
        }
    }
    /// Capture the Listener identity and payload synchronously, including before a
    /// role change. Serialize requests so an older active heartbeat cannot win.
    @discardableResult private func queueHeartbeat() -> Task<Void, Never>? {
        guard role == .listener, paired, let client = try? client() else { return nil }
        func remote(_ episode: CryEpisode) -> RemoteEpisode {
            RemoteEpisode(id: episode.id, startedAt: episode.startedAt, endedAt: episode.endedAt, alertSentAt: episode.alertSentAt)
        }
        let value = Heartbeat(listenerId: client.credential.deviceId, timestamp: currentTime(), monitoring: monitoring,
                              batteryLevel: batteryLevel, powerConnected: powerConnected, state: state,
                              currentEpisode: snapshot.current.map(remote), episodes: Array(snapshot.history.prefix(100)).map(remote))
        let revision = environmentRevision, generation = settingsGeneration
        let previous = heartbeatTask
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let config = try await client.heartbeat(value)
                guard let self, revision == self.environmentRevision else { return }
                self.lastHeartbeatAt = self.currentTime(); self.deliveryStatus = "Connected"
                if !self.settingsDirty, generation == self.settingsGeneration { self.applyRemote(config) }
            } catch {
                guard let self, revision == self.environmentRevision else { return }
                self.deliveryStatus = "Monitoring locally. Alerts may be delayed: \(error.localizedDescription)"
            }
        }
        heartbeatTask = task
        return task
    }
    func refreshParent() async {
        guard role == .parent else { return }
        let revision = environmentRevision, generation = settingsGeneration
        do {
            let client = try await registeredClient(); let status = try await client.status()
            guard revision == environmentRevision, role == .parent else { return }
            parentStatus = status; paired = status.paired; defaults.set(paired, forKey: pairingKey)
            if !settingsDirty, generation == settingsGeneration { applyRemote(status.configuration) }
            lastRefreshAt = Date(); deliveryStatus = "Connected"; error = nil
            publishWatch()
        } catch {
            guard revision == environmentRevision else { return }
            deliveryStatus = "Status unavailable: \(error.localizedDescription)"; parentStatus = nil
            publishWatch()
        }
    }
    func acknowledge(_ id: UUID) async {
        do { let client = try await registeredClient(); try await client.acknowledge(id); await refreshParent() }
        catch { self.error = error.localizedDescription }
    }
    func foreground() async {
        if credential == nil { loadCredential() }
        if role == .parent { await notifications.register(); await refreshParent() }
        if role == .listener && needsRestart && !monitoring && !starting && !recoveringAudio { error = "Monitoring needs to be restarted. Check the microphone and tap Start Monitoring." }
    }

    private var watchAcknowledgementsKey: String { "watchAcknowledgements|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
    private var watchConfirmedKey: String { "watchConfirmed|\(backendURL)|\(credential?.deviceId.uuidString ?? "none")" }
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
        value.state = value.parentMode ? parentStatus?.state : nil
        value.alertDuration = configuration.alertDuration
        value.watchPushRegistered = value.parentMode && parentStatus?.watchPushRegistered == true
        value.acknowledgedEventId = defaults.string(forKey: watchConfirmedKey).flatMap(UUID.init(uuidString:))
        if value.parentMode, let alert = activeAlert {
            value.alert = WatchCryAlert(eventId: alert.eventId, episodeId: alert.episodeId, startedAt: alert.cryStartedAt,
                                        createdAt: alert.createdAt, duration: alert.durationSeconds, isTest: alert.isTest == true)
        }
        value.message = message
        return value
    }
    private func publishWatch() { watch.publish(watchSnapshot()) }

    private func handleWatch(_ command: WatchCommand) async -> WatchSnapshot {
        guard role == .parent else { return watchSnapshot(message: "Choose Parent Alerts on your paired iPhone.") }
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
                guard revision == environmentRevision else { return nil }
                if pendingWatchToken == token {
                    hasPendingWatchToken = false
                    defaults.removeObject(forKey: registrationKey)
                }
            }
            let queue = defaults.stringArray(forKey: queueKey) ?? []
            for rawID in queue {
                guard let id = UUID(uuidString: rawID), revision == environmentRevision else { continue }
                try await client.acknowledge(id)
                var remaining = defaults.stringArray(forKey: queueKey) ?? []
                remaining.removeAll { $0 == rawID }
                defaults.set(remaining, forKey: queueKey)
                defaults.set(rawID, forKey: confirmedKey)
            }
            return nil
        } catch { return "Watch sync pending. Check the Parent iPhone connection and backend setup." }
    }
}
