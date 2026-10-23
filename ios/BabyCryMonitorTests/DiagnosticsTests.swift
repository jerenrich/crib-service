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
        let body = path.contains("decode-error") ? "private-response-body" : (status == 503 ? "{\"error\":\"private-server-message\"}" : "{\"ok\":true}")
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DiagnosticsTests: XCTestCase {
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
                      "request_id=6705ae24-2863-49df-8dc5-5fa15b2d0418", "server_diagnostics=unavailable"] {
            XCTAssertTrue(exported.contains(value), value)
        }
    }
}
#endif
