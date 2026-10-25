import Foundation
import Observation

@MainActor @Observable final class DiagnosticLog {
    static let maximumLines = 10_000
    private static let compactionSlack = 1_000
    private(set) var lines: [String] = []
    private(set) var persistenceAvailable = true
    private(set) var persistenceFailure: String?
    private let url: URL?
    private let batteryDrain: BatteryDrainLog
    let benchmark: BackgroundBenchmark
    private var recent: [String: Date] = [:]
    private var watchTraceKeys: Set<String> = []
    private var persistedLineCount = 0
    private var storagePrepared = false
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let events: Set<String> = [
        "alert_pipeline_ready", "app_launched", "foreground", "background", "monitoring_recovered_after_relaunch",
        "paired_successfully", "pairing_created", "pairing_failed", "credential_failed", "metadata_load_failed",
        "monitoring_started", "monitoring_stopped", "monitoring_paused", "monitoring_start_failed", "microphone_permission_denied",
        "test_push_queued", "audio_active", "audio_recovering", "audio_interrupted", "audio_stalled",
        "audio_interruption_began", "audio_interruption_ended", "audio_route_changed", "audio_services_reset", "audio_engine_changed",
        "crying_started", "possible_cry", "crying_ended", "crying_resumed", "quiet_gap_started",
        "alert_threshold_reached", "metadata_write_failed", "alert_apns_accepted", "alert_acknowledged",
        "alert_delivery_failed", "alert_uncertain", "alert_blocked", "alert_server_pending", "alert_retry_scheduled",
        "test_push_apns_accepted", "heartbeat_retry_scheduled", "heartbeat_recovered", "settings_synced",
        "settings_sync_failed", "parent_status_failed", "parent_status_recovered", "backend_unavailable",
        "network_available", "network_unavailable", "push_token_received", "push_token_uploaded", "push_received",
        "notification_permission_allowed", "notification_permission_denied", "notification_permission_failed",
        "notification_sound_permission_before_request", "notification_alert_permission", "notification_sound_permission", "notification_time_sensitive_permission",
        "parent_connection_warning_armed", "parent_connection_warning_cancelled", "parent_connection_warning_failed",
        "push_registration_failed", "local_notification_scheduled", "local_notification_failed", "watch_sync_failed", "watch_token_synced",
        "watch_notification_authorization", "watch_alert_permission", "watch_sound_permission", "watch_time_sensitive_permission",
        "watch_payload_unrecognized", "watch_foreground_notification", "watch_haptic_started", "watch_haptic_requested", "watch_haptic_stopped", "watch_haptic_inactive", "watch_acknowledgement_requested",
        "watch_acknowledged", "watch_acknowledgement_discarded", "watch_activation_failed", "watch_activated", "watch_reachable", "watch_unreachable",
        "watch_snapshot_failed", "watch_snapshot_received", "watch_command_queued", "watch_command_failed", "watch_push_received",
        "monitoring_start_blocked_safety", "monitoring_start_blocked_storage", "test_push_failed",
        "acknowledgement_failed", "connection_preferences_failed", "device_removal_failed",
        "calibration_failed", "listener_status_failed", "monitoring_control_failed", "resume_alerts_failed", "timeline_failed"
    ]
    init(directory: URL? = nil) {
        let folder = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        url = folder?.appendingPathComponent("diagnostics.txt")
        batteryDrain = BatteryDrainLog(directory: folder)
        benchmark = BackgroundBenchmark(directory: folder)
        do {
            guard let folder, let url else { persistenceAvailable = false; return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let saved = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                persistedLineCount = saved.count
                lines = Array(saved.suffix(Self.maximumLines))
                watchTraceKeys = Set(lines.compactMap(WatchAlertTrace.key(in:)))
            }
        } catch { persistenceAvailable = false; persistenceFailure = Self.errorDetails(error) }
    }
    func battery(batteryLevel: Double?, powerConnected: Bool?, monitoring: Bool, audioActive: Bool,
                 lowPowerMode: Bool, appActive: Bool, at now: Date) {
        batteryDrain.record(batteryLevel: batteryLevel, powerConnected: powerConnected, monitoring: monitoring,
                            audioActive: audioActive, lowPowerMode: lowPowerMode, appActive: appActive, at: now)
    }
    func record(_ event: String, code: Int? = nil, error: (any Error)? = nil) {
        // Enforced allowlist: callers cannot accidentally append an exception, token or URL.
        guard Self.events.contains(event) else { return }
        let repetitive: Set<String> = ["alert_retry_scheduled", "alert_uncertain", "alert_blocked", "alert_server_pending",
                                      "heartbeat_retry_scheduled", "settings_sync_failed", "parent_status_failed",
                                      "backend_unavailable", "watch_sync_failed", "watch_snapshot_failed", "watch_snapshot_received",
                                      "listener_status_failed", "monitoring_start_blocked_storage", "monitoring_start_blocked_safety",
                                      "parent_connection_warning_armed", "parent_connection_warning_failed", "watch_payload_unrecognized"]
        let details = error.map { Self.errorDetails($0) } ?? ""
        let fingerprint = "event_\(event)_\(code ?? 0)_\(details)"
        if repetitive.contains(event), let last = recent[fingerprint], Date().timeIntervalSince(last) < 60 { return }
        recent[fingerprint] = Date()
        append(event + (code.map { " code=\($0)" } ?? "") + (details.isEmpty ? "" : " " + details))
    }
    func network(operation: String, outcome: String, status: Int? = nil, requestID: UUID? = nil,
                 elapsedMS: Int, storageUnavailable: Bool = false, error: (any Error)? = nil, eventID: UUID? = nil, benchmarkAttempt: UUID? = nil, serverDiagnosticMS: Int? = nil) {
        let operations: Set<String> = ["register", "pairing_create", "pairing_claim", "push_token", "watch_token", "heartbeat", "alert", "status", "timeline", "monitoring", "monitoring_complete", "settings", "acknowledge", "test_push", "connection_preferences", "unpair", "delete_device", "resume_alerts"]
        guard operations.contains(operation), ["ok", "http_error", "transport_error", "decode_error", "encode_error", "cancelled", "invalid_response"].contains(outcome) else { return }
        if operation == "status" {
            benchmark.requestFinished(benchmarkAttempt, outcome: outcome, requestID: requestID, status: status, elapsedMS: elapsedMS)
        }
        // Routine successes are sampled; preserve a failure and its first recovery.
        let failureKey = "failure_\(operation)"
        let details = error.map { Self.errorDetails($0) } ?? ""
        let fingerprint = "network_\(operation)_\(outcome)_\(status ?? 0)_\(details)"
        let recovered = outcome == "ok" && recent.removeValue(forKey: failureKey) != nil
        if outcome != "ok" { recent[failureKey] = Date() }
        let routine = ["status", "heartbeat", "timeline"].contains(operation)
        let sample = outcome == "ok" ? routine : operation != "alert"
        if sample, elapsedMS < 2000, !recovered, !storageUnavailable, (serverDiagnosticMS ?? 0) < 2000, let last = recent[fingerprint], Date().timeIntervalSince(last) < (outcome == "ok" ? 900 : 60) { return }
        recent[fingerprint] = Date()
        var entry = "network operation=\(operation) outcome=\(outcome) elapsed_ms=\(max(0, elapsedMS))"
        if let status { entry += " status=\(status)" }
        if let requestID { entry += " request_id=\(requestID.uuidString.lowercased())" }
        if operation == "alert", let eventID { entry += " event_id=\(eventID.uuidString.lowercased())" }
        if storageUnavailable { entry += " server_diagnostics=unavailable" }
        if let serverDiagnosticMS, (0...3_600_000).contains(serverDiagnosticMS) { entry += " server_diagnostic_ms=\(serverDiagnosticMS)" }
        if !details.isEmpty { entry += " " + details }
        append(entry)
    }
    func alertPersisted(_ alert: CryAlert, at now: Date, elapsedMS: Int) {
        alertOutbox(alert, phase: "persisted", at: now, extra: " persistence_ms=\(max(0, elapsedMS))")
    }
    func alertUploadStarted(_ alert: CryAlert, attempt: Int, at now: Date) {
        alertOutbox(alert, phase: "upload_started", at: now, extra: " attempt=\(max(1, attempt))")
    }
    private func alertOutbox(_ alert: CryAlert, phase: String, at now: Date, extra: String) {
        let created = alert.createdAt.timeIntervalSince1970 * 1000, observed = now.timeIntervalSince1970 * 1000
        guard created.isFinite, observed.isFinite, abs(created) < 9e15, abs(observed) < 9e15 else { return }
        let age = Int64(observed.rounded()) - Int64(created.rounded())
        append("alert_outbox phase=\(phase) event_id=\(alert.eventId.uuidString.lowercased()) generated_at_ms=\(Int64(created.rounded())) observed_at_ms=\(Int64(observed.rounded())) age_ms=\(age)" + extra + (age < 0 ? " clock_order=check" : ""))
    }
    func watchAlert(_ trace: WatchAlertTrace) {
        watchAlerts([trace])
    }
    func watchAlerts(_ traces: [WatchAlertTrace]) {
        var entries: [String] = []
        for trace in traces {
            guard !watchTraceKeys.contains(trace.key), let entry = trace.entry else { continue }
            watchTraceKeys.insert(trace.key)
            entries.append("\(trace.observedAt.formatted(Self.timestampStyle)) \(entry)")
        }
        // A recovered Notification Center history needs only one atomic write.
        if !entries.isEmpty { appendLines(entries) }
    }
    /// Error descriptions, debug descriptions and userInfo can contain payloads, paths or secrets.
    /// Export only known categories, numeric codes and allowlisted schema keys, with a bounded cause chain.
    private static func errorDetails(_ error: any Error, depth: Int = 0) -> String {
        #if os(iOS)
        if let failure = error as? MetadataStoreError {
            return "operation=metadata_\(failure.operation.rawValue) " + errorDetails(failure.underlyingError, depth: depth)
        }
        if let failure = error as? KeychainError {
            return "error=keychain domain=NSOSStatusErrorDomain code=\(failure.status)"
        }
        if let failure = error as? BackendError {
            switch failure {
            case .message: return "error=backend_configuration_or_response"
            case .response(let status, _): return "error=backend_http status=\(status)"
            }
        }
        #endif
        if error is CancellationError { return "error=cancelled" }
        let nsError = error as NSError
        let domains: Set<String> = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                                   "AVFoundationErrorDomain", "com.apple.coreaudio.avfaudio", "AVAudioSessionErrorDomain",
                                   "WCErrorDomain", "UNErrorDomain", "CribService.Audio"]
        let domain = domains.contains(nsError.domain) ? nsError.domain : "other"
        var result = "domain=\(domain) code=\(nsError.code)"
        var context: DecodingError.Context?
        switch error {
        case DecodingError.keyNotFound(let key, let value):
            result += " error=decoding_key_not_found path=\(schemaPath(value.codingPath + [key]))"; context = value
        case DecodingError.valueNotFound(_, let value):
            result += " error=decoding_value_not_found path=\(schemaPath(value.codingPath))"; context = value
        case DecodingError.typeMismatch(_, let value):
            result += " error=decoding_type_mismatch path=\(schemaPath(value.codingPath))"; context = value
        case DecodingError.dataCorrupted(let value):
            result += " error=decoding_data_corrupted path=\(schemaPath(value.codingPath))"; context = value
        case EncodingError.invalidValue(_, let value):
            result += " error=encoding_invalid_value path=\(schemaPath(value.codingPath))"
            if depth < 3, let underlying = value.underlyingError {
                result += " underlying={\(errorDetails(underlying, depth: depth + 1))}"
            }
        default:
            // Stable descriptions for common failures; no interpolated system exception text.
            let reasons: [Int: String] = [
                NSFileNoSuchFileError: "file_not_found", NSFileReadNoPermissionError: "file_read_permission_denied",
                NSFileReadCorruptFileError: "file_read_corrupt", NSFileReadNoSuchFileError: "file_read_not_found",
                NSFileWriteNoPermissionError: "file_write_permission_denied", NSFileWriteOutOfSpaceError: "file_write_out_of_space",
                NSFileWriteVolumeReadOnlyError: "file_write_read_only"
            ]
            if nsError.domain == NSCocoaErrorDomain, let reason = reasons[nsError.code] { result += " error=\(reason)" }
            else if nsError.domain == "CribService.Audio" { result += " error=microphone_input_unavailable" }
        }
        if depth < 3, let underlying = context?.underlyingError ?? nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            result += " underlying={\(errorDetails(underlying, depth: depth + 1))}"
        }
        return result
    }
    private static func schemaPath(_ keys: [any CodingKey]) -> String {
        let allowed: Set<String> = [
            "configuration", "history", "current", "pending", "failedAlerts", "lastObservedAt", "wasMonitoring",
            "alertDuration", "quietResetDuration", "sensitivity", "repeatInterval", "absoluteThreshold",
            "id", "startedAt", "endedAt", "alertQueuedAt", "alertSentAt", "lastAlertQueuedAt", "maximumDBFS", "averageDBFS", "sampleCount",
            "alert", "attempts", "nextAttemptAt", "failedAt", "eventId", "episodeId", "listenerId", "type", "cryStartedAt",
            "durationSeconds", "createdAt", "isRepeat", "isTest", "paired", "pairingID", "watchPushRegistered", "phonePushRegistered",
            "connectionAlertsEnabled", "listenerConfiguration", "lastHeartbeat", "serverTime", "nextHeartbeatExpectedAt", "monitoring", "batteryLevel", "powerConnected",
            "state", "currentEpisode", "episodes", "alerts", "status", "acknowledgedAt", "deliveryTarget", "ok", "expiresAt",
            "deviceId", "role", "registered", "updatedAt", "parentMode", "message", "acknowledgedEventId", "kind"
        ]
        return "$" + keys.prefix(12).map { key in
            if let index = key.intValue, index >= 0 { return "[\(index)]" }
            return "." + (allowed.contains(key.stringValue) ? key.stringValue : "<redacted>")
        }.joined() + (keys.count > 12 ? ".<truncated>" : "")
    }
    private func append(_ event: String) {
        appendLines(["\(Date().formatted(Self.timestampStyle)) \(event)"])
    }
    private func appendLines(_ entries: [String]) {
        lines.append(contentsOf: entries)
        if lines.count > Self.maximumLines {
            for line in lines.prefix(lines.count - Self.maximumLines) {
                if let key = WatchAlertTrace.key(in: line) { watchTraceKeys.remove(key) }
            }
            lines = Array(lines.suffix(Self.maximumLines))
        }
        do {
            guard let url else { persistenceAvailable = false; return }
            // Append only the new rows. Compact occasionally, rather than rewriting
            // several MB on every notification. The plain-text file stays directly
            // readable; its temporary overlap is bounded to 1,000 older rows.
            if !storagePrepared || persistedLineCount + entries.count > Self.maximumLines + Self.compactionSlack
                || !FileManager.default.fileExists(atPath: url.path) {
                let data = Data(lines.joined(separator: "\n").utf8)
            #if os(iOS) || os(watchOS)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try data.write(to: url, options: .atomic)
            #endif
                var protectedURL = url
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protectedURL.setResourceValues(values)
                persistedLineCount = lines.count
                storagePrepared = true
            } else {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                let offset = try file.seekToEnd()
                try file.write(contentsOf: Data(((offset > 0 ? "\n" : "") + entries.joined(separator: "\n")).utf8))
                persistedLineCount += entries.count
            }
            persistenceAvailable = true; persistenceFailure = nil
        } catch {
            // A failed append may be partial. Repair from the bounded in-memory
            // snapshot on the next write instead of appending to uncertain data.
            storagePrepared = false
            persistenceAvailable = false; persistenceFailure = Self.errorDetails(error)
        }
    }
    private var exportHeader: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "Crib Service diagnostics · app=\(version) build=\(build) os=\(ProcessInfo.processInfo.operatingSystemVersionString)\npersistence=\(persistenceAvailable ? "available" : "unavailable")\n"
            + "retention_limit=\(Self.maximumLines) retained_lines=\(lines.count)\n"
            + (persistenceFailure.map { "diagnostic_storage_error \($0)\n" } ?? "")
    }
    var recentExport: String { exportHeader + lines.joined(separator: "\n") }
    var previewExport: String {
        exportHeader + "Showing latest \(min(200, lines.count)) retained lines. Full history is available in the diagnostic log.\n"
            + lines.suffix(200).joined(separator: "\n")
    }
    var export: String { recentExport + "\n\n" + batteryDrain.export }
}
