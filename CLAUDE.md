# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Kymara is a native macOS (Apple silicon, macOS 14+) SDR receiver for RTL-SDR dongles and SDRplay RSPs, modelled on SDR Console.
Swift Package, Swift 5 language mode (`swiftLanguageModes: [.v5]`), no Xcode project.

**Language:** the app (all UI text, messages, menus) and all documentation (README, CLAUDE.md, code comments, commit
messages) are always written in English, even when the conversation is in another language.

## Commands

```bash
swift build -c release                         # build (always use release: DSP loops are 10–50× slower in debug)
swift test -c release                          # all tests (SDRCoreTests + KymaraTests)
swift test -c release --filter RDSTests        # one test class
swift test -c release --filter DSPTests/testEngineWFMEndToEnd   # one test
KYMARA_HARDWARE_TESTS=1 swift test -c release --filter SDRplayTests   # include the test with an attached RSP
KYMARA_NETWORK_TESTS=1 swift test -c release --filter DXClusterTests  # include the test that fetches from dxheat.com
./scripts/build-app.sh                         # → build/Kymara.app (bundles librtlsdr + libusb, ad-hoc signed)
./scripts/make-dmg.sh [version]                # → build/Kymara-<version>.dmg (for GitHub releases)
swift run -c release Kymara                    # run unbundled (uses a separate UserDefaults domain "Kymara")
rtl_sdr -f 99000000 -s 2400000 -g 40 -n 19200000 out.cu8   # record raw IQ from the attached dongle for testing
```

`scripts/check-sdrplay-shim.sh` checks `Sources/CSDRplay/include/sdrplay_shim.h` against the installed SDRplay API headers (run after an API upgrade). `scripts/check-licenses.sh` checks that the README's bundled-libraries table
matches the librtlsdr, libusb and Sparkle versions in `build/Kymara.app` (run by `/release`). `scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`. There is no linter. Releases: `/release <version>` (`.claude/skills/release/SKILL.md`) tests, bumps the version, builds the DMG, tags and publishes a GitHub release.

## Architecture

Two modules: **SDRCore** (sources, DSP, audio, recording — no UI) and **Kymara** (SwiftUI app, Metal renderers, persistence), plus **CSDRplay** (C declarations of the SDRplay API types only).

**Data flow / threading.** An `IQSource` (`RTLSDRSource`, `SDRplaySource`, `RTLTCPSource`, `FileSource`, `DemoSource`) delivers interleaved I/Q as `IQSamples` (`.u8` for RTL-SDR, `.s16` for SDRplay and 16-bit/float WAV files) on its own thread and calls `DSPEngine.process(_:)` directly. I/Q recordings use the source's `sampleBits`. `process` runs under `processLock`, takes a snapshot of `DSPConfig` and rebuilds filters when structural fields change (sample rate, mode → full rebuild; bandwidth → channel filter; FFT size → analyzer). `RadioController` (`@MainActor @Observable`) is the single source of UI state; every setting change calls `pushConfig()` which writes a fresh `DSPConfig`. Results flow back by polling, not callbacks: a 30 Hz timer reads `engine.status` (level, squelch, stereo, `RDSInfo`), and the Metal renderers pull from `SpectrumStore` each frame. Waterfall lines are queued in `SpectrumStore` and drained only by `WaterfallRenderer`.

**DSP chain** (`DSPEngine.rates(for:)`): u8→float, DC removal, spectrum analyzer tap → NCO mix by `vfoOffset` → stage-1 decimation to ~240 kHz → WFM: channel filter, FM discriminator, RDS decoder on the MPX, `StereoDecoder` (pilot PLL, decimates to audio) → others: stage-2 decimation to ~48 kHz, channel filter (`FFTFilter`, overlap-save, complex taps for SSB), demodulate, auto notch (AM/SSB/DSB: a 1 s averaged FFT finds steady tones, narrow IIR notches remove them without latency), AGC. Audio rate is whatever falls out (48/51.2/… kHz); `AVAudioEngine` resamples. Filter passband edges per mode come from `DemodMode.filterEdges(bandwidth:)`, shared by DSP and the spectrum overlay.

**Tuning model.** `vfoFrequency` and `centerFrequency` (tuner LO) are absolute; the engine only sees `vfoOffset = vfo − center`. `RadioController.tune(to:follow:)` retunes the LO when the VFO leaves the usable band (jumps place the VFO at +fs/8 to avoid the DC spike). Any VFO change clears RDS (`vfoFrequency` didSet).

**Rendering.** Shaders are compiled at runtime from a string in `MetalContext.swift` (no offline Metal toolchain needed). Spectrum geometry is built on the CPU per frame (max-per-pixel resampling) into a triple-buffered vertex ring. The waterfall is an R16Float ring texture; a per-row frequency shift buffer keeps old lines aligned after retuning. `Axis` tick math is shared by the GPU grid and the SwiftUI labels. Spectrum and waterfall have their own theme setting (`DisplayTheme`: auto follows the app theme, or forced light/dark); the renderers resolve it against the view's effective appearance each frame (`SpectrumColors.light/.dark`; each `WaterfallPalette` has a light variant).

