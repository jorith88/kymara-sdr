import SwiftUI
import AppKit

/// Vertical split between spectrum and waterfall. Replaces `VSplitView`, whose 1 pt divider is
/// hard to grab: the visible line stays 1 pt, but a transparent handle around it takes the drag.
struct SpectrumSplit<Top: View, Bottom: View>: View {
    /// Spectrum share of the available height, so the split scales with the window.
    @Binding var fraction: Double
    var minTop: CGFloat = 140
    var minBottom: CGFloat = 100
    /// Height of the grab zone, centred on the divider line.
    var handleHeight: CGFloat = 10
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.height - 1, 0)
            let topHeight = clampedTop(CGFloat(fraction) * available, available: available)
            VStack(spacing: 0) {
                top.frame(height: topHeight)
                Rectangle().fill(Theme.border).frame(height: 1)
                bottom.frame(maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                SplitHandle(
                    onDrag: { dy in
                        let start = dragStartHeight ?? topHeight
                        dragStartHeight = start
                        fraction = Double(clampedTop(start + dy, available: available) / max(available, 1))
                    },
                    onEnd: { dragStartHeight = nil }
                )
                .frame(height: handleHeight)
                .offset(y: topHeight + 0.5 - handleHeight / 2)
            }
        }
    }

    private func clampedTop(_ h: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(available - minBottom, minTop)
        return min(max(h, minTop), upper)
    }
}

/// Transparent AppKit view that shows the resize cursor and reports the vertical drag distance
/// (positive = downwards) since mouse-down. An NSView rather than a SwiftUI gesture, so it wins
/// hit-testing over the Metal views underneath and owns its cursor.
private struct SplitHandle: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startY: CGFloat = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
        }

        override func mouseDragged(with event: NSEvent) {
            NSCursor.resizeUpDown.set()
            // Window coordinates have y pointing up.
            onDrag?(startY - event.locationInWindow.y)
        }

        override func mouseUp(with event: NSEvent) {
            onEnd?()
            window?.invalidateCursorRects(for: self)
        }
    }
}
