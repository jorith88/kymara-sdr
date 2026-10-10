import SwiftUI
import AppKit
import SDRCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        TitleBarDoubleClick.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct KymaraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var radio = RadioController()
    @State private var updater = Updater()
    @State private var dxCluster = DXClusterStore()

    var body: some Scene {
        Window("Kymara", id: "main") {
            ContentView()
                .environment(radio)
                .environment(dxCluster)
                .frame(minWidth: 1180, minHeight: 680)
                .onAppear {
                    let radio = radio
                    if CommandLine.arguments.contains("--demo") { radio.sourceKind = .demo }
                    if CommandLine.arguments.contains("--start") { radio.start() }
                    appDelegate.onTerminate = {
                        MainActor.assumeIsolated {
                            radio.stop()
                            radio.saveNow()
                        }
                    }
                }
        }
        .defaultSize(width: 1560, height: 940)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // Display commands belong in the standard View menu, above Show/Customize Toolbar.
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { radio.setZoom(radio.zoom * 2) }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("Zoom Out") { radio.setZoom(radio.zoom / 2) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size") { radio.resetView() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Auto Range") { radio.autoRange() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Toggle("Show RDS Panel", isOn: $radio.showRDSPanel)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(radio.mode != .wfm || !radio.rdsEnabled)
                Toggle("Show Favourites", isOn: $radio.showBookmarks)
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
            }
            CommandMenu("Radio") {
                Button(radio.isRunning ? "Stop" : "Start") { radio.toggleRunning() }
                    .keyboardShortcut("r")
                Button("Enter Frequency…") { radio.showFrequencyEntry = true }
                    .keyboardShortcut("f")
                Divider()
                // Toggles rather than buttons so the menu shows a checkmark on the current mode.
                ForEach(Array(DemodMode.allCases.enumerated()), id: \.element) { i, m in
                    Toggle(m.rawValue, isOn: Binding(get: { radio.mode == m }, set: { if $0 { radio.mode = m } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Tune Up") { radio.tuneSteps(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Tune Down") { radio.tuneSteps(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Add to Favourites") { radio.addBookmark() }
                    .keyboardShortcut("d")
                Toggle("Mute", isOn: $radio.muted)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Toggle("Auto Notch", isOn: $radio.autoNotch)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!radio.mode.supportsAutoNotch)
                Divider()
                Button(radio.recordingAudio ? "Stop Audio Recording" : "Record Audio") { radio.toggleAudioRecording() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(radio.recordingIQ ? "Stop I/Q Recording" : "Record I/Q") { radio.toggleIQRecording() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show Recordings in Finder") { radio.showRecordingsInFinder() }
            }
        }

        Settings {
            SettingsView()
                .environment(radio)
                .environment(updater)
        }
    }
}
