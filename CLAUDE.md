# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Kymara is a native macOS (Apple silicon, macOS 14+) SDR receiver for RTL-SDR dongles, modelled on SDR Console.
Swift Package, Swift 5 language mode (`swiftLanguageModes: [.v5]`), no Xcode project.

**Language:** the app (all UI text, messages, menus) and all documentation (README, CLAUDE.md, code comments, commit
messages) are always written in English, even when the conversation is in another language.

## Commands

```bash
swift build -c release                         # build (always use release: DSP loops are 10–50× slower in debug)
swift test -c release                          # all tests (SDRCoreTests + KymaraTests)
swift test -c release --filter RDSTests        # one test class
swift test -c release --filter DSPTests/testEngineWFMEndToEnd   # one test
./scripts/build-app.sh                         # → build/Kymara.app (bundles librtlsdr + libusb, ad-hoc signed)
swift run -c release Kymara                    # run unbundled (uses a separate UserDefaults domain "Kymara")
rtl_sdr -f 99000000 -s 2400000 -g 40 -n 19200000 out.cu8   # record raw IQ from the attached dongle for testing
```

`scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`. There is no linter.

## Architecture

Two modules: **SDRCore** (sources, DSP, audio, recording — no UI) and **Kymara** (SwiftUI app, Metal renderers, persistence).

**Data flow / threading.** An `IQSource` (`RTLSDRSource`, `RTLTCPSource`, `FileSource`, `DemoSource`) delivers interleaved u8 I/Q on its own thread and calls `DSPEngine.process(_:)` directly. `process` runs under `processLock`, takes a snapshot of `DSPConfig` and rebuilds filters when structural fields change (sample rate, mode → full rebuild; bandwidth → channel filter; FFT size → analyzer). `RadioController` (`@MainActor @Observable`) is the single source of UI state; every setting change calls `pushConfig()` which writes a fresh `DSPConfig`. Results flow back by polling, not callbacks: a 30 Hz timer reads `engine.status` (level, squelch, stereo, `RDSInfo`), and the Metal renderers pull from `SpectrumStore` each frame. Waterfall lines are queued in `SpectrumStore` and drained only by `WaterfallRenderer`.

**DSP chain** (`DSPEngine.rates(for:)`): u8→float, DC removal, spectrum analyzer tap → NCO mix by `vfoOffset` → stage-1 decimation to ~240 kHz → WFM: channel filter, FM discriminator, RDS decoder on the MPX, `StereoDecoder` (pilot PLL, decimates to audio) → others: stage-2 decimation to ~48 kHz, channel filter (`FFTFilter`, overlap-save, complex taps for SSB), demodulate, AGC. Audio rate is whatever falls out (48/51.2/… kHz); `AVAudioEngine` resamples. Filter passband edges per mode come from `DemodMode.filterEdges(bandwidth:)`, shared by DSP and the spectrum overlay.

**Tuning model.** `vfoFrequency` and `centerFrequency` (tuner LO) are absolute; the engine only sees `vfoOffset = vfo − center`. `RadioController.tune(to:follow:)` retunes the LO when the VFO leaves the usable band (jumps place the VFO at +fs/8 to avoid the DC spike). Any VFO change clears RDS (`vfoFrequency` didSet).

**Rendering.** Shaders are compiled at runtime from a string in `MetalContext.swift` (no offline Metal toolchain needed). Spectrum geometry is built on the CPU per frame (max-per-pixel resampling) into a triple-buffered vertex ring. The waterfall is an R16Float ring texture; a per-row frequency shift buffer keeps old lines aligned after retuning. `Axis` tick math is shared by the GPU grid and the SwiftUI labels. Spectrum and waterfall stay dark in the light theme by design.

**Persistence** (`Persistence.swift`). Settings and favourites live in UserDefaults under separate keys. `RadioSettings` has a hand-written tolerant `init(from:)`: when adding a setting, add the field to `RadioSettings`, a `read(.key, &field)` line there, and the load/save mapping in `RadioController.load()` / `currentSettings()`. Never make decoding of the whole blob depend on a new field.

**librtlsdr** is loaded with `dlopen` (`RTLSDRLibrary`), looking in the app's Frameworks folder first, then Homebrew. It is not a link-time dependency.

## Gotchas

- Don't pass the same array to a vDSP call as both input and `&output` — it traps at runtime (exclusivity). Use the `inPlace` helper in `ArrayInPlace.swift`.
- `AudioRingBuffer.read` returns silence *without consuming* until ~80 ms is buffered. A drain loop on a lower threshold never terminates (this once ate 400 GB of RAM in a test).
- The title bar uses `.windowToolbarStyle(.unifiedCompact)`, where AppKit ignores title-bar double-clicks; `TitleBarDoubleClick.swift` performs the system action instead. Remove it if the toolbar style changes.
- The terminal has no Screen Recording or event-posting permission, so `screencapture` and synthetic clicks fail. For visual checks, add a temporary in-app hook that grabs the window via `CGWindowListCreateImage` (looked up with `dlsym`), and remove it before committing.
- An RTL-SDR is usually attached to this machine; real FM stations with RDS are around 99.4, 101.6 and 102.3 MHz. The demo source has RDS on 100.0 and 101.2 MHz.
