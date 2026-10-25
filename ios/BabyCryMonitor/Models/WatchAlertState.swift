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
    private var acknowledgedUntil: [String: Double]
    private let currentTime: () -> Date
    private var snoozeDuration: TimeInterval
    private var mutedUntil: Date?
    private var localMutedUntil: Date?
    private var pendingAcknowledgements: [UUID]

    init(defaults: UserDefaults = .standard, currentTime: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.currentTime = currentTime
        snoozeDuration = defaults.object(forKey: "snoozeDuration") as? Double ?? 60
        mutedUntil = defaults.object(forKey: "cryAlertsMutedUntil") as? Date
        localMutedUntil = defaults.object(forKey: "localCryAlertsMutedUntil") as? Date
        if let saved = defaults.dictionary(forKey: "episodeMutedUntil") as? [String: Double] {
            acknowledgedUntil = saved
        } else {
            let legacy = defaults.dictionary(forKey: "episodeAcknowledgedAt") as? [String: Double] ?? [:]
            acknowledgedUntil = legacy.mapValues { $0 + 300 }
        }
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
        guard !isSuppressed(value) else { return }
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
        guard !isEpisodeSuppressed(value) else { return }
        acknowledgedUntil[value.episodeId.uuidString] = currentTime().timeIntervalSince1970 + snoozeDuration
        acknowledgedEpisodes.removeAll { $0 == value.episodeId }
        acknowledgedEpisodes.append(value.episodeId)
        acknowledgedEpisodes = Array(acknowledgedEpisodes.suffix(100))
        pendingAcknowledgements.append(value.eventId)
        // A real Snooze applies to all crying episodes, including older alerts.
        // Test acknowledgements affect only that test.
        if !value.isTest {
            localMutedUntil = currentTime().addingTimeInterval(snoozeDuration)
            if alert?.isTest == false { alert = nil }
            if localAlert?.isTest == false { localAlert = nil }
        } else {
            if alert?.eventId == value.eventId { alert = nil }
            if localAlert?.eventId == value.eventId { localAlert = nil }
        }
        persist()
        retryPendingAcknowledgement()
    }

    func acceptAlert(from value: WatchSnapshot) {
        snoozeDuration = value.snoozeDuration ?? 60
        if value.statusAvailable {
            mutedUntil = value.alertsMutedUntil
            if pendingAcknowledgements.isEmpty { localMutedUntil = mutedUntil }
            if let until = mutedUntil, until > currentTime() || pendingAcknowledgements.isEmpty {
                for id in acknowledgedEpisodes { acknowledgedUntil[id.uuidString] = until.timeIntervalSince1970 }
            }
        }
        persist()
        if let incoming = value.alert, !isSuppressed(incoming) {
            if localAlert == nil || incoming.createdAt >= localAlert!.createdAt { alert = incoming }
        } else if value.statusAvailable && (localAlert == nil || value.updatedAt >= localAlert!.createdAt) {
            alert = nil; localAlert = nil
        }
    }

    func resolveAcknowledgements(from snapshot: WatchSnapshot) {
        confirmAcknowledgement(snapshot.acknowledgedEventId)
        confirmAcknowledgement(snapshot.discardedAcknowledgementEventId)
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

    private func isSuppressed(_ value: WatchCryAlert) -> Bool {
        if !value.isTest, let localMutedUntil, value.createdAt < localMutedUntil { return true }
        if !value.isTest, let mutedUntil, value.createdAt < mutedUntil { return true }
        return isEpisodeSuppressed(value)
    }

    private func isEpisodeSuppressed(_ value: WatchCryAlert) -> Bool {
        guard acknowledgedEpisodes.contains(value.episodeId) else { return false }
        guard let time = acknowledgedUntil[value.episodeId.uuidString] else { return true }
        // Old notifications stay dismissed; a new alert after the mute may wake again.
        return value.createdAt.timeIntervalSince1970 < time
    }

    private func persist() {
        acknowledgedUntil = acknowledgedUntil.filter { acknowledgedEpisodes.map(\.uuidString).contains($0.key) }
        defaults.set(acknowledgedUntil, forKey: "episodeMutedUntil")
        defaults.set(snoozeDuration, forKey: "snoozeDuration")
        defaults.set(mutedUntil, forKey: "cryAlertsMutedUntil")
        defaults.set(localMutedUntil, forKey: "localCryAlertsMutedUntil")
        defaults.set(acknowledgedEpisodes.map(\.uuidString), forKey: "acknowledgedEpisodes")
        defaults.set(pendingAcknowledgements.map(\.uuidString), forKey: "pendingAcknowledgements")
        defaults.removeObject(forKey: "pendingAcknowledgement")
    }
}
