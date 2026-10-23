import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif
final class AlertCoordinatorTests: XCTestCase {
    actor Transport: AlertSending {
        var available = false
        var ids: [UUID] = []
        func online() { available = true }
        func send(_ alert: CryAlert) async throws -> AlertReceipt {
            ids.append(alert.eventId)
            guard available else { throw URLError(.notConnectedToInternet) }
            return AlertReceipt(status: "sent")
        }
        func requests() -> [UUID] { ids }
    }
    @MainActor func testOfflineEventRestoresThenRetriesSameUUID() async throws {
        var simulation = CrySessionTests.Simulation(); simulation.run(306)
        var engine = simulation.engine
        let sender = Transport(); let coordinator = AlertCoordinator()
        let initialId = try XCTUnwrap(engine.snapshot.pending.first?.alert.eventId)
        await coordinator.deliverReady(engine.snapshot.pending, listenerId: simulation.listener, now: simulation.time, sender: sender) { alert, result in
            if case .failure = result { engine.failed(alert.eventId, at: simulation.time) }
        }
        let persisted = try JSONEncoder().encode(engine.snapshot)
        engine = CrySessionManager(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: persisted))
        XCTAssertEqual(engine.snapshot.pending.count, 1)
        await sender.online()
        await coordinator.deliverReady(engine.snapshot.pending, listenerId: simulation.listener, now: simulation.time.addingTimeInterval(3), sender: sender) { alert, result in
            if case .success = result { engine.delivered(alert.eventId, at: simulation.time.addingTimeInterval(3)) }
        }
        XCTAssertTrue(engine.snapshot.pending.isEmpty)
        let requests = await sender.requests(); XCTAssertEqual(requests, [initialId, initialId])
        await coordinator.deliverReady(engine.snapshot.pending, listenerId: simulation.listener, now: simulation.time.addingTimeInterval(600), sender: sender) { _, _ in XCTFail("Delivered event retried") }
    }
    @MainActor func testBackoffAndDeviceIdentityAreRespected() async {
        var simulation = CrySessionTests.Simulation(); simulation.run(306)
        let sender = Transport(); let coordinator = AlertCoordinator()
        await coordinator.deliverReady(simulation.engine.snapshot.pending, listenerId: UUID(), now: simulation.time, sender: sender) { _, _ in XCTFail("Wrong device") }
        let before = await sender.requests(); XCTAssertTrue(before.isEmpty)
        if let id = simulation.emitted.first?.eventId { simulation.engine.failed(id, at: simulation.time) }
        await coordinator.deliverReady(simulation.engine.snapshot.pending, listenerId: simulation.listener, now: simulation.time, sender: sender) { _, _ in XCTFail("Backoff not respected") }
        let after = await sender.requests(); XCTAssertTrue(after.isEmpty)
    }
}
