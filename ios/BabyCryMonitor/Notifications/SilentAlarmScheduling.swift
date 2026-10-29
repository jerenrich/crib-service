import AlarmKit
import AppIntents
import Foundation

/// One alarm definition for both methods: the app's background wake and the
/// notification extension schedule exactly the same alarm, keyed by episode.
@available(iOS 26.0, *)
enum SilentAlarmScheduling {
    struct Metadata: AlarmMetadata {}
    /// Leaves time for the scheduling call itself; both methods schedule within ~1 s of the push.
    static let delay: TimeInterval = 1
    static let soundName = "AlarmTestSilence.caf"
    static var assetAvailable: Bool { Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil }

    static func title(for request: SilentCryAlarmRequest) -> String {
        request.isTest ? "Test alarm · Crib Service" : request.isDisconnected ? "Listener connection lost"
            : request.isMonitoringFailure ? "Nursery monitoring stopped" : "Check on baby"
    }

    static func configuration(for request: SilentCryAlarmRequest, at date: Date) -> AlarmManager.AlarmConfiguration<Metadata> {
        let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: .init(
            title: LocalizedStringResource(stringLiteral: title(for: request)),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        )), metadata: Metadata(), tintColor: .mint)
        return .alarm(schedule: .fixed(date), attributes: attributes,
                      stopIntent: SnoozeSilentCryAlarmIntent(episodeID: request.episodeID.uuidString),
                      sound: .named(soundName))
    }
}

@available(iOS 26.0, *)
struct SnoozeSilentCryAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Snooze alerts" }
    @Parameter(title: "Episode") var episodeID: String
    init() {}
    init(episodeID: String) { self.episodeID = episodeID }
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: episodeID) else { return .result() }
        #if ALARM_EXTENSION
        // If iOS ever runs Stop in the extension, leave a marker; the app applies
        // the snooze the next time it runs.
        try? AlarmJournal.forMethod(.extension)?.append(AlarmAttempt(method: .extension, outcome: .stopped, reason: nil,
            eventID: nil, episodeID: id, isTest: false, flags: [], pushCreatedAt: nil, startedAt: Date(), finishedAt: Date(),
            alarmAt: nil, conditions: .init(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)))
        #else
        await SilentCryAlarmService.shared.snooze(episodeID: id)
        #endif
        return .result()
    }
}
