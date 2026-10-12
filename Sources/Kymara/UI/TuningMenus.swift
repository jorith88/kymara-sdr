import SwiftUI

/// The favourites, a submenu per group, for the Favourites menu.
/// Toggles rather than buttons so the menu shows a checkmark on the favourite the radio is tuned to.
struct FavouriteMenuItems: View {
    let radio: RadioController

    var body: some View {
        ForEach(Bookmark.grouped(radio.bookmarks), id: \.0) { group, items in
            Menu(group) {
                ForEach(items) { b in
                    Toggle(b.name, isOn: Binding(
                        get: { abs(b.frequency - radio.vfoFrequency) < 1 },
                        set: { _ in radio.recall(b) }
                    ))
                }
            }
        }
    }
}

/// The amateur bands, with a checkmark on the band the VFO is in.
struct BandMenuItems: View {
    let radio: RadioController

    var body: some View {
        ForEach(AmateurBand.all) { band in
            Toggle(band.name, isOn: Binding(
                get: { radio.currentBand == band },
                set: { _ in radio.selectBand(band) }
            ))
        }
    }
}
