import SwiftUI
import AppKit

/// Context menu items for a station's callsign: copy it, or look it up on QRZ.com.
struct CallsignMenuItems: View {
    let callsign: String

    var body: some View {
        Button("Copy Callsign") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(callsign, forType: .string)
        }
        if let url = Self.qrzURL(callsign) {
            Button("Look Up on QRZ.com") { NSWorkspace.shared.open(url) }
        }
    }

    static func qrzURL(_ call: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let call = call.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty, let path = call.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.qrz.com/db/\(path)")
    }
}
