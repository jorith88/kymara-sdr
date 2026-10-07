import SwiftUI
import SDRCore

/// Axis labels and readouts drawn over the Metal spectrum.
struct SpectrumOverlay: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let start = radio.viewStart, span = radio.viewSpan
            let top = radio.spectrumTop
            let bottom = min(radio.spectrumBottom, top - 10)
            let fTicks = Axis.frequencyTicks(start: start, end: start + span, width: w)

            ZStack(alignment: .topLeading) {
                // dB scale.
                ForEach(Axis.dbTicks(bottom: bottom, top: top, height: h), id: \.self) { db in
                    let y = h - (db - bottom) / (top - bottom) * h
                    Text("\(Int(db))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .position(x: 16, y: min(max(y, 7), h - 7))
                }
                // Frequency scale.
                ForEach(fTicks.ticks, id: \.self) { f in
                    let x = (f - start) / span * w
                    Text(Axis.frequencyLabel(f, step: fTicks.step))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
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
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                        .position(x: w - 90, y: 28)
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
                VSplitView {
                    ZStack {
                        MetalDisplay(radio: radio, kind: .spectrum)
                        SpectrumOverlay()
                    }
                    .frame(minHeight: 140, idealHeight: 320)
                    MetalDisplay(radio: radio, kind: .waterfall)
                        .frame(minHeight: 100, idealHeight: 420)
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
