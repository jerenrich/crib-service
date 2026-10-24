import Foundation
import Observation

/// Keeps alert setup feedback separate from routine nursery status refreshes.
@MainActor @Observable final class WatchAlertSetup {
    enum Phase { case idle, requestingPermission, registeringPush, syncing, registered, blocked }
    private(set) var phase: Phase = .idle
    private(set) var notificationsAllowed = false
    private(set) var detail = "Allow notifications, then register this Watch through your Parent iPhone."
    private(set) var registrationCommand: WatchCommand?
    private(set) var awaitingConnection = false
    private var awaitingPushToken = false
    /// True once Watch Connectivity has accepted the command for durable delivery.
    @ObservationIgnored var sendRegistration: ((WatchCommand) -> Bool)?

    var title: String {
        switch phase {
        case .idle: "Finish setting up alerts"
        case .requestingPermission: "Requesting notification permission…"
        case .registeringPush: "Registering this Watch…"
        case .syncing: awaitingConnection ? "Waiting for your iPhone…" : "Syncing with Parent iPhone…"
        case .registered: "Direct Watch alerts registered"
        case .blocked: "Alert setup needs attention"
        }
    }
    var inProgress: Bool { [.requestingPermission, .registeringPush, .syncing].contains(phase) }
    var hasToken: Bool { registrationCommand?.token != nil }

    func requestPermission(using request: () async throws -> Bool) async throws -> Bool {
        guard phase != .requestingPermission else { return false }
        phase = .requestingPermission
        awaitingPushToken = true
        detail = "Respond to the notification permission request on your Watch."
        do {
            let allowed = try await request()
            updateAuthorization(allowed)
            if allowed { beginPushRegistration() }
            return allowed
        } catch {
            fail("Could not request notification permission. Tap Retry setup.")
            throw error
        }
    }

    func updateAuthorization(_ allowed: Bool, denied: Bool = true, registeredOnPhone: Bool = false) {
        notificationsAllowed = allowed
        guard !allowed else { return }
        awaitingPushToken = false
        // Retain removals through session activation too, so revoking permission
        // cannot leave the backend routing notifications to a disabled Watch.
        if hasToken || (registeredOnPhone && registrationCommand == nil) {
            registrationCommand = WatchCommand(kind: .registerToken)
            retryRegistration()
        }
        phase = denied ? .blocked : .idle
        detail = denied
            ? "Notifications are off. On your paired iPhone, open Watch → Notifications → Crib Service and allow notifications. Then return here and tap Retry setup."
            : "Tap Enable alerts to allow notifications on this Watch."
    }

    func beginPushRegistration() {
        guard notificationsAllowed else { return }
        phase = .registeringPush
        awaitingPushToken = true
        detail = "Getting a push address from Apple. Keep your Watch connected to the internet. If this stalls, tap Retry setup."
    }

    func receivedToken(_ token: String) {
        guard notificationsAllowed else { return }
        registrationCommand = WatchCommand(kind: .registerToken, token: token)
        awaitingPushToken = false
        phase = .syncing
        detail = "Open Crib Service in Parent Mode on your paired iPhone to finish registration."
        retryRegistration()
    }

    func retryRegistration() {
        guard let command = registrationCommand else { return }
        awaitingConnection = sendRegistration?(command) != true
        if notificationsAllowed, phase != .requestingPermission, phase != .registeringPush, phase != .blocked {
            phase = .syncing
        }
    }

    func accept(_ snapshot: WatchSnapshot) {
        guard notificationsAllowed, hasToken, !awaitingConnection, !awaitingPushToken,
              phase != .requestingPermission, phase != .registeringPush else { return }
        if snapshot.parentMode && snapshot.watchPushRegistered {
            phase = .registered
            detail = "Setup complete. Send a test push from your nursery Listener to check delivery."
        } else if !snapshot.parentMode {
            fail("Choose Parent Mode in Crib Service on your paired iPhone, then tap Retry setup.")
        } else if let message = snapshot.message {
            fail(message)
        } else if phase != .blocked {
            phase = .syncing
            detail = "Open Crib Service on your Parent iPhone and check its internet connection. Waiting for registration confirmation."
        }
    }

    func fail(_ message: String) {
        phase = .blocked
        detail = message
    }
}
