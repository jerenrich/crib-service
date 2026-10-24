import Foundation

@MainActor protocol LiveSoundStreaming: AnyObject {
    var onFrame: ((SoundLevelFrame) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    func connect(baseURL: URL, credential: DeviceCredential)
    func disconnect()
    func publish(_ frame: SoundLevelFrame)
}

/// A separate, best-effort display channel. It never blocks capture, heartbeats,
/// alert delivery, or their retries, and never queues sound-level history.
@MainActor final class LiveSoundStream: LiveSoundStreaming {
    var onFrame: ((SoundLevelFrame) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private let enabled: Bool
    private var scope: String?
    private var generation = UUID()
    private var connectionTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var viewing = false
    private var lastSentAt = Date.distantPast
    private var lastMessageAt = Date.distantPast
    private var requestID: String?
    private var requests = LiveSoundRequests()

    init(enabled: Bool = true) { self.enabled = enabled }
    deinit { connectionTask?.cancel(); sendTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }

    func connect(baseURL: URL, credential: DeviceCredential) {
        guard enabled, baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { return }
        let identity = "\(baseURL.absoluteString)|\(credential.deviceId)"
        guard scope != identity else { return }
        disconnect(); scope = identity
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
                self?.socket = socket; self?.viewing = false; self?.lastSentAt = .distantPast
                self?.requestID = nil; self?.requests = LiveSoundRequests()
                self?.lastMessageAt = Date()
                socket.resume()
                let keepalive = Task { [weak self, weak socket] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(credential.role == .parent ? 1 : 10)) } catch { return }
                        guard let self, let socket else { return }
                        // A silent or half-open connection must reconnect, even if TCP
                        // has not reported the network switch yet.
                        if Date().timeIntervalSince(self.lastMessageAt) > 20 {
                            socket.cancel(with: .goingAway, reason: nil); return
                        }
                        let ping: String
                        if credential.role == .parent {
                            let id = self.requests.issue(at: Date())
                            ping = "{\"type\":\"ping\",\"requestID\":\"\(id)\"}"
                        } else { ping = "{\"type\":\"ping\"}" }
                        do { try await socket.send(.string(ping)) }
                        catch { socket.cancel(with: .goingAway, reason: nil); return }
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
                            retry = 1; self?.onConnectionChange?(true)
                        case "sourceChanged": self?.onConnectionChange?(true)
                        case "viewing":
                            self?.viewing = control.active == true
                            self?.requestID = control.requestID
                        case "levels":
                            let frame = try JSONDecoder().decode(SoundLevelFrame.self, from: data)
                            guard frame.isValid else { throw URLError(.cannotParseResponse) }
                            if self?.requests.accepts(frame, at: Date()) == true { self?.onFrame?(frame) }
                        case "pong": break
                        default: throw URLError(.cannotParseResponse)
                        }
                    }
                } catch { /* Reconnect without logging frames or credentials. */ }
                keepalive.cancel(); socket.cancel(with: .goingAway, reason: nil)
                guard self?.generation == generation else { return }
                self?.sendTask?.cancel(); self?.sendTask = nil
                self?.viewing = false; self?.onConnectionChange?(false)
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(retry)) } catch { return }
                retry = min(15, retry * 2)
            }
        }
    }
    func disconnect() {
        guard scope != nil || socket != nil else { return }
        generation = UUID(); scope = nil; viewing = false; requestID = nil; requests = LiveSoundRequests()
        connectionTask?.cancel(); connectionTask = nil
        sendTask?.cancel(); sendTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        onConnectionChange?(false)
    }
    func publish(_ frame: SoundLevelFrame) {
        guard viewing, let requestID, let socket, sendTask == nil, frame.isValid,
              Date().timeIntervalSince(lastSentAt) >= 1 else { return }
        var frame = frame; frame.requestID = requestID
        guard let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else { return }
        lastSentAt = Date()
        sendTask = Task { [weak self] in
            // Drop a blocked send rather than building a delayed playback queue.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { timeout.cancel(); if self?.socket === socket { self?.sendTask = nil } }
            do { try await socket.send(.string(text)) }
            catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }
    private struct Control: Decodable { let type: String; let active: Bool?; let requestID: String? }
}
