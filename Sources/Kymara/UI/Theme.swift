import SwiftUI

enum Theme {
    static let window = Color(red: 0.085, green: 0.09, blue: 0.105)
    static let panel = Color(red: 0.12, green: 0.128, blue: 0.148)
    static let panelHeader = Color(red: 0.155, green: 0.165, blue: 0.19)
    static let ribbon = Color(red: 0.105, green: 0.112, blue: 0.13)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.25, green: 0.72, blue: 1.0)
    static let lcd = Color(red: 0.02, green: 0.03, blue: 0.05)
    static let lcdText = Color(red: 0.85, green: 0.95, blue: 1.0)
    static let dim = Color.white.opacity(0.45)
    static let red = Color(red: 1, green: 0.3, blue: 0.25)
    static let green = Color(red: 0.3, green: 0.9, blue: 0.4)
    static let amber = Color(red: 1, green: 0.75, blue: 0.2)
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
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Theme.accent : Color.white.opacity(0.07))
                )
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(selected ? 0 : 0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
