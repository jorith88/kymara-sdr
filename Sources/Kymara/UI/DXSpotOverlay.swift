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

    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    static let rowHeight: Double = 17
    /// Below the VFO tag.
    static let firstRowY: Double = 34

    var body: some View {
        if cluster.isEnabled && radio.showDXLabels {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let start = radio.viewStart, span = radio.viewSpan
                let spots = cluster.spots(in: start...(start + span))
                let rows = max(0, min(4, Int((h - Self.firstRowY - 40) / Self.rowHeight)))
                let placed = DXLabelLayout.place(spots.map {
                    .init(id: $0.id, x: ($0.frequency - start) / span * w, width: Self.labelWidth($0.dxCall))
                }, rows: rows)
                let now = Date()

                ZStack(alignment: .topLeading) {
                    // Faint markers from each label down to the bottom of the plot.
                    Canvas { ctx, size in
                        for spot in spots {
                            guard let row = placed[spot.id] else { continue }
                            let x = ((spot.frequency - start) / span * size.width).rounded() + 0.5
                            let top = Self.firstRowY + Double(row) * Self.rowHeight + Self.rowHeight / 2
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: top))
                            line.addLine(to: CGPoint(x: x, y: size.height - 18))
                            ctx.stroke(line, with: .color(spot.category.color.opacity(0.35 * fade(spot, now))),
                                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(spots) { spot in
                        if let row = placed[spot.id] {
                            DXSpotLabel(spot: spot, active: abs(spot.frequency - radio.vfoFrequency) < 500,
                                        opacity: fade(spot, now)) {
                                radio.tune(to: spot, centre: false)
                            }
                            .position(x: (spot.frequency - start) / span * w,
                                      y: Self.firstRowY + Double(row) * Self.rowHeight)
                        }
                    }
                }
            }
        }
    }

    /// Full strength for five minutes, then fading to 55 % at the maximum age.
    private func fade(_ spot: DXSpot, _ now: Date) -> Double {
        let age = now.timeIntervalSince(spot.time), fresh: Double = 5 * 60
        guard age > fresh, cluster.maxAge > fresh else { return 1 }
        return max(0.55, 1 - 0.45 * (age - fresh) / (cluster.maxAge - fresh))
    }

    static func labelWidth(_ call: String) -> Double {
        (call as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 10
    }
}

private struct DXSpotLabel: View {
    let spot: DXSpot
    let active: Bool
    let opacity: Double
    let tune: () -> Void

    var body: some View {
        Button(action: tune) {
            Text(spot.dxCall)
                .font(Font(DXSpotOverlayLayer.font))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(spot.category.color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .overlay {
                    if active { RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1.5) }
                }
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
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
