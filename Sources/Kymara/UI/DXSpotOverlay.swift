import SwiftUI
import AppKit

/// Stacks spot labels in rows so they don't overlap.
enum DXLabelLayout {
    struct Item {
        var id: String
        /// Centre of the label.
        var x: Double
        var width: Double
    }

    /// Places items in order of priority (the first wins), each in the first row where it fits,
    /// and drops what doesn't fit in `rows` rows. Returns the row of every placed item.
    static func place(_ items: [Item], rows: Int, gap: Double = 4) -> [String: Int] {
        var occupied = Array(repeating: [ClosedRange<Double>](), count: max(rows, 0))
        var result: [String: Int] = [:]
        for item in items {
            let span = (item.x - item.width / 2 - gap / 2)...(item.x + item.width / 2 + gap / 2)
            if let row = occupied.indices.first(where: { r in !occupied[r].contains { $0.overlaps(span) } }) {
                occupied[row].append(span)
                result[item.id] = row
            }
        }
        return result
    }
}

/// Callsign labels for the DX spots and recent FreeDV transmitters in view, over the spectrum. A separate
/// view so that only it observes the spot lists and the view range; clicking a label tunes to the station.
struct DXSpotOverlayLayer: View {
    @Environment(RadioController.self) private var radio
    @Environment(DXClusterStore.self) private var cluster
    @Environment(FreeDVStationStore.self) private var freedv
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    static let tagFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Also the height of a label's click target.
    static let rowHeight: Double = 20
    static let labelHeight: Double = 16
    /// Below the VFO tag.
    static let firstRowY: Double = 36

    /// One label: a DX spot or a FreeDV station.
    private struct Entry: Identifiable {
        var id: String
        var frequency: Double
        var text: String
        var tag: String?
        var color: Color
        var strength: Double
        var tooltip: String
        var accessibilityLabel: String
        var tune: () -> Void
    }

    var body: some View {
        if (cluster.isEnabled || freedv.isEnabled) && radio.showDXLabels {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let start = radio.viewStart, span = radio.viewSpan
                // FreeDV stations first: there are few of them, and they are live.
                let entries = freedvEntries(start...(start + span)) + dxEntries(start...(start + span))
                let rows = max(0, min(4, Int((h - Self.firstRowY - 40) / Self.rowHeight)))
                let placed = DXLabelLayout.place(entries.map {
                    .init(id: $0.id, x: ($0.frequency - start) / span * w, width: Self.labelWidth($0.text, tag: $0.tag))
                }, rows: rows)

                ZStack(alignment: .topLeading) {
                    // Faint markers from each label down to the bottom of the plot.
                    Canvas { ctx, size in
                        for entry in entries {
                            guard let row = placed[entry.id] else { continue }
                            let x = ((entry.frequency - start) / span * size.width).rounded() + 0.5
                            let top = Self.firstRowY + Double(row) * Self.rowHeight + Self.labelHeight / 2
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: top))
                            line.addLine(to: CGPoint(x: x, y: size.height - 18))
                            ctx.stroke(line, with: .color(entry.color.opacity(0.45 * entry.strength)),
                                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(entries) { entry in
                        if let row = placed[entry.id] {
                            SpectrumLabel(text: entry.text, tag: entry.tag, color: entry.color,
                                          active: abs(entry.frequency - radio.vfoFrequency) < 500,
                                          strength: entry.strength, tooltip: entry.tooltip,
                                          accessibilityLabel: entry.accessibilityLabel, tune: entry.tune)
                                .position(x: (entry.frequency - start) / span * w,
                                          y: Self.firstRowY + Double(row) * Self.rowHeight)
                        }
                    }
                }
            }
            // Semantic colours follow the spectrum's own theme, which can differ from the app's.
            .environment(\.colorScheme, radio.displayTheme.isLight(in: colorScheme) ? .light : .dark)
        }
    }

    private func dxEntries(_ range: ClosedRange<Double>) -> [Entry] {
        guard cluster.isEnabled else { return [] }
        let now = Date()
        return cluster.spots(in: range).map { spot in
            var lines = ["\(spot.dxCall) · \(FrequencyFormat.short(spot.frequency)) · \(spot.demodMode.rawValue)"]
            if !spot.comment.isEmpty { lines.append(spot.comment) }
            if !spot.spotters.isEmpty { lines.append("Spotted by \(spot.spotters.joined(separator: ", "))") }
            return Entry(id: "dx:" + spot.id, frequency: spot.frequency, text: spot.dxCall,
                         tag: differentiateWithoutColor ? Self.tag(spot) : nil, color: spot.category.color,
                         strength: fade(spot, now), tooltip: lines.joined(separator: "\n"),
                         accessibilityLabel: "\(spot.dxCall), \(FrequencyFormat.short(spot.frequency)), \(spot.category.rawValue)",
                         tune: { radio.tune(to: spot) })
        }
    }

