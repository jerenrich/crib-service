#if !canImport(MonitorCore)
import Foundation
import XCTest
@testable import BabyCryMonitor

private final class DiagnosticsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.contains("transport") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://private-host/private-token"]))
            return
        }
        let status = path.contains("http-error") ? 503 : 200
        let requestID = path.contains("invalid-id") ? "private-token" : "6705ae24-2863-49df-8dc5-5fa15b2d0418"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["x-request-id": requestID, "x-diagnostics-status": "unavailable"])!
        let body: String
        if path.contains("schema-error") { body = "{\"quietResetDuration\":20,\"sensitivity\":\"medium\",\"absoluteThreshold\":-35}" }
        else if path.contains("date-error") { body = "{\"code\":\"private-pairing-code\",\"expiresAt\":\"private-invalid-timestamp\"}" }
        else if path.hasSuffix("/v1/listener/event") { body = "{\"status\":\"sent\"}" }
        else { body = path.contains("decode-error") ? "private-response-body" : (status == 503 ? "{\"error\":\"private-server-message\"}" : "{\"ok\":true}") }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DiagnosticsTests: XCTestCase {
    @MainActor func testWatchTraceDeduplicatesAcrossCallbacksAndRelaunchButPreservesDistinctPhases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let alert = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: created,
                                  createdAt: created, duration: 5, isTest: false)
        let trace = WatchAlertTrace(alert: alert, phase: .retained,
                                   deliveredAt: created.addingTimeInterval(1.125), observedAt: created.addingTimeInterval(30.625))
        let log = DiagnosticLog(directory: directory)
        for _ in 0..<100 { log.watchAlert(trace) }
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertTrue(log.lines[0].hasPrefix("2027-01-15T08:00:30.625Z "))
        XCTAssertTrue(log.lines[0].contains("callback_lag_ms=29500"))
        let restored = DiagnosticLog(directory: directory)
        restored.watchAlert(trace)
        XCTAssertEqual(restored.lines, log.lines)
        restored.watchAlert(WatchAlertTrace(alert: alert, phase: .opened, deliveredAt: trace.deliveredAt, observedAt: trace.observedAt))
        XCTAssertEqual(restored.lines.count, 2)
        restored.watchAlerts([trace, trace])
        XCTAssertEqual(restored.lines.count, 2, "Repeated foreground history scans must not grow the log")
        for _ in 0..<500 { restored.record("foreground") }
        XCTAssertEqual(restored.lines.count, 500)
        restored.watchAlert(trace)
        XCTAssertEqual(restored.lines.count, 500)
        XCTAssertTrue(restored.lines.last?.contains("watch_alert phase=retained") == true, "Evicted keys must not accumulate forever")
    }
    @MainActor func testAlertNetworkLogLinksWatchEventToBackendRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let credential = DeviceCredential(deviceId: UUID(), secret: "private-credential", role: .listener, registered: true)
        let client = BackendClient(baseURL: URL(string: "https://private-host")!, credential: credential, log: log, session: session)
        let alert = CryAlert(episodeId: UUID(), listenerId: credential.deviceId, cryStartedAt: Date(),
                             durationSeconds: 5, createdAt: Date(), isRepeat: false)
        let receipt = try await client.send(alert)
        XCTAssertEqual(receipt.status, "sent")
        XCTAssertEqual(log.lines.count, 1, "Correlation must reuse the existing network log write")
        XCTAssertTrue(log.lines[0].contains("event_id=\(alert.eventId.uuidString.lowercased())"))
        XCTAssertTrue(log.lines[0].contains("request_id=6705ae24-2863-49df-8dc5-5fa15b2d0418"))
        XCTAssertFalse(log.export.contains(credential.deviceId.uuidString.lowercased()))
        XCTAssertFalse(log.export.contains("private-credential"))
        XCTAssertFalse(log.export.contains("private-host"))
        log.network(operation: "status", outcome: "ok", elapsedMS: 1, eventID: alert.eventId)
        XCTAssertFalse(log.lines.last!.contains("event_id="), "Only alert operations may add event identifiers")
    }
    @MainActor func testBatteryHistorySurvivesDiagnosticRingAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.battery(batteryLevel: 0.65, powerConnected: false, monitoring: true, audioActive: true,
                    lowPowerMode: false, appActive: false, at: Date())
        for _ in 0..<600 { log.record("foreground") }
        XCTAssertEqual(log.lines.count, 500)
        let restored = DiagnosticLog(directory: directory)
        XCTAssertTrue(restored.export.contains("Battery drain samples"))
        XCTAssertTrue(restored.export.contains(",65.00,0,1,1,0,0"))
        XCTAssertTrue(restored.export.contains("sampled_at,run_id,battery_percent"))
    }
    @MainActor func testBoundedPersistentLogAndPrivacyAllowlist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.record("Bearer secret-token")
        log.record("https://private-url")
        XCTAssertTrue(log.lines.isEmpty)
        for _ in 0..<510 { log.record("foreground") }
        XCTAssertEqual(log.lines.count, 500)
        XCTAssertTrue(log.persistenceAvailable)
        XCTAssertEqual(DiagnosticLog(directory: directory).lines, log.lines)
        let url = directory.appendingPathComponent("diagnostics.txt")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(log.export.contains("build="))
        XCTAssertFalse(log.export.contains("secret-token"))
    }
    @MainActor func testPersistenceFailureKeepsExportAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.record("metadata_write_failed")
        XCTAssertFalse(log.persistenceAvailable)
        XCTAssertTrue(log.export.contains("metadata_write_failed"))
        XCTAssertTrue(log.export.contains("persistence=unavailable"))
        XCTAssertTrue(log.export.contains("diagnostic_storage_error domain=NSCocoaErrorDomain code="))
    }
    @MainActor func testRoutineNetworkSamplingPreservesFirstRecovery() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.network(operation: "status", outcome: "ok", elapsedMS: 1)
        log.network(operation: "status", outcome: "ok", elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 1)
        log.network(operation: "status", outcome: "http_error", status: 503, elapsedMS: 1)
        log.network(operation: "status", outcome: "http_error", status: 503, elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 2)
        log.network(operation: "status", outcome: "ok", elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 3)
        log.network(operation: "private-url", outcome: "ok", elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 3)
        log.network(operation: "alert", outcome: "ok", elapsedMS: 1)
        log.network(operation: "alert", outcome: "ok", elapsedMS: 1)
        log.network(operation: "alert", outcome: "http_error", status: 503, elapsedMS: 1)
        log.network(operation: "alert", outcome: "http_error", status: 503, elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 7, "Every alert attempt must retain its request reference")
    }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(_ value: String) { stringValue = value; intValue = nil }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { stringValue = "Index \(intValue)"; self.intValue = intValue }
    }
    @MainActor func testExceptionDetailsIncludeSchemaPathAndRedactUntrustedText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSLocalizedDescriptionKey: "private-token"])
        let context = DecodingError.Context(codingPath: [Key("history"), Key(intValue: 0)!],
            debugDescription: "private-response-body", underlyingError: underlying)
        log.record("metadata_load_failed", error: MetadataStoreError(operation: .decode,
            underlyingError: DecodingError.keyNotFound(Key("sampleCount"), context)))
        log.record("metadata_write_failed", error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
            userInfo: [NSFilePathErrorKey: "/private/secret", NSLocalizedDescriptionKey: "private-description", NSUnderlyingErrorKey: underlying]))
        let privateContext = DecodingError.Context(codingPath: [Key("private-key"), Key("token")], debugDescription: "private-debug")
        log.record("watch_snapshot_failed", error: DecodingError.typeMismatch(String.self, privateContext))
        log.record("credential_failed", error: KeychainError(status: -25308))
        log.record("backend_unavailable", error: BackendError.response(503, "private-server-message"))
        log.record("audio_interrupted", error: CancellationError())
        log.record("pairing_failed", error: NSError(domain: "private-domain", code: 42))
        let exported = log.export
        for value in ["operation=metadata_decode", "error=decoding_key_not_found", "path=$.history[0].sampleCount",
                      "domain=NSPOSIXErrorDomain code=13", "error=file_write_out_of_space", "underlying={",
                      "path=$.<redacted>.<redacted>", "error=keychain domain=NSOSStatusErrorDomain code=-25308",
                      "error=backend_http status=503", "error=cancelled", "domain=other code=42"] {
            XCTAssertTrue(exported.contains(value), value)
        }
        for value in ["private-token", "private-response-body", "/private/secret", "private-description",
                      "private-key", "private-debug", "private-server-message", "private-domain"] {
            XCTAssertFalse(exported.contains(value), value)
        }
        XCTAssertEqual(DiagnosticLog(directory: directory).lines, log.lines)
    }
    @MainActor func testEncodingAndOtherDecodingFailuresAreClassifiedAndBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let context = DecodingError.Context(codingPath: [Key("configuration"), Key("alertDuration")], debugDescription: "secret")
        log.record("metadata_write_failed", error: EncodingError.invalidValue(Double.nan, .init(codingPath: context.codingPath, debugDescription: "secret")))
        log.record("metadata_load_failed", error: DecodingError.valueNotFound(Double.self, context))
        log.record("metadata_load_failed", error: DecodingError.dataCorrupted(context))
        var nested = NSError(domain: NSPOSIXErrorDomain, code: 1)
        for code in 2...10 { nested = NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSUnderlyingErrorKey: nested]) }
        log.record("metadata_load_failed", error: nested)
        XCTAssertTrue(log.export.contains("error=encoding_invalid_value path=$.configuration.alertDuration"))
        XCTAssertTrue(log.export.contains("error=decoding_value_not_found"))
        XCTAssertTrue(log.export.contains("error=decoding_data_corrupted"))
        XCTAssertEqual(log.lines.last?.components(separatedBy: "underlying={").count, 4)
        XCTAssertFalse(log.export.contains("secret"))
    }
    @MainActor func testThrottlingPreservesDifferentExceptionCauses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        for code in [NSFileReadNoPermissionError, NSFileReadNoPermissionError, NSFileReadCorruptFileError] {
            log.record("monitoring_start_blocked_storage", error: NSError(domain: NSCocoaErrorDomain, code: code))
        }
        XCTAssertEqual(log.lines.count, 2)
        for field in ["history", "history", "configuration"] {
            let error = DecodingError.keyNotFound(Key(field), .init(codingPath: [], debugDescription: "secret"))
            log.network(operation: "heartbeat", outcome: "decode_error", status: 200, elapsedMS: 1, error: error)
        }
        XCTAssertEqual(log.lines.count, 4)
        log.network(operation: "heartbeat", outcome: "ok", status: 200, elapsedMS: 1)
        XCTAssertEqual(log.lines.count, 5)
    }
    @MainActor func testBackendSerializationFailuresIncludeTheFieldAndRequestReference() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let credential = DeviceCredential(deviceId: UUID(), secret: "private-credential", role: .listener, registered: true)
        let heartbeat = Heartbeat(listenerId: credential.deviceId, timestamp: Date(), monitoring: true,
            batteryLevel: nil, powerConnected: false, state: .quiet, currentEpisode: nil, episodes: [])
        let client = BackendClient(baseURL: URL(string: "https://private-host/schema-error")!, credential: credential, log: log, session: session)
        do { _ = try await client.heartbeat(heartbeat); XCTFail("Expected a missing field") } catch { }
        XCTAssertTrue(log.export.contains("error=decoding_key_not_found path=$.alertDuration"))
        XCTAssertTrue(log.export.contains("request_id=6705ae24-2863-49df-8dc5-5fa15b2d0418"))
        let dateClient = BackendClient(baseURL: URL(string: "https://private-host/date-error")!, credential: credential, log: log, session: session)
        do { _ = try await dateClient.createPairing(); XCTFail("Expected an invalid timestamp") } catch { }
        XCTAssertTrue(log.export.contains("error=decoding_data_corrupted path=$.expiresAt"))
        var invalidConfig = MonitoringConfiguration(); invalidConfig.alertDuration = .nan
        do { try await client.settings(invalidConfig); XCTFail("Expected a non-finite encoding error") } catch { }
        XCTAssertTrue(log.export.contains("operation=settings outcome=encode_error"))
        XCTAssertTrue(log.export.contains("error=encoding_invalid_value path=$.alertDuration"))
        for value in ["private-credential", "private-host", "private-pairing-code", "private-invalid-timestamp"] {
            XCTAssertFalse(log.export.contains(value), value)
        }
    }
    @MainActor func testBackendDiagnosticsExcludeCredentialsURLsAndResponseBodies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let credential = DeviceCredential(deviceId: UUID(), secret: "private-credential", role: .listener, registered: true)
        for scenario in ["ok", "http-error", "transport", "decode-error", "invalid-id"] {
            let client = BackendClient(baseURL: URL(string: "https://private-host/\(scenario)")!, credential: credential, log: log, session: session)
            do { try await client.register() } catch { /* Expected errors must still produce safe diagnostics. */ }
        }
        let exported = log.export
        for value in ["private-host", "private-credential", "private-token", "private-server-message", "private-response-body", credential.deviceId.uuidString] {
            XCTAssertFalse(exported.contains(value), value)
        }
        for value in ["outcome=ok", "outcome=http_error", "outcome=transport_error", "outcome=decode_error", "status=503", "status=-1001",
                      "request_id=6705ae24-2863-49df-8dc5-5fa15b2d0418", "server_diagnostics=unavailable",
                      "domain=NSURLErrorDomain code=-1001", "error=decoding_data_corrupted path=$"] {
            XCTAssertTrue(exported.contains(value), value)
        }
    }
}
#endif
