import SwiftUI
import SDRCore

/// The top bar: power, VFO display, mode/bandwidth, S-meter, audio, recording.
struct TopRibbon: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        HStack(alignment: .center, spacing: 14) {
            powerButton
                .fixedSize()

            divider

            // VFO display.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("VFO A")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Theme.accent)
                    Text(radio.mode.rawValue + "  ·  " + FrequencyFormat.bandwidth(radio.bandwidth))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if radio.stereoLocked {
                        Text("STEREO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.green)
                    }
                    if radio.overload {
                        Text("OVERLOAD")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.red)
                            .help("ADC clipping: lower the RF gain")
                    }
                    Spacer(minLength: 0)
                    Text("Hz")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                FrequencyDisplay(frequency: radio.vfoFrequency,
                                 onChange: { radio.tune(to: $0) },
                                 onRequestEntry: { radio.showFrequencyEntry = true })
                    .frame(width: 330, height: 52)
                    .popover(isPresented: $radio.showFrequencyEntry, arrowEdge: .bottom) {
                        FrequencyEntryView()
                    }
                HStack(spacing: 4) {
                    Text("LO")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.amber.opacity(0.8))
                    Text(FrequencyFormat.dotted(radio.centerFrequency))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Step \(FrequencyFormat.bandwidth(radio.step))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .fixedSize()

            // Mode + bandwidth.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach(DemodMode.allCases) { m in
                        ChipButton(title: m.rawValue, selected: radio.mode == m, width: 34) { radio.mode = m }
                    }
                }
                HStack(spacing: 3) {
                    ForEach(radio.mode.bandwidthPresets.filter { $0 <= radio.maxBandwidth }, id: \.self) { bw in
                        ChipButton(title: FrequencyFormat.compact(bw),
                                   selected: abs(radio.bandwidth - bw) < 1) { radio.bandwidth = bw }
                    }
                }
                HStack(spacing: 6) {
                    Menu {
                        ForEach(RadioController.steps, id: \.self) { s in
                            Button(FrequencyFormat.bandwidth(s)) { radio.step = s }
                        }
                    } label: {
                        Text("Step \(FrequencyFormat.bandwidth(radio.step))")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)

                    Picker("AGC", selection: $radio.agcMode) {
                        ForEach(AGCMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(radio.mode == .wfm || radio.mode == .nfm)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            // Drop the controls that also live in the sidebar/menu when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    SMeterView()
                    divider
                    audioControls
                    divider
                    recordControls
                }
                HStack(spacing: 14) {
                    SMeterView()
                    divider
                    audioControls
                }
                SMeterView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.ribbon)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 70)
    }

    private var powerButton: some View {
        Button {
            radio.toggleRunning()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "power")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(radio.isRunning ? Theme.green : Theme.dim)
                    .shadow(color: radio.isRunning ? Theme.green.opacity(0.7) : .clear, radius: 6)
                Text(radio.isRunning ? "Stop" : "Start")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54, height: 60)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(radio.isRunning ? Theme.green.opacity(0.5) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Start/stop the radio (⌘R)")
    }

    private var audioControls: some View {
        @Bindable var radio = radio
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    radio.muted.toggle()
                } label: {
                    Image(systemName: radio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                        .foregroundStyle(radio.muted ? Theme.red : .primary)
                }
                .buttonStyle(.plain)
                .help("Mute")
                Slider(value: $radio.volume, in: 0...1)
                    .frame(width: 120)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Toggle(isOn: $radio.squelchEnabled) {
                    Text("SQL").font(.system(size: 10, weight: .bold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(radio.squelchOpen ? Theme.green : Theme.red)
                .help("Squelch")
                Toggle(isOn: $radio.squelchAuto) {
                    Text("A").font(.system(size: 10, weight: .bold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!radio.squelchEnabled || !(radio.mode == .nfm || radio.mode == .wfm))
                .help("Auto squelch (FM): open on carrier-to-noise ratio")
                Slider(value: $radio.squelchLevel, in: -120...0)
                    .frame(width: 70)
                    .controlSize(.small)
                    .disabled(!radio.squelchEnabled || radio.autoSquelchActive)
            }
            // The hidden longest variant reserves the width, so switching modes does not resize the group.
            ZStack(alignment: .leading) {
                Text("Squelch auto · SNR -99 dB").hidden()
                Text(squelchText)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private var squelchText: String {
        guard radio.squelchEnabled else { return "Squelch off" }
        if radio.autoSquelchActive {
            return radio.snrDB.map { String(format: "Squelch auto · SNR %3.0f dB", $0) } ?? "Squelch auto"
        }
        return String(format: "Squelch %.0f dBFS", radio.squelchLevel)
    }

    private var recordControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            recordButton(title: "Audio", active: radio.recordingAudio) { radio.toggleAudioRecording() }
            recordButton(title: "I/Q", active: radio.recordingIQ) { radio.toggleIQRecording() }
            if let start = radio.recordingStart, radio.recordingAudio || radio.recordingIQ {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.red)
                }
            }
        }
    }

    private func recordButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? Theme.red : Theme.red.opacity(0.35))
                    .frame(width: 9, height: 9)
                    .shadow(color: active ? Theme.red : .clear, radius: 4)
                Text(active ? "Stop \(title)" : "Rec \(title)")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(width: 84, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(active ? Theme.fillStrong : Theme.fill, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
