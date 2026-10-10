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

/// Callsign labels for the DX spots in view, over the spectrum. A separate view so that only it
/// observes the spot list and the view range; clicking a label tunes to the spot.
struct DXSpotOverlayLayer: View {
    @Environment(RadioController.self) private var radio
    @Environment(DXClusterStore.self) private var cluster
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    static let tagFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Also the height of a label's click target.
    static let rowHeight: Double = 20
    static let labelHeight: Double = 16
    /// Below the VFO tag.
    static let firstRowY: Double = 36

    var body: some View {
        if cluster.isEnabled && radio.showDXLabels {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let start = radio.viewStart, span = radio.viewSpan
                let spots = cluster.spots(in: start...(start + span))
                let rows = max(0, min(4, Int((h - Self.firstRowY - 40) / Self.rowHeight)))
                let placed = DXLabelLayout.place(spots.map {
                    .init(id: $0.id, x: ($0.frequency - start) / span * w, width: Self.labelWidth($0, tagged: differentiateWithoutColor))
                }, rows: rows)
                let now = Date()

                ZStack(alignment: .topLeading) {
                    // Faint markers from each label down to the bottom of the plot.
                    Canvas { ctx, size in
                        for spot in spots {
                            guard let row = placed[spot.id] else { continue }
                            let x = ((spot.frequency - start) / span * size.width).rounded() + 0.5
                            let top = Self.firstRowY + Double(row) * Self.rowHeight + Self.labelHeight / 2
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: top))
                            line.addLine(to: CGPoint(x: x, y: size.height - 18))
                            ctx.stroke(line, with: .color(spot.category.color.opacity(0.45 * fade(spot, now))),
                                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(spots) { spot in
                        if let row = placed[spot.id] {
                            DXSpotLabel(spot: spot, active: abs(spot.frequency - radio.vfoFrequency) < 500,
                                        strength: fade(spot, now), tagged: differentiateWithoutColor) {
                                radio.tune(to: spot)
                            }
                            .position(x: (spot.frequency - start) / span * w,
                                      y: Self.firstRowY + Double(row) * Self.rowHeight)
                        }
                    }
                }
            }
            // Semantic colours follow the spectrum's own theme, which can differ from the app's.
            .environment(\.colorScheme, radio.displayTheme.isLight(in: colorScheme) ? .light : .dark)
        }
    }

    /// Full strength for five minutes, then fading to 40 % at the maximum age.
    private func fade(_ spot: DXSpot, _ now: Date) -> Double {
        let age = now.timeIntervalSince(spot.time), fresh: Double = 5 * 60
        guard age > fresh, cluster.maxAge > fresh else { return 1 }
        return max(0.4, 1 - 0.6 * (age - fresh) / (cluster.maxAge - fresh))
    }

    /// The mode shown in a label when colour alone must not carry it.
    static func tag(_ spot: DXSpot) -> String {
        switch spot.category {
        case .cw: return "CW"
        case .digital: return "DIG"
        case .phone: return spot.demodMode.rawValue
        }
    }

    static func labelWidth(_ spot: DXSpot, tagged: Bool) -> Double {
        var width = (spot.dxCall as NSString).size(withAttributes: [.font: font]).width + 12
        if tagged { width += (tag(spot) as NSString).size(withAttributes: [.font: tagFont]).width + 3 }
        return width.rounded(.up)
    }
}

/// A callsign in the label colour on a neutral background (readable on any spectrum), with the mode
/// category as a coloured stripe and border. Age fades the colour, never the text.
private struct DXSpotLabel: View {
    let spot: DXSpot
    let active: Bool
    let strength: Double
    let tagged: Bool
    let tune: () -> Void

    var body: some View {
        let color = spot.category.color
        let shape = RoundedRectangle(cornerRadius: 3)
        Button(action: tune) {
            HStack(spacing: 3) {
                Text(spot.dxCall)
                    .font(Font(DXSpotOverlayLayer.font))
                    .foregroundStyle(.primary)
                if tagged {
                    Text(DXSpotOverlayLayer.tag(spot))
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
        .accessibilityLabel("\(spot.dxCall), \(FrequencyFormat.short(spot.frequency)), \(spot.category.rawValue)")
        .accessibilityHint("Tunes to this spot")
    }

    private var tooltip: String {
        var lines = ["\(spot.dxCall) · \(FrequencyFormat.short(spot.frequency)) · \(spot.demodMode.rawValue)"]
        if !spot.comment.isEmpty { lines.append(spot.comment) }
        if !spot.spotters.isEmpty { lines.append("Spotted by \(spot.spotters.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
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
