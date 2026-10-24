import Foundation

struct ParentStatus: Codable, Sendable {
    var paired: Bool
    var pairingID: String?
    var watchPushRegistered: Bool?
    var phonePushRegistered: Bool?
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
    func unpair() async throws
    func deleteDevice() async throws
}
extension BackendServing {
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
    func register() async throws {
        struct Registration: Codable { let deviceId: UUID; let role: DeviceRole; let secret: String }
        let _: EmptyResponse = try await request("/v1/device/register", body: Registration(deviceId: credential.deviceId, role: credential.role, secret: credential.secret))
    }
    func createPairing() async throws -> PairingCode { try await request("/v1/pairing/create", body: [String: String]()) }
    func claim(_ code: String) async throws { let _: PairingResult = try await request("/v1/pairing/claim", body: ["code": code]) }
    func status() async throws -> ParentStatus { try await request("/v1/listener/status", method: "GET", body: Optional<String>.none) }
    func timeline() async throws -> TimelineResponse { try await request("/v1/timeline", method: "GET", body: Optional<String>.none) }
    func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration { try await request("/v1/listener/heartbeat", body: value) }
    func send(_ alert: CryAlert) async throws -> AlertReceipt { try await request("/v1/listener/event", body: alert) }
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
    func pushToken(_ token: String) async throws { let _: EmptyResponse = try await request("/v1/device/push-token", body: ["token": token]) }
    func connectionAlerts(_ enabled: Bool) async throws { let _: EmptyResponse = try await request("/v1/connection-alerts", body: ["enabled": enabled]) }
    func requestTestPush() async throws { let _: AlertReceipt = try await request("/v1/test-push", body: [String:String]()) }
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
    private func request<B: Encodable, R: Decodable>(_ path: String, method: String = "POST", body: B?) async throws -> R {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw BackendError.message("Set a valid HTTPS backend URL in Settings.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.deviceId.uuidString.lowercased()).\(credential.secret)", forHTTPHeaderField: "Authorization")
        let operation = ["/v1/device/register": "register", "/v1/pairing/create": "pairing_create", "/v1/pairing/claim": "pairing_claim",
                         "/v1/device/push-token": "push_token", "/v1/device/watch-push-token": "watch_token",
                         "/v1/listener/heartbeat": "heartbeat", "/v1/listener/event": "alert", "/v1/listener/status": "status",
                         "/v1/timeline": "timeline", "/v1/monitoring": "monitoring", "/v1/monitoring/complete": "monitoring_complete", "/v1/settings": "settings", "/v1/alert/acknowledge": "acknowledge", "/v1/test-push": "test_push", "/v1/alert/resume": "resume_alerts",
                         "/v1/connection-alerts": "connection_preferences", "/v1/pairing/remove": "unpair", "/v1/device/delete": "delete_device"][path] ?? "unknown"
        let started = Date()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        do { if let body { request.httpBody = try encoder.encode(body) } }
        catch {
            await log?.network(operation: operation, outcome: "encode_error",
                               elapsedMS: Int(Date().timeIntervalSince(started) * 1000), error: error)
            throw error
        }
        let data: Data, rawResponse: URLResponse
        do { (data, rawResponse) = try await session.data(for: request) }
        catch {
            let code = (error as? URLError)?.code.rawValue
            await log?.network(operation: operation, outcome: code == URLError.cancelled.rawValue ? "cancelled" : "transport_error",
                               status: code, elapsedMS: Int(Date().timeIntervalSince(started) * 1000), error: error)
            throw error
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            await log?.network(operation: operation, outcome: "invalid_response", elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
            throw BackendError.message("Invalid server response.")
        }
        let requestID = response.value(forHTTPHeaderField: "x-request-id").flatMap(UUID.init(uuidString:))
        let storageUnavailable = response.value(forHTTPHeaderField: "x-diagnostics-status") == "unavailable"
        guard (200..<300).contains(response.statusCode) else {
            await log?.network(operation: operation, outcome: "http_error", status: response.statusCode, requestID: requestID,
                               elapsedMS: Int(Date().timeIntervalSince(started) * 1000), storageUnavailable: storageUnavailable)
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
                               elapsedMS: Int(Date().timeIntervalSince(started) * 1000), storageUnavailable: storageUnavailable)
            return result
        } catch {
            await log?.network(operation: operation, outcome: "decode_error", status: response.statusCode, requestID: requestID,
                               elapsedMS: Int(Date().timeIntervalSince(started) * 1000), storageUnavailable: storageUnavailable, error: error)
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
