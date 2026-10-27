import Foundation

struct ParentStatus: Codable, Sendable {
    var paired: Bool
    var pairingID: String?
    var watchPushRegistered: Bool?
    var phonePushRegistered: Bool?
    var silentWatchAlarmsEnabled: Bool? = nil
    var connectionAlertsEnabled: Bool?
    var alertsMutedUntil: Date?
    var listenerConfiguration: MonitoringConfiguration?
    var listenerId: UUID?
    var lastHeartbeat: Date?
    var serverTime: Date?
    var nextHeartbeatExpectedAt: Date?
    var monitoringCommand: MonitoringCommand?
    var monitoring: Bool?
    var batteryLevel: Double?
    var powerConnected: Bool?
    var state: CryState?
    var currentEpisode: RemoteEpisode?
    var episodes: [RemoteEpisode]?
    var alerts: [RemoteAlert]?
    var configuration: MonitoringConfiguration
    var notificationRelevance: NotificationRelevance? = nil
    var microphoneActive: Bool? = nil

    /// Compare two server timestamps so the Parent's clock cannot shift polling.
    func refreshDelay() -> TimeInterval {
        guard paired, monitoring == true || microphoneActive == true, let serverTime, let nextHeartbeatExpectedAt else { return 15 }
        let remaining = nextHeartbeatExpectedAt.timeIntervalSince(serverTime)
        // Stop the one-second burst after 15 seconds of lateness. A new heartbeat
        // restores the schedule; a stopped/missing Listener uses ordinary polling.
        guard remaining.isFinite, remaining >= -15 else { return 15 }
        return min(15, max(1, remaining))
    }
}
struct MonitoringCommand: Codable, Sendable, Equatable {
    let id: UUID
    let enabled: Bool
    var status: String
    let createdAt: Date
    let expiresAt: Date
}
struct RemoteEpisode: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var alertSentAt: Date?
    var quietConfirmed: Bool? = nil
}
struct RemoteAlert: Identifiable, Codable, Sendable {
    let eventId: UUID
    let episodeId: UUID
    let cryStartedAt: Date
    let durationSeconds: Double
    let createdAt: Date
    let status: String
    let acknowledgedAt: Date?
    let isTest: Bool?
    var resolvedAt: Date? = nil
    var deliveryTarget: String? = nil
    var id: UUID { eventId }
}
struct Heartbeat: Codable, Sendable {
    let listenerId: UUID
    let timestamp: Date
    let monitoring: Bool
    let batteryLevel: Double?
    let powerConnected: Bool
    let state: CryState
    let currentEpisode: RemoteEpisode?
    let episodes: [RemoteEpisode]
    var appliedConfiguration: MonitoringConfiguration? = nil
    var timelineEvents: [TimelineEvent]? = nil
    var microphoneActive: Bool? = nil
}
struct PairingCode: Codable, Sendable { let code: String; let expiresAt: Date }
struct PairingResult: Codable, Sendable { let paired: Bool }
struct EmptyResponse: Codable, Sendable { var ok: Bool? }
protocol BackendServing: AlertSending {
    var credential: DeviceCredential { get }
    func register() async throws
    func createPairing() async throws -> PairingCode
    func claim(_ code: String) async throws
    func status() async throws -> ParentStatus
    func timeline() async throws -> TimelineResponse
    func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration
    func setMonitoring(_ enabled: Bool, id: UUID) async throws -> MonitoringCommand
    func completeMonitoring(_ id: UUID, succeeded: Bool) async throws
    func settings(_ configuration: MonitoringConfiguration) async throws
    func acknowledge(_ id: UUID) async throws
    func resumeAlerts(until: Date) async throws
    func pushToken(_ token: String) async throws
    func watchPushToken(_ token: String?) async throws
    func connectionAlerts(_ enabled: Bool) async throws
    func requestTestPush() async throws
    func alertTest() async throws -> AlertTestResponse
    func startAlertTest(id: UUID, configuration: AlertTestConfiguration) async throws -> AlertTestResponse
    func stopAlertTest(id: UUID) async throws -> AlertTestResponse
    func sendWatchTest() async throws
    func sendSilentAlarmTest() async throws -> UUID
    func silentWatchAlarms(_ enabled: Bool) async throws
    func confirmAlarmScheduled(episodeID: UUID, eventID: UUID, cycleID: UUID) async throws
    func unpair() async throws
    func deleteDevice() async throws
}
extension BackendServing {
    func alertTest() async throws -> AlertTestResponse { throw BackendError.message("Configurable tests require an updated connection service.") }
    func startAlertTest(id: UUID, configuration: AlertTestConfiguration) async throws -> AlertTestResponse { throw BackendError.message("Configurable tests require an updated connection service.") }
    func stopAlertTest(id: UUID) async throws -> AlertTestResponse { throw BackendError.message("Configurable tests require an updated connection service.") }
    func confirmAlarmScheduled(episodeID: UUID, eventID: UUID, cycleID: UUID) async throws { throw BackendError.message("Alarm scheduling receipts require an updated connection service.") }
    func silentWatchAlarms(_ enabled: Bool) async throws { throw BackendError.message("Silent Watch alarms require an updated connection service.") }
    func sendSilentAlarmTest() async throws -> UUID { throw BackendError.message("Silent alarm testing requires an updated connection service.") }
    func sendWatchTest() async throws { throw BackendError.message("Watch test mode requires an updated connection service.") }
    func resumeAlerts(until: Date) async throws { throw BackendError.message("Resume alerts requires an updated connection service.") }
    func setMonitoring(_ enabled: Bool, id: UUID) async throws -> MonitoringCommand { throw BackendError.message("Monitoring controls require an updated connection service.") }
    func completeMonitoring(_ id: UUID, succeeded: Bool) async throws { throw BackendError.message("Monitoring confirmation unavailable.") }
    func timeline() async throws -> TimelineResponse { throw BackendError.message("Timeline requires an updated connection service.") }
    func connectionAlerts(_ enabled: Bool) async throws { throw BackendError.message("Connection alerts unavailable.") }
    func requestTestPush() async throws { throw BackendError.message("Remote test unavailable.") }
    func unpair() async throws { throw BackendError.message("Unpairing unavailable.") }
    func deleteDevice() async throws { throw BackendError.message("Deletion unavailable.") }
}
struct BackendClient: BackendServing {
    let baseURL: URL
    let credential: DeviceCredential
    var log: DiagnosticLog? = nil
    var session: URLSession = .shared
    var requestTimeout: TimeInterval = 20
    func register() async throws {
        struct Registration: Codable { let deviceId: UUID; let role: DeviceRole; let secret: String }
        let _: EmptyResponse = try await request("/v1/device/register", body: Registration(deviceId: credential.deviceId, role: credential.role, secret: credential.secret))
    }
    func createPairing() async throws -> PairingCode { try await request("/v1/pairing/create", body: [String: String]()) }
    func claim(_ code: String) async throws { let _: PairingResult = try await request("/v1/pairing/claim", body: ["code": code]) }
    func status() async throws -> ParentStatus { try await request("/v1/listener/status", method: "GET", body: Optional<String>.none) }
    func timeline() async throws -> TimelineResponse { try await request("/v1/timeline", method: "GET", body: Optional<String>.none) }
    func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration { try await request("/v1/listener/heartbeat", body: value) }
    func send(_ alert: CryAlert) async throws -> AlertReceipt { try await request("/v1/listener/event", body: AlertUpload(alert: alert), eventID: alert.eventId) }
    func setMonitoring(_ enabled: Bool, id: UUID) async throws -> MonitoringCommand {
        struct Request: Encodable { let id: UUID; let enabled: Bool }
        return try await request("/v1/monitoring", body: Request(id: id, enabled: enabled))
    }
    func completeMonitoring(_ id: UUID, succeeded: Bool) async throws {
        struct Request: Encodable { let id: UUID; let succeeded: Bool }
        let _: EmptyResponse = try await request("/v1/monitoring/complete", body: Request(id: id, succeeded: succeeded))
    }
    func settings(_ configuration: MonitoringConfiguration) async throws { let _: EmptyResponse = try await request("/v1/settings", body: configuration) }
    func acknowledge(_ id: UUID) async throws { let _: EmptyResponse = try await request("/v1/alert/acknowledge", body: ["eventId": id.uuidString]) }
    func resumeAlerts(until: Date) async throws {
        let _: EmptyResponse = try await request("/v1/alert/resume", body: ["expectedUntil": Int64((until.timeIntervalSince1970 * 1000).rounded())])
    }
    func pushToken(_ token: String) async throws {
        struct Request: Encodable { let token: String; let alarmReceiptsVersion: Int? }
        let version: Int? = if #available(iOS 26.0, *) { 1 } else { nil }
        let _: EmptyResponse = try await request("/v1/device/push-token", body: Request(token: token, alarmReceiptsVersion: version))
    }
    func confirmAlarmScheduled(episodeID: UUID, eventID: UUID, cycleID: UUID) async throws {
        // Receipts must not consume an unbounded background execution budget.
        var bounded = self; bounded.requestTimeout = min(requestTimeout, 2)
        let _: EmptyResponse = try await bounded.request("/v1/alarm/scheduled", body: ["episodeId": episodeID.uuidString, "eventId": eventID.uuidString, "cycleId": cycleID.uuidString])
    }
    func connectionAlerts(_ enabled: Bool) async throws { let _: EmptyResponse = try await request("/v1/connection-alerts", body: ["enabled": enabled]) }
    func alertTest() async throws -> AlertTestResponse {
        try await request("/v1/alert-test", method: "GET", body: Optional<String>.none)
    }
    func startAlertTest(id: UUID, configuration: AlertTestConfiguration) async throws -> AlertTestResponse {
        struct Request: Encodable { let id: UUID; let configuration: AlertTestConfiguration }
        return try await request("/v1/alert-test", body: Request(id: id, configuration: configuration))
    }
    func stopAlertTest(id: UUID) async throws -> AlertTestResponse {
        try await request("/v1/alert-test/stop", body: ["id": id.uuidString])
    }
    func requestTestPush() async throws { let _: AlertReceipt = try await request("/v1/test-push", body: [String:String]()) }
    func sendWatchTest() async throws {
        let _: EmptyResponse = try await request("/v1/watch-test/push", body: [String:String]())
    }
    func sendSilentAlarmTest() async throws -> UUID {
        struct Receipt: Decodable { let eventId: UUID }
        let receipt: Receipt = try await request("/v1/listener/silent-alarm-test", body: [String:String]())
        return receipt.eventId
    }
    func silentWatchAlarms(_ enabled: Bool) async throws {
        let _: EmptyResponse = try await request("/v1/silent-watch-alarms", body: ["enabled": enabled])
    }
    func unpair() async throws { let _: EmptyResponse = try await request("/v1/pairing/remove", body: [String:String]()) }
    func deleteDevice() async throws {
        // A lost success response leaves a revoked credential. Retrying deletion is safe.
        do { let _: EmptyResponse = try await request("/v1/device/delete", body: [String:String]()) }
        catch BackendError.response(401, _) { return }
    }
    func watchPushToken(_ token: String?) async throws {
        struct Token: Encodable { let token: String?; enum CodingKeys: String, CodingKey { case token }
            func encode(to encoder: Encoder) throws { var values = encoder.container(keyedBy: CodingKeys.self); if let token { try values.encode(token, forKey: .token) } else { try values.encodeNil(forKey: .token) } }
        }
        let _: EmptyResponse = try await request("/v1/device/watch-push-token", body: Token(token: token))
    }
    private func request<B: Encodable, R: Decodable>(_ path: String, method: String = "POST", body: B?, eventID: UUID? = nil) async throws -> R {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw BackendError.message("Set a valid HTTPS backend URL in Settings.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method; request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.deviceId.uuidString.lowercased()).\(credential.secret)", forHTTPHeaderField: "Authorization")
        let operation = ["/v1/device/register": "register", "/v1/pairing/create": "pairing_create", "/v1/pairing/claim": "pairing_claim",
                         "/v1/alarm/scheduled": "alarm_scheduled", "/v1/device/push-token": "push_token", "/v1/device/watch-push-token": "watch_token",
                         "/v1/listener/heartbeat": "heartbeat", "/v1/listener/event": "alert", "/v1/listener/status": "status",
                         "/v1/timeline": "timeline", "/v1/monitoring": "monitoring", "/v1/monitoring/complete": "monitoring_complete", "/v1/settings": "settings", "/v1/alert/acknowledge": "acknowledge", "/v1/test-push": "test_push", "/v1/alert-test": "test_push", "/v1/alert-test/stop": "test_push", "/v1/watch-test": "test_push", "/v1/watch-test/push": "test_push", "/v1/listener/silent-alarm-test": "test_push", "/v1/alert/resume": "resume_alerts",
                         "/v1/connection-alerts": "connection_preferences", "/v1/pairing/remove": "unpair", "/v1/device/delete": "delete_device"][path] ?? "unknown"
        // Generated for each transport attempt, before receiving any response.
        // It is diagnostic correlation only; the event UUID remains idempotency authority.
        let clientRequestID = eventID == nil ? nil : UUID()
        if let clientRequestID {
            request.setValue(clientRequestID.uuidString.lowercased(), forHTTPHeaderField: "X-Client-Request-ID")
        }
        let started = ContinuousClock.now
        let metricsCollector = BackendMetricsCollector()
        let benchmarkAttempt = operation == "status" && credential.role == .parent ? await log?.benchmark.requestStarted() : nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        do { if let body { request.httpBody = try encoder.encode(body) } }
        catch {
            await log?.network(operation: operation, outcome: "encode_error",
                               elapsedMS: DiagnosticTiming.elapsedMS(since: started), error: error, eventID: eventID, benchmarkAttempt: benchmarkAttempt, metrics: metricsCollector.snapshot, monotonic: true, clientRequestID: clientRequestID)
            throw error
        }
        let data: Data, rawResponse: URLResponse
        if let eventID, let clientRequestID { await log?.alertRequestStarted(eventID: eventID, clientRequestID: clientRequestID) }
        let sentAt = Date(), networkStarted = ContinuousClock.now
        do { (data, rawResponse) = try await session.data(for: request, delegate: metricsCollector) }
        catch {
            let code = (error as? URLError)?.code.rawValue
            await log?.network(operation: operation, outcome: code == URLError.cancelled.rawValue ? "cancelled" : "transport_error",
                               status: code, elapsedMS: DiagnosticTiming.elapsedMS(since: started), error: error, eventID: eventID, benchmarkAttempt: benchmarkAttempt, metrics: metricsCollector.snapshot, monotonic: true, clientRequestID: clientRequestID)
            throw error
        }
        let receivedAt = Date(), networkElapsed = DiagnosticTiming.elapsedMS(since: networkStarted)
        guard let response = rawResponse as? HTTPURLResponse else {
            await log?.network(operation: operation, outcome: "invalid_response", elapsedMS: DiagnosticTiming.elapsedMS(since: started), eventID: eventID, benchmarkAttempt: benchmarkAttempt, metrics: metricsCollector.snapshot, monotonic: true, clientRequestID: clientRequestID)
            throw BackendError.message("Invalid server response.")
        }
        let clock = DiagnosticClockSample.estimate(localStarted: sentAt, localFinished: receivedAt, monotonicMS: networkElapsed,
            remoteReceivedMS: response.value(forHTTPHeaderField: "x-server-received-at-ms").flatMap(Int64.init),
            remoteSentMS: response.value(forHTTPHeaderField: "x-server-sent-at-ms").flatMap(Int64.init))
        await log?.observeClock(clock)
        let requestID = response.value(forHTTPHeaderField: "x-request-id").flatMap(UUID.init(uuidString:))
        let diagnosticState = response.value(forHTTPHeaderField: "x-diagnostics-status")
        let storageUnavailable = diagnosticState == "unavailable"
        let serverDiagnosticMS = response.value(forHTTPHeaderField: "x-diagnostics-elapsed-ms").flatMap(Int.init).flatMap { (0...3_600_000).contains($0) ? $0 : nil }
        guard (200..<300).contains(response.statusCode) else {
            await log?.network(operation: operation, outcome: "http_error", status: response.statusCode, requestID: requestID,
                               elapsedMS: DiagnosticTiming.elapsedMS(since: started), storageUnavailable: storageUnavailable, eventID: eventID, benchmarkAttempt: benchmarkAttempt, serverDiagnosticMS: serverDiagnosticMS, diagnosticState: diagnosticState, metrics: metricsCollector.snapshot, clock: clock, monotonic: true, clientRequestID: clientRequestID)
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "Backend request failed (\(response.statusCode))."
            throw BackendError.response(response.statusCode, reason)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid server timestamp."))
            }
            return date
        }
        do {
            let result = try decoder.decode(R.self, from: data)
            await log?.network(operation: operation, outcome: "ok", status: response.statusCode, requestID: requestID,
                               elapsedMS: DiagnosticTiming.elapsedMS(since: started), storageUnavailable: storageUnavailable, eventID: eventID, benchmarkAttempt: benchmarkAttempt, serverDiagnosticMS: serverDiagnosticMS, diagnosticState: diagnosticState, metrics: metricsCollector.snapshot, clock: clock, monotonic: true, clientRequestID: clientRequestID)
            return result
        } catch {
            await log?.network(operation: operation, outcome: "decode_error", status: response.statusCode, requestID: requestID,
                               elapsedMS: DiagnosticTiming.elapsedMS(since: started), storageUnavailable: storageUnavailable, error: error, eventID: eventID, benchmarkAttempt: benchmarkAttempt, serverDiagnosticMS: serverDiagnosticMS, diagnosticState: diagnosticState, metrics: metricsCollector.snapshot, clock: clock, monotonic: true, clientRequestID: clientRequestID)
            throw error
        }
    }
}
enum BackendError: LocalizedError {
    case message(String)
    case response(Int, String)
    var errorDescription: String? { switch self { case .message(let text), .response(_, let text): text } }
}

