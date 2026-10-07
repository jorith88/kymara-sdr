import SwiftUI
import SDRCore

/// Station information from RDS, shown above the spectrum in WFM mode.
struct RDSBar: View {
    @Environment(RadioController.self) private var radio

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        let r = radio.rds
        HStack(spacing: 12) {
            Text("RDS")
                .font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(r.synced ? Theme.green : Theme.dim)
                .background((r.synced ? Theme.green : Theme.dim).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .help(r.synced ? String(format: "Synchronised · %.0f%% block errors", r.blockErrorRate * 100) : "Not synchronised")

            if r.hasData {
                Text(r.programService.isEmpty ? "        " : r.programService)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.lcdText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                field("PI", r.piHex)
                if !r.ptyName.isEmpty {
                    Text(r.ptyName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                badge("TP", on: r.trafficProgram, color: Theme.accent)
                badge("TA", on: r.trafficAnnouncement, color: Theme.amber)
                Rectangle().fill(Theme.border).frame(width: 1, height: 16)
                Text(r.radioText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(r.radioText)
                if let time = r.clockTime {
                    Label(Self.clockFormat.string(from: time.addingTimeInterval(Double(r.clockOffsetMinutes) * 60)),
                          systemImage: "clock")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("Station clock (RDS CT)")
                }
            } else {
                Text(radio.isRunning ? "Searching for RDS…" : "RDS decoding starts when the radio is running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.ribbon)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
        .font(.system(size: 10.5))
        .fixedSize()
    }

    private func badge(_ text: String, on: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(on ? color : Theme.dim.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? color : Theme.border))
    }
}
