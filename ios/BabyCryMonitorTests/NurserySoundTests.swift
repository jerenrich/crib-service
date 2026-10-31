import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class NurserySoundTests: XCTestCase {
    func testLateSettingsChangesNeverRestartExpiredOrStoppedSound() {
        let now = ContinuousClock.now
        for restart in [false, true] {
            var playback = NurserySoundPlayback()
            playback.apply(.init(settings: .init(timerMinutes: 5), action: .play), at: now)
            // Even without a timer tick, the edit must observe the elapsed deadline.
            playback.apply(.init(settings: .init(sound: .twinkleTwinkle, volume: 0.6, timerMinutes: 10),
                                 action: .updateSettings, restartTimer: restart), at: now.advanced(by: .seconds(301)))
            XCTAssertFalse(playback.state.playing)
            XCTAssertEqual(playback.state.remainingSeconds, 0)
            XCTAssertEqual(playback.state.settings.timerMinutes, 10)
            playback.apply(.init(settings: playback.state.settings, action: .play), at: now.advanced(by: .seconds(302)))
            XCTAssertTrue(playback.state.playing)
            XCTAssertEqual(playback.state.remainingSeconds, 600)
            playback.stop()
            playback.apply(.init(settings: .init(), action: .updateSettings), at: now.advanced(by: .seconds(303)))
            XCTAssertFalse(playback.state.playing)
        }
    }
    func testRequestWireFormatDistinguishesPlayStopAndSettingsEdits() throws {
        for action in [NurserySoundRequest.Action.play, .stop, .updateSettings] {
            let request = NurserySoundRequest(settings: .init(), action: action)
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(NurserySoundRequest.self, from: data), request)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("playing"))
        }
    }
    func testEveryTimerExpiresWithoutDependingOnTheOtherPhoneOrWallClock() {
        for minutes in NurserySoundSettings.timerOptions {
            let now = ContinuousClock.now
            var playback = NurserySoundPlayback()
            playback.apply(.init(settings: .init(timerMinutes: minutes), action: .play), at: now)
            XCTAssertEqual(playback.state.remainingSeconds, Double(minutes * 60))
            XCTAssertFalse(playback.expired(at: now.advanced(by: .seconds(minutes * 60 - 1))))
            XCTAssertTrue(playback.expired(at: now.advanced(by: .seconds(minutes * 60))))
            playback.update(at: now.advanced(by: .seconds(minutes * 60 + 50)))
            XCTAssertFalse(playback.state.playing)
            XCTAssertEqual(playback.state.remainingSeconds, 0)
            XCTAssertTrue(playback.state.isValid)
        }
    }
    func testSwitchingSoundsAndVolumePreservesDeadlineAndTimerSelectionRestartsIt() {
        let now = ContinuousClock.now
        var playback = NurserySoundPlayback()
        playback.apply(.init(settings: .init(), action: .play), at: now)
        let settings = NurserySoundSettings(sound: .twinkleTwinkle, volume: 0.6, timerMinutes: 20)
        playback.apply(.init(settings: settings, action: .updateSettings), at: now.advanced(by: .seconds(60)))
        XCTAssertEqual(playback.state.remainingSeconds, 19 * 60)
        playback.apply(.init(settings: settings, action: .updateSettings, restartTimer: true), at: now.advanced(by: .seconds(90)))
        XCTAssertEqual(playback.state.remainingSeconds, 20 * 60)
        playback.apply(.init(settings: settings, action: .stop), at: now.advanced(by: .seconds(100)))
        XCTAssertFalse(playback.state.playing)
        playback.apply(.init(settings: settings, action: .play), at: now.advanced(by: .seconds(110)))
        XCTAssertEqual(playback.state.remainingSeconds, 20 * 60)
    }
    func testEditingStoppedSettingsNeverStartsSoundAndInvalidSettingsAreRejected() {
        var playback = NurserySoundPlayback()
        let now = ContinuousClock.now
        playback.apply(.init(settings: .init(sound: .twinkleTwinkle, timerMinutes: 5), action: .stop), at: now)
        XCTAssertFalse(playback.state.playing)
        for settings in [NurserySoundSettings(volume: .nan), .init(volume: -1), .init(volume: 1.1), .init(timerMinutes: 15)] {
            XCTAssertFalse(settings.isValid)
            playback.apply(.init(settings: settings, action: .play), at: now)
            XCTAssertFalse(playback.state.playing)
        }
    }
    func testDelayedCommandsAndUnknownControlTokensCannotStartPlayback() {
        let now = Date()
        var tokens = NurserySoundControlTokens()
        let token = tokens.issue(at: now)
        XCTAssertTrue(tokens.accepts(token, at: now.addingTimeInterval(4.9)))
        XCTAssertFalse(tokens.accepts(token, at: now.addingTimeInterval(5)))
        XCTAssertFalse(tokens.accepts(token, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(tokens.accepts(UUID(), at: now))
        tokens = NurserySoundControlTokens()
        XCTAssertFalse(tokens.accepts(token, at: now))
    }
    func testRemotePlaybackAgesWithoutExtendingFreshnessAndDisconnectIsUnconfirmed() {
        let now = Date()
        var remote = RemoteNurserySound()
        let state = NurserySoundState(settings: .init(), playing: true, remainingSeconds: 120)
        remote.receive(.init(state: state, controlToken: UUID()), at: now)
        XCTAssertEqual(remote.state(at: now.addingTimeInterval(2))?.remainingSeconds, 118)
        XCTAssertFalse(remote.isLive(at: now.addingTimeInterval(3)))
        remote.disconnect()
        XCTAssertFalse(remote.isLive(at: now))
        XCTAssertEqual(remote.state(at: now)?.settings.sound, .whiteNoise)
    }
    func testSoundGenerationProducesBoundedDistinctNonSilentAudioAndCorrectMelodyLength() {
        let noise = NurserySound.whiteNoise.samples(sampleRate: 8_000)
        let melody = NurserySound.twinkleTwinkle.samples(sampleRate: 8_000)
        XCTAssertEqual(noise.count, 32_000)
        XCTAssertEqual(melody.count, 249_600) // 48 beats at 0.65 seconds.
        for samples in [noise, melody] {
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 0.3 })
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            XCTAssertGreaterThan(rms, 0.01)
        }
        XCTAssertEqual(melody.first, 0)
        XCTAssertLessThan(abs(melody.last ?? 1), 0.001)
        XCTAssertTrue(NurserySound.whiteNoise.samples(sampleRate: .infinity).isEmpty)
    }
    func testWireValidationRejectsImpossiblePlaybackAndNonFiniteCountdowns() throws {
        for state in [NurserySoundState(playing: true), .init(playing: true, remainingSeconds: .infinity),
                      .init(playing: true, remainingSeconds: 1201), .init(playing: false, remainingSeconds: 5)] {
            XCTAssertFalse(state.isValid)
        }
        let value = NurserySoundUpdate(state: .init(playing: true, remainingSeconds: 300), controlToken: UUID(), commandID: UUID())
        XCTAssertEqual(try JSONDecoder().decode(NurserySoundUpdate.self, from: JSONEncoder().encode(value)), value)
    }
}