private struct ErrorBody: Decodable { let error: String }


/// Per-task delegate keeps the shared session and its connection pool unchanged.
/// Retain only a bounded numeric summary; never retain transaction objects.
private final class BackendMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DiagnosticNetworkTiming?
    var snapshot: DiagnosticNetworkTiming? { lock.withLock { value } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var summary = DiagnosticNetworkTiming(transactions: metrics.transactionMetrics.count, redirects: metrics.redirectCount)
        func accumulate(_ target: inout Int?, _ start: Date?, _ end: Date?) {
            guard let start, let end else { return }
            let elapsed = end.timeIntervalSince(start) * 1000
            guard elapsed.isFinite, (0...3_600_000).contains(elapsed) else { return }
            target = min(3_600_000, (target ?? 0) + Int(elapsed.rounded()))
        }
        accumulate(&summary.taskMS, metrics.taskInterval.start, metrics.taskInterval.end)
        accumulate(&summary.taskToFetchMS, metrics.taskInterval.start, metrics.transactionMetrics.first?.fetchStartDate)
        for transaction in metrics.transactionMetrics.prefix(100) {
            if transaction.isReusedConnection { summary.reusedConnections += 1 }
            accumulate(&summary.dnsMS, transaction.domainLookupStartDate, transaction.domainLookupEndDate)
            accumulate(&summary.connectMS, transaction.connectStartDate, transaction.connectEndDate)
            accumulate(&summary.tlsMS, transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
            accumulate(&summary.requestMS, transaction.requestStartDate, transaction.requestEndDate)
            accumulate(&summary.serverWaitMS, transaction.requestEndDate, transaction.responseStartDate)
            accumulate(&summary.responseMS, transaction.responseStartDate, transaction.responseEndDate)
        }
        lock.withLock { value = summary }
    }
}
