import Foundation
import Observation

@MainActor @Observable final class DiagnosticLog {
    private(set) var lines: [String] = []
    private(set) var persistenceAvailable = true
    private let url: URL?
    private var recent: [String: Date] = [:]
    private static let events: Set<String> = [
        "app_launched", "foreground", "background", "monitoring_recovered_after_relaunch",
        "paired_successfully", "pairing_created", "pairing_failed", "credential_failed", "metadata_load_failed",
        "monitoring_started", "monitoring_stopped", "monitoring_start_failed", "microphone_permission_denied",
        "test_push_queued", "audio_active", "audio_recovering", "audio_interrupted", "audio_stalled",
        "audio_interruption_began", "audio_interruption_ended", "audio_route_changed", "audio_services_reset", "audio_engine_changed",
        "crying_started", "possible_cry", "crying_ended", "crying_resumed", "quiet_gap_started",
        "alert_threshold_reached", "metadata_write_failed", "alert_apns_accepted", "alert_acknowledged",
        "alert_delivery_failed", "alert_uncertain", "alert_blocked", "alert_server_pending", "alert_retry_scheduled",
        "test_push_apns_accepted", "heartbeat_retry_scheduled", "heartbeat_recovered", "settings_synced",
        "settings_sync_failed", "parent_status_failed", "parent_status_recovered", "backend_unavailable",
        "network_available", "network_unavailable", "push_token_received", "push_token_uploaded", "push_received",
        "notification_permission_allowed", "notification_permission_denied", "notification_permission_failed",
        "push_registration_failed", "local_notification_scheduled", "local_notification_failed", "watch_sync_failed", "watch_token_synced",
        "watch_acknowledged", "watch_activation_failed", "watch_activated", "watch_reachable", "watch_unreachable",
        "watch_snapshot_failed", "watch_snapshot_received", "watch_command_queued", "watch_push_received"
    ]
    init(directory: URL? = nil) {
        let folder = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        url = folder?.appendingPathComponent("diagnostics.txt")
        do {
            guard let folder, let url else { persistenceAvailable = false; return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                lines = Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(500))
            }
        } catch { persistenceAvailable = false }
    }
    func record(_ event: String, code: Int? = nil) {
        // Enforced allowlist: callers cannot accidentally append an exception, token or URL.
        guard Self.events.contains(event) else { return }
        let repetitive: Set<String> = ["alert_retry_scheduled", "alert_uncertain", "alert_blocked", "alert_server_pending",
                                      "heartbeat_retry_scheduled", "settings_sync_failed", "parent_status_failed",
                                      "backend_unavailable", "watch_sync_failed", "watch_snapshot_failed", "watch_snapshot_received"]
        let fingerprint = "event_\(event)_\(code ?? 0)"
        if repetitive.contains(event), let last = recent[fingerprint], Date().timeIntervalSince(last) < 60 { return }
        recent[fingerprint] = Date()
        append(event + (code.map { " code=\($0)" } ?? ""))
    }
    func network(operation: String, outcome: String, status: Int? = nil, requestID: UUID? = nil,
                 elapsedMS: Int, storageUnavailable: Bool = false) {
        let operations: Set<String> = ["register", "pairing_create", "pairing_claim", "push_token", "watch_token", "heartbeat", "alert", "status", "settings", "acknowledge"]
        guard operations.contains(operation), ["ok", "http_error", "transport_error", "decode_error", "cancelled", "invalid_response"].contains(outcome) else { return }
        // Routine successes are sampled; preserve a failure and its first recovery.
        let failureKey = "failure_\(operation)"
        let fingerprint = "network_\(operation)_\(outcome)_\(status ?? 0)"
        let recovered = outcome == "ok" && recent.removeValue(forKey: failureKey) != nil
        if outcome != "ok" { recent[failureKey] = Date() }
        let routine = ["status", "heartbeat"].contains(operation)
        let sample = outcome == "ok" ? routine : operation != "alert"
        if sample, !recovered, !storageUnavailable, let last = recent[fingerprint], Date().timeIntervalSince(last) < (outcome == "ok" ? 900 : 60) { return }
        recent[fingerprint] = Date()
        var entry = "network operation=\(operation) outcome=\(outcome) elapsed_ms=\(max(0, elapsedMS))"
        if let status { entry += " status=\(status)" }
        if let requestID { entry += " request_id=\(requestID.uuidString.lowercased())" }
        if storageUnavailable { entry += " server_diagnostics=unavailable" }
        append(entry)
    }
    private func append(_ event: String) {
        lines.append("\(Date().formatted(.iso8601)) \(event)"); lines = Array(lines.suffix(500))
        do {
            guard let url else { persistenceAvailable = false; return }
            let data = Data(lines.joined(separator: "\n").utf8)
            #if os(iOS) || os(watchOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var protectedURL = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            persistenceAvailable = true
        } catch { persistenceAvailable = false }
    }
    var export: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "Crib Service diagnostics · app=\(version) build=\(build) os=\(ProcessInfo.processInfo.operatingSystemVersionString)\npersistence=\(persistenceAvailable ? "available" : "unavailable")\n" + lines.joined(separator: "\n")
    }
}
