import SwiftUI

/// Coarse frequency bar under the waterfall, like SDR Console's: a wide span around the tuner LO with the
/// range the waterfall shows highlighted. Clicking tunes there, retuning the LO when it falls outside the band;
/// dragging slides the highlighted range, moving LO and VFO together.
struct BandOverview: View {
    @Environment(RadioController.self) private var radio

    /// Bar range and frequencies at the start of a drag. The bar stays put while dragging, otherwise it
    /// would recentre on the moving LO under the pointer.
    private struct DragStart { var start, span, center, vfo: Double }
    @State private var drag: DragStart?

    /// Span of the bar, in multiples of the sample rate.
    static let spanFactor: Double = 10
    static let height: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let (start, span) = range
            let ticks = Axis.frequencyTicks(start: start, end: start + span, width: w)
            let x0 = (radio.viewStart - start) / span * w
            let x1 = (radio.viewEnd - start) / span * w

            ZStack(alignment: .topLeading) {
                Theme.panel
                // Waterfall range; at least 3 pt wide so it stays visible when zoomed in far.
                let rw = max(x1 - x0, 3)
                Rectangle()
                    .fill(Theme.accent.opacity(0.3))
                    .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
                    .frame(width: rw, height: h)
                    .offset(x: (x0 + x1) / 2 - rw / 2)
                // Ticks: tall at labelled frequencies, medium halfway, short in between.
                let minor = Axis.minorStep(major: ticks.step, range: span, width: w)
                let perMajor = Int((ticks.step / minor).rounded())
                Canvas { ctx, _ in
                    for i in Int(ceil(start / minor))...Int(floor((start + span) / minor)) {
                        let x = (Double(i) * minor - start) / span * w
                        let len: CGFloat = i % perMajor == 0 ? 7 : perMajor % 2 == 0 && i % (perMajor / 2) == 0 ? 5 : 3
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 1, width: 1, height: len)), with: .color(Theme.dim.opacity(0.6)))
                    }
                }
                .allowsHitTesting(false)
                ForEach(ticks.ticks, id: \.self) { f in
                    let x = (f - start) / span * w
                    Text(Axis.frequencyLabel(f, step: ticks.step))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize()
                        .position(x: min(max(x, 24), w - 24), y: h / 2 + 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard radio.canRetune, abs(g.translation.width) >= 3 || drag != nil else { return }
                        let d = drag ?? DragStart(start: start, span: span,
                                                  center: radio.centerFrequency, vfo: radio.vfoFrequency)
                        drag = d
                        // Snap the VFO to the step and move the LO by the same amount, so the offset is kept.
                        let vfo = radio.snapped(d.vfo + g.translation.width / w * d.span)
                        radio.setCenterFrequency(d.center + vfo - d.vfo)
                        radio.tune(to: vfo)
                    }
                    .onEnded { g in
                        if drag == nil {
                            radio.tune(to: radio.snapped(start + g.location.x / w * span))
                        }
                        drag = nil
                    }
            )
            .help("Click to tune, drag to move the band")
        }
        .frame(height: Self.height)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .accessibilityElement()
        .accessibilityLabel("Band overview")
        .accessibilityValue("Showing \(FrequencyFormat.short(radio.viewStart)) to \(FrequencyFormat.short(radio.viewEnd))")
        .accessibilityHint("Adjust to move the tuned frequency by one waterfall width")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? radio.viewSpan : -radio.viewSpan
            radio.tune(to: radio.snapped(radio.vfoFrequency + delta))
        }
    }

    /// Start and span of the bar, centred on the LO and kept within the tunable range.
    private var range: (start: Double, span: Double) {
        if let drag { return (drag.start, drag.span) }
        let span = radio.sampleRate * Self.spanFactor
        let start = min(max(radio.centerFrequency - span / 2, 0), 2_200_000_000 - span)
        return (start, span)
    }
}
