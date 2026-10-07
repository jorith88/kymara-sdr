import SwiftUI

/// Signal strength meter: S1…S9 in 6 dB steps (S9 = −73 dBm), then +10…+60 dB.
struct SMeterView: View {
    @Environment(RadioController.self) private var radio

    private static let minDBm = -127.0
    private static let maxDBm = -13.0

    private func position(_ dbm: Double) -> Double {
        let s9 = -73.0
        // S1..S9 take 60% of the scale, +60 dB the remaining 40%.
        if dbm <= s9 {
            return max(0, (dbm - Self.minDBm) / (s9 - Self.minDBm)) * 0.6
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

    var body: some View {
        let dbm = radio.signalDBm
        let peakDBm = radio.signalPeakDB - radio.gainDB + radio.meterCalibration
        let squelchDBm: Double? = radio.squelchEnabled && !radio.autoSquelchActive ? radio.squelchLevel - radio.gainDB + radio.meterCalibration : nil

        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(radio.isRunning ? Self.sUnits(dbm) : "--")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(dbm > -73 ? Theme.amber : Theme.lcdText)
                    .contentTransition(.identity)
                Text(radio.isRunning ? String(format: "%.1f dBm", dbm) : " ")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(radio.isRunning ? String(format: "%.1f dBFS", radio.signalDB) : " ")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 92, alignment: .trailing)

            Canvas { ctx, size in
                let barTop: CGFloat = 18
                let barH: CGFloat = 12
                let segments = 46
                let gap: CGFloat = 1.5
                let segW = (size.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
                let level = radio.isRunning ? position(dbm) : 0
                for i in 0..<segments {
                    let x = CGFloat(i) * (segW + gap)
                    let frac = Double(i) / Double(segments)
                    let lit = frac < level
                    let base: Color = frac < 0.6 ? Theme.green : (frac < 0.8 ? Theme.amber : Theme.red)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: barTop, width: segW, height: barH), cornerRadius: 1),
                             with: .color(lit ? base : base.opacity(0.12)))
                }
                // Peak marker.
                if radio.isRunning {
                    let px = CGFloat(position(peakDBm)) * size.width
                    ctx.fill(Path(CGRect(x: px - 1, y: barTop - 2, width: 2, height: barH + 4)), with: .color(Theme.text))
                }
                // Squelch marker.
                if let squelchDBm {
                    let sx = CGFloat(position(squelchDBm)) * size.width
                    var tri = Path()
                    tri.move(to: CGPoint(x: sx, y: barTop + barH + 1))
                    tri.addLine(to: CGPoint(x: sx - 5, y: barTop + barH + 8))
                    tri.addLine(to: CGPoint(x: sx + 5, y: barTop + barH + 8))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(radio.squelchOpen ? Theme.green : Theme.red))
                }
                // Scale labels.
                let labels: [(String, Double)] = [("1", -121), ("3", -109), ("5", -97), ("7", -85), ("9", -73),
                                                  ("+20", -53), ("+40", -33), ("+60", -13)]
                for (text, value) in labels {
                    let x = CGFloat(position(value)) * size.width
                    let color: Color = value > -73 ? Theme.red.opacity(0.9) : Theme.dim
                    ctx.draw(Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color),
                             at: CGPoint(x: min(max(x, 8), size.width - 10), y: 7))
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 13, width: 1, height: 4)), with: .color(color.opacity(0.7)))
                }
            }
            .frame(width: 260, height: 42)
            .drawingGroup()
        }
    }
}