    private func freedvEntries(_ range: ClosedRange<Double>) -> [Entry] {
        guard freedv.isEnabled else { return [] }
        let now = Date()
        return freedv.transmitters(in: range).map { station in
            let call = station.callsign.uppercased()
            var lines = ["\(call) · \(FrequencyFormat.short(station.frequency)) · FreeDV \(station.locator)"]
            if station.transmitting {
                lines.append("Transmitting")
            } else if let t = station.lastTransmission {
                lines.append("Last transmission \(t.formatted(date: .omitted, time: .shortened))")
            }
            if !station.message.isEmpty { lines.append(station.message) }
            return Entry(id: "fdv:" + station.id, frequency: station.frequency, text: call,
                         tag: station.transmitting ? "TX" : (differentiateWithoutColor ? "FDV" : nil),
                         color: station.transmitting ? Color(nsColor: .systemRed) : FreeDVStationStore.labelColor,
                         strength: fade(station, now), tooltip: lines.joined(separator: "\n"),
                         accessibilityLabel: "\(call), \(FrequencyFormat.short(station.frequency)), FreeDV"
                             + (station.transmitting ? ", transmitting" : ""),
                         tune: { radio.tune(to: station) })
        }
    }

    /// Full strength for five minutes, then fading to 40 % at the maximum age.
    private func fade(_ spot: DXSpot, _ now: Date) -> Double {
        let age = now.timeIntervalSince(spot.time), fresh: Double = 5 * 60
        guard age > fresh, cluster.maxAge > fresh else { return 1 }
        return max(0.4, 1 - 0.6 * (age - fresh) / (cluster.maxAge - fresh))
    }

    /// Full strength while transmitting and for a minute after, then fading to 40 % when the label goes.
    private func fade(_ station: FreeDVStation, _ now: Date) -> Double {
        guard !station.transmitting, let t = station.lastTransmission else { return 1 }
        let age = now.timeIntervalSince(t), fresh: Double = 60, window = FreeDVStationStore.transmitterWindow
        guard age > fresh else { return 1 }
        return max(0.4, 1 - 0.6 * (age - fresh) / (window - fresh))
    }

    /// The mode shown in a label when colour alone must not carry it.
    static func tag(_ spot: DXSpot) -> String {
        switch spot.category {
        case .cw: return "CW"
        case .digital: return "DIG"
        case .phone: return spot.demodMode.rawValue
        }
    }

    static func labelWidth(_ text: String, tag: String?) -> Double {
        var width = (text as NSString).size(withAttributes: [.font: font]).width + 12
        if let tag { width += (tag as NSString).size(withAttributes: [.font: tagFont]).width + 3 }
        return width.rounded(.up)
    }
}

/// A callsign in the label colour on a neutral background (readable on any spectrum), with the kind of
/// station as a coloured stripe and border. Age fades the colour, never the text.
private struct SpectrumLabel: View {
    let text: String
    let tag: String?
    let color: Color
    let active: Bool
    let strength: Double
    let tooltip: String
    let accessibilityLabel: String
    let tune: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        Button(action: tune) {
            HStack(spacing: 3) {
                Text(text)
                    .font(Font(DXSpotOverlayLayer.font))
                    .foregroundStyle(.primary)
                if let tag {
                    Text(tag)
                        .font(Font(DXSpotOverlayLayer.tagFont))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .frame(height: DXSpotOverlayLayer.labelHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            .overlay(alignment: .leading) { Rectangle().fill(color.opacity(strength)).frame(width: 3) }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(active ? Color.primary : color.opacity(0.7 * strength), lineWidth: active ? 1.5 : 1)
            }
            .fixedSize()
            // The click target is the full row height, taller than the label.
            .frame(height: DXSpotOverlayLayer.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Tunes to this station")
    }
}

extension DXSpotCategory {
    var color: Color {
        switch self {
        case .cw: return Theme.amber
        case .phone: return Color(nsColor: .systemBlue)
        case .digital: return Color(nsColor: .systemPurple)
        }
    }
}
