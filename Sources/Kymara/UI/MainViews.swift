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
                        .font(.system(size: 10, design: .monospaced))
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

                // Zoom indicator.
                if radio.zoom > 1.01 {
                    Text(String(format: "Zoom ×%.1f · span %@", radio.zoom, FrequencyFormat.bandwidth(span)))
                        .font(.system(size: 10))
                        .foregroundStyle(scale.opacity(0.6))
                        .fixedSize()
                        .position(x: w - 110, y: 28)
                }
            }
            .allowsHitTesting(false)
            .drawingGroup()
        }
    }
}

/// The frequency under the cursor, at the top of the waterfall, for a hover over the spectrum or the
/// waterfall (over the spectrum it would cover the DX spot labels).
struct WaterfallOverlay: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            if let hover = radio.hover {
                let hx = (hover.frequency - radio.viewStart) / radio.viewSpan * w
                Text(FrequencyFormat.short(hover.frequency))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(x: hx + (hx > w - 110 ? -55 : 55), y: 14)
            }
        }
        .allowsHitTesting(false)
    }
}

struct StatusBar: View {
    @Environment(RadioController.self) private var radio
    @Environment(DXClusterStore.self) private var cluster

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Circle()
                    .fill(radio.isRunning ? Theme.green : Color.gray)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(radio.sourceName)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(radio.isRunning ? "Running" : "Stopped")
            item("Rate", String(format: "%.3f MS/s", radio.sampleRate / 1e6))
            if radio.isRunning {
                item("Actual", String(format: "%.3f MS/s", radio.measuredRate / 1e6))
                item("Audio", String(format: "%.1f kHz · %.0f ms", radio.audioRate / 1e3, radio.audioLatency * 1000))
            }
            item("RBW", String(format: "%.1f Hz", radio.sampleRate / Double(radio.fftSize)))
            if cluster.isEnabled { DXClusterStatus() }
            Spacer()
            Text("Scroll: tune · ⌘/⌥ scroll or pinch: zoom · drag: pan/LO · ⌥: fine")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.ribbon)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}

/// The RDS panel over the spectrum. A separate view so that ContentView does not observe `rds`,
/// which changes several times a second while RDS is decoding.
private struct RDSOverlayLayer: View {
    @Environment(RadioController.self) private var radio
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if radio.mode == .wfm && radio.rdsEnabled && radio.showRDSPanel && radio.rds.hasData {
            GeometryReader { geo in
                // Keep the panel on the side away from the tuned station.
                let vfoOnRight = (radio.vfoFrequency - radio.viewStart) / radio.viewSpan > 0.5
                RDSOverlay(availableHeight: geo.size.height)
                    .padding(.top, 38)
                    .padding(.horizontal, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: vfoOnRight ? .topLeading : .topTrailing)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: vfoOnRight)
            }
            .allowsHitTesting(false)
        }
    }
}

struct ContentView: View {
    @Environment(RadioController.self) private var radio
    @Environment(DXClusterStore.self) private var cluster

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
                            .accessibilityElement()
                            .accessibilityLabel("Spectrum")
                            .accessibilityValue("Tuned to \(FrequencyFormat.short(radio.vfoFrequency))")
                            .accessibilityHint("Scroll to tune, drag to pan")
                        SpectrumOverlay()
                        DXSpotOverlayLayer()
                        RDSOverlayLayer()
                    }
                } bottom: {
                    VStack(spacing: 0) {
                        MetalDisplay(radio: radio, kind: .waterfall)
                            .accessibilityElement()
                            .accessibilityLabel("Waterfall")
                            .overlay { WaterfallOverlay() }
                        BandOverview()
                    }
                }
                if radio.showBookmarks {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    SidePanel()
                        .frame(width: 230)
                }
            }
            StatusBar()
        }
        .background(Theme.window)
        // Polling for DX spots stops while nobody can see them.
        .background(WindowVisibilityReader { cluster.isPaused = !$0 })
        // Identified items make the toolbar user-customizable (View > Customize Toolbar…).
        .toolbar(id: "main") {
            ToolbarItem(id: "zoomOut", placement: .primaryAction) {
                Button {
                    radio.setZoom(radio.zoom / 2)
                } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            }
            ToolbarItem(id: "zoomIn", placement: .primaryAction) {
                Button {
                    radio.setZoom(radio.zoom * 2)
                } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
            }
            ToolbarItem(id: "autoRange", placement: .primaryAction) {
                Button {
                    radio.autoRange()
                } label: { Label("Auto Range", systemImage: "arrow.up.and.down.text.horizontal") }
                .help("Fit the spectrum and waterfall levels to the signal (⌥⌘0)")
            }
            ToolbarItem(id: "rdsPanel", placement: .primaryAction) {
                Toggle(isOn: $radio.showRDSPanel) {
                    Label("RDS Panel", systemImage: "info.circle")
                }
                .disabled(radio.mode != .wfm || !radio.rdsEnabled)
                .help("Show or hide the RDS panel on the spectrum (⇧⌘R)")
            }
            ToolbarItem(id: "dxLabels", placement: .primaryAction) {
                Toggle(isOn: $radio.showDXLabels) {
                    Label("DX Labels", systemImage: "tag")
                }
                .disabled(!cluster.isEnabled)
                .help("Show or hide DX spot labels on the spectrum (⇧⌘L)")
            }
            ToolbarItem(id: "favourites", placement: .primaryAction) {
                Toggle(isOn: $radio.showBookmarks) {
                    Label("Favourites", systemImage: "sidebar.right")
                }
                .help("Show or hide favourites (⌥⌘B)")
            }
        }
        .alert("Error", isPresented: Binding(get: { radio.errorMessage != nil }, set: { if !$0 { radio.errorMessage = nil } })) {
            Button("OK") { radio.errorMessage = nil }
        } message: {
            Text(radio.errorMessage ?? "")
        }
    }
}

/// DX cluster state in the status bar: spot count, or why there are no new spots.
private struct DXClusterStatus: View {
    @Environment(DXClusterStore.self) private var cluster

    private var state: (color: Color, text: String) {
        if cluster.isPaused { return (.gray, "paused") }
        if cluster.lastError != nil { return (Theme.amber, cluster.spots.isEmpty ? "offline" : "\(cluster.spots.count) spots, offline") }
        if cluster.lastUpdate == nil { return (.gray, "connecting") }
        return (Theme.green, "\(cluster.spots.count) spots")
    }

    var body: some View {
        let state = state
        HStack(spacing: 4) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("DX").foregroundStyle(.tertiary)
            Text(state.text)
        }
        .help(cluster.lastError ?? "Spots from \(cluster.providerName).com"
              + (cluster.lastUpdate.map { ", updated \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("DX cluster")
        .accessibilityValue(state.text)
    }
}
