import Foundation
import Observation
@preconcurrency import WatchConnectivity

@MainActor @Observable final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private(set) var installed = false
    private(set) var reachable = false
    private(set) var activated = false
    private(set) var status = "Install the companion from the Watch app."
    var onCommand: ((WatchCommand) async -> WatchSnapshot)?
    weak var log: DiagnosticLog?
    private var latest = WatchSnapshot()

    init(enabled: Bool = true) {
        super.init()
        guard enabled, WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ snapshot: WatchSnapshot) {
        latest = snapshot
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        updateState()
        guard installed, let data = try? JSONEncoder().encode(snapshot) else { return }
        do { try WCSession.default.updateApplicationContext(["snapshot": data]) }
        catch { status = "Watch status sync is temporarily unavailable."; log?.record("watch_snapshot_failed", code: (error as NSError).code) }
    }

    private func updateState() {
        let session = WCSession.default
        activated = session.activationState == .activated
        installed = session.isPaired && session.isWatchAppInstalled
        reachable = session.isReachable
        status = installed ? (latest.watchPushRegistered ? "Direct Watch alerts registered" : "Open the Watch app and enable alerts.") : "Install the companion from the Watch app."
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let code = (error as NSError?)?.code
        Task { @MainActor in self.log?.record(code == nil ? "watch_activated" : "watch_activation_failed", code: code); self.publish(self.latest) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateState(); self.log?.record(self.reachable ? "watch_reachable" : "watch_unreachable") }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateState() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        guard let data = message["command"] as? Data, let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else {
            replyHandler([:]); return
        }
        Task { @MainActor in
            let snapshot = await self.onCommand?(command) ?? self.latest
            self.publish(snapshot)
            replyHandler(["snapshot": (try? JSONEncoder().encode(snapshot)) ?? Data()])
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["command"] as? Data, let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in
            if let snapshot = await self.onCommand?(command) { self.publish(snapshot) }
        }
    }
}
