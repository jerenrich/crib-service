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
        for index in 0..<(AlarmJournal.capacity + 5) { try journal.append(attempt(index)) }
        let entries = journal.read()
        XCTAssertEqual(entries.count, AlarmJournal.capacity)
        XCTAssertEqual(entries.first?.startedAt, attempt(5).startedAt)
        XCTAssertEqual(entries.last?.pushToStartMS, (AlarmJournal.capacity + 4) * 1000 + 500)
        XCTAssertEqual(entries.last?.handlerMS, 250)

        var late = attempt(0); late.outcome = .timedOut
        try journal.append(late)
        XCTAssertEqual(journal.read().last?.outcome, .timedOut)
        XCTAssertTrue(String(decoding: try Data(contentsOf: journal.url), as: UTF8.self).contains(#""outcome":"timed_out""#))
    }

    /// A `no_snapshot` rejection says why, and the extension records how old the state was.
    func testSnapshotReadReportsWhyItIsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(AlarmSnapshot.read(from: nil).failure, .appGroupUnavailable)
        XCTAssertEqual(AlarmSnapshot.read(from: directory).failure, .missing)
        try Data("{".utf8).write(to: directory.appendingPathComponent("alarm-snapshot.json"))
        XCTAssertEqual(AlarmSnapshot.read(from: directory).failure, .undecodable)

        let request = try XCTUnwrap(SilentCryAlarmRequest(payload: payload(["alarmExtension": true], age: 2), now: now))
        var value = snapshot()
        XCTAssertFalse(value.evidenceApplies(to: request))
        value.evidence = .init(observedAt: request.createdAt.addingTimeInterval(-1), paired: true, enabled: true, relevance: nil, mutedUntil: nil)
        XCTAssertFalse(value.evidenceApplies(to: request))
        value.evidence = .init(observedAt: request.createdAt, paired: true, enabled: true, relevance: nil, mutedUntil: nil)
        XCTAssertTrue(value.evidenceApplies(to: request))

        XCTAssertNil(AlarmShared.protectedDataAvailable(in: directory))
        AlarmShared.writeLockProbe(to: directory)
        XCTAssertEqual(AlarmShared.protectedDataAvailable(in: directory), true)
    }

    /// Concurrent appends keep every entry, and an unreadable journal is never replaced.
    func testJournalAppendsAreSerializedAndNeverTruncateAnUnreadableJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try XCTUnwrap(AlarmJournal.forMethod(.extension, directory: directory))
        let start = now
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            try? journal.append(AlarmAttempt(method: .extension, outcome: .timedOut, reason: nil, eventID: UUID(), episodeID: UUID(),
                isTest: false, flags: [], pushCreatedAt: nil, startedAt: start.addingTimeInterval(Double(index)),
                finishedAt: start.addingTimeInterval(Double(index)), alarmAt: nil, conditions: .init(lowPower: false)))
        }
        let entries = journal.read()
        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(Set(entries.map(\.key)).count, 40)

        try Data([0xFF, 0xFE]).write(to: journal.url)
        XCTAssertThrowsError(try journal.append(entries[0]))
        XCTAssertEqual(try Data(contentsOf: journal.url), Data([0xFF, 0xFE]))
    }

    #if !canImport(MonitorCore)
    func testStatusDecodesAlarmMethods() throws {
        let decoder = JSONDecoder()
        let methods = try decoder.decode(ParentStatus.AlarmMethods.self, from: Data(#"{"appWake":false,"extension":true}"#.utf8))
        XCTAssertEqual(methods, ParentStatus.AlarmMethods(appWake: false, extensionMethod: true))
    }
    #endif
}

private extension Result {
    var failure: Failure? { if case .failure(let value) = self { value } else { nil } }
}
