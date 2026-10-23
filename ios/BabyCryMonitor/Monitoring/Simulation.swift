import Foundation
/// Value clock used by deterministic simulation; advance by feeding timestamped 250ms samples.
public struct SimulationClock: ClockProviding { public let now: Date; public init(now: Date) { self.now = now } }
