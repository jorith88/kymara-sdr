import AppKit

/// With the compact unified toolbar AppKit ignores double-clicks on the title bar,
/// so perform the user's System Settings action ourselves.
enum TitleBarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let window = event.window, isInTitleBar(event, window) else { return event }
            performAction(on: window)
            return nil
        }
    }

    private static func isInTitleBar(_ event: NSEvent, _ window: NSWindow) -> Bool {
        let p = event.locationInWindow
        guard p.y > window.contentLayoutRect.maxY, p.y <= window.frame.height else { return false }
        // Leave toolbar buttons and other controls alone.
        guard let root = window.contentView?.superview else { return true }
        var view = root.hitTest(root.convert(p, from: nil))
        while let v = view {
            if v is NSControl { return false }
            view = v.superview
        }
        return true
    }

    private static func performAction(on window: NSWindow) {
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            window.zoom(nil)
        }
    }
}
