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

    var body: some Scene {
        Window("Kymara", id: "main") {
            ContentView()
                .environment(radio)
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
            CommandMenu("Radio") {
                Button(radio.isRunning ? "Stop" : "Start") { radio.toggleRunning() }
                    .keyboardShortcut("r")
                Button("Enter Frequency…") { radio.showFrequencyEntry = true }
                    .keyboardShortcut("f")
                Divider()
                ForEach(Array(DemodMode.allCases.enumerated()), id: \.element) { i, m in
                    Button(m.rawValue) { radio.mode = m }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Tune Up") { radio.tuneSteps(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Tune Down") { radio.tuneSteps(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Zoom In") { radio.setZoom(radio.zoom * 2) }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("Zoom Out") { radio.setZoom(radio.zoom / 2) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Reset Zoom") { radio.resetView() }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
                Toggle("Show RDS Panel", isOn: $radio.showRDSPanel)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Add Favourite") { radio.addBookmark() }
                    .keyboardShortcut("d")
                Button(radio.muted ? "Unmute" : "Mute") { radio.muted.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button(radio.recordingAudio ? "Stop Audio Recording" : "Record Audio") { radio.toggleAudioRecording() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(radio.recordingIQ ? "Stop I/Q Recording" : "Record I/Q") { radio.toggleIQRecording() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}
