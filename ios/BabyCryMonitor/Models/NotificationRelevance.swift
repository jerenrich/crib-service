import Foundation

/// A complete server snapshot, independent of the latest-100 alert display window.
struct NotificationRelevance: Codable, Equatable, Sendable {
    // Wire name retained for older apps; includes crying and Listener-loss episodes.
    var cryEpisodeIDs: [UUID] = []
    var testEventIDs: [UUID] = []

    func contains(eventID: UUID, episodeID: UUID, isTest: Bool) -> Bool {
        isTest ? testEventIDs.contains(eventID) : cryEpisodeIDs.contains(episodeID)
    }
}
