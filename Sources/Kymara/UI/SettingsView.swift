import SwiftUI

/// The standard Settings window (⌘,) for app-wide preferences that are not changed while listening.
struct SettingsView: View {
    @Environment(RadioController.self) private var radio
    @Environment(Updater.self) private var updater
    @Environment(DXClusterStore.self) private var cluster

    var body: some View {
        @Bindable var radio = radio
        @Bindable var updater = updater
        @Bindable var cluster = cluster
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
            Section {
                Toggle("Show DX cluster spots", isOn: $cluster.isEnabled)
                Picker("Check for new spots", selection: $cluster.refreshInterval) {
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                }
                .disabled(!cluster.isEnabled)
                Picker("Keep spots for", selection: $cluster.maxAge) {
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1_800.0)
                    Text("1 hour").tag(3_600.0)
                }
                .disabled(!cluster.isEnabled)
            } header: {
                Text("DX Cluster")
            } footer: {
                Text("Spots come from \(cluster.providerName).com, a community DX cluster. Kymara only checks for new spots while its window is visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Include pre-releases", isOn: $updater.includePreReleases)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.isAvailable
                     ? "Pre-releases are beta versions that are still being tested."
                     : "Updates are only available in the installed app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!updater.isAvailable)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
