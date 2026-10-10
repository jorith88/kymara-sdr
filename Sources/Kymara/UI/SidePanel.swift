import SwiftUI

enum SidePanelTab: String, CaseIterable, Identifiable, Codable {
    case favourites = "Favourites"
    case dxSpots = "DX Spots"
    var id: String { rawValue }
}

/// The right-hand panel: favourites and DX cluster spots, one at a time.
struct SidePanel: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        VStack(spacing: 0) {
            Picker("Side Panel", selection: $radio.sidePanelTab) {
                ForEach(SidePanelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Theme.panelHeader)

            Group {
                switch radio.sidePanelTab {
                case .favourites: BookmarksView()
                case .dxSpots: DXSpotsView()
                }
            }
            // Keeps the tab picker at the top when the content (an empty state) is short.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
    }
}
