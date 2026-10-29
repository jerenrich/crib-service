import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class AlarmSharedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let episode = UUID()

    private func payload(_ markers: [String: Any], age: Double = 0) -> [AnyHashable: Any] {
        var value: [AnyHashable: Any] = ["eventId": UUID().uuidString, "episodeId": episode.uuidString,
            "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))]
        for (key, marker) in markers { value[key] = marker }
        return value
    }

    private func snapshot(enabled: Bool = true, extensionEnabled: Bool = true, pending: Bool = false,
                          muted: Date? = nil, stopped: Date? = nil) -> AlarmSnapshot {
        AlarmSnapshot(enabled: enabled, extensionEnabled: extensionEnabled, acknowledgementPending: pending,
                      localMutedUntil: muted, stoppedBefore: stopped, evidence: nil, snoozeDuration: 60, publishedAt: now)
    }

    func testEitherMethodMarkerIsAcceptedAndPushFlagsAreReported() throws {
        XCTAssertNotNil(SilentCryAlarmRequest(payload: payload(["alarmExtension": true]), now: now))
        XCTAssertNotNil(SilentCryAlarmRequest(payload: payload(["silentCryAlarm": true]), now: now))
        XCTAssertEqual(SilentCryAlarmRequest.payloadRejection(payload([:]), now: now), .notRequested)
        XCTAssertEqual(AlarmAttempt.flags(in: ["aps": ["content-available": 1, "mutable-content": 1]]), ["wake", "extension"])
        XCTAssertEqual(AlarmAttempt.flags(in: ["aps": ["mutable-content": 1]]), ["extension"])
        XCTAssertEqual(AlarmAttempt.flags(in: [:]), [])
    }

    /// The extension applies the app's push-only rules from the app's published state.
    func testExtensionUsesThePublishedSnapshotAndItsMethodSetting() throws {
        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(["alarmExtension": true], age: 2), now: now))
        XCTAssertNil(snapshot().ineligibilityReason(for: request, now: now))
        XCTAssertEqual(snapshot(extensionEnabled: false).ineligibilityReason(for: request, now: now), .methodDisabled)
        XCTAssertEqual(snapshot(enabled: false).ineligibilityReason(for: request, now: now), .disabled)
        XCTAssertEqual(snapshot(pending: true).ineligibilityReason(for: request, now: now), .acknowledgementPending)
        XCTAssertEqual(snapshot(muted: now.addingTimeInterval(60)).ineligibilityReason(for: request, now: now), .locallyMuted)
        XCTAssertEqual(snapshot(stopped: now).ineligibilityReason(for: request, now: now), .stopped)
        XCTAssertEqual(snapshot().ineligibilityReason(for: request, now: now.addingTimeInterval(61)), .stale)
    }

    func testSnapshotAndJournalRoundTripAndTheJournalIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(AlarmSnapshot.load(from: directory))
        try snapshot(muted: now).save(to: directory)
        XCTAssertEqual(AlarmSnapshot.load(from: directory), snapshot(muted: now))

        let journal = try XCTUnwrap(AlarmJournal.forMethod(.extension, directory: directory))
        func attempt(_ index: Int) -> AlarmAttempt {
            AlarmAttempt(method: .extension, outcome: .scheduled, reason: nil, eventID: UUID(), episodeID: episode, isTest: false,
                         flags: ["extension"], pushCreatedAt: now, startedAt: now.addingTimeInterval(Double(index) + 0.5),
                         finishedAt: now.addingTimeInterval(Double(index) + 0.75), alarmAt: now.addingTimeInterval(Double(index) + 3.75),
                         conditions: .init(charging: false, batteryLevel: 0.5, lowPower: false))
        }
        for index in 0..<(AlarmJournal.capacity + 5) { journal.append(attempt(index)) }
        let entries = journal.read()
        XCTAssertEqual(entries.count, AlarmJournal.capacity)
        XCTAssertEqual(entries.first?.startedAt, attempt(5).startedAt)
        XCTAssertEqual(entries.last?.pushToStartMS, (AlarmJournal.capacity + 4) * 1000 + 500)
        XCTAssertEqual(entries.last?.handlerMS, 250)

        var late = attempt(0); late.outcome = .timedOut
        journal.append(late)
        XCTAssertEqual(journal.read().last?.outcome, .timedOut)
        XCTAssertTrue(String(decoding: try Data(contentsOf: journal.url), as: UTF8.self).contains(#""outcome":"timed_out""#))
    }

    #if !canImport(MonitorCore)
    func testStatusDecodesAlarmMethods() throws {
        let decoder = JSONDecoder()
        let methods = try decoder.decode(ParentStatus.AlarmMethods.self, from: Data(#"{"appWake":false,"extension":true}"#.utf8))
        XCTAssertEqual(methods, ParentStatus.AlarmMethods(appWake: false, extensionMethod: true))
    }
    #endif
}
