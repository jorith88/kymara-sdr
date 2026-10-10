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
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Theme.accent)
                    Text(radio.modeLabel + "  ·  " + FrequencyFormat.bandwidth(radio.bandwidth))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if radio.stereoLocked {
                        Text("STEREO")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.green)
                            .accessibilityLabel("Stereo")
                    }
                    if let call = radio.radeCallsign, radio.mode == .rade {
                        Text(call)
                            .font(.system(size: 10, weight: .bold).monospaced())
                            .foregroundStyle(Theme.accent)
                            .help("Callsign from the last RADE over")
                            .accessibilityLabel("Callsign \(call)")
                    }
                    if radio.rade?.sync == true {
                        Text("RADE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.green)
                            .help("Receiving FreeDV RADE")
                            .accessibilityLabel("RADE in sync")
                    }
                    if radio.overload {
                        Text("OVERLOAD")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.red)
                            .help("ADC clipping: lower the RF gain")
                            .accessibilityLabel("Overload: lower the RF gain")
                    }
                    Spacer(minLength: 0)
                    Text("Hz")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                FrequencyDisplay(frequency: radio.vfoFrequency,
                                 step: radio.step,
                                 onChange: { radio.tune(to: $0) },
                                 onRequestEntry: { radio.showFrequencyEntry = true })
                    .frame(width: 330, height: 52)
                    .popover(isPresented: $radio.showFrequencyEntry, arrowEdge: .bottom) {
                        FrequencyEntryView()
                    }
                HStack(spacing: 4) {
                    Text("LO")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.amber.opacity(0.8))
                    Text(FrequencyFormat.dotted(radio.centerFrequency))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Step \(FrequencyFormat.bandwidth(radio.step))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .fixedSize()

            // Mode + bandwidth.
            VStack(alignment: .leading, spacing: 5) {
                Picker("Mode", selection: $radio.mode) {
                    ForEach(DemodMode.available) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // A bandwidth that is not a preset (set with the sidebar slider) selects no segment.
                Picker("Bandwidth", selection: Binding(
                    get: { presets.first { abs(radio.bandwidth - $0) < 1 } },
                    set: { if let bw = $0 { radio.bandwidth = bw } }
                )) {
                    ForEach(presets, id: \.self) { Text(FrequencyFormat.compact($0)).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                    .disabled(radio.mode == .wfm || radio.mode == .nfm || radio.mode == .rade)
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

    private var presets: [Double] {
        radio.mode.bandwidthPresets.filter { $0 <= radio.maxBandwidth }
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
        .help(radio.isRunning ? "Stop the radio (⌘R)" : "Start the radio (⌘R)")
        .accessibilityLabel(radio.isRunning ? "Stop radio" : "Start radio")
    }

    private var audioControls: some View {
        @Bindable var radio = radio
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    radio.muted.toggle()
                } label: {
                    Image(systemName: radio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(radio.muted ? Theme.red : .primary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(radio.muted ? "Unmute (⇧⌘M)" : "Mute (⇧⌘M)")
                .accessibilityLabel(radio.muted ? "Unmute" : "Mute")
                Slider(value: $radio.volume, in: 0...1)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(radio.volume * 100)) percent")
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
                .accessibilityLabel("Squelch")
                .accessibilityValue(radio.squelchOpen ? "Open" : "Closed")
                Toggle(isOn: $radio.squelchAuto) {
                    Text("A").font(.system(size: 10, weight: .bold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!radio.squelchEnabled || !(radio.mode == .nfm || radio.mode == .wfm))
                .help("Auto squelch (FM): open on carrier-to-noise ratio")
                .accessibilityLabel("Auto squelch")
                Slider(value: $radio.squelchLevel, in: -120...0)
                    .accessibilityLabel("Squelch level")
                    .accessibilityValue(String(format: "%.0f dBFS", radio.squelchLevel))
                    .frame(width: 70)
                    .controlSize(.small)
                    .disabled(!radio.squelchEnabled || radio.autoSquelchActive)
            }
            // The hidden longest variant reserves the width, so switching modes does not resize the group.
            ZStack(alignment: .leading) {
                Text("Squelch auto · SNR -99 dB").hidden()
                Text(squelchText)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.red)
                        .accessibilityLabel("Recording time")
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
                    .accessibilityHidden(true)
                Text(active ? "Stop \(title)" : "Record \(title)")
                    .font(.caption.weight(.medium))
            }
            .frame(width: 96, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(active ? Theme.fillStrong : Theme.fill, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(active ? "Recording" : "")
    }
}