**UI conventions** (macOS HIG). `Theme` maps to AppKit semantic colours (accent = the user's accent colour); only
the frequency LCD has fixed colours. Every toolbar item also exists in the menu bar (display commands in the View
menu, radio commands in the Radio menu), and the toolbar is customizable (`.toolbar(id:)`). App-wide preferences
that are not touched while listening (appearance, display theme) live in the `Settings` scene (⌘,), not the sidebar.
Controls in a `Row` keep a real label (hidden with `.labelsHidden()`) so VoiceOver can read them; don't use
`Toggle("")`/`Picker("")`. Keep text ≥ 10 pt and gate animations on `accessibilityReduceMotion`.

**Persistence** (`Persistence.swift`). Settings and favourites live in UserDefaults under separate keys. `RadioSettings` has a hand-written tolerant `init(from:)`: when adding a setting, add the field to `RadioSettings`, a `read(.key, &field)` line there, and the load/save mapping in `RadioController.load()` / `currentSettings()`. Never make decoding of the whole blob depend on a new field.

**Updates** (`Updater.swift`) use Sparkle 2 (SwiftPM binary framework, copied into the bundle by `build-app.sh`).
The feed is `appcast.xml` on `main` (`SUFeedURL` in Info.plist); `scripts/update-appcast.sh` adds a signed item per
release, with pre-releases in the `beta` channel (`allowedChannels`, the "Include pre-releases" setting). The EdDSA
private key is in the login keychain; its public half is `SUPublicEDKey`. Never replace the key: installed copies
only accept updates signed with it. The updater is off when running unbundled (`swift run`).

**DX cluster** (`Sources/Kymara/DXCluster/`). `DXHeatProvider` (behind the `SpotProvider` protocol) reads
`https://dxheat.com/source/spots/`, the undocumented JSON endpoint DXHeat's own page polls: frequency in kHz as a
string, time as UTC "HH:MM" (the date field is ambiguous, so `resolveTime` takes the most recent such moment), mode
often missing. Its band (`b`) and mode (`m`) parameters had no effect when tested, so only the continent (`cdx`) is
sent and the rest is filtered locally. `DXClusterStore` (`@MainActor @Observable`, owned by `KymaraApp`, in the
environment) polls with exponential backoff on errors, merges duplicate reports (same call within the same kHz),
drops spots older than `maxAge`, pauses while the main window is not visible (`WindowVisibilityReader`), and saves its
settings under its own UserDefaults key (`DXClusterSettings`, tolerant decoding). `DXSpot.demodMode` maps the
reported mode (digital → USB; without one: comment words, the FT8/FT4 dial frequencies, else the sideband
convention). `DXClusterStore.isShown` (mode and continent filters) applies to both the spot list (`DXSpotsView`, a tab
of `SidePanel`) and the spectrum labels (`DXSpotOverlayLayer`, rows from `DXLabelLayout.place`). Tuning from a
favourite or spot goes through `RadioController.jump(to:)`, which only centres a zoomed view when the target is out of
view or the LO moves.

**librtlsdr** is loaded with `dlopen` (`RTLSDRLibrary`), looking in the app's Frameworks folder first, then Homebrew. It is not a link-time dependency.

**SDRplay API** (closed source, installed by the user, never bundled) is loaded with `dlopen` from `/usr/local/lib` (`SDRplayLibrary` in `SDRplaySource.swift`), using the struct declarations in `CSDRplay`. The API connection is opened once per process. Settings are written into the API's parameter structs and applied with `sdrplay_api_Update` reason flags (`SDRplayUpdate`); IF mode and RSPduo tuner changes need a restart (`configure` returns true). `SDRplayRatePlan` maps each output rate to ADC rate, IF, IF filter and decimation; `SDRplayModel` holds the per-model LNA tables and options.

## Gotchas

- Don't pass the same array to a vDSP call as both input and `&output` — it traps at runtime (exclusivity). Use the `inPlace` helper in `ArrayInPlace.swift`.
- `AudioRingBuffer.read` returns silence *without consuming* until ~80 ms is buffered. A drain loop on a lower threshold never terminates (this once ate 400 GB of RAM in a test).
- The title bar uses `.windowToolbarStyle(.unifiedCompact)`, where AppKit ignores title-bar double-clicks; `TitleBarDoubleClick.swift` performs the system action instead. Remove it if the toolbar style changes.
- The terminal has Screen Recording permission: `screencapture -x -o -l <windowID>` grabs the app window (get the ID from `CGWindowListCopyWindowInfo`, owner "Kymara"). Synthetic clicks are untested; to get the app into a state (start the radio, force an appearance), add a temporary env-var hook in `RadioController.init` and remove it before committing.
- The SDRplay API service keeps a device claimed for a while when the app is killed instead of quit (a test hook should quit with `NSApp.terminate`), so the next start reports "No SDRplay device found". `SDRplayTests.testStreamsFromAttachedDevice` streams from an attached RSP; it only runs with `KYMARA_HARDWARE_TESTS=1` (and is skipped without a free device).
- An RTL-SDR and an SDRplay RSP1 are usually attached to this machine; real FM stations with RDS are around 99.4, 101.6 and 102.3 MHz. The demo source has RDS on 100.0 and 101.2 MHz.
