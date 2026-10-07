import SwiftUI

/// The standard Settings window (⌘,) for app-wide preferences that are not changed while listening.
struct SettingsView: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        Form {
            Section {
                Picker("Appearance", selection: $radio.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Spectrum and waterfall", selection: $radio.displayTheme) {
                    ForEach(DisplayTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Auto gives the spectrum and waterfall the same appearance as the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recordings") {
                LabeledContent("Folder") {
                    Text(RadioController.recordingsFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Show in Finder") { radio.showRecordingsInFinder() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
