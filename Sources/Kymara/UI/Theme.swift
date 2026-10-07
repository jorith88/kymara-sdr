import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = appearance
    }
}

/// Theme of the spectrum and waterfall, independent of the app theme.
enum DisplayTheme: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    /// Resolves `auto` against the appearance the display is shown in.
    func isLight(in appearance: NSAppearance) -> Bool {
        switch self {
        case .auto: return appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        case .light: return true
        case .dark: return false
        }
    }

    func isLight(in scheme: ColorScheme) -> Bool {
        self == .auto ? scheme == .light : self == .light
    }
}

extension NSColor {
    /// Colour that resolves per appearance (light/dark).
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: .adaptive(light: light, dark: dark))
}

enum Theme {
    static let window = adaptive(.rgb(0.925, 0.93, 0.94), .rgb(0.085, 0.09, 0.105))
    static let panel = adaptive(.rgb(0.975, 0.977, 0.982), .rgb(0.12, 0.128, 0.148))
    static let panelHeader = adaptive(.rgb(0.89, 0.9, 0.915), .rgb(0.155, 0.165, 0.19))
    static let ribbon = adaptive(.rgb(0.955, 0.958, 0.965), .rgb(0.105, 0.112, 0.13))
    static let border = adaptive(.rgb(0, 0, 0, 0.12), .rgb(1, 1, 1, 0.08))
    static let accent = adaptive(.rgb(0.0, 0.47, 0.85), .rgb(0.25, 0.72, 1.0))
    static let lcd = adaptive(.rgb(0.86, 0.9, 0.93), .rgb(0.02, 0.03, 0.05))
    static let lcdText = adaptive(.rgb(0.05, 0.12, 0.22), .rgb(0.85, 0.95, 1.0))
    static let dim = adaptive(.rgb(0, 0, 0, 0.55), .rgb(1, 1, 1, 0.45))
    static let text = adaptive(.rgb(0, 0, 0, 0.85), .rgb(1, 1, 1, 0.85))
    /// Subtle fill for buttons and chips.
    static let fill = adaptive(.rgb(0, 0, 0, 0.06), .rgb(1, 1, 1, 0.07))
    static let fillStrong = adaptive(.rgb(0, 0, 0, 0.12), .rgb(1, 1, 1, 0.12))
    static let red = adaptive(.rgb(0.85, 0.15, 0.12), .rgb(1, 0.3, 0.25))
    static let green = adaptive(.rgb(0.1, 0.62, 0.22), .rgb(0.3, 0.9, 0.4))
    static let amber = adaptive(.rgb(0.8, 0.5, 0.0), .rgb(1, 0.75, 0.2))
}

/// Collapsible sidebar section in the SDR Console style.
struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self._expanded = AppStorage(wrappedValue: true, "panel.\(title)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.8)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.panelHeader)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

/// Label + control row.
struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .frame(width: 78, alignment: .leading)
            content
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Slider with a value readout.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        Row(label) {
            HStack(spacing: 6) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

/// Toggle-style button used for mode selection etc.
struct ChipButton: View {
    let title: String
    let selected: Bool
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .bold : .medium))
                .lineLimit(1)
                .fixedSize()
                .frame(width: width)
                .frame(minWidth: 34)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Theme.accent : Theme.fill)
                )
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
