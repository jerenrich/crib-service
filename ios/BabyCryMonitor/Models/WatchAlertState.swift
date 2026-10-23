import Foundation
import Observation

/// Alert selection and the durable acknowledgement queue, independent of WatchKit.
@MainActor @Observable final class WatchAlertState {
    private(set) var alert: WatchCryAlert?
    var acknowledgementPending: Bool { !pendingAcknowledgements.isEmpty }
    @ObservationIgnored var sendAcknowledgement: ((WatchCommand) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private var localAlert: WatchCryAlert?
    private var acknowledgedEpisodes: [UUID]
    private var pendingAcknowledgements: [UUID]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acknowledgedEpisodes = (defaults.stringArray(forKey: "acknowledgedEpisodes") ?? []).compactMap(UUID.init(uuidString:))
        if let saved = defaults.stringArray(forKey: "pendingAcknowledgements") {
            pendingAcknowledgements = saved.compactMap(UUID.init(uuidString:))
        } else {
            // Preserve acknowledgements queued by older Watch builds.
            pendingAcknowledgements = defaults.string(forKey: "pendingAcknowledgement").flatMap(UUID.init(uuidString:)).map { [$0] } ?? []
        }
        persist()
    }

    func receive(_ value: WatchCryAlert) {
        guard !acknowledgedEpisodes.contains(value.episodeId) else { return }
        localAlert = value
        alert = value
    }

    func handleNotification(_ value: WatchCryAlert, acknowledging: Bool) {
        if acknowledging { acknowledge(value) }
        else { receive(value) }
    }

    func acknowledgeCurrent() {
        guard let alert else { return }
        acknowledge(alert)
    }

    private func acknowledge(_ value: WatchCryAlert) {
        guard !acknowledgedEpisodes.contains(value.episodeId) else { return }
        acknowledgedEpisodes.append(value.episodeId)
        acknowledgedEpisodes = Array(acknowledgedEpisodes.suffix(100))
        pendingAcknowledgements.append(value.eventId)
        // A notification action may refer to an older episode than the visible alert.
        if alert?.episodeId == value.episodeId { alert = nil }
        if localAlert?.episodeId == value.episodeId { localAlert = nil }
        persist()
        retryPendingAcknowledgement()
    }

    func acceptAlert(from value: WatchSnapshot) {
        if let incoming = value.alert, !acknowledgedEpisodes.contains(incoming.episodeId) {
            if localAlert == nil || incoming.createdAt >= localAlert!.createdAt { alert = incoming }
        } else if value.statusAvailable && (localAlert == nil || value.updatedAt >= localAlert!.createdAt) {
            alert = nil; localAlert = nil
        }
    }

    func confirmAcknowledgement(_ eventID: UUID?) {
        guard let eventID, pendingAcknowledgements.contains(eventID) else { return }
        pendingAcknowledgements.removeAll { $0 == eventID }
        persist()
        retryPendingAcknowledgement()
    }

    /// Called after activation, on reconnect, and when returning to the foreground.
    /// The transport may be unavailable; retain each event until the Parent confirms it.
    func retryPendingAcknowledgement() {
        guard let eventID = pendingAcknowledgements.first else { return }
        sendAcknowledgement?(WatchCommand(kind: .acknowledge, eventId: eventID))
    }

    private func persist() {
        defaults.set(acknowledgedEpisodes.map(\.uuidString), forKey: "acknowledgedEpisodes")
        defaults.set(pendingAcknowledgements.map(\.uuidString), forKey: "pendingAcknowledgements")
        defaults.removeObject(forKey: "pendingAcknowledgement")
    }
}
