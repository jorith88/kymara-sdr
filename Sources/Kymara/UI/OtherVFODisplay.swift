import SwiftUI
import SDRCore

/// Compact readout of the VFO that is not selected, next to the main LCD. Clicking it selects that VFO.
struct OtherVFODisplay: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        let vfo = radio.otherVFO
        let meter = radio.otherMeter
        let id = radio.selectedVFO.other
        let letter = id.rawValue
        Button {
            radio.toggleSelectedVFO()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("VFO \(letter)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.vfo(id).opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Theme.vfo(id))
                    Text(vfo.modeLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if vfo.muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.red)
                    }
                }
                Text(String(format: "%.6f", vfo.frequency / 1e6))
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(radio.otherInBand ? Theme.lcdText : Theme.dim)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !radio.otherInBand {
                        Text("Out of band")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    } else {
                        level(meter.signalDB)
                        if let call = meter.radeCallsign, vfo.mode.isRADE {
                            Text(call)
                                .font(.system(size: 10, weight: .bold).monospaced())
                                .foregroundStyle(Theme.vfo(id))
                        } else if vfo.mode == .wfm, meter.rds.hasData {
                            Text(meter.rds.trimmedProgramService)
                                .font(.system(size: 10, weight: .bold).monospaced())
                                .foregroundStyle(Theme.vfo(id))
                        }
                    }
                }
                .frame(height: 13)
            }
            .frame(width: 150, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("VFO \(letter): click to control it (⌘B)")
        .accessibilityLabel(accessibilityText(letter: letter, vfo: vfo, meter: meter))
        .accessibilityHint("Selects this VFO")
    }

    /// A short bar from −120 to −20 dBFS.
    private func level(_ db: Double) -> some View {
        let fraction = min(max((db + 120) / 100, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.fill)
            Capsule().fill(meterColor).frame(width: 60 * fraction)
        }
        .frame(width: 60, height: 5)
        .accessibilityHidden(true)
    }

    private var meterColor: Color {
        radio.otherMeter.squelchOpen || !radio.otherVFO.squelchEnabled ? Theme.green : Theme.dim
    }

    private func accessibilityText(letter: String, vfo: VFOState, meter: VFOMeter) -> String {
        var parts = ["VFO \(letter)", FrequencyFormat.short(vfo.frequency), vfo.modeLabel]
        if !radio.otherInBand { parts.append("out of band") }
        if vfo.muted { parts.append("muted") }
        if vfo.mode == .wfm, meter.rds.hasData { parts.append(meter.rds.trimmedProgramService) }
        if vfo.mode.isRADE, let call = meter.radeCallsign { parts.append("callsign \(call)") }
        return parts.joined(separator: ", ")
    }
}
