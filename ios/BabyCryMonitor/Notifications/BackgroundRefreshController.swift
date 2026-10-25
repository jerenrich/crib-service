import Observation
import BackgroundTasks
import UIKit

@MainActor protocol RefreshScheduling {
    func pendingDate() async -> Date?
    func submit(earliest: Date) async throws
    func cancel()
}
@MainActor private struct SystemRefreshScheduler: RefreshScheduling {
    func pendingDate() async -> Date? {
        let requests = await BGTaskScheduler.shared.pendingTaskRequests()
        return requests.first { $0.identifier == BackgroundRefreshController.identifier }?.earliestBeginDate
    }
    func submit(earliest: Date) async throws {
        // The iOS 27 submission API must not be invoked from the main thread.
        try await Task.detached(priority: .utility) {
            let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshController.identifier)
            request.earliestBeginDate = earliest
            if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
            else { try BGTaskScheduler.shared.submit(request) }
        }.value
    }
    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshController.identifier) }
}

/// This controller intentionally does not perform nursery polling or renew any real alarm.
@MainActor @Observable final class BackgroundRefreshController {
    nonisolated static let identifier = "com.jordanerenrich.cribservice.benchmark.refresh"
    static let shared = BackgroundRefreshController()
    let log: RefreshExperimentLog
    private(set) var registrationSucceeded = false
    private(set) var availability = "unknown"
    @ObservationIgnored private let scheduler: any RefreshScheduling
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var isParent: () -> Bool = { true }

    init(log: RefreshExperimentLog? = nil, scheduler: (any RefreshScheduling)? = nil) {
        let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.log = log ?? RefreshExperimentLog(directory: directory)
        self.scheduler = scheduler ?? SystemRefreshScheduler()
    }
    func register(isParent: @escaping () -> Bool) {
        self.isParent = isParent
        registrationSucceeded = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated { BackgroundRefreshController.shared.handle(task) }
        }
        Task { await reconcile() }
    }
    func setEnabled(_ enabled: Bool) async {
        if enabled, isParent() { log.start(); await reconcile() }
        else { log.stop(); scheduler.cancel() }
    }
    func maintain(parent: Bool, foreground: Bool) {
        guard log.enabled else { return }
        if !parent || log.expireIfNeeded() { log.stop(); scheduler.cancel(); return }
        // Only check/retry while our ordinary loop already has execution time.
        if foreground && Date().timeIntervalSince(lastCheck) >= 60 {
            Task { await reconcile() }
        }
    }
    func reconcile(at now: Date = Date()) async {
        guard !busy else { return }
        busy = true; defer { busy = false }; lastCheck = now
        availability = switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        log.expireIfNeeded(at: now)
        guard log.enabled, isParent() else { scheduler.cancel(); return }
        let expectedPendingID = log.pending?.id
        let pendingDate = await scheduler.pendingDate()
        guard log.enabled, isParent() else { scheduler.cancel(); return }
        // A delivery can occur while the OS queue snapshot is in flight.
        guard log.pending?.id == expectedPendingID else { return }
        log.reconcile(earliestBeginAt: pendingDate, at: now)
        if log.pending == nil, log.lastSubmissionAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            await schedule(at: now)
        }
    }
    private func schedule(at now: Date) async {
        guard let attempt = log.beginRequest(availability: availability, at: now), let earliest = attempt.earliestBeginAt else { return }
        do {
            try await scheduler.submit(earliest: earliest)
            log.submission(attempt.id, errorCode: nil)
            if !log.enabled || !isParent() || log.attempts.first(where: { $0.id == attempt.id })?.status == .cancelled { scheduler.cancel() }
        } catch {
            log.submission(attempt.id, errorCode: (error as NSError).code)
        }
    }
    private func handle(_ task: BGTask) {
        let id = log.delivered()
        task.expirationHandler = {
            Task { @MainActor in
                let log = BackgroundRefreshController.shared.log
                guard log.attempts.first(where: { $0.id == id })?.status == .delivered else { return }
                log.finished(id, expired: true)
                task.setTaskCompleted(success: false)
            }
        }
        Task { @MainActor in
            log.expireIfNeeded()
            if log.enabled, isParent() { await schedule(at: Date()) }
            else { scheduler.cancel() }
            if log.attempts.first(where: { $0.id == id })?.status == .delivered {
                log.finished(id, expired: false)
                task.setTaskCompleted(success: true)
            }
        }
    }
}
