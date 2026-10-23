import Foundation

struct ParentStatus: Codable, Sendable {
    var paired: Bool
    var watchPushRegistered: Bool?
    var listenerId: UUID?
    var lastHeartbeat: Date?
    var monitoring: Bool?
    var batteryLevel: Double?
    var powerConnected: Bool?
    var state: CryState?
    var currentEpisode: RemoteEpisode?
    var episodes: [RemoteEpisode]?
    var alerts: [RemoteAlert]?
    var configuration: MonitoringConfiguration
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
    func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration
    func settings(_ configuration: MonitoringConfiguration) async throws
    func acknowledge(_ id: UUID) async throws
    func pushToken(_ token: String) async throws
    func watchPushToken(_ token: String?) async throws
}
struct BackendClient: BackendServing {
    let baseURL: URL
    let credential: DeviceCredential
    func register() async throws {
        struct Registration: Codable { let deviceId: UUID; let role: DeviceRole; let secret: String }
        let _: EmptyResponse = try await request("/v1/device/register", body: Registration(deviceId: credential.deviceId, role: credential.role, secret: credential.secret))
    }
    func createPairing() async throws -> PairingCode { try await request("/v1/pairing/create", body: [String: String]()) }
    func claim(_ code: String) async throws { let _: PairingResult = try await request("/v1/pairing/claim", body: ["code": code]) }
    func status() async throws -> ParentStatus { try await request("/v1/listener/status", method: "GET", body: Optional<String>.none) }
    func heartbeat(_ value: Heartbeat) async throws -> MonitoringConfiguration { try await request("/v1/listener/heartbeat", body: value) }
    func send(_ alert: CryAlert) async throws -> AlertReceipt { try await request("/v1/listener/event", body: alert) }
    func settings(_ configuration: MonitoringConfiguration) async throws { let _: EmptyResponse = try await request("/v1/settings", body: configuration) }
    func acknowledge(_ id: UUID) async throws { let _: EmptyResponse = try await request("/v1/alert/acknowledge", body: ["eventId": id.uuidString]) }
    func pushToken(_ token: String) async throws { let _: EmptyResponse = try await request("/v1/device/push-token", body: ["token": token]) }
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
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let body { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendError.message("Invalid server response.") }
        guard (200..<300).contains(response.statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "Backend request failed (\(response.statusCode))."
            throw BackendError.response(response.statusCode, reason)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw BackendError.message("Invalid server timestamp.") }
            return date
        }
        return try decoder.decode(R.self, from: data)
    }
}
enum BackendError: LocalizedError {
    case message(String)
    case response(Int, String)
    var errorDescription: String? { switch self { case .message(let text), .response(_, let text): text } }
}

private struct ErrorBody: Decodable { let error: String }
