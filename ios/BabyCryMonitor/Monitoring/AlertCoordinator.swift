import Foundation

public struct AlertReceipt: Codable, Sendable {
    public let status: String
    public init(status: String) { self.status = status }
}
public protocol AlertSending: Sendable {
    func send(_ alert: CryAlert) async throws -> AlertReceipt
}
/// Delivery transport is independent of detection, UIKit, and any future watchOS companion.
/// The caller owns persistence and commits each result before scheduling another retry.
@MainActor public final class AlertCoordinator {
    private var sending = false
    public init() {}
    public func deliverReady(_ pending: [PendingAlert], listenerId: UUID, now: Date, sender: any AlertSending, willSend: ((CryAlert, Int) -> Void)? = nil,
                             receive: (CryAlert, Result<AlertReceipt, Error>) -> Void) async {
        guard !sending else { return }
        sending = true; defer { sending = false }
        for item in pending where item.nextAttemptAt <= now && item.alert.listenerId == listenerId {
            guard !Task.isCancelled else { return }
            willSend?(item.alert, item.attempts + 1)
            do { receive(item.alert, .success(try await sender.send(item.alert))) }
            catch { receive(item.alert, .failure(error)) }
        }
    }
}
