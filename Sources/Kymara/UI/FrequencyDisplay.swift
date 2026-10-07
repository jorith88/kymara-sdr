import SwiftUI
import AppKit

/// Large digit display: scroll over a digit to change it, click the upper/lower half to step it,
/// double-click (or type a number) to enter a frequency.
final class FrequencyDisplayNSView: NSView {
    static let digitCount = 10

    var frequency: Double = 0 {
        didSet { if oldValue != frequency { needsDisplay = true } }
    }
    var onChange: ((Double) -> Void)?
    var onRequestEntry: (() -> Void)?

    private var hoverDigit: Int?
    private var hoverUpper = true
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var digitRects: [CGRect] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 330, height: 52) }

    private let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .regular)
    private let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 29, weight: .regular)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func isSmall(_ index: Int) -> Bool { index >= 7 }

    private func layoutDigits() -> [CGRect] {
        var rects: [CGRect] = []
        let bigW = ("0" as NSString).size(withAttributes: [.font: bigFont]).width + 1
        let smallW = ("0" as NSString).size(withAttributes: [.font: smallFont]).width + 1
        let dotW: CGFloat = 9
        var x: CGFloat = 4
        for i in 0..<Self.digitCount {
            let w = isSmall(i) ? smallW : bigW
            rects.append(CGRect(x: x, y: 2, width: w, height: bounds.height - 4))
            x += w
            if i == 0 || i == 3 || i == 6 { x += dotW }
        }
        return rects
    }

    override func draw(_ dirtyRect: NSRect) {
        digitRects = layoutDigits()
        let value = Int64(max(0, frequency.rounded()))
        let digits = String(format: "%010lld", value).map { String($0) }
        let firstSignificant = digits.firstIndex { $0 != "0" } ?? (Self.digitCount - 1)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bright = dark ? NSColor(red: 0.88, green: 0.96, blue: 1, alpha: 1) : NSColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1)
        let dimColor = dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.18)
        let accent = dark ? NSColor(red: 0.25, green: 0.72, blue: 1, alpha: 1) : NSColor(red: 0, green: 0.47, blue: 0.85, alpha: 1)
        let baseline = bounds.height - 9

        for (i, rect) in digitRects.enumerated() {
            if i == hoverDigit {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3)
                (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)).setFill()
                path.fill()
                let half = NSRect(x: rect.minX, y: hoverUpper ? rect.minY + 1 : rect.midY, width: rect.width, height: rect.height / 2 - 1)
                accent.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: half, xRadius: 3, yRadius: 3).fill()
            }
            let font = isSmall(i) ? smallFont : bigFont
            let color = i < firstSignificant && i < 4 ? dimColor : (isSmall(i) ? bright.withAlphaComponent(0.8) : bright)
            let s = digits[i] as NSString
            let size = s.size(withAttributes: [.font: font])
            s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: baseline - font.ascender),
                   withAttributes: [.font: font, .foregroundColor: color])
            if i == 0 || i == 3 || i == 6 {
                let dot = NSRect(x: rect.maxX + 2.5, y: baseline - 5, width: 4, height: 4)
                (i == 0 && firstSignificant > 0 ? dimColor : bright.withAlphaComponent(0.7)).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    private func digitIndex(at p: CGPoint) -> Int? {
        if digitRects.isEmpty { digitRects = layoutDigits() }
        return digitRects.firstIndex { p.x >= $0.minX && p.x < $0.maxX }
    }

    private func weight(_ index: Int) -> Double {
        pow(10, Double(Self.digitCount - 1 - index))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let d = digitIndex(at: p)
        let upper = p.y < bounds.midY
        if d != hoverDigit || upper != hoverUpper {
            hoverDigit = d
            hoverUpper = upper
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverDigit = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onRequestEntry?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        guard let d = digitIndex(at: p) else { return }
        let delta = weight(d) * (p.y < bounds.midY ? 1 : -1)
        onChange?(max(0, frequency + delta))
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = digitIndex(at: p) else { return }
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            while abs(scrollAccumulator) >= 10 {
                steps += scrollAccumulator > 0 ? 1 : -1
                scrollAccumulator -= scrollAccumulator > 0 ? 10 : -10
            }
        } else if event.scrollingDeltaY != 0 {
            steps = event.scrollingDeltaY > 0 ? 1 : -1
        }
        if steps != 0 {
            onChange?(max(0, frequency + Double(steps) * weight(d)))
        }
    }

    override func keyDown(with event: NSEvent) {
        if let ch = event.charactersIgnoringModifiers?.first, ch.isNumber || ch == "." || event.keyCode == 36 {
            onRequestEntry?()
        } else {
            super.keyDown(with: event)
        }
    }
}

struct FrequencyDisplay: NSViewRepresentable {
    let frequency: Double
    let onChange: (Double) -> Void
    let onRequestEntry: () -> Void

    func makeNSView(context: Context) -> FrequencyDisplayNSView {
        let v = FrequencyDisplayNSView()
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }

    func updateNSView(_ v: FrequencyDisplayNSView, context: Context) {
        v.frequency = frequency
        v.onChange = onChange
        v.onRequestEntry = onRequestEntry
    }
}

/// Popover for typing a frequency.
struct FrequencyEntryView: View {
    @Environment(RadioController.self) private var radio
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter frequency")
                .font(.headline)
            TextField("e.g. 145.5, 7100k, 1090M", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16, design: .monospaced))
                .frame(width: 240)
                .focused($focused)
                .onSubmit(apply)
            Text("Plain numbers below 10 000 are MHz. Suffixes: k, M, G.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { radio.showFrequencyEntry = false }
                    .keyboardShortcut(.cancelAction)
                Button("Tune", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(FrequencyFormat.parse(text) == nil)
            }
        }
        .padding(14)
        .onAppear {
            text = String(format: "%.6f", radio.vfoFrequency / 1e6)
            focused = true
        }
    }

    private func apply() {
        guard let f = FrequencyFormat.parse(text) else { return }
        radio.tune(to: f)
        radio.showFrequencyEntry = false
    }
}
