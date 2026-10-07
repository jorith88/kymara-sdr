import SwiftUI
import MetalKit
import SDRCore

enum DisplayKind {
    case spectrum
    case waterfall
}

/// MTKView with SDR-style mouse handling: click to tune, drag the passband or its edges,
/// drag the background to pan / move the tuner, scroll to tune, ⌘/⌥-scroll or pinch to zoom.
@MainActor
final class InteractiveMTKView: MTKView {
    weak var radio: RadioController?
    var kind: DisplayKind = .spectrum

    private enum DragMode {
        case none
        case pending(startX: CGFloat)
        case tune(grabOffset: Double)
        case edgeLow
        case edgeHigh
        case pan(lastX: CGFloat)
    }

    private var drag: DragMode = .none
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func frequency(at x: CGFloat) -> Double {
        guard let r = radio else { return 0 }
        return r.viewStart + Double(x / max(bounds.width, 1)) * r.viewSpan
    }

    private func screenX(_ f: Double) -> CGFloat {
        guard let r = radio else { return 0 }
        return CGFloat((f - r.viewStart) / r.viewSpan) * bounds.width
    }

    private func db(at y: CGFloat) -> Double? {
        guard kind == .spectrum, let r = radio else { return nil }
        let bottom = min(r.spectrumBottom, r.spectrumTop - 10)
        return bottom + Double(y / max(bounds.height, 1)) * (r.spectrumTop - bottom)
    }

    private enum Hit { case edgeLow, edgeHigh, passband, background }

    private func hitTest(x: CGFloat) -> Hit {
        guard let r = radio else { return .background }
        let lo = screenX(r.filterStart), hi = screenX(r.filterEnd)
        if hi - lo > 12 {
            if abs(x - lo) < 5 { return .edgeLow }
            if abs(x - hi) < 5 { return .edgeHigh }
        }
        if x >= min(lo, hi - 4) && x <= max(hi, lo + 4) { return .passband }
        return .background
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        radio?.hover = (frequency(at: p.x), db(at: p.y))
        switch hitTest(x: p.x) {
        case .edgeLow, .edgeHigh: NSCursor.resizeLeftRight.set()
        case .passband: NSCursor.openHand.set()
        case .background: NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        radio?.hover = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let r = radio else { return }
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, kind == .spectrum {
            // Double click: centre the view on the VFO.
            r.setZoom(r.zoom, anchor: nil)
            return
        }
        switch hitTest(x: p.x) {
        case .edgeLow: drag = .edgeLow
        case .edgeHigh: drag = .edgeHigh
        case .passband:
            drag = .tune(grabOffset: frequency(at: p.x) - r.vfoFrequency)
            NSCursor.closedHand.set()
        case .background: drag = .pending(startX: p.x)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let r = radio else { return }
        let p = convert(event.locationInWindow, from: nil)
        let f = frequency(at: p.x)
        r.hover = (f, db(at: p.y))
        let fine = event.modifierFlags.contains(.option)
        switch drag {
        case .pending(let startX):
            if abs(p.x - startX) > 3 { drag = .pan(lastX: p.x) }
        case .pan(let lastX):
            let dHz = Double(p.x - lastX) / Double(bounds.width) * r.viewSpan
            if r.zoom > 1 {
                r.pan(by: -dHz)
            } else if r.canRetune {
                // Drag the band: the tuner moves opposite to the mouse, signals follow the cursor.
                r.setCenterFrequency(r.centerFrequency - dHz)
            }
            drag = .pan(lastX: p.x)
        case .tune(let grab):
            let target = f - grab
            r.tune(to: fine ? target.rounded() : r.snapped(target))
        case .edgeLow, .edgeHigh:
            let isLow: Bool = { if case .edgeLow = drag { return true } else { return false } }()
            let d = f - r.vfoFrequency
            switch r.mode {
            case .usb: r.setBandwidth((isLow ? r.filterEnd - f : d - 100))
            case .lsb: r.setBandwidth((isLow ? -d - 100 : f - r.filterStart))
            default: r.setBandwidth(2 * abs(d))
            }
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let r = radio else { return }
        let p = convert(event.locationInWindow, from: nil)
        if case .pending = drag {
            let f = frequency(at: p.x)
            r.tune(to: event.modifierFlags.contains(.option) ? f.rounded() : r.snapped(f))
        }
        drag = .none
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = radio else { return }
        let p = convert(event.locationInWindow, from: nil)
        let anchor = frequency(at: p.x)
        let dy = event.scrollingDeltaY, dx = event.scrollingDeltaX
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let amount = event.hasPreciseScrollingDeltas ? dy / 50 : dy / 5
            r.setZoom(r.zoom * pow(1.25, Double(amount)), anchor: anchor)
            return
        }
        if event.hasPreciseScrollingDeltas && abs(dx) > abs(dy) {
            if r.zoom > 1 {
                r.pan(by: -Double(dx) / Double(bounds.width) * r.viewSpan)
            }
            return
        }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += dy
            let threshold: CGFloat = 12
            while abs(scrollAccumulator) >= threshold {
                r.tuneSteps(scrollAccumulator > 0 ? 1 : -1)
                scrollAccumulator -= scrollAccumulator > 0 ? threshold : -threshold
            }
        } else if dy != 0 {
            r.tuneSteps(dy > 0 ? 1 : -1)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let r = radio else { return }
        let p = convert(event.locationInWindow, from: nil)
        r.setZoom(r.zoom * (1 + Double(event.magnification)), anchor: frequency(at: p.x))
    }

    override func keyDown(with event: NSEvent) {
        guard let r = radio else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: r.tuneSteps(event.modifierFlags.contains(.shift) ? -10 : -1)   // ←
        case 124: r.tuneSteps(event.modifierFlags.contains(.shift) ? 10 : 1)     // →
        case 126: r.setZoom(r.zoom * 1.5)                                        // ↑
        case 125: r.setZoom(r.zoom / 1.5)                                        // ↓
        default:
            if let ch = event.charactersIgnoringModifiers?.first, ch.isNumber || ch == "." {
                r.showFrequencyEntry = true
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let r = radio else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let f = r.snapped(frequency(at: p.x))
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Tune to \(FrequencyFormat.short(f))") { r.tune(to: f) })
        if r.canRetune {
            menu.addItem(ClosureMenuItem("Move tuner centre here") { r.setCenterFrequency(f) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add bookmark at VFO") { r.addBookmark() })
        menu.addItem(ClosureMenuItem("Auto range levels") { r.autoRange() })
        menu.addItem(ClosureMenuItem("Reset zoom") { r.resetView() })
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

struct MetalDisplay: NSViewRepresentable {
    let radio: RadioController
    let kind: DisplayKind

    final class Coordinator {
        var delegate: MTKViewDelegate?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 1)
        view.radio = radio
        view.kind = kind
        let delegate: MTKViewDelegate = kind == .spectrum ? SpectrumRenderer(radio: radio) : WaterfallRenderer(radio: radio)
        context.coordinator.delegate = delegate
        view.delegate = delegate
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {}
}
