import Foundation

@MainActor protocol LiveSoundStreaming: AnyObject {
    var onFrame: ((SoundLevelFrame) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    var onNurserySoundCommand: ((NurserySoundCommand) -> Void)? { get set }
    var onNurserySoundUpdate: ((NurserySoundUpdate) -> Void)? { get set }
    var onNurserySoundRequest: (() -> Void)? { get set }
    func connect(baseURL: URL, credential: DeviceCredential)
    func disconnect()
    func publish(_ frame: SoundLevelFrame)
    func sendNurserySoundCommand(_ command: NurserySoundCommand) async throws
    func publishNurserySound(_ update: NurserySoundUpdate)
}

/// A separate live channel for chart display and confirmed nursery sound controls.
/// It never blocks capture, heartbeats, or alerts, and never queues commands or history.
@MainActor final class LiveSoundStream: LiveSoundStreaming {
    var onFrame: ((SoundLevelFrame) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNurserySoundCommand: ((NurserySoundCommand) -> Void)?
    var onNurserySoundUpdate: ((NurserySoundUpdate) -> Void)?
    var onNurserySoundRequest: (() -> Void)?
    private let enabled: Bool
    private var scope: String?
    private var generation = UUID()
    private var connectionTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var soundStateSendTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var viewing = false
    private var lastSentAt = Date.distantPast
    private var lastMessageAt = Date.distantPast
    private var requests = LiveSoundRequests()
    weak var log: DiagnosticLog?
    private var diagnosticRole: String?
    private var connectionID: UUID?
    private var failureReason: String?
    private var needsRecovery = false

    init(enabled: Bool = true) { self.enabled = enabled }
    deinit { connectionTask?.cancel(); sendTask?.cancel(); soundStateSendTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }

    func connect(baseURL: URL, credential: DeviceCredential) {
        guard enabled, baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { return }
        let identity = "\(baseURL.absoluteString)|\(credential.deviceId)"
        guard scope != identity else { return }
        disconnect(); scope = identity
        diagnosticRole = credential.role.rawValue
        let generation = self.generation
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/live-sound"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.deviceId.uuidString.lowercased()).\(credential.secret)", forHTTPHeaderField: "Authorization")
        connectionTask = Task { [weak self] in
            var retry: Double = 1
            while !Task.isCancelled {
                guard self?.generation == generation else { return }
                let socket = URLSession.shared.webSocketTask(with: request)
                let connectionID = UUID(), started = ContinuousClock.now
                self?.connectionID = connectionID; self?.failureReason = nil
                self?.log?.liveSound(phase: "connecting", role: credential.role.rawValue, connectionID: connectionID)
                self?.socket = socket; self?.viewing = false; self?.lastSentAt = .distantPast
                self?.requests = LiveSoundRequests()
                self?.lastMessageAt = Date()
                socket.resume()
                let keepalive = Task { [weak self, weak socket] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(credential.role == .parent ? 1 : 10)) } catch { return }
                        guard let self, let socket else { return }
                        // A silent or half-open connection must reconnect, even if TCP
                        // has not reported the network switch yet.
                        if Date().timeIntervalSince(self.lastMessageAt) > 20 {
                            self.recordFailure(reason: "keepalive_timeout", socket: socket, connectionID: connectionID)
                            socket.cancel(with: .goingAway, reason: nil); return
                        }
                        let ping: String
                        if credential.role == .parent {
                            let id = self.requests.issue(at: Date())
                            ping = "{\"type\":\"ping\",\"requestID\":\"\(id)\"}"
                        } else { ping = "{\"type\":\"ping\"}" }
                        do { try await socket.send(.string(ping)) }
                        catch {
                            self.recordFailure(reason: "keepalive_send", socket: socket, connectionID: connectionID, error: error)
                            socket.cancel(with: .goingAway, reason: nil); return
                        }
                    }
                }
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard !Task.isCancelled else { break }
                        guard self?.generation == generation else { break }
                        self?.lastMessageAt = Date()
                        guard case .string(let string) = message, string.utf8.count <= 4096,
                              let data = string.data(using: .utf8) else { throw URLError(.cannotParseResponse) }
                        let control = try JSONDecoder().decode(Control.self, from: data)
                        switch control.type {
                        case "ready":
                            self?.log?.liveSound(phase: self?.needsRecovery == true ? "recovered" : "connected",
                                role: credential.role.rawValue, connectionID: connectionID, elapsedMS: DiagnosticTiming.elapsedMS(since: started))
                            self?.needsRecovery = false
                            retry = 1; self?.onConnectionChange?(true)
                        case "sourceChanged":
                            self?.log?.liveSound(phase: "peer_changed", role: credential.role.rawValue, connectionID: connectionID)
                            self?.onConnectionChange?(true)
                        case "viewing":
                            self?.viewing = control.active == true
                            if control.active != true { self?.requests = LiveSoundRequests() }
                            if let id = control.requestID { self?.requests.include(id, at: Date()) }
                            if control.active == true, control.requestID != nil { self?.onNurserySoundRequest?() }
                        case "nurserySoundCommand":
                            guard credential.role == .listener else { throw URLError(.cannotParseResponse) }
                            let command = try JSONDecoder().decode(NurserySoundCommand.self, from: data)
                            guard command.request.settings.isValid else { throw URLError(.cannotParseResponse) }
                            self?.onNurserySoundCommand?(command)
                        case "nurserySoundState":
                            guard credential.role == .parent else { throw URLError(.cannotParseResponse) }
                            let update = try JSONDecoder().decode(NurserySoundUpdate.self, from: data)
                            guard update.isValid else { throw URLError(.cannotParseResponse) }
                            if self?.requests.accepts(requestID: update.requestID, requestIDs: update.requestIDs, at: Date()) == true { self?.onNurserySoundUpdate?(update) }
                        case "levels":
                            let frame = try JSONDecoder().decode(SoundLevelFrame.self, from: data)
                            guard frame.isValid else { throw URLError(.cannotParseResponse) }
                            if self?.requests.accepts(frame, at: Date()) == true { self?.onFrame?(frame) }
                        case "pong": break
                        default: throw URLError(.cannotParseResponse)
                        }
                    }
                } catch {
                    if self?.generation == generation, !Task.isCancelled {
                        let reason = error is DecodingError ? "decoding" : (error as? URLError)?.code == .cannotParseResponse ? "invalid_message" : "transport"
                        self?.recordFailure(reason: reason, socket: socket, connectionID: connectionID, error: error)
                    }
                }
                keepalive.cancel(); socket.cancel(with: .goingAway, reason: nil)
                guard self?.generation == generation else { return }
                self?.log?.liveSound(phase: "disconnected", role: credential.role.rawValue, connectionID: connectionID,
                    reason: self?.failureReason ?? "connection_closed", closeCode: socket.closeCode.rawValue,
                    httpStatus: (socket.response as? HTTPURLResponse)?.statusCode, elapsedMS: DiagnosticTiming.elapsedMS(since: started))
                self?.sendTask?.cancel(); self?.sendTask = nil
                self?.soundStateSendTask?.cancel(); self?.soundStateSendTask = nil
                self?.viewing = false; self?.onConnectionChange?(false)
                guard !Task.isCancelled else { return }
                self?.log?.liveSound(phase: "retrying", role: credential.role.rawValue, connectionID: connectionID, retrySeconds: Int(retry))
                do { try await Task.sleep(for: .seconds(retry)) } catch { return }
                retry = min(15, retry * 2)
            }
        }
    }
    func disconnect() {
        guard scope != nil || socket != nil else { return }
        if let diagnosticRole {
            log?.liveSound(phase: "disconnected", role: diagnosticRole, connectionID: connectionID, reason: "requested")
        }
        generation = UUID(); scope = nil; viewing = false; requests = LiveSoundRequests()
        connectionTask?.cancel(); connectionTask = nil
        sendTask?.cancel(); sendTask = nil
        soundStateSendTask?.cancel(); soundStateSendTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connectionID = nil; failureReason = nil; needsRecovery = false
        onConnectionChange?(false)
    }
    private func recordFailure(reason: String, socket: URLSessionWebSocketTask, connectionID: UUID?, commandID: UUID? = nil, error: (any Error)? = nil) {
        guard self.connectionID == connectionID, let diagnosticRole else { return }
        needsRecovery = true
        // Keep the initiating cause; a timeout is followed by a cancellation error.
        guard failureReason == nil else { return }
        failureReason = reason
        log?.liveSound(phase: "failed", role: diagnosticRole, connectionID: connectionID, commandID: commandID, reason: reason,
            closeCode: socket.closeCode.rawValue, httpStatus: (socket.response as? HTTPURLResponse)?.statusCode, error: error)
    }
    func publish(_ frame: SoundLevelFrame) {
        let ids = requests.activeIDs(at: Date())
        guard viewing, !ids.isEmpty, let socket, sendTask == nil, frame.isValid,
              Date().timeIntervalSince(lastSentAt) >= 1 else { return }
        var frame = frame; frame.requestID = ids.last; frame.requestIDs = ids
        guard let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else { return }
        lastSentAt = Date()
        let connectionID = self.connectionID
        sendTask = Task { [weak self] in
            // Drop a blocked send rather than building a delayed playback queue.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.recordFailure(reason: "send_timeout", socket: socket, connectionID: connectionID)
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { timeout.cancel(); if self?.socket === socket { self?.sendTask = nil } }
            do { try await socket.send(.string(text)) }
            catch {
                self?.recordFailure(reason: "levels_send", socket: socket, connectionID: connectionID, error: error)
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
    func sendNurserySoundCommand(_ command: NurserySoundCommand) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONEncoder().encode(command)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        // No retry or offline queue: a later reconnect must not replay Play.
        let connectionID = self.connectionID
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.recordFailure(reason: "send_timeout", socket: socket, connectionID: connectionID, commandID: command.id)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        do { try await socket.send(.string(text)) }
        catch {
            recordFailure(reason: "command_send", socket: socket, connectionID: connectionID, commandID: command.id, error: error)
            throw error
        }
    }
    func publishNurserySound(_ value: NurserySoundUpdate) {
        let ids = requests.activeIDs(at: Date())
        guard viewing, !ids.isEmpty, let socket, soundStateSendTask == nil else { return }
        var value = value; value.requestID = ids.last; value.requestIDs = ids
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        let connectionID = self.connectionID
        soundStateSendTask = Task { [weak self] in
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.recordFailure(reason: "send_timeout", socket: socket, connectionID: connectionID)
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { timeout.cancel(); if self?.socket === socket { self?.soundStateSendTask = nil } }
            do { try await socket.send(.string(text)) }
            catch {
                self?.recordFailure(reason: "sound_state_send", socket: socket, connectionID: connectionID, error: error)
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
    private struct Control: Decodable { let type: String; let active: Bool?; let requestID: String? }
}
