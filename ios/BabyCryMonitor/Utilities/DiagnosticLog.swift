import Foundation
import Observation

@MainActor @Observable final class DiagnosticLog {
    private(set) var lines: [String] = []
    private let url: URL?
    init(directory: URL? = nil) {
        let folder = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        url = folder?.appendingPathComponent("diagnostics.txt")
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) { lines = Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(500)) }
    }
    func record(_ event: String) {
        // Caller supplies fixed event names, never credentials, raw audio, URLs, or tokens.
        lines.append("\(Date().formatted(.iso8601)) \(event)"); lines = Array(lines.suffix(500))
        if let url { try? export.write(to: url, atomically: true, encoding: .utf8) }
    }
    var export: String { lines.joined(separator: "\n") }
}
