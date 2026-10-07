import SwiftUI
import UniformTypeIdentifiers
import SDRCore

struct Sidebar: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                SourcePanel()
                ReceiverPanel()
                TunerPanel()
                DisplayPanel()
                RecordingPanel()
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
    }
}

private func hz(_ v: Double) -> String { FrequencyFormat.bandwidth(v) }

struct SourcePanel: View {
    @Environment(RadioController.self) private var radio
    @State private var showFilePicker = false

    var body: some View {
        @Bindable var radio = radio
        Panel("Source", systemImage: "antenna.radiowaves.left.and.right") {
            Picker("", selection: $radio.sourceKind) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)

            switch radio.sourceKind {
            case .rtlsdr:
                if radio.libraryPath == nil {
                    Label("librtlsdr not found. Run 'brew install librtlsdr'.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                }
                HStack {
                    Picker("", selection: $radio.selectedDevice) {
                        if radio.rtlDevices.isEmpty {
                            Text("No device found").tag(UInt32(0))
                        }
                        ForEach(radio.rtlDevices) { Text($0.label).tag($0.index) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Button {
                        radio.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Rescan USB devices")
                }
            case .rtltcp:
                Row("Host") {
                    TextField("127.0.0.1", text: $radio.tcpHost)
                        .textFieldStyle(.roundedBorder)
                }
                Row("Port") {
                    TextField("1234", value: $radio.tcpPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
            case .demo:
                Text("Synthetic band with FM broadcast, AM, NFM, SSB and CW signals around 100 MHz and on the bookmark frequencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .file:
                HStack {
                    Text(radio.fileURL?.lastPathComponent ?? "No file selected")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { showFilePicker = true }
                        .controlSize(.small)
                }
                Text("WAV (8/16-bit, float) or raw .cu8. Frequency and rate are read from the file name (…_100000000Hz_…, …2400000sps…).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                radio.toggleRunning()
            } label: {
                Label(radio.isRunning ? "Stop" : "Start", systemImage: radio.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .tint(radio.isRunning ? Theme.red : Theme.accent)
            .buttonStyle(.borderedProminent)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.wav, .data, .item]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                radio.fileURL = url
            }
        }
    }
}

struct ReceiverPanel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        Panel("Receiver", systemImage: "dial.medium") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                ForEach(DemodMode.allCases) { m in
                    ChipButton(title: m.rawValue, selected: radio.mode == m) { radio.mode = m }
                }
            }

            ValueSlider(label: "Bandwidth",
                        value: Binding(get: { radio.bandwidth }, set: { radio.setBandwidth($0) }),
                        range: radio.mode.bandwidthRange.lowerBound...max(radio.mode.bandwidthRange.lowerBound + 1, radio.maxBandwidth),
                        format: hz)

            Row("Step") {
                Picker("", selection: $radio.step) {
                    ForEach(RadioController.steps, id: \.self) { Text(hz($0)).tag($0) }
                }
                .labelsHidden()
            }

            if radio.mode != .wfm && radio.mode != .nfm {
                Row("AGC") {
                    Picker("", selection: $radio.agcMode) {
                        ForEach(AGCMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if radio.agcMode == .off {
                    ValueSlider(label: "AF gain", value: $radio.afGain, range: -10...80, format: { String(format: "%.0f dB", $0) })
                }
            }

            if radio.mode == .wfm {
                Row("De-emphasis") {
                    Picker("", selection: $radio.deemphasis) {
                        ForEach(Deemphasis.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Row("Stereo") {
                    Toggle("", isOn: $radio.stereoEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    if radio.stereoLocked {
                        Text("pilot locked").font(.caption2).foregroundStyle(Theme.green)
                    }
                }
            }

            if radio.mode == .cw {
                ValueSlider(label: "CW pitch", value: $radio.cwPitch, range: 300...1200, step: 10, format: { String(format: "%.0f Hz", $0) })
            }

            Row("Squelch") {
                Toggle("", isOn: $radio.squelchEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Circle()
                    .fill(radio.squelchOpen ? Theme.green : Theme.red.opacity(0.6))
                    .frame(width: 8, height: 8)
            }
            ValueSlider(label: "Level", value: $radio.squelchLevel, range: -120...0, format: { String(format: "%.0f dBFS", $0) })
                .disabled(!radio.squelchEnabled)
            ValueSlider(label: "Volume", value: $radio.volume, range: 0...1, format: { String(format: "%.0f %%", $0 * 100) })
        }
    }
}

struct TunerPanel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        Panel("RF / Tuner", systemImage: "cpu") {
            Row("Sample rate") {
                Picker("", selection: $radio.sampleRate) {
                    ForEach(RadioController.sampleRates, id: \.self) { Text(String(format: "%.3f MS/s", $0 / 1e6)).tag($0) }
                    if !RadioController.sampleRates.contains(radio.sampleRate) {
                        Text(String(format: "%.3f MS/s", radio.sampleRate / 1e6)).tag(radio.sampleRate)
                    }
                }
                .labelsHidden()
                .disabled(radio.sourceKind == .file)
            }

            Row("Tuner AGC") {
                Toggle("", isOn: $radio.gainAuto)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if !radio.gainAuto && !radio.gains.isEmpty {
                let idx = Binding<Double>(
                    get: { Double(radio.gains.firstIndex(of: radio.gain) ?? radio.gains.count / 2) },
                    set: { radio.gain = radio.gains[min(radio.gains.count - 1, max(0, Int($0.rounded())))] }
                )
                ValueSlider(label: "RF gain", value: idx, range: 0...Double(max(1, radio.gains.count - 1)), step: 1,
                            format: { _ in String(format: "%.1f dB", Double(radio.gain) / 10) })
            }
            Row("RTL AGC") {
                Toggle("", isOn: $radio.rtlAGC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("RTL2832U digital AGC")
            }
            Row("PPM") {
                Stepper(value: $radio.ppm, in: -200...200) {
                    Text("\(radio.ppm)")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Row("Direct samp.") {
                Picker("", selection: $radio.directSampling) {
                    Text("Off").tag(0)
                    Text("I").tag(1)
                    Text("Q (HF)").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Direct sampling for HF below 24 MHz (RTL-SDR Blog V3: Q branch)")
            }
            Row("Bias-T") {
                Toggle("", isOn: $radio.biasTee)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Powers an LNA through the coax. Only use with compatible hardware.")
                Spacer()
                Text("Offset").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Toggle("", isOn: $radio.offsetTuning)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Offset tuning (E4000 tuners)")
            }
            Row("DC removal") {
                Toggle("", isOn: $radio.dcCorrection)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Spacer()
                Text("Swap I/Q").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Toggle("", isOn: $radio.swapIQ)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            ValueSlider(label: "Meter cal.", value: $radio.meterCalibration, range: -40...20, step: 1,
                        format: { String(format: "%+.0f dB", $0) })
                .help("Offset applied when converting dBFS to the (estimated) dBm reading of the S-meter")
        }
    }
}

struct DisplayPanel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        Panel("Display", systemImage: "waveform.path.ecg.rectangle") {
            Row("Theme") {
                Picker("", selection: $radio.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Row("FFT size") {
                Picker("", selection: $radio.fftSize) {
                    ForEach(SpectrumAnalyzer.sizes, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
            Text(String(format: "Resolution %.1f Hz", radio.sampleRate / Double(radio.fftSize)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ValueSlider(label: "Averaging", value: $radio.averaging, range: 0...0.95, format: { String(format: "%.0f %%", $0 * 100) })
            ValueSlider(label: "Frame rate", value: $radio.spectrumRate, range: 10...60, step: 5, format: { String(format: "%.0f fps", $0) })

            Divider().opacity(0.4)
            Text("Spectrum").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ValueSlider(label: "Top", value: $radio.spectrumTop, range: -80...20, step: 1, format: { String(format: "%.0f dB", $0) })
            ValueSlider(label: "Bottom", value: $radio.spectrumBottom, range: -160 ... -20, step: 1, format: { String(format: "%.0f dB", $0) })
            Row("Options") {
                Toggle("Fill", isOn: $radio.fillSpectrum).toggleStyle(.checkbox)
                Toggle("Peak hold", isOn: $radio.peakHold).toggleStyle(.checkbox)
            }

            Divider().opacity(0.4)
            Text("Waterfall").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Row("Palette") {
                Picker("", selection: $radio.palette) {
                    ForEach(WaterfallPalette.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            ValueSlider(label: "Min", value: $radio.waterfallMin, range: -160 ... -20, step: 1, format: { String(format: "%.0f dB", $0) })
            ValueSlider(label: "Max", value: $radio.waterfallMax, range: -120...20, step: 1, format: { String(format: "%.0f dB", $0) })
            ValueSlider(label: "Speed", value: $radio.waterfallSpeed, range: 5...60, step: 1, format: { String(format: "%.0f l/s", $0) })

            HStack {
                Button("Auto range") { radio.autoRange() }
                Button("Reset zoom") { radio.resetView() }
            }
            .controlSize(.small)
        }
    }
}

struct RecordingPanel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        Panel("Recording", systemImage: "record.circle") {
            HStack {
                Button(radio.recordingAudio ? "Stop audio" : "Record audio") { radio.toggleAudioRecording() }
                Button(radio.recordingIQ ? "Stop I/Q" : "Record I/Q") { radio.toggleIQRecording() }
            }
            .controlSize(.small)
            Text("Audio: 16-bit stereo WAV. I/Q: 8-bit WAV (playable as an I/Q file source).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open recordings folder") {
                NSWorkspace.shared.open(RadioController.recordingsFolder)
            }
            .controlSize(.small)
        }
    }
}
