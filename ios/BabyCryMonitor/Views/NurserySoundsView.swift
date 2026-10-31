import SwiftUI

struct NurserySoundButton: View {
    @Environment(AppModel.self) private var model
    var action: () -> Void
    var body: some View {
        let state = model.displayedNurserySound
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: state.settings.sound.symbol)
                    .font(.title3).foregroundStyle(Palette.mint)
                    .frame(width: 36, height: 36).background(Palette.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.playing ? state.settings.sound.title : "Nursery sounds").font(.subheadline.weight(.semibold))
                    if model.role == .parent, !model.remoteNurserySound.isLive(at: model.now) {
                        Text("Nursery unavailable · Sound controls").font(.caption).foregroundStyle(Palette.muted)
                    } else if model.changingNurserySound {
                        Text("Waiting for confirmation…").font(.caption).foregroundStyle(Palette.muted)
                    } else {
                        Text(state.playing ? "Stops in \(durationText(ceil(state.remainingSeconds))) · \(Int(state.settings.volume * 100))% volume" : "White noise or a gentle lullaby")
                            .font(.caption).monospacedDigit().foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.caption).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("nurserySoundControls")
    }
}

struct NurserySoundsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var volume = 0.3
    @State private var editingVolume = false

    private var state: NurserySoundState { model.displayedNurserySound }
    private func change(settings: NurserySoundSettings, action: NurserySoundRequest.Action = .updateSettings, restartTimer: Bool = false) {
        let request = NurserySoundRequest(settings: settings, action: action, restartTimer: restartTimer)
        Task { await model.changeNurserySound(request) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Nursery sounds").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                }
                Text(model.nurserySoundConnectionText).font(.footnote).foregroundStyle(Palette.muted)
                    .padding(.top, -14).accessibilityIdentifier("nurserySoundConnection")

                VStack(spacing: 10) {
                    ForEach(NurserySound.allCases, id: \.self) { sound in
                        let selected = state.settings.sound == sound
                        Button {
                            var settings = state.settings; settings.sound = sound; change(settings: settings)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: sound.symbol).font(.title2).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sound.title).font(.headline)
                                    Text(sound == .whiteNoise ? "A steady, gentle hush" : "A soft instrumental lullaby")
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark.circle.fill") }
                            }
                            .foregroundStyle(selected ? Palette.mint : .white)
                            .padding(16).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                            .background(selected ? Palette.mint.opacity(0.1) : Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? Palette.mint : .clear, lineWidth: 1) }
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("nurserySound_\(sound.rawValue)")
                    }
                }.disabled(!model.canControlNurserySound)

                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text("Turn off after"); Spacer(); Text("minutes").foregroundStyle(Palette.muted) }.font(.subheadline)
                    HStack(spacing: 7) {
                        ForEach(NurserySoundSettings.timerOptions, id: \.self) { minutes in
                            let selected = state.settings.timerMinutes == minutes
                            Button {
                                var settings = state.settings; settings.timerMinutes = minutes
                                change(settings: settings, restartTimer: true)
                            } label: {
                                Text("\(minutes)").font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(selected ? Palette.lavender : Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(selected ? Palette.background : .white)
                            }.buttonStyle(.plain).accessibilityLabel("\(minutes) minutes")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("nurserySoundTimer_\(minutes)")
                        }
                    }
                }.disabled(!model.canControlNurserySound)

                VStack(spacing: 8) {
                    HStack { Text("Nursery volume"); Spacer(); Text("\(Int((volume * 100).rounded()))%").monospacedDigit() }.font(.subheadline)
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                        Slider(value: $volume, in: 0...1, step: 0.01) { editing in
                            editingVolume = editing
                            if !editing {
                                guard model.canControlNurserySound else { volume = state.settings.volume; return }
                                var settings = state.settings; settings.volume = volume; change(settings: settings)
                            }
                        }.tint(Palette.mint).accessibilityLabel("Nursery volume").accessibilityIdentifier("nurserySoundVolume")
                        Image(systemName: "speaker.wave.3.fill")
                    }.foregroundStyle(Palette.muted)
                }.disabled(!model.canControlNurserySound)

                VStack(spacing: 10) {
                    Button { change(settings: state.settings, action: state.playing ? .stop : .play) } label: {
                        HStack(spacing: 8) {
                            if model.changingNurserySound { ProgressView().tint(Palette.background) }
                            else { Image(systemName: state.playing ? "stop.fill" : "play.fill") }
                            Text(state.playing ? "Stop sound" : "Play \(state.settings.sound.title)")
                        }.font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Palette.background)
                    }.buttonStyle(.plain).disabled(!model.canControlNurserySound).accessibilityIdentifier("nurserySoundPlayback")
                    if state.playing, model.role == .listener || model.remoteNurserySound.isLive(at: model.now) {
                        Text("Stops in \(durationText(ceil(state.remainingSeconds))) · \(state.settings.timerMinutes) min timer")
                            .font(.footnote).monospacedDigit().foregroundStyle(Palette.mint).accessibilityIdentifier("nurserySoundCountdown")
                    }
                    if let failure = model.nurserySoundError {
                        Text(failure).font(.footnote).foregroundStyle(Palette.amber).accessibilityIdentifier("nurserySoundError")
                    }
                }
                Text("Changing sound or volume keeps the timer running. Choosing a timer starts a new countdown.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(22)
        }
        .background(Palette.background).foregroundStyle(.white).tint(Palette.lavender)
        .onAppear { volume = state.settings.volume }
        .onChange(of: state.settings.volume) { _, value in if !editingVolume { volume = value } }
        .onChange(of: model.changingNurserySound) { _, changing in
            if !changing, !editingVolume { volume = state.settings.volume }
        }
    }
}
