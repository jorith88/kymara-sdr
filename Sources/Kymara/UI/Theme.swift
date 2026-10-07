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

/// Colours for the app chrome. Everything except the instrument display (`lcd`) maps to an AppKit
/// semantic colour, so the UI follows the user's accent colour, desktop tinting and Increase Contrast.
enum Theme {
    static let window = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panelHeader = Color(nsColor: .quaternarySystemFill)
    static let ribbon = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    /// Frequency read-out background: a deliberately instrument-like panel.
    static let lcd = adaptive(.rgb(0.86, 0.9, 0.93), .rgb(0.02, 0.03, 0.05))
    static let lcdText = adaptive(.rgb(0.05, 0.12, 0.22), .rgb(0.85, 0.95, 1.0))
    static let dim = Color(nsColor: .secondaryLabelColor)
    static let text = Color(nsColor: .labelColor)
    /// Subtle fill for buttons and chips.
    static let fill = Color(nsColor: .quaternarySystemFill)
    static let fillStrong = Color(nsColor: .tertiarySystemFill)
    static let red = Color(nsColor: .systemRed)
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
}

/// Collapsible sidebar section in the SDR Console style.
struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @AppStorage private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.panelHeader)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the section" : "Expands the section")
            .accessibilityAddTraits(.isHeader)

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

/// Label + control row. The label is also given to the control for VoiceOver, so controls inside
/// can keep their own labels hidden.
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 8) { content }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
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
                Group {
                    if let step {
                        Slider(value: $value, in: range, step: step)
                    } else {
                        Slider(value: $value, in: range)
                    }
                }
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
                Text(format(value))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}
