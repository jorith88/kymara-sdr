import SwiftUI
import SDRCore

/// Axis labels and readouts drawn over the Metal spectrum.
struct SpectrumOverlay: View {
    @Environment(RadioController.self) private var radio
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let start = radio.viewStart, span = radio.viewSpan
            let top = radio.spectrumTop
            let bottom = min(radio.spectrumBottom, top - 10)
            let fTicks = Axis.frequencyTicks(start: start, end: start + span, width: w)
            let scale: Color = radio.displayTheme.isLight(in: colorScheme) ? Color(red: 0.05, green: 0.1, blue: 0.2) : .white

            ZStack(alignment: .topLeading) {
                // dB scale, mirrored on both edges so the plot reads as framed when nothing sits to its right.
                ForEach(Axis.dbTicks(bottom: bottom, top: top, height: h), id: \.self) { db in
                    let y = min(max(h - (db - bottom) / (top - bottom) * h, 7), h - 7)
                    let label = Text("\(Int(db))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(scale.opacity(0.7))
                    label.position(x: 16, y: y)
                    label.position(x: w - 16, y: y)
                }
                // Frequency scale.
                ForEach(fTicks.ticks, id: \.self) { f in
                    let x = (f - start) / span * w
                    Text(Axis.frequencyLabel(f, step: fTicks.step))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(scale.opacity(0.8))
                        .fixedSize()
                        .position(x: min(max(x, 30), w - 30), y: h - 8)
                }
                // VFO tag.
                let vx = (radio.vfoFrequency - start) / span * w
                Text(FrequencyFormat.short(radio.vfoFrequency))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(x: min(max(vx, 50), w - 50), y: 10)

                // Hover readout.
                if let hover = radio.hover {
                    let hx = (hover.frequency - start) / span * w
                    VStack(alignment: .leading, spacing: 0) {
                        Text(FrequencyFormat.short(hover.frequency))
                        if let db = hover.db { Text(String(format: "%.1f dB", db)) }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(4)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(x: hx + (hx > w - 110 ? -55 : 55), y: 36)
                }

                // Zoom indicator.
                if radio.zoom > 1.01 {
                    Text(String(format: "Zoom ×%.1f · span %@", radio.zoom, FrequencyFormat.bandwidth(span)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(scale.opacity(0.55))
                        .fixedSize()
                        .position(x: w - 110, y: 28)
                }
            }
            .allowsHitTesting(false)
            .drawingGroup()
        }
    }
}

struct StatusBar: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Circle()
                    .fill(radio.isRunning ? Theme.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(radio.sourceName)
            }
            item("Rate", String(format: "%.3f MS/s", radio.sampleRate / 1e6))
            if radio.isRunning {
                item("Actual", String(format: "%.3f MS/s", radio.measuredRate / 1e6))
                item("Audio", String(format: "%.1f kHz · %.0f ms", radio.audioRate / 1e3, radio.audioLatency * 1000))
            }
            item("RBW", String(format: "%.1f Hz", radio.sampleRate / Double(radio.fftSize)))
            Spacer()
            Text("Scroll: tune · ⌘/⌥ scroll or pinch: zoom · drag: pan/LO · ⌥: fine")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.ribbon)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10.5, design: .monospaced))
        }
    }
}

struct ContentView: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        VStack(spacing: 0) {
            TopRibbon()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 290)
                Rectangle().fill(Theme.border).frame(width: 1)
                SpectrumSplit(fraction: $radio.spectrumFraction) {
                    ZStack {
                        MetalDisplay(radio: radio, kind: .spectrum)
                        SpectrumOverlay()
                        if radio.mode == .wfm && radio.rdsEnabled && radio.showRDSPanel && radio.rds.hasData {
                            GeometryReader { geo in
                                // Keep the panel on the side away from the tuned station.
                                let vfoOnRight = (radio.vfoFrequency - radio.viewStart) / radio.viewSpan > 0.5
                                RDSOverlay(availableHeight: geo.size.height)
                                    .padding(.top, 38)
                                    .padding(.horizontal, 44)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: vfoOnRight ? .topLeading : .topTrailing)
                                    .animation(.easeInOut(duration: 0.25), value: vfoOnRight)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                } bottom: {
                    MetalDisplay(radio: radio, kind: .waterfall)
                }
                if radio.showBookmarks {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    BookmarksView()
                        .frame(width: 230)
                }
            }
            StatusBar()
        }
        .background(Theme.window)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    radio.setZoom(radio.zoom / 2)
                } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                Button {
                    radio.setZoom(radio.zoom * 2)
                } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                Button {
                    radio.autoRange()
                } label: { Label("Auto range", systemImage: "arrow.up.and.down.text.horizontal") }
                Toggle(isOn: $radio.showRDSPanel) {
                    Label("RDS panel", systemImage: "info.circle")
                }
                .disabled(radio.mode != .wfm || !radio.rdsEnabled)
                .help("Show or hide the RDS panel on the spectrum (⇧⌘R)")
                Toggle(isOn: $radio.showBookmarks) {
                    Label("Favourites", systemImage: "sidebar.right")
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { radio.errorMessage != nil }, set: { if !$0 { radio.errorMessage = nil } })) {
            Button("OK") { radio.errorMessage = nil }
        } message: {
            Text(radio.errorMessage ?? "")
        }
    }
}
