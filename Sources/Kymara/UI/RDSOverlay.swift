import SwiftUI
import SDRCore

/// RDS station panel drawn over the top-right of the spectrum in WFM mode.
struct RDSOverlay: View {
    @Environment(RadioController.self) private var radio
    /// Height available in the spectrum; below ~230 pt only the station name is shown.
    let availableHeight: CGFloat

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        let r = radio.rds
        let compact = availableHeight < 230
        VStack(spacing: compact ? 2 : 6) {
            if !compact {
                HStack(spacing: 14) {
                    if !r.ptyName.isEmpty { Text(r.ptyName) }
                    Text(String(format: "%.1f", radio.vfoFrequency / 1e6))
                    badge("TP", on: r.trafficProgram, color: Color(red: 0.4, green: 0.75, blue: 1))
                    badge("TA", on: r.trafficAnnouncement, color: Color(red: 1, green: 0.75, blue: 0.2))
                }
                HStack(spacing: 14) {
                    Text("PI \(r.piHex)")
                    if let time = r.clockTime {
                        Text(Self.clockFormat.string(from: time.addingTimeInterval(Double(r.clockOffsetMinutes) * 60)))
                    }
                }
                .foregroundStyle(.white.opacity(0.75))
            }

            Text(r.programService.isEmpty ? " " : r.programService)
                .font(.system(size: compact ? 30 : 50, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.vertical, compact ? 0 : 6)

            if !compact && !r.radioText.isEmpty {
                Text(r.radioText)
                    .font(.system(size: 14, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 14, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 8 : 14)
        .frame(width: compact ? 250 : 420)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
        .opacity(r.synced ? 1 : 0.6)
    }

    private func badge(_ text: String, on: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(on ? color : .white.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? color : .white.opacity(0.2)))
    }
}
