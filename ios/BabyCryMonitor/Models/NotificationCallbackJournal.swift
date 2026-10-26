import Foundation

/// A tiny synchronous append at callback entry, independent of the main-actor
/// model/logger. Two bounded segments retain repeated callbacks across relaunch.
/// No fsync, network requests, notification changes or background execution.
final class NotificationCallbackJournal: @unchecked Sendable {
    static let shared = NotificationCallbackJournal()
    static let segmentBytes = 2 * 1024 * 1024
    enum Lifecycle: String { case launch, foreground, inactive, background }
    private let lock = NSLock()
    private let directory: URL?
    private let maximumSegmentBytes: Int
    private let processID = UUID()
    private let started = ContinuousClock.now
    private var handle: FileHandle?
    private var size = 0
    private var sequence = 0
    private var failures = 0
    private var rotations = 0
    private var prepared = false
    private var repairedTails = 0
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(directory: URL? = nil, segmentBytes: Int = NotificationCallbackJournal.segmentBytes) {
        self.directory = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        maximumSegmentBytes = max(1024, segmentBytes)
    }
    deinit { try? handle?.close() }

    @discardableResult func record(_ trace: WatchAlertTrace) -> Int {
        switch trace.phase {
        case .foreground, .controllerReceived, .controllerActivated, .controllerDeactivated, .viewAppeared, .opened, .acknowledged: break
        default: return 0 // A history scan must never masquerade as callback entry.
        }
        guard trace.callbackID != nil, let entry = trace.entry else { return 0 }
        return append(at: trace.observedAt, entry.replacingOccurrences(of: "watch_alert ", with: "watch_callback ", options: .anchored))
    }
    func presentationProfile(_ profile: WatchNotificationPresentation = .current, at now: Date = Date()) {
        _ = append(at: now, "watch_notification_presentation profile=\(profile.rawValue)")
    }
    func lifecycle(_ phase: Lifecycle, at now: Date = Date()) {
        _ = append(at: now, "watch_callback_lifecycle phase=\(phase.rawValue)")
    }
    func checkpoint(historyCount: Int? = nil, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let count = historyCount.map { " delivered_history_count=\(min(100_000, max(0, $0)))" } ?? ""
        write(at: now, "watch_callback_coverage schema=1 segment_bytes=\(maximumSegmentBytes) segments=2 write_failures=\(failures) rotations=\(rotations) repaired_tails=\(repairedTails)" + count)
    }
    private func append(at now: Date, _ entry: String) -> Int {
        let start = ContinuousClock.now
        lock.lock(); defer { lock.unlock() }
        write(at: now, entry)
        return DiagnosticTiming.elapsedMS(since: start)
    }
    private func write(at now: Date, _ entry: String) {
        guard DiagnosticTiming.milliseconds(now) != nil, let directory else { failures += 1; return }
        do {
            let url = directory.appendingPathComponent("watch-callbacks.log")
            if !prepared {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try open(url); prepared = true
            }
            sequence += 1
            let line = "\(now.formatted(Self.timestamp)) \(entry) callback_process_id=\(processID.uuidString.lowercased()) journal_sequence=\(sequence) process_elapsed_ms=\(DiagnosticTiming.elapsedMS(since: started))\n"
            let bytes = Data(line.utf8)
            if size + bytes.count > maximumSegmentBytes {
                try handle?.close(); handle = nil
                let previous = directory.appendingPathComponent("watch-callbacks.previous.log")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
                rotations += 1
                try open(url)
            }
            guard let handle else { throw CocoaError(.fileWriteUnknown) }
            try handle.write(contentsOf: bytes); size += bytes.count
        } catch {
            failures += 1; try? handle?.close(); handle = nil; prepared = false
        }
    }
    private func open(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
        // A terminated/failed write may leave a partial final record. Repair only
        // at open; ordinary callback appends never scan or rewrite the journal.
        if size > 0 {
            let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
            let offset = max(0, size - 8192)
            try reader.seek(toOffset: UInt64(offset))
            let tail = try reader.readToEnd() ?? Data()
            if tail.last != 10 {
                size = tail.lastIndex(of: 10).map { offset + $0 + 1 } ?? 0
                try handle!.truncate(atOffset: UInt64(size)); try handle!.seekToEnd()
                repairedTails += 1
            }
        }
    }
}
