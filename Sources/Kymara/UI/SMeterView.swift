import SwiftUI

/// Signal strength meter: S1…S9 in 6 dB steps (S9 = −73 dBm), then +10…+60 dB.
///
/// The meter updates at 30 Hz, so this view itself reads no radio state: the static scale is drawn once by
/// `SMeterScale`, and the live parts (`SMeterReadout`, `SMeterBar`) sit in views whose size doesn't depend on
/// their content, so an update redraws only them and never relayouts the ribbon.
struct SMeterView: View {
    static let minDBm = -127.0
    static let maxDBm = -13.0
    static let segments = 46

    static func position(_ dbm: Double) -> Double {
        let s9 = -73.0
        // S1..S9 take 60% of the scale, +60 dB the remaining 40%.
        if dbm <= s9 {
            return max(0, (dbm - minDBm) / (s9 - minDBm)) * 0.6
        }
        return 0.6 + min(1, (dbm - s9) / 60) * 0.4
    }

    static func sUnits(_ dbm: Double) -> String {
        if dbm <= -73 {
            let s = max(0, Int(((dbm + 127) / 6).rounded(.down)))
            return "S\(min(s, 9))"
        }
        return "S9+\(Int((dbm + 73).rounded()))"
    }

    /// The colour of a scale segment at `frac` (0…1) of the width.
    static func segmentColor(_ frac: Double) -> Color {
        frac < 0.6 ? Theme.green : (frac < 0.8 ? Theme.amber : Theme.red)
    }

    /// The rectangle of segment `i` in a meter `width` wide.
    static func segmentRect(_ i: Int, width: CGFloat) -> CGRect {
        let gap: CGFloat = 1.5
        let segW = (width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        return CGRect(x: CGFloat(i) * (segW + gap), y: barTop, width: segW, height: barHeight)
    }

    static let barTop: CGFloat = 18
    static let barHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 10) {
            // Sized by placeholder text, so the live readout in the overlay can't change the layout.
            SMeterReadout.layout(big: "S9+60", small: "-100.0 dBFS")
                .hidden()
                .frame(width: 92, alignment: .trailing)
                .overlay(alignment: .trailing) { SMeterReadout() }

            ZStack {
                SMeterScale()
                SMeterBar()
            }
            .frame(width: 260, height: 42)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

/// S units, dBm and dBFS.
private struct SMeterReadout: View {
    @Environment(RadioController.self) private var radio

    static func layout(big: String, small: String, smallTertiary: String? = nil,
                       bigColor: Color = Theme.lcdText) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(big)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(bigColor)
                .contentTransition(.identity)
            Text(small)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(smallTertiary ?? small)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        let dbm = radio.signalDBm
        let running = radio.isRunning
        Self.layout(big: running ? SMeterView.sUnits(dbm) : "--",
                    small: running ? String(format: "%.1f dBm", dbm) : " ",
                    smallTertiary: running ? String(format: "%.1f dBFS", radio.signalDB) : " ",
                    bigColor: dbm > -73 ? Theme.amber : Theme.lcdText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Signal strength")
            .accessibilityValue(running ? "\(SMeterView.sUnits(dbm)), \(String(format: "%.0f", dbm)) dBm" : "Radio stopped")
    }
}

/// The parts of the meter that never change: unlit segments, scale labels and ticks.
private struct SMeterScale: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<SMeterView.segments {
                let color = SMeterView.segmentColor(Double(i) / Double(SMeterView.segments))
                ctx.fill(Path(roundedRect: SMeterView.segmentRect(i, width: size.width), cornerRadius: 1),
                         with: .color(color.opacity(0.25)))
            }
            let labels: [(String, Double)] = [("1", -121), ("3", -109), ("5", -97), ("7", -85), ("9", -73),
                                              ("+20", -53), ("+40", -33), ("+60", -13)]
            for (text, value) in labels {
                let x = CGFloat(SMeterView.position(value)) * size.width
                let color: Color = value > -73 ? Theme.red.opacity(0.9) : Theme.dim
                ctx.draw(Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color),
                         at: CGPoint(x: min(max(x, 8), size.width - 10), y: 7))
                ctx.fill(Path(CGRect(x: x - 0.5, y: 13, width: 1, height: 4)), with: .color(color.opacity(0.7)))
            }
        }
    }
}

/// Lit segments, peak and squelch markers, drawn over `SMeterScale`.
private struct SMeterBar: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        let running = radio.isRunning
        let level = running ? SMeterView.position(radio.signalDBm) : 0
        let peakDBm = radio.signalPeakDB - radio.gainDB + radio.meterCalibration
        let squelchDBm: Double? = radio.squelchEnabled && !radio.autoSquelchActive
            ? radio.squelchLevel - radio.gainDB + radio.meterCalibration : nil
        let squelchOpen = radio.squelchOpen

        Canvas { ctx, size in
            // One path per colour, so a frame resolves three colours instead of one per segment.
            var lit: [(Color, Path)] = [(Theme.green, Path()), (Theme.amber, Path()), (Theme.red, Path())]
            for i in 0..<SMeterView.segments {
                let frac = Double(i) / Double(SMeterView.segments)
                guard frac < level else { break }
                let band = frac < 0.6 ? 0 : (frac < 0.8 ? 1 : 2)
                lit[band].1.addRoundedRect(in: SMeterView.segmentRect(i, width: size.width),
                                           cornerSize: CGSize(width: 1, height: 1))
            }
            for (color, path) in lit where !path.isEmpty {
                ctx.fill(path, with: .color(color))
            }
            let barTop = SMeterView.barTop, barH = SMeterView.barHeight
            if running {
                let px = CGFloat(SMeterView.position(peakDBm)) * size.width
                ctx.fill(Path(CGRect(x: px - 1, y: barTop - 2, width: 2, height: barH + 4)), with: .color(Theme.text))
            }
            if let squelchDBm {
                let sx = CGFloat(SMeterView.position(squelchDBm)) * size.width
                var tri = Path()
                tri.move(to: CGPoint(x: sx, y: barTop + barH + 1))
                tri.addLine(to: CGPoint(x: sx - 5, y: barTop + barH + 8))
                tri.addLine(to: CGPoint(x: sx + 5, y: barTop + barH + 8))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(squelchOpen ? Theme.green : Theme.red))
            }
        }
    }
}
